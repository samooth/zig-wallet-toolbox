const std = @import("std");

/// HTTP response with parsed JSON body.
///
/// Ownership: `body` (and `raw`) borrow from an internal parse arena that is
/// released by `deinit()`. Callers must either consume the data before calling
/// `deinit()` or deep-copy it out (see `src/http/json_rpc.zig deepCopyValue`).
pub const JsonResponse = struct {
    status: std.http.Status,
    body: std.json.Value,
    raw: []u8,
    parsed: ?std.json.Parsed(std.json.Value) = null,

    /// Free all memory backing `body` and `raw`.
    pub fn deinit(self: *JsonResponse) void {
        if (self.parsed) |*p| p.deinit();
        self.parsed = null;
        self.body = .null;
        self.raw = &.{};
    }
};

pub const BinaryResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn doRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    method: std.http.Method,
    url: []const u8,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) !BinaryResponse {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);

    var req = try client.request(method, uri, .{
        .extra_headers = extra_headers,
    });
    defer req.deinit();

    if (payload) |body| {
        try req.sendBodyComplete(@constCast(body));
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [8192]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);

    var transfer_buf: [8192]u8 = undefined;

    // Handle decompression for gzip/deflate responses (CDNs like Cloudflare).
    // Flate requires buffer >= max_window_len (history_len * 2 = 65536).
    var decompress: std.http.Decompress = undefined;
    const decompress_buf = try allocator.alloc(u8, 1 << 16); // 64KB
    defer allocator.free(decompress_buf);
    const body_reader = resp.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    const body = try body_reader.allocRemaining(allocator, std.Io.Limit.limited(4 * 1024 * 1024));

    return .{
        .status = resp.head.status,
        .body = body,
    };
}

fn parseJson(allocator: std.mem.Allocator, raw: []u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
}

pub fn getJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !JsonResponse {
    const result = try doRequest(allocator, io, .GET, url, extra_headers, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.body, .{});
    return .{
        .status = result.status,
        .body = parsed.value,
        .raw = result.body,
        .parsed = parsed,
    };
}

pub fn postJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body_bytes: []const u8,
    extra_headers: []const std.http.Header,
) !JsonResponse {
    const result = try doRequest(allocator, io, .POST, url, extra_headers, body_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.body, .{});
    return .{
        .status = result.status,
        .body = parsed.value,
        .raw = result.body,
        .parsed = parsed,
    };
}

pub fn getBinary(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !BinaryResponse {
    return doRequest(allocator, io, .GET, url, extra_headers, null);
}

pub fn postBinary(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body_bytes: []const u8,
    extra_headers: []const std.http.Header,
) !BinaryResponse {
    return doRequest(allocator, io, .POST, url, extra_headers, body_bytes);
}
