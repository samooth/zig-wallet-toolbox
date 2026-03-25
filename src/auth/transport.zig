const std = @import("std");
const bsvz = @import("bsvz");
const message_mod = @import("message.zig");
const payload_mod = @import("payload.zig");
const http_client = @import("../http/client.zig");
const hex = bsvz.primitives.hex;

const AuthMessage = message_mod.AuthMessage;
const MessageType = message_mod.MessageType;

pub const SimplifiedHttpTransport = struct {
    base_url: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) SimplifiedHttpTransport {
        return .{
            .base_url = base_url,
            .allocator = allocator,
        };
    }

    /// Send a handshake message (initialRequest/initialResponse) to /.well-known/auth.
    /// Returns the server's parsed response.
    pub fn sendHandshake(self: *SimplifiedHttpTransport, msg: AuthMessage) !AuthMessage.Parsed {
        const json_body = try msg.toJson(self.allocator);
        defer self.allocator.free(json_body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/.well-known/auth", .{self.base_url});
        defer self.allocator.free(url);

        const result = try http_client.postBinary(
            self.allocator,
            url,
            json_body,
            &.{.{ .name = "Content-Type", .value = "application/json" }},
        );
        defer self.allocator.free(result.body);

        if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
            return error.HandshakeFailed;
        }

        return AuthMessage.fromJson(self.allocator, result.body);
    }

    /// Send a general authenticated message.
    /// Deserializes the payload to extract the real HTTP request, adds x-bsv-auth-*
    /// headers, performs the request, then wraps the response as an AuthMessage.
    pub fn sendGeneral(self: *SimplifiedHttpTransport, msg: AuthMessage, method: []const u8, target_url: []const u8) !GeneralResponse {
        _ = method;

        // Decode the base64 payload to get the serialized request
        const payload_b64 = msg.payload orelse return error.MissingPayload;
        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(payload_b64) catch return error.InvalidPayload;
        const payload_bytes = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(payload_bytes);
        std.base64.standard.Decoder.decode(payload_bytes, payload_b64) catch return error.InvalidPayload;

        // Deserialize to get the actual HTTP request details
        const req = try payload_mod.deserializeRequest(self.allocator, payload_bytes);
        defer {
            self.allocator.free(req.method);
            if (req.path) |p| self.allocator.free(p);
            if (req.search) |s| self.allocator.free(s);
            for (req.headers) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            self.allocator.free(req.headers);
            if (req.body) |b| self.allocator.free(b);
        }

        // Build the request ID as base64 for the header
        const req_id_b64_len = std.base64.standard.Encoder.calcSize(payload_mod.request_id_len);
        var req_id_b64_buf: [48]u8 = undefined; // 32 bytes -> 44 base64 chars, use 48 for safety
        _ = std.base64.standard.Encoder.encode(req_id_b64_buf[0..req_id_b64_len], &req.request_id);

        // Hex-encode the signature
        const sig_b64 = msg.signature orelse "";
        const sig_decoded_len = std.base64.standard.Decoder.calcSizeForSlice(sig_b64) catch 0;
        const sig_bytes = try self.allocator.alloc(u8, sig_decoded_len);
        defer self.allocator.free(sig_bytes);
        if (sig_decoded_len > 0) {
            std.base64.standard.Decoder.decode(sig_bytes, sig_b64) catch {};
        }
        var sig_hex_buf: [144]u8 = undefined; // max 72 DER bytes -> 144 hex chars
        const sig_hex = hex.encodeLower(sig_bytes, &sig_hex_buf) catch "";

        // Build the full URL
        const path_part = req.path orelse "";
        const search_part = req.search orelse "";
        const full_url = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ target_url, path_part, search_part });
        defer self.allocator.free(full_url);

        // Build auth headers plus original request headers
        const auth_header_count = 6;
        const total_headers = auth_header_count + req.headers.len;
        const extra_headers = try self.allocator.alloc(std.http.Header, total_headers);
        defer self.allocator.free(extra_headers);

        extra_headers[0] = .{ .name = "x-bsv-auth-version", .value = msg.version };
        extra_headers[1] = .{ .name = "x-bsv-auth-identity-key", .value = msg.identity_key };
        extra_headers[2] = .{ .name = "x-bsv-auth-nonce", .value = msg.nonce orelse "" };
        extra_headers[3] = .{ .name = "x-bsv-auth-your-nonce", .value = msg.your_nonce orelse "" };
        extra_headers[4] = .{ .name = "x-bsv-auth-signature", .value = sig_hex };
        extra_headers[5] = .{ .name = "x-bsv-auth-request-id", .value = req_id_b64_buf[0..req_id_b64_len] };

        for (req.headers, 0..) |h, i| {
            extra_headers[auth_header_count + i] = .{ .name = h.name, .value = h.value };
        }

        // Determine HTTP method
        const http_method = parseHttpMethod(req.method);

        // Perform the request
        const result = try doGeneralRequest(
            self.allocator,
            http_method,
            full_url,
            extra_headers,
            req.body,
        );

        return .{
            .status = result.status,
            .body = result.body,
            .allocator = self.allocator,
        };
    }
};

pub const GeneralResponse = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GeneralResponse) void {
        self.allocator.free(self.body);
    }
};

fn parseHttpMethod(method_str: []const u8) std.http.Method {
    const map = std.StaticStringMap(std.http.Method).initComptime(.{
        .{ "GET", .GET },
        .{ "POST", .POST },
        .{ "PUT", .PUT },
        .{ "DELETE", .DELETE },
        .{ "PATCH", .PATCH },
        .{ "HEAD", .HEAD },
        .{ "OPTIONS", .OPTIONS },
    });
    return map.get(method_str) orelse .GET;
}

fn doGeneralRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    extra_headers: []const std.http.Header,
    body: ?[]const u8,
) !http_client.BinaryResponse {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(method, uri, .{
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    if (body) |b| {
        try req.sendBodyComplete(@constCast(b));
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8192]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);

    var transfer_buf: [8192]u8 = undefined;
    var body_reader = resp.reader(&transfer_buf);
    const resp_body = try body_reader.allocRemaining(allocator, std.io.Limit.limited(4 * 1024 * 1024));

    return .{
        .status = resp.head.status,
        .body = resp_body,
    };
}
