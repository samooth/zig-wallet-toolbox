const std = @import("std");

pub const RpcError = struct {
    code: i32,
    message: []const u8,
};

pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: std.json.Value,
    id: u32,
};

pub const Response = struct {
    jsonrpc: []const u8,
    result: ?std.json.Value,
    @"error": ?RpcError,
    id: u32,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Response) void {
        self.parsed.deinit();
    }

    pub fn fromJson(allocator: std.mem.Allocator, raw: []const u8) !Response {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        const obj = parsed.value.object;

        const id_val = obj.get("id") orelse return error.MissingId;
        const id: u32 = switch (id_val) {
            .integer => |i| @intCast(i),
            else => return error.InvalidId,
        };

        const jsonrpc_val = obj.get("jsonrpc") orelse return error.MissingJsonrpc;
        const jsonrpc = switch (jsonrpc_val) {
            .string => |s| s,
            else => return error.InvalidJsonrpc,
        };

        var rpc_error: ?RpcError = null;
        if (obj.get("error")) |err_val| {
            if (err_val != .null) {
                const err_obj = err_val.object;
                const code_val = err_obj.get("code") orelse return error.InvalidError;
                const msg_val = err_obj.get("message") orelse return error.InvalidError;
                rpc_error = .{
                    .code = @intCast(switch (code_val) {
                        .integer => |i| i,
                        else => return error.InvalidError,
                    }),
                    .message = switch (msg_val) {
                        .string => |s| s,
                        else => return error.InvalidError,
                    },
                };
            }
        }

        return .{
            .jsonrpc = jsonrpc,
            .result = obj.get("result"),
            .@"error" = rpc_error,
            .id = id,
            .parsed = parsed,
        };
    }
};

pub fn buildRequest(allocator: std.mem.Allocator, method: []const u8, params: std.json.Value, id: u32) ![]u8 {
    const req = Request{
        .method = method,
        .params = params,
        .id = id,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    var w: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try w.write(req);
    return try out.toOwnedSlice();
}

pub fn parseResponse(allocator: std.mem.Allocator, body_bytes: []const u8) !Response {
    return Response.fromJson(allocator, body_bytes);
}
