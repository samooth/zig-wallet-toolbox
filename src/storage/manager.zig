const std = @import("std");
const WalletStorageProvider = @import("interface.zig").WalletStorageProvider;
const types = @import("types.zig");

pub const WalletStorageManager = struct {
    allocator: std.mem.Allocator,
    active: ?WalletStorageProvider,
    backups: std.ArrayList(WalletStorageProvider),

    pub fn init(allocator: std.mem.Allocator) WalletStorageManager {
        return .{
            .allocator = allocator,
            .active = null,
            .backups = .empty,
        };
    }

    pub fn setActive(self: *WalletStorageManager, provider: WalletStorageProvider) void {
        self.active = provider;
    }

    pub fn addBackup(self: *WalletStorageManager, provider: WalletStorageProvider) !void {
        try self.backups.append(self.allocator, provider);
    }

    pub fn makeAvailable(self: *WalletStorageManager, allocator: std.mem.Allocator) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.makeAvailable(allocator);
    }

    pub fn migrate(self: *WalletStorageManager, allocator: std.mem.Allocator, storage_name: []const u8) anyerror![]const u8 {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.migrate(allocator, storage_name);
    }

    pub fn findOrInsertUser(self: *WalletStorageManager, allocator: std.mem.Allocator, identity_key: []const u8) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.findOrInsertUser(allocator, identity_key);
    }

    pub fn createAction(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.createAction(allocator, auth, args);
    }

    pub fn processAction(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.processAction(allocator, auth, args);
    }

    pub fn abortAction(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.abortAction(allocator, auth, args);
    }

    pub fn listOutputs(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.listOutputs(allocator, auth, args);
    }

    pub fn listActions(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.listActions(allocator, auth, args);
    }

    pub fn internalizeAction(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.internalizeAction(allocator, auth, args);
    }

    pub fn relinquishOutput(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, basket: []const u8, txid: []const u8, vout: u32) anyerror!u64 {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.relinquishOutput(allocator, auth, basket, txid, vout);
    }

    pub fn storeKeyShares(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId, shares: []const []const u8) !void {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.storeKeyShares(allocator, auth, shares);
    }

    pub fn loadKeyShares(self: *WalletStorageManager, allocator: std.mem.Allocator, auth: types.AuthId) ![][]u8 {
        const provider = self.active orelse return error.NoActiveProvider;
        return provider.loadKeyShares(allocator, auth);
    }

    pub fn storageProvider(self: *WalletStorageManager) WalletStorageProvider {
        return WalletStorageProvider.init(self);
    }

    /// WalletStorageManager does NOT own storage providers: it holds vtable
    /// references set via setActive/addBackup. Callers retain ownership and
    /// are responsible for deiniting the underlying clients themselves.
    /// (Previously deinit destroyed active+backups, causing double-destroy
    /// when callers also deinited their own clients.)
    pub fn deinit(self: *WalletStorageManager) void {
        self.active = null;
        self.backups.deinit(self.allocator);
    }
};

test "WalletStorageManager init and deinit" {
    const allocator = std.testing.allocator;
    var mgr = WalletStorageManager.init(allocator);
    defer mgr.deinit();

    try std.testing.expect(mgr.active == null);
    try std.testing.expectEqual(@as(usize, 0), mgr.backups.items.len);
}
