const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const crypto_random = std.crypto.random;

const peer_mod = @import("peer.zig");
const payload_mod = @import("payload.zig");

const Peer = peer_mod.Peer;
const PrivateKey = ec.PrivateKey;
const HttpRequestPayload = payload_mod.HttpRequestPayload;
const Header = payload_mod.Header;

pub const AuthResponse = struct {
    status: u16,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AuthResponse) void {
        self.allocator.free(self.body);
    }
};

pub const AuthFetch = struct {
    allocator: std.mem.Allocator,
    private_key: PrivateKey,
    peers: std.StringHashMap(Peer),

    pub fn init(allocator: std.mem.Allocator, private_key: PrivateKey) AuthFetch {
        return .{
            .allocator = allocator,
            .private_key = private_key,
            .peers = std.StringHashMap(Peer).init(allocator),
        };
    }

    pub fn deinit(self: *AuthFetch) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.peers.deinit();
    }

    pub fn get(self: *AuthFetch, url: []const u8) !AuthResponse {
        return self.doRequest("GET", url, null, null);
    }

    pub fn postJson(self: *AuthFetch, url: []const u8, body: []const u8) !AuthResponse {
        const headers = [_]Header{
            .{ .name = "content-type", .value = "application/json" },
        };
        const effective_body: []const u8 = if (body.len == 0) "{}" else body;
        return self.doRequest("POST", url, effective_body, &headers);
    }

    pub fn postBinary(self: *AuthFetch, url: []const u8, body: []const u8) !AuthResponse {
        const headers = [_]Header{
            .{ .name = "content-type", .value = "application/octet-stream" },
        };
        return self.doRequest("POST", url, body, &headers);
    }

    fn doRequest(
        self: *AuthFetch,
        method: []const u8,
        url: []const u8,
        body: ?[]const u8,
        headers: ?[]const Header,
    ) !AuthResponse {
        const parsed = try parseUrl(url);

        // Extract origin (scheme://host[:port])
        const origin = try self.buildOrigin(parsed);
        defer self.allocator.free(origin);

        // Get or create peer for this origin
        const p = try self.getOrCreatePeer(origin);

        // Generate request ID
        var request_id: [payload_mod.request_id_len]u8 = undefined;
        crypto_random.bytes(&request_id);

        // Prepend "?" to query string to match Go/TS URL.search behavior
        const search_with_prefix: ?[]const u8 = if (parsed.query_str) |q| blk: {
            const prefixed = try self.allocator.alloc(u8, q.len + 1);
            prefixed[0] = '?';
            @memcpy(prefixed[1..], q);
            break :blk prefixed;
        } else null;
        defer if (search_with_prefix) |s| self.allocator.free(s);

        // Build payload
        const req_payload = HttpRequestPayload{
            .request_id = request_id,
            .method = method,
            .path = parsed.path_str orelse "/",
            .search = search_with_prefix,
            .headers = headers orelse &.{},
            .body = body,
        };

        // Serialize
        const serialized = try payload_mod.serializeRequest(self.allocator, req_payload);
        defer self.allocator.free(serialized);

        // Send via peer
        var result = try p.sendMessage(method, origin, serialized);

        // Deserialize the response payload
        const resp = try payload_mod.deserializeResponse(self.allocator, result.body);
        defer {
            for (resp.headers) |h| {
                self.allocator.free(h.name);
                self.allocator.free(h.value);
            }
            self.allocator.free(resp.headers);
        }
        // Free the raw result body now that we've deserialized
        result.allocator.free(result.body);

        // Copy the response body since we're freeing the deserialized result
        const resp_body = if (resp.body) |b|
            try self.allocator.dupe(u8, b)
        else
            try self.allocator.alloc(u8, 0);

        // Free the deserialized body now that we've copied it
        if (resp.body) |b| self.allocator.free(b);

        return .{
            .status = resp.status,
            .body = resp_body,
            .allocator = self.allocator,
        };
    }

    fn getOrCreatePeer(self: *AuthFetch, origin: []const u8) !*Peer {
        if (self.peers.getPtr(origin)) |p| {
            return p;
        }

        const owned_origin = try self.allocator.dupe(u8, origin);
        errdefer self.allocator.free(owned_origin);

        const p = try Peer.init(self.allocator, self.private_key, owned_origin);
        try self.peers.put(owned_origin, p);
        return self.peers.getPtr(owned_origin).?;
    }

    const ParsedUrl = struct {
        scheme: []const u8,
        host: []const u8,
        port: ?u16,
        path_str: ?[]const u8,
        query_str: ?[]const u8,
    };

    fn parseUrl(url: []const u8) !ParsedUrl {
        const uri = try std.Uri.parse(url);

        const scheme = if (uri.scheme.len > 0) uri.scheme else "https";

        const host = if (uri.host) |h| switch (h) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        } else return error.MissingHost;

        const path_str: ?[]const u8 = if (uri.path.isEmpty())
            null
        else switch (uri.path) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };

        const query_str: ?[]const u8 = if (uri.query) |q| blk: {
            const raw = switch (q) {
                .raw => |r| r,
                .percent_encoded => |p| p,
            };
            break :blk if (raw.len > 0) raw else null;
        } else null;

        return .{
            .scheme = scheme,
            .host = host,
            .port = uri.port,
            .path_str = path_str,
            .query_str = query_str,
        };
    }

    fn buildOrigin(self: *AuthFetch, parsed: ParsedUrl) ![]const u8 {
        if (parsed.port) |port| {
            return std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}", .{ parsed.scheme, parsed.host, port });
        }
        return std.fmt.allocPrint(self.allocator, "{s}://{s}", .{ parsed.scheme, parsed.host });
    }
};

test "AuthFetch init and deinit" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();
    var af = AuthFetch.init(allocator, priv);
    defer af.deinit();

    try std.testing.expectEqual(@as(u32, 0), af.peers.count());
}

test "parseUrl basic" {
    const parsed = try AuthFetch.parseUrl("https://example.com/api/v1/test?q=hello");
    try std.testing.expectEqualStrings("https", parsed.scheme);
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expect(parsed.port == null);
    try std.testing.expectEqualStrings("/api/v1/test", parsed.path_str.?);
    try std.testing.expectEqualStrings("q=hello", parsed.query_str.?);
}

test "parseUrl with port" {
    const parsed = try AuthFetch.parseUrl("http://localhost:8080/health");
    try std.testing.expectEqualStrings("http", parsed.scheme);
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port.?);
    try std.testing.expectEqualStrings("/health", parsed.path_str.?);
    try std.testing.expect(parsed.query_str == null);
}

test "parseUrl no path" {
    const parsed = try AuthFetch.parseUrl("https://example.com");
    try std.testing.expectEqualStrings("https", parsed.scheme);
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expect(parsed.path_str == null);
    try std.testing.expect(parsed.query_str == null);
}

test "buildOrigin without port" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();
    var af = AuthFetch.init(allocator, priv);
    defer af.deinit();

    const parsed = try AuthFetch.parseUrl("https://example.com/api/test");
    const origin = try af.buildOrigin(parsed);
    defer allocator.free(origin);
    try std.testing.expectEqualStrings("https://example.com", origin);
}

test "buildOrigin with port" {
    const allocator = std.testing.allocator;
    const priv = try PrivateKey.generate();
    var af = AuthFetch.init(allocator, priv);
    defer af.deinit();

    const parsed = try AuthFetch.parseUrl("http://localhost:3000/api");
    const origin = try af.buildOrigin(parsed);
    defer allocator.free(origin);
    try std.testing.expectEqualStrings("http://localhost:3000", origin);
}
