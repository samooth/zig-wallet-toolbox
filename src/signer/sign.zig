const std = @import("std");
const types = @import("types.zig");

pub const SignedInput = struct {
    input_index: u32,
    unlocking_script: []const u8,
    sequence_number: ?u32 = null,
};

/// After signing inputs externally, build the SignActionArgs to send back to storage.
pub fn buildSignActionArgs(allocator: std.mem.Allocator, reference: []const u8, signed_inputs: []const SignedInput) !types.SignActionArgs {
    var spends = try allocator.alloc(types.SignActionSpend, signed_inputs.len);
    for (signed_inputs, 0..) |input, i| {
        spends[i] = .{
            .input_index = input.input_index,
            .unlocking_script = input.unlocking_script,
            .sequence_number = input.sequence_number,
        };
    }

    return .{
        .reference = reference,
        .spends = spends,
    };
}

test "buildSignActionArgs" {
    const allocator = std.testing.allocator;

    const inputs = [_]SignedInput{
        .{ .input_index = 0, .unlocking_script = "483045..." },
        .{ .input_index = 2, .unlocking_script = "473044...", .sequence_number = 0xffffffff },
    };

    const args = try buildSignActionArgs(allocator, "ref-abc", &inputs);
    defer allocator.free(args.spends);

    try std.testing.expectEqualStrings("ref-abc", args.reference);
    try std.testing.expectEqual(@as(usize, 2), args.spends.len);
    try std.testing.expectEqual(@as(u32, 0), args.spends[0].input_index);
    try std.testing.expectEqualStrings("483045...", args.spends[0].unlocking_script);
    try std.testing.expect(args.spends[0].sequence_number == null);
    try std.testing.expectEqual(@as(u32, 2), args.spends[1].input_index);
    try std.testing.expectEqual(@as(u32, 0xffffffff), args.spends[1].sequence_number.?);
}
