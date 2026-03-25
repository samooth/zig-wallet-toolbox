const std = @import("std");

pub const MessageType = enum {
    initial_request,
    initial_response,
    certificate_request,
    certificate_response,
    general,

    pub fn toWireString(self: MessageType) []const u8 {
        return switch (self) {
            .initial_request => "initialRequest",
            .initial_response => "initialResponse",
            .certificate_request => "certificateRequest",
            .certificate_response => "certificateResponse",
            .general => "general",
        };
    }

    pub fn fromWireString(s: []const u8) ?MessageType {
        const map = std.StaticStringMap(MessageType).initComptime(.{
            .{ "initialRequest", .initial_request },
            .{ "initialResponse", .initial_response },
            .{ "certificateRequest", .certificate_request },
            .{ "certificateResponse", .certificate_response },
            .{ "general", .general },
        });
        return map.get(s);
    }
};

pub const AuthMessage = struct {
    version: []const u8,
    message_type: MessageType,
    identity_key: []const u8, // compressed public key hex (66 chars)
    nonce: ?[]const u8 = null, // base64-encoded
    initial_nonce: ?[]const u8 = null, // base64-encoded
    your_nonce: ?[]const u8 = null, // base64-encoded
    payload: ?[]const u8 = null, // base64-encoded binary
    signature: ?[]const u8 = null, // base64-encoded DER signature

    pub fn toJson(self: *const AuthMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("{");
        try writer.print("\"version\":\"{s}\",", .{self.version});
        try writer.print("\"messageType\":\"{s}\",", .{self.message_type.toWireString()});
        try writer.print("\"identityKey\":\"{s}\"", .{self.identity_key});

        if (self.nonce) |v| {
            try writer.print(",\"nonce\":\"{s}\"", .{v});
        }
        if (self.initial_nonce) |v| {
            try writer.print(",\"initialNonce\":\"{s}\"", .{v});
        }
        if (self.your_nonce) |v| {
            try writer.print(",\"yourNonce\":\"{s}\"", .{v});
        }
        if (self.payload) |v| {
            try writer.writeAll(",\"payload\":[");
            for (v, 0..) |byte, i| {
                if (i > 0) try writer.writeAll(",");
                try std.fmt.format(writer, "{d}", .{byte});
            }
            try writer.writeAll("]");
        }
        if (self.signature) |v| {
            try writer.writeAll(",\"signature\":[");
            for (v, 0..) |byte, i| {
                if (i > 0) try writer.writeAll(",");
                try std.fmt.format(writer, "{d}", .{byte});
            }
            try writer.writeAll("]");
        }

        try writer.writeAll("}");
        return buf.toOwnedSlice(allocator);
    }

    /// Result of fromJson; owns the backing memory for all string fields.
    /// Call deinit() when done to free.
    pub const Parsed = struct {
        value: AuthMessage,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *Parsed) void {
            self.arena.deinit();
        }
    };

    fn jsonArrayToBytes(allocator: std.mem.Allocator, val: std.json.Value) !?[]const u8 {
        switch (val) {
            .array => |arr| {
                const bytes = try allocator.alloc(u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    bytes[i] = switch (item) {
                        .integer => |n| @intCast(n),
                        else => return error.InvalidByteArray,
                    };
                }
                return bytes;
            },
            .null => return null,
            else => return error.InvalidByteArray,
        }
    }

    fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn fromJson(allocator: std.mem.Allocator, json_bytes: []const u8) !Parsed {
        // Use fully dynamic parsing to avoid Zig 0.15 limitations with
        // mixed typed/dynamic struct fields
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json_bytes, .{});
        const root = parsed.value;

        const obj = switch (root) {
            .object => |o| o,
            else => return error.InvalidMessageFormat,
        };

        const version = getStr(obj, "version") orelse return error.MissingField;
        const message_type_str = getStr(obj, "messageType") orelse return error.MissingField;
        const identity_key = getStr(obj, "identityKey") orelse return error.MissingField;

        const msg = AuthMessage{
            .version = version,
            .message_type = MessageType.fromWireString(message_type_str) orelse return error.InvalidMessageType,
            .identity_key = identity_key,
            .nonce = getStr(obj, "nonce"),
            .initial_nonce = getStr(obj, "initialNonce"),
            .your_nonce = getStr(obj, "yourNonce"),
            .payload = if (obj.get("payload")) |v| try jsonArrayToBytes(arena_alloc, v) else null,
            .signature = if (obj.get("signature")) |v| try jsonArrayToBytes(arena_alloc, v) else null,
        };

        return .{
            .value = msg,
            .arena = arena,
        };
    }
};

test "AuthMessage round-trip JSON" {
    const allocator = std.testing.allocator;
    const msg = AuthMessage{
        .version = "0.1",
        .message_type = .initial_request,
        .identity_key = "02aabbccdd",
        .nonce = "abc123==",
        .initial_nonce = null,
        .your_nonce = "xyz789==",
    };

    const json = try msg.toJson(allocator);
    defer allocator.free(json);

    var parsed = try AuthMessage.fromJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("0.1", parsed.value.version);
    try std.testing.expectEqual(MessageType.initial_request, parsed.value.message_type);
    try std.testing.expectEqualStrings("02aabbccdd", parsed.value.identity_key);
    try std.testing.expectEqualStrings("abc123==", parsed.value.nonce.?);
    try std.testing.expect(parsed.value.initial_nonce == null);
    try std.testing.expectEqualStrings("xyz789==", parsed.value.your_nonce.?);
    try std.testing.expect(parsed.value.payload == null);
    try std.testing.expect(parsed.value.signature == null);
}

test "AuthMessage payload/signature serialize as number arrays" {
    const allocator = std.testing.allocator;
    const payload_bytes = &[_]u8{ 48, 69, 2, 33 };
    const sig_bytes = &[_]u8{ 30, 44, 0, 255 };
    const msg = AuthMessage{
        .version = "0.1",
        .message_type = .general,
        .identity_key = "02ff",
        .payload = payload_bytes,
        .signature = sig_bytes,
    };

    const json = try msg.toJson(allocator);
    defer allocator.free(json);

    // Verify the JSON contains number arrays, not base64 strings
    try std.testing.expect(std.mem.indexOf(u8, json, "\"payload\":[48,69,2,33]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"signature\":[30,44,0,255]") != null);

    // Round-trip: parse back and verify bytes match
    var parsed = try AuthMessage.fromJson(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualSlices(u8, payload_bytes, parsed.value.payload.?);
    try std.testing.expectEqualSlices(u8, sig_bytes, parsed.value.signature.?);
}

test "MessageType wire string round-trip" {
    const cases = [_]MessageType{ .initial_request, .initial_response, .certificate_request, .certificate_response, .general };
    for (cases) |mt| {
        const s = mt.toWireString();
        const back = MessageType.fromWireString(s);
        try std.testing.expectEqual(mt, back.?);
    }
}

test "AuthMessage fromJson with all fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"version":"0.1","messageType":"general","identityKey":"02ff","nonce":"n1","initialNonce":"n2","yourNonce":"n3","payload":[1,2,3],"signature":[4,5,6]}
    ;
    var parsed = try AuthMessage.fromJson(allocator, json);
    defer parsed.deinit();
    const msg = parsed.value;
    try std.testing.expectEqual(MessageType.general, msg.message_type);
    try std.testing.expectEqualStrings("n1", msg.nonce.?);
    try std.testing.expectEqualStrings("n2", msg.initial_nonce.?);
    try std.testing.expectEqualStrings("n3", msg.your_nonce.?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, msg.payload.?);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 5, 6 }, msg.signature.?);
}
