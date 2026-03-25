const std = @import("std");
const bsvz = @import("bsvz");
const VarInt = bsvz.primitives.varint.VarInt;

pub const request_id_len = 32;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequestPayload = struct {
    request_id: [request_id_len]u8,
    method: []const u8,
    path: ?[]const u8,
    search: ?[]const u8,
    headers: []const Header,
    body: ?[]const u8,
};

pub const HttpResponsePayload = struct {
    request_id: [request_id_len]u8,
    status: u16,
    headers: []const Header,
    body: ?[]const u8,
};

const negative_one: [9]u8 = .{0xff} ** 9;

const ByteList = std.ArrayList(u8);

fn appendVarint(list: *ByteList, allocator: std.mem.Allocator, value: u64) !void {
    var buf: [9]u8 = undefined;
    const len = try VarInt.encodeInto(&buf, value);
    try list.appendSlice(allocator, buf[0..len]);
}

fn appendNegativeOne(list: *ByteList, allocator: std.mem.Allocator) !void {
    try list.appendSlice(allocator, &negative_one);
}

fn appendString(list: *ByteList, allocator: std.mem.Allocator, s: []const u8) !void {
    try appendVarint(list, allocator, @intCast(s.len));
    try list.appendSlice(allocator, s);
}

fn appendOptionalBytes(list: *ByteList, allocator: std.mem.Allocator, data: ?[]const u8) !void {
    if (data) |d| {
        if (d.len == 0) {
            try appendNegativeOne(list, allocator);
        } else {
            try appendVarint(list, allocator, @intCast(d.len));
            try list.appendSlice(allocator, d);
        }
    } else {
        try appendNegativeOne(list, allocator);
    }
}

fn readFixedBytes(data: []const u8, pos: *usize, comptime n: usize) ![n]u8 {
    if (pos.* + n > data.len) return error.EndOfStream;
    const result: [n]u8 = data[pos.*..][0..n].*;
    pos.* += n;
    return result;
}

fn readVarint(data: []const u8, pos: *usize) !u64 {
    if (pos.* >= data.len) return error.EndOfStream;
    const vi = try VarInt.parse(data[pos.*..]);
    pos.* += vi.len;
    return vi.value;
}

const max_uint64: u64 = std.math.maxInt(u64);

fn isNegativeOne(val: u64) bool {
    return val == max_uint64;
}

fn readString(allocator: std.mem.Allocator, data: []const u8, pos: *usize) ![]const u8 {
    const len = try readVarint(data, pos);
    if (isNegativeOne(len) or len == 0) return "";
    const end = pos.* + @as(usize, @intCast(len));
    if (end > data.len) return error.EndOfStream;
    const result = try allocator.dupe(u8, data[pos.*..end]);
    pos.* = end;
    return result;
}

fn readOptionalBytes(allocator: std.mem.Allocator, data: []const u8, pos: *usize) !?[]const u8 {
    const len = try readVarint(data, pos);
    if (isNegativeOne(len) or len == 0) return null;
    const end = pos.* + @as(usize, @intCast(len));
    if (end > data.len) return error.EndOfStream;
    const result = try allocator.dupe(u8, data[pos.*..end]);
    pos.* = end;
    return result;
}

pub fn serializeRequest(allocator: std.mem.Allocator, payload: HttpRequestPayload) ![]u8 {
    var list: ByteList = .empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &payload.request_id);
    try appendString(&list, allocator, payload.method);
    try appendOptionalBytes(&list, allocator, payload.path);
    try appendOptionalBytes(&list, allocator, payload.search);

    try appendVarint(&list, allocator, @intCast(payload.headers.len));
    for (payload.headers) |header| {
        try appendString(&list, allocator, header.name);
        try appendString(&list, allocator, header.value);
    }

    try appendOptionalBytes(&list, allocator, payload.body);

    return list.toOwnedSlice(allocator);
}

