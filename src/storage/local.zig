const std = @import("std");
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const hex = bsvz.primitives.hex;
const WalletStorageProvider = @import("interface.zig").WalletStorageProvider;
const types = @import("types.zig");
const util = @import("../util.zig");

/// In-memory local wallet storage provider.
///
/// WARNING: TESTS / EPHEMERAL USE ONLY.
/// All data lives in process memory (HashMaps) and is irrecoverably lost when
/// the process exits, crashes, or the client is deinited. There is no
/// persistence and no way to recover a stored wallet, key shares, or action
/// history afterwards. For persistent storage use `SqliteStorageClient` (file
/// backed) or `RemoteStorageClient` (BRC-100 server backed).
///
/// Intended for unit/integration tests, examples, and short-lived throwaway
/// wallets where data loss is acceptable.
pub const LocalStorageClient = struct {
    allocator: std.mem.Allocator,
    // In-memory storage
    users: std.StringHashMap(UserData),
    actions: std.StringHashMap(ActionData),
    outputs: std.StringHashMap(OutputData),
    key_shares: std.StringHashMap([]u8),

    const UserData = struct {
        identity_key: []u8,
        is_new: bool,
    };

    const ActionData = struct {
        reference: []u8,
        identity_key: []u8,
        args: std.json.Value,
        created_at: u64,
    };

    const OutputData = struct {
        identity_key: []u8,
        outputs: std.json.Value,
    };

    pub fn init(allocator: std.mem.Allocator) LocalStorageClient {
        return LocalStorageClient{
            .allocator = allocator,
            .users = std.StringHashMap(UserData).init(allocator),
            .actions = std.StringHashMap(ActionData).init(allocator),
            .outputs = std.StringHashMap(OutputData).init(allocator),
            .key_shares = std.StringHashMap([]u8).init(allocator),
        };
    }

    fn getOrCreateUser(self: *LocalStorageClient, identity_key: []const u8) !*UserData {
        if (self.users.getPtr(identity_key)) |user| {
            return user;
        }
        // Map key and UserData.identity_key must be separate allocations:
        // destroy() frees both, so sharing one dupe would double-free.
        const key = try self.allocator.dupe(u8, identity_key);
        const user = UserData{
            .identity_key = try self.allocator.dupe(u8, identity_key),
            .is_new = true,
        };
        try self.users.put(key, user);
        return self.users.getPtr(key).?;
    }

    fn getOrCreateOutputs(self: *LocalStorageClient, identity_key: []const u8) !*OutputData {
        if (self.outputs.getPtr(identity_key)) |out| {
            return out;
        }
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "outputs", .{ .array = std.json.Array.init(self.allocator) });
        const data = OutputData{
            .identity_key = try self.allocator.dupe(u8, identity_key),
            .outputs = .{ .object = obj },
        };
        try self.outputs.put(try self.allocator.dupe(u8, identity_key), data);
        return self.outputs.getPtr(identity_key).?;
    }

    fn getOrCreateActions(self: *LocalStorageClient, _: []const u8) !std.json.Value {
        // For simplicity, return empty actions array
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "actions", .{ .array = std.json.Array.init(self.allocator) });
        return .{ .object = obj };
    }

    pub fn makeAvailable(self: *LocalStorageClient, _: std.mem.Allocator) !std.json.Value {
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "available", .{ .bool = true });
        return .{ .object = obj };
    }

    pub fn migrate(_: *LocalStorageClient, _: std.mem.Allocator, _: []const u8) ![]const u8 {
        return "migrated";
    }

    pub fn findOrInsertUser(self: *LocalStorageClient, _: std.mem.Allocator, identity_key: []const u8) !std.json.Value {
        const user = try self.getOrCreateUser(identity_key);
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "user", .{ .string = identity_key });
        try obj.put(self.allocator, "isNew", .{ .bool = user.is_new });
        user.is_new = false;
        return .{ .object = obj };
    }

    pub fn createAction(self: *LocalStorageClient, _: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        const reference = try std.fmt.allocPrint(self.allocator, "ref_{d}", .{util.nowMilli()});

        // ActionData owns its slices; destroy() frees them. Do NOT free here.
        const action = ActionData{
            .reference = reference,
            .identity_key = try self.allocator.dupe(u8, auth.identity_key),
            .args = args, // Note: shallow copy, caller owns original
            .created_at = util.nowSecs(),
        };
        try self.actions.put(try self.allocator.dupe(u8, reference), action);

        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "referenceNumber", .{ .string = reference });
        try obj.put(self.allocator, "txid", .{ .string = std.fmt.allocPrint(self.allocator, "local_tx_{d}", .{util.nowMilli()}) catch "local_tx" });
        return .{ .object = obj };
    }

    pub fn processAction(self: *LocalStorageClient, _: std.mem.Allocator, _: types.AuthId, _: std.json.Value) !std.json.Value {
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "txid", .{ .string = "local_tx_processed" });
        try obj.put(self.allocator, "status", .{ .string = "success" });
        return .{ .object = obj };
    }

    pub fn abortAction(self: *LocalStorageClient, _: std.mem.Allocator, _: types.AuthId, _: std.json.Value) !std.json.Value {
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "status", .{ .string = "aborted" });
        return .{ .object = obj };
    }

    pub fn listOutputs(self: *LocalStorageClient, _: std.mem.Allocator, auth: types.AuthId, _: std.json.Value) !std.json.Value {
        const data = try self.getOrCreateOutputs(auth.identity_key);
        return data.outputs;
    }

    pub fn listActions(self: *LocalStorageClient, _: std.mem.Allocator, auth: types.AuthId, _: std.json.Value) !std.json.Value {
        return try self.getOrCreateActions(auth.identity_key);
    }

    pub fn internalizeAction(self: *LocalStorageClient, _: std.mem.Allocator, _: types.AuthId, _: std.json.Value) !std.json.Value {
        var obj = try std.json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try obj.put(self.allocator, "status", .{ .string = "internalized" });
        return .{ .object = obj };
    }

    pub fn storeKeyShares(self: *LocalStorageClient, _: std.mem.Allocator, auth: types.AuthId, shares: []const []const u8) !void {
        const owned = try types.serializeShares(self.allocator, shares);
        if (self.key_shares.get(auth.identity_key)) |prev| self.allocator.free(prev);
        try self.key_shares.put(try self.allocator.dupe(u8, auth.identity_key), owned);
    }

    pub fn loadKeyShares(self: *LocalStorageClient, allocator: std.mem.Allocator, auth: types.AuthId) ![][]u8 {
        const stored = self.key_shares.get(auth.identity_key) orelse return error.KeySharesNotFound;
        return types.parseSharesJson(allocator, stored);
    }

    /// Free a JSON value previously returned by one of this client's methods.
    /// Results own their memory in the allocator passed to the producing call
    /// (`makeAvailable`, `findOrInsertUser`, `createAction`, …); release them
    /// with this once done.
    pub fn freeResult(_: *LocalStorageClient, allocator: std.mem.Allocator, value: std.json.Value) void {
        freeJsonValue(allocator, value);
    }

    pub fn destroy(self: *LocalStorageClient) void {
        var users_it = self.users.iterator();
        while (users_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.identity_key);
        }
        self.users.deinit();

        var actions_it = self.actions.iterator();
        while (actions_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.reference);
            self.allocator.free(entry.value_ptr.*.identity_key);
        }
        self.actions.deinit();

        var outputs_it = self.outputs.iterator();
        while (outputs_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.identity_key);
        }
        self.outputs.deinit();

        var ks_it = self.key_shares.iterator();
        while (ks_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.key_shares.deinit();
    }

    pub fn storageProvider(self: *LocalStorageClient) WalletStorageProvider {
        return WalletStorageProvider.init(self);
    }

    pub fn deinit(self: *LocalStorageClient) void {
        self.destroy();
    }
};

/// Recursively free a `std.json.Value` allocated with `allocator` (objects,
/// arrays, and strings). Scalarm values are trivial and ignored.
pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var arr_mut = arr; arr_mut.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var obj_mut = obj; obj_mut.deinit(allocator);
        },
        else => {},
    }
}
