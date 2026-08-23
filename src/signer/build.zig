const std = @import("std");

/// Data extracted from the storage createAction response needed for signing.
pub const SignableData = struct {
    reference: []const u8,
    input_beef: ?[]const u8,
    inputs: ?std.json.Array,
    outputs: ?std.json.Array,
};

/// Takes the storage createAction response and extracts the transaction skeleton.
/// Returns the reference and input BEEF needed for signing.
pub fn extractSignableData(create_result: std.json.Value) !SignableData {
    const obj = switch (create_result) {
        .object => |o| o,
        else => return error.InvalidCreateActionResult,
    };

    const reference = blk: {
        const val = obj.get("referenceNumber") orelse return error.MissingReference;
        break :blk switch (val) {
            .string => |s| s,
            else => return error.MissingReference,
        };
    };

    const input_beef: ?[]const u8 = blk: {
        const val = obj.get("inputBeef") orelse break :blk null;
        break :blk switch (val) {
            .string => |s| s,
            else => null,
        };
    };

    const inputs: ?std.json.Array = blk: {
        const val = obj.get("inputs") orelse break :blk null;
        break :blk switch (val) {
            .array => |a| a,
            else => null,
        };
    };

    const outputs: ?std.json.Array = blk: {
        const val = obj.get("outputs") orelse break :blk null;
        break :blk switch (val) {
            .array => |a| a,
            else => null,
        };
    };

    return .{
        .reference = reference,
        .input_beef = input_beef,
        .inputs = inputs,
        .outputs = outputs,
    };
}

test "extractSignableData from valid response" {
    const allocator = std.testing.allocator;

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator,"referenceNumber", .{ .string = "ref-123" });
    try obj.put(allocator,"inputBeef", .{ .string = "0100beef..." });

    const result = try extractSignableData(.{ .object = obj });
    try std.testing.expectEqualStrings("ref-123", result.reference);
    try std.testing.expectEqualStrings("0100beef...", result.input_beef.?);
    try std.testing.expect(result.inputs == null);
    try std.testing.expect(result.outputs == null);
}

test "extractSignableData missing reference" {
    const allocator = std.testing.allocator;

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator,"inputBeef", .{ .string = "0100beef..." });

    const result = extractSignableData(.{ .object = obj });
    try std.testing.expectError(error.MissingReference, result);
}

test "extractSignableData invalid value" {
    const result = extractSignableData(.null);
    try std.testing.expectError(error.InvalidCreateActionResult, result);
}