pub fn deserializeRequest(allocator: std.mem.Allocator, data: []const u8) !HttpRequestPayload {
    var pos: usize = 0;

    const request_id = try readFixedBytes(data, &pos, request_id_len);
    const method = try readString(allocator, data, &pos);
    const path = try readOptionalBytes(allocator, data, &pos);
    const search = try readOptionalBytes(allocator, data, &pos);

    const num_headers = try readVarint(data, &pos);
    var headers: std.ArrayList(Header) = .empty;
    errdefer headers.deinit(allocator);

    if (!isNegativeOne(num_headers)) {
        try headers.ensureTotalCapacity(allocator, @intCast(num_headers));
        for (0..@intCast(num_headers)) |_| {
            const name = try readString(allocator, data, &pos);
            const value = try readString(allocator, data, &pos);
            headers.appendAssumeCapacity(.{ .name = name, .value = value });
        }
    }

    const body = try readOptionalBytes(allocator, data, &pos);

    return .{
        .request_id = request_id,
        .method = method,
        .path = path,
        .search = search,
        .headers = try headers.toOwnedSlice(allocator),
        .body = body,
    };
}

pub fn serializeResponse(allocator: std.mem.Allocator, payload: HttpResponsePayload) ![]u8 {
    var list: ByteList = .empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &payload.request_id);
    try appendVarint(&list, allocator, @intCast(payload.status));

    try appendVarint(&list, allocator, @intCast(payload.headers.len));
    for (payload.headers) |header| {
        try appendString(&list, allocator, header.name);
        try appendString(&list, allocator, header.value);
    }

    try appendOptionalBytes(&list, allocator, payload.body);

    return list.toOwnedSlice(allocator);
}

pub fn deserializeResponse(allocator: std.mem.Allocator, data: []const u8) !HttpResponsePayload {
    var pos: usize = 0;

    const request_id = try readFixedBytes(data, &pos, request_id_len);
    const status_raw = try readVarint(data, &pos);

    const num_headers = try readVarint(data, &pos);
    var headers: std.ArrayList(Header) = .empty;
    errdefer headers.deinit(allocator);

    if (!isNegativeOne(num_headers)) {
        try headers.ensureTotalCapacity(allocator, @intCast(num_headers));
        for (0..@intCast(num_headers)) |_| {
            const name = try readString(allocator, data, &pos);
            const value = try readString(allocator, data, &pos);
            headers.appendAssumeCapacity(.{ .name = name, .value = value });
        }
    }

    const body = try readOptionalBytes(allocator, data, &pos);

    return .{
        .request_id = request_id,
        .status = @intCast(status_raw),
        .headers = try headers.toOwnedSlice(allocator),
        .body = body,
    };
}

test "request round-trip with body and headers" {
    const allocator = std.testing.allocator;

    var req_id: [32]u8 = undefined;
    for (&req_id, 0..) |*b, i| b.* = @intCast(i);

    const headers = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-bsv-custom", .value = "hello" },
    };

    const payload = HttpRequestPayload{
        .request_id = req_id,
        .method = "POST",
        .path = "/api/v1/test",
        .search = "?q=hello&limit=10",
        .headers = &headers,
        .body = "{\"key\":\"value\"}",
    };

    const serialized = try serializeRequest(allocator, payload);
    defer allocator.free(serialized);

    const result = try deserializeRequest(allocator, serialized);
    defer {
        allocator.free(result.method);
        if (result.path) |p| allocator.free(p);
        if (result.search) |s| allocator.free(s);
        for (result.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(result.headers);
        if (result.body) |b| allocator.free(b);
    }

    try std.testing.expectEqualSlices(u8, &req_id, &result.request_id);
    try std.testing.expectEqualStrings("POST", result.method);
    try std.testing.expectEqualStrings("/api/v1/test", result.path.?);
    try std.testing.expectEqualStrings("?q=hello&limit=10", result.search.?);
    try std.testing.expectEqual(@as(usize, 2), result.headers.len);
    try std.testing.expectEqualStrings("content-type", result.headers[0].name);
    try std.testing.expectEqualStrings("application/json", result.headers[0].value);
    try std.testing.expectEqualStrings("x-bsv-custom", result.headers[1].name);
    try std.testing.expectEqualStrings("hello", result.headers[1].value);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", result.body.?);
}

