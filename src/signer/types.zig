const std = @import("std");

// --- CreateAction ---

pub const CreateActionArgs = struct {
    description: []const u8,
    outputs: []const ActionOutput,
    inputs: ?[]const ActionInput = null,
    labels: ?[]const []const u8 = null,
    options: CreateActionOptions = .{},

    pub fn toJson(self: CreateActionArgs, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        try obj.put(allocator, "description", .{ .string = self.description });

        var outputs_arr = std.json.Array.init(allocator);
        for (self.outputs) |output| {
            try outputs_arr.append(try output.toJson(allocator));
        }
        try obj.put(allocator, "outputs", .{ .array = outputs_arr });

        if (self.inputs) |inputs| {
            var inputs_arr = std.json.Array.init(allocator);
            for (inputs) |input| {
                try inputs_arr.append(try input.toJson(allocator));
            }
            try obj.put(allocator, "inputs", .{ .array = inputs_arr });
        }

        if (self.labels) |labels| {
            var labels_arr = std.json.Array.init(allocator);
            for (labels) |label| {
                try labels_arr.append(.{ .string = label });
            }
            try obj.put(allocator, "labels", .{ .array = labels_arr });
        }

        try obj.put(allocator, "options", try self.options.toJson(allocator));

        return .{ .object = obj };
    }
};

pub const ActionOutput = struct {
    locking_script: []const u8,
    satoshis: u64,
    description: ?[]const u8 = null,
    basket: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,

    pub fn toJson(self: ActionOutput, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        try obj.put(allocator, "lockingScript", .{ .string = self.locking_script });
        try obj.put(allocator, "satoshis", .{ .integer = @intCast(self.satoshis) });

        if (self.description) |desc| {
            try obj.put(allocator, "description", .{ .string = desc });
        }
        if (self.basket) |basket| {
            try obj.put(allocator, "basket", .{ .string = basket });
        }
        if (self.tags) |tags| {
            var tags_arr = std.json.Array.init(allocator);
            for (tags) |tag| {
                try tags_arr.append(.{ .string = tag });
            }
            try obj.put(allocator, "tags", .{ .array = tags_arr });
        }

        return .{ .object = obj };
    }
};

pub const ActionInput = struct {
    outpoint: []const u8,
    unlocking_script: ?[]const u8 = null,
    unlocking_script_length: ?u32 = null,
    input_description: ?[]const u8 = null,
    sequence_number: ?u32 = null,

    pub fn toJson(self: ActionInput, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        try obj.put(allocator, "outpoint", .{ .string = self.outpoint });

        if (self.unlocking_script) |script| {
            try obj.put(allocator, "unlockingScript", .{ .string = script });
        }
        if (self.unlocking_script_length) |len| {
            try obj.put(allocator, "unlockingScriptLength", .{ .integer = @intCast(len) });
        }
        if (self.input_description) |desc| {
            try obj.put(allocator, "inputDescription", .{ .string = desc });
        }
        if (self.sequence_number) |seq| {
            try obj.put(allocator, "sequenceNumber", .{ .integer = @intCast(seq) });
        }

        return .{ .object = obj };
    }
};

pub const CreateActionOptions = struct {
    no_send: bool = false,
    sign_and_process: bool = true,
    accept_delayed_broadcast: bool = true,
    return_txid_only: bool = false,
    randomize_outputs: bool = true,
    change_basket: ?[]const u8 = null,
    send_with: ?[]const []const u8 = null,

    pub fn toJson(self: CreateActionOptions, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        try obj.put(allocator, "noSend", .{ .bool = self.no_send });
        try obj.put(allocator, "signAndProcess", .{ .bool = self.sign_and_process });
        try obj.put(allocator, "acceptDelayedBroadcast", .{ .bool = self.accept_delayed_broadcast });
        try obj.put(allocator, "returnTXIDOnly", .{ .bool = self.return_txid_only });
        try obj.put(allocator, "randomizeOutputs", .{ .bool = self.randomize_outputs });

        if (self.change_basket) |basket| {
            try obj.put(allocator, "changeBasket", .{ .string = basket });
        }
        if (self.send_with) |send_with| {
            var arr = std.json.Array.init(allocator);
            for (send_with) |txid| {
                try arr.append(.{ .string = txid });
            }
            try obj.put(allocator, "sendWith", .{ .array = arr });
        }

        return .{ .object = obj };
    }
};

