const std = @import("std");

pub const JsonResponse = struct {
    status: std.http.Status,
    body: std.json.Value,
    raw: []u8,
};

pub const BinaryResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn doRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) !BinaryResponse {
    var client: std.http.Client = .{ .allocator = allocator };
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
    var body_reader = resp.reader(&transfer_buf);
    const body = try body_reader.allocRemaining(allocator, std.io.Limit.limited(4 * 1024 * 1024));

    return .{
        .status = resp.head.status,
        .body = body,
    };
}

fn parseJson(allocator: std.mem.Allocator, raw: []u8) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    return parsed.value;
}

pub fn getJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !JsonResponse {
    const result = try doRequest(allocator, .GET, url, extra_headers, null);
    const value = try parseJson(allocator, result.body);
    return .{
        .status = result.status,
        .body = value,
        .raw = result.body,
    };
}

pub fn postJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    body_bytes: []const u8,
    extra_headers: []const std.http.Header,
) !JsonResponse {
    const result = try doRequest(allocator, .POST, url, extra_headers, body_bytes);
    const value = try parseJson(allocator, result.body);
    return .{
        .status = result.status,
        .body = value,
        .raw = result.body,
    };
}

pub fn getBinary(
    allocator: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !BinaryResponse {
    return doRequest(allocator, .GET, url, extra_headers, null);
}

pub fn postBinary(
    allocator: std.mem.Allocator,
    url: []const u8,
    body_bytes: []const u8,
    extra_headers: []const std.http.Header,
) !BinaryResponse {
    return doRequest(allocator, .POST, url, extra_headers, body_bytes);
}
