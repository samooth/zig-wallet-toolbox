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
            try writer.print(",\"payload\":\"{s}\"", .{v});
        }
        if (self.signature) |v| {
            try writer.print(",\"signature\":\"{s}\"", .{v});
        }

        try writer.writeAll("}");
        return buf.toOwnedSlice(allocator);
    }

    /// Wire format for JSON deserialization (camelCase field names).
    const JsonWire = struct {
        version: []const u8,
        messageType: []const u8,
        identityKey: []const u8,
        nonce: ?[]const u8 = null,
        initialNonce: ?[]const u8 = null,
        yourNonce: ?[]const u8 = null,
        payload: ?[]const u8 = null,
        signature: ?[]const u8 = null,
    };

    /// Result of fromJson; owns the backing memory for all string fields.
    /// Call deinit() when done to free.
    pub const Parsed = struct {
        value: AuthMessage,
        arena: *std.heap.ArenaAllocator,
        allocator: std.mem.Allocator,

        pub fn deinit(self: *Parsed) void {
            const alloc = self.allocator;
            self.arena.deinit();
            alloc.destroy(self.arena);
        }
    };

    pub fn fromJson(allocator: std.mem.Allocator, json_bytes: []const u8) !Parsed {
        const parsed = try std.json.parseFromSlice(JsonWire, allocator, json_bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        const wire = parsed.value;
        const msg = AuthMessage{
            .version = wire.version,
            .message_type = MessageType.fromWireString(wire.messageType) orelse return error.InvalidMessageType,
            .identity_key = wire.identityKey,
            .nonce = wire.nonce,
            .initial_nonce = wire.initialNonce,
            .your_nonce = wire.yourNonce,
            .payload = wire.payload,
            .signature = wire.signature,
        };

        return .{
            .value = msg,
            .arena = parsed.arena,
            .allocator = allocator,
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
        \\{"version":"0.1","messageType":"general","identityKey":"02ff","nonce":"n1","initialNonce":"n2","yourNonce":"n3","payload":"p1","signature":"s1"}
    ;
    var parsed = try AuthMessage.fromJson(allocator, json);
    defer parsed.deinit();
    const msg = parsed.value;
    try std.testing.expectEqual(MessageType.general, msg.message_type);
    try std.testing.expectEqualStrings("n1", msg.nonce.?);
    try std.testing.expectEqualStrings("n2", msg.initial_nonce.?);
    try std.testing.expectEqualStrings("n3", msg.your_nonce.?);
    try std.testing.expectEqualStrings("p1", msg.payload.?);
    try std.testing.expectEqualStrings("s1", msg.signature.?);
}