pub const CreateActionResult = struct {
    raw: std.json.Value,

    pub fn getTxid(self: CreateActionResult) ?[]const u8 {
        return switch (self.raw) {
            .object => |obj| blk: {
                const val = obj.get("txid") orelse break :blk null;
                break :blk switch (val) {
                    .string => |s| s,
                    else => null,
                };
            },
            else => null,
        };
    }

    pub fn getReference(self: CreateActionResult) ?[]const u8 {
        return switch (self.raw) {
            .object => |obj| blk: {
                const val = obj.get("referenceNumber") orelse break :blk null;
                break :blk switch (val) {
                    .string => |s| s,
                    else => null,
                };
            },
            else => null,
        };
    }

    pub fn getInputBeef(self: CreateActionResult) ?[]const u8 {
        return switch (self.raw) {
            .object => |obj| blk: {
                const val = obj.get("inputBeef") orelse break :blk null;
                break :blk switch (val) {
                    .string => |s| s,
                    else => null,
                };
            },
            else => null,
        };
    }

    pub fn getNoSendChangeVouts(self: CreateActionResult) ?std.json.Array {
        return switch (self.raw) {
            .object => |obj| blk: {
                const val = obj.get("noSendChangeOutputVouts") orelse break :blk null;
                break :blk switch (val) {
                    .array => |a| a,
                    else => null,
                };
            },
            else => null,
        };
    }
};

// --- SignAction ---

pub const SignActionArgs = struct {
    reference: []const u8,
    spends: []const SignActionSpend,
    options: SignActionOptions = .{},

    pub fn toJson(self: SignActionArgs, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        try obj.put(allocator, "reference", .{ .string = self.reference });

        var spends_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        for (self.spends) |spend| {
            const key = try std.fmt.allocPrint(allocator, "{d}", .{spend.input_index});
            try spends_obj.put(allocator, key, try spend.toJson(allocator));
        }
        try obj.put(allocator, "spends", .{ .object = spends_obj });

        try obj.put(allocator, "options", try self.options.toJson(allocator));

        return .{ .object = obj };
    }
};

pub const SignActionSpend = struct {
    input_index: u32,
    unlocking_script: []const u8,
    sequence_number: ?u32 = null,

    pub fn toJson(self: SignActionSpend, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        try obj.put(allocator, "unlockingScript", .{ .string = self.unlocking_script });

        if (self.sequence_number) |seq| {
            try obj.put(allocator, "sequenceNumber", .{ .integer = @intCast(seq) });
        }

        return .{ .object = obj };
    }
};

pub const SignActionOptions = struct {
    accept_delayed_broadcast: ?bool = null,
    return_txid_only: ?bool = null,
    no_send: ?bool = null,
    send_with: ?[]const []const u8 = null,

    pub fn toJson(self: SignActionOptions, allocator: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});

        if (self.accept_delayed_broadcast) |v| {
            try obj.put(allocator, "acceptDelayedBroadcast", .{ .bool = v });
        }
        if (self.return_txid_only) |v| {
            try obj.put(allocator, "returnTXIDOnly", .{ .bool = v });
        }
        if (self.no_send) |v| {
            try obj.put(allocator, "noSend", .{ .bool = v });
        }
        if (self.send_with) |send_with| {
            var arr = std.json.Array.init(allocator);
            for (send_with) |txid| {
                try arr.append(.{ .string = txid });
            }
            try obj.put(allocator, "sendWith", .{ .array = arr });
        }

        return .{ .object = obj };
    }
};

pub const SignActionResult = struct {
    raw: std.json.Value,

    pub fn getTxid(self: SignActionResult) ?[]const u8 {
        return switch (self.raw) {
            .object => |obj| blk: {
                const val = obj.get("txid") orelse break :blk null;
                break :blk switch (val) {
                    .string => |s| s,
                    else => null,
                };
            },
            else => null,
        };
    }
};

// --- Process Action ---

pub const ProcessActionArgs = struct {
    raw: std.json.Value,
};

pub const ProcessActionResult = struct {
    raw: std.json.Value,
};
