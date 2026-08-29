const std = @import("std");
const testing = std.testing;
const json_rpc = @import("zig-wallet-toolbox").http.json_rpc;

test "buildRequest produces valid JSON-RPC 2.0" {
    const allocator = testing.allocator;

    var params_map = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer params_map.deinit(allocator);
    try params_map.put(allocator, "key", .{ .string = "value" });

    const bytes = try json_rpc.buildRequest(allocator, "test.method", .{ .object = params_map }, 1);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try testing.expectEqualStrings("test.method", obj.get("method").?.string);
    try testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);

    const p = obj.get("params").?.object;
    try testing.expectEqualStrings("value", p.get("key").?.string);
}

test "parseResponse handles success" {
    const allocator = testing.allocator;

    const raw =
        \\{"jsonrpc":"2.0","result":{"data":"hello"},"id":42}
    ;

    var resp = try json_rpc.parseResponse(allocator, raw);
    defer resp.deinit();

    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expectEqual(@as(u32, 42), resp.id);
    try testing.expect(resp.@"error" == null);
    try testing.expect(resp.result != null);
    try testing.expectEqualStrings("hello", resp.result.?.object.get("data").?.string);
}

test "parseResponse handles error" {
    const allocator = testing.allocator;

    const raw =
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}
    ;

    var resp = try json_rpc.parseResponse(allocator, raw);
    defer resp.deinit();

    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expectEqual(@as(u32, 1), resp.id);
    try testing.expect(resp.result == null);
    try testing.expect(resp.@"error" != null);
    try testing.expectEqual(@as(i32, -32601), resp.@"error".?.code);
    try testing.expectEqualStrings("Method not found", resp.@"error".?.message);
}

test "buildRequest and parseResponse round-trip" {
    const allocator = testing.allocator;

    var params_map = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    defer params_map.deinit(allocator);
    try params_map.put(allocator, "foo", .{ .string = "bar" });

    const req_bytes = try json_rpc.buildRequest(allocator, "echo", .{ .object = params_map }, 99);
    defer allocator.free(req_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, req_bytes, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try testing.expectEqualStrings("echo", obj.get("method").?.string);
    try testing.expectEqual(@as(i64, 99), obj.get("id").?.integer);
}