test "request round-trip without body" {
    const allocator = std.testing.allocator;

    var req_id: [32]u8 = undefined;
    @memset(&req_id, 0xAB);

    const payload = HttpRequestPayload{
        .request_id = req_id,
        .method = "GET",
        .path = "/health",
        .search = null,
        .headers = &.{},
        .body = null,
    };

    const serialized = try serializeRequest(allocator, payload);
    defer allocator.free(serialized);

    const result = try deserializeRequest(allocator, serialized);
    defer {
        allocator.free(result.method);
        if (result.path) |p| allocator.free(p);
        if (result.search) |s| allocator.free(s);
        for (result.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(result.headers);
        if (result.body) |b| allocator.free(b);
    }

    try std.testing.expectEqualSlices(u8, &req_id, &result.request_id);
    try std.testing.expectEqualStrings("GET", result.method);
    try std.testing.expectEqualStrings("/health", result.path.?);
    try std.testing.expect(result.search == null);
    try std.testing.expectEqual(@as(usize, 0), result.headers.len);
    try std.testing.expect(result.body == null);
}

test "request round-trip without path or search" {
    const allocator = std.testing.allocator;

    var req_id: [32]u8 = undefined;
    @memset(&req_id, 0x00);

    const payload = HttpRequestPayload{
        .request_id = req_id,
        .method = "DELETE",
        .path = null,
        .search = null,
        .headers = &.{},
        .body = null,
    };

    const serialized = try serializeRequest(allocator, payload);
    defer allocator.free(serialized);

    const result = try deserializeRequest(allocator, serialized);
    defer {
        allocator.free(result.method);
        if (result.path) |p| allocator.free(p);
        if (result.search) |s| allocator.free(s);
        allocator.free(result.headers);
        if (result.body) |b| allocator.free(b);
    }

    try std.testing.expectEqualStrings("DELETE", result.method);
    try std.testing.expect(result.path == null);
    try std.testing.expect(result.search == null);
    try std.testing.expect(result.body == null);
}

test "response round-trip with body and headers" {
    const allocator = std.testing.allocator;

    var req_id: [32]u8 = undefined;
    for (&req_id, 0..) |*b, i| b.* = @intCast(i);

    const headers = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    const payload = HttpResponsePayload{
        .request_id = req_id,
        .status = 200,
        .headers = &headers,
        .body = "{\"ok\":true}",
    };

    const serialized = try serializeResponse(allocator, payload);
    defer allocator.free(serialized);

    const result = try deserializeResponse(allocator, serialized);
    defer {
        for (result.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(result.headers);
        if (result.body) |b| allocator.free(b);
    }

    try std.testing.expectEqualSlices(u8, &req_id, &result.request_id);
    try std.testing.expectEqual(@as(u16, 200), result.status);
    try std.testing.expectEqual(@as(usize, 1), result.headers.len);
    try std.testing.expectEqualStrings("content-type", result.headers[0].name);
    try std.testing.expectEqualStrings("application/json", result.headers[0].value);
    try std.testing.expectEqualStrings("{\"ok\":true}", result.body.?);
}

test "response round-trip without body" {
    const allocator = std.testing.allocator;

    var req_id: [32]u8 = undefined;
    @memset(&req_id, 0xFF);

    const payload = HttpResponsePayload{
        .request_id = req_id,
        .status = 404,
        .headers = &.{},
        .body = null,
    };

    const serialized = try serializeResponse(allocator, payload);
    defer allocator.free(serialized);

    const result = try deserializeResponse(allocator, serialized);
    defer {
        allocator.free(result.headers);
        if (result.body) |b| allocator.free(b);
    }

    try std.testing.expectEqual(@as(u16, 404), result.status);
    try std.testing.expectEqual(@as(usize, 0), result.headers.len);
    try std.testing.expect(result.body == null);
}

test "response round-trip with multiple headers" {
    const allocator = std.testing.allocator;

    var req_id: [32]u8 = undefined;
    @memset(&req_id, 0x42);

    const headers = [_]Header{
        .{ .name = "content-type", .value = "text/html" },
        .{ .name = "x-bsv-topic", .value = "ordinals" },
        .{ .name = "x-bsv-version", .value = "1.0" },
    };

    const payload = HttpResponsePayload{
        .request_id = req_id,
        .status = 201,
        .headers = &headers,
        .body = "<html></html>",
    };

    const serialized = try serializeResponse(allocator, payload);
    defer allocator.free(serialized);

    const result = try deserializeResponse(allocator, serialized);
    defer {
        for (result.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(result.headers);
        if (result.body) |b| allocator.free(b);
    }

    try std.testing.expectEqual(@as(u16, 201), result.status);
    try std.testing.expectEqual(@as(usize, 3), result.headers.len);
    try std.testing.expectEqualStrings("content-type", result.headers[0].name);
    try std.testing.expectEqualStrings("x-bsv-topic", result.headers[1].name);
    try std.testing.expectEqualStrings("x-bsv-version", result.headers[2].name);
    try std.testing.expectEqualStrings("<html></html>", result.body.?);
}
