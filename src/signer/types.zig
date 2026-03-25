const std = @import("std");

// --- CreateAction ---

pub const CreateActionArgs = struct {
    description: []const u8,
    outputs: []const ActionOutput,
    inputs: ?[]const ActionInput = null,
    labels: ?[]const []const u8 = null,
    options: CreateActionOptions = .{},

    pub fn toJson(self: CreateActionArgs, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put("description", .{ .string = self.description });

        var outputs_arr = std.json.Array.init(allocator);
        for (self.outputs) |output| {
            try outputs_arr.append(try output.toJson(allocator));
        }
        try obj.put("outputs", .{ .array = outputs_arr });

        if (self.inputs) |inputs| {
            var inputs_arr = std.json.Array.init(allocator);
            for (inputs) |input| {
                try inputs_arr.append(try input.toJson(allocator));
            }
            try obj.put("inputs", .{ .array = inputs_arr });
        }

        if (self.labels) |labels| {
            var labels_arr = std.json.Array.init(allocator);
            for (labels) |label| {
                try labels_arr.append(.{ .string = label });
            }
            try obj.put("labels", .{ .array = labels_arr });
        }

        try obj.put("options", try self.options.toJson(allocator));

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
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put("lockingScript", .{ .string = self.locking_script });
        try obj.put("satoshis", .{ .integer = @intCast(self.satoshis) });

        if (self.description) |desc| {
            try obj.put("description", .{ .string = desc });
        }
        if (self.basket) |basket| {
            try obj.put("basket", .{ .string = basket });
        }
        if (self.tags) |tags| {
            var tags_arr = std.json.Array.init(allocator);
            for (tags) |tag| {
                try tags_arr.append(.{ .string = tag });
            }
            try obj.put("tags", .{ .array = tags_arr });
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
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put("outpoint", .{ .string = self.outpoint });

        if (self.unlocking_script) |script| {
            try obj.put("unlockingScript", .{ .string = script });
        }
        if (self.unlocking_script_length) |len| {
            try obj.put("unlockingScriptLength", .{ .integer = @intCast(len) });
        }
        if (self.input_description) |desc| {
            try obj.put("inputDescription", .{ .string = desc });
        }
        if (self.sequence_number) |seq| {
            try obj.put("sequenceNumber", .{ .integer = @intCast(seq) });
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
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put("noSend", .{ .bool = self.no_send });
        try obj.put("signAndProcess", .{ .bool = self.sign_and_process });
        try obj.put("acceptDelayedBroadcast", .{ .bool = self.accept_delayed_broadcast });
        try obj.put("returnTXIDOnly", .{ .bool = self.return_txid_only });
        try obj.put("randomizeOutputs", .{ .bool = self.randomize_outputs });

        if (self.change_basket) |basket| {
            try obj.put("changeBasket", .{ .string = basket });
        }
        if (self.send_with) |send_with| {
            var arr = std.json.Array.init(allocator);
            for (send_with) |txid| {
                try arr.append(.{ .string = txid });
            }
            try obj.put("sendWith", .{ .array = arr });
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
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put("reference", .{ .string = self.reference });

        var spends_obj = std.json.ObjectMap.init(allocator);
        for (self.spends) |spend| {
            const key = try std.fmt.allocPrint(allocator, "{d}", .{spend.input_index});
            try spends_obj.put(key, try spend.toJson(allocator));
        }
        try obj.put("spends", .{ .object = spends_obj });

        try obj.put("options", try self.options.toJson(allocator));

        return .{ .object = obj };
    }
};

pub const SignActionSpend = struct {
    input_index: u32,
    unlocking_script: []const u8,
    sequence_number: ?u32 = null,

    pub fn toJson(self: SignActionSpend, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);

        try obj.put("unlockingScript", .{ .string = self.unlocking_script });

        if (self.sequence_number) |seq| {
            try obj.put("sequenceNumber", .{ .integer = @intCast(seq) });
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
        var obj = std.json.ObjectMap.init(allocator);

        if (self.accept_delayed_broadcast) |v| {
            try obj.put("acceptDelayedBroadcast", .{ .bool = v });
        }
        if (self.return_txid_only) |v| {
            try obj.put("returnTXIDOnly", .{ .bool = v });
        }
        if (self.no_send) |v| {
            try obj.put("noSend", .{ .bool = v });
        }
        if (self.send_with) |send_with| {
            var arr = std.json.Array.init(allocator);
            for (send_with) |txid| {
                try arr.append(.{ .string = txid });
            }
            try obj.put("sendWith", .{ .array = arr });
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
