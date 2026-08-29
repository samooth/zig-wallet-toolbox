const std = @import("std");
const types = @import("types.zig");

pub const WalletStorageProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        makeAvailable: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!std.json.Value,
        migrate: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, storage_name: []const u8) anyerror![]const u8,
        findOrInsertUser: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, identity_key: []const u8) anyerror!std.json.Value,
        createAction: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value,
        processAction: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value,
        abortAction: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value,
        listOutputs: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value,
        listActions: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value,
        internalizeAction: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value,
        storeKeyShares: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, shares: []const []const u8) anyerror!void,
        loadKeyShares: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId) anyerror![][]u8,
        destroy: *const fn (ptr: *anyopaque) void,
    };

    pub fn makeAvailable(self: WalletStorageProvider, allocator: std.mem.Allocator) !std.json.Value {
        return self.vtable.makeAvailable(self.ptr, allocator);
    }

    pub fn migrate(self: WalletStorageProvider, allocator: std.mem.Allocator, storage_name: []const u8) ![]const u8 {
        return self.vtable.migrate(self.ptr, allocator, storage_name);
    }

    pub fn findOrInsertUser(self: WalletStorageProvider, allocator: std.mem.Allocator, identity_key: []const u8) !std.json.Value {
        return self.vtable.findOrInsertUser(self.ptr, allocator, identity_key);
    }

    pub fn createAction(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        return self.vtable.createAction(self.ptr, allocator, auth, args);
    }

    pub fn processAction(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        return self.vtable.processAction(self.ptr, allocator, auth, args);
    }

    pub fn abortAction(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        return self.vtable.abortAction(self.ptr, allocator, auth, args);
    }

    pub fn listOutputs(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        return self.vtable.listOutputs(self.ptr, allocator, auth, args);
    }

    pub fn listActions(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        return self.vtable.listActions(self.ptr, allocator, auth, args);
    }

    pub fn internalizeAction(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        return self.vtable.internalizeAction(self.ptr, allocator, auth, args);
    }

    pub fn storeKeyShares(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId, shares: []const []const u8) !void {
        return self.vtable.storeKeyShares(self.ptr, allocator, auth, shares);
    }

    pub fn loadKeyShares(self: WalletStorageProvider, allocator: std.mem.Allocator, auth: types.AuthId) ![][]u8 {
        return self.vtable.loadKeyShares(self.ptr, allocator, auth);
    }

    pub fn destroy(self: WalletStorageProvider) void {
        self.vtable.destroy(self.ptr);
    }

    pub fn init(ptr: anytype) WalletStorageProvider {
        const Ptr = @TypeOf(ptr);
        const impl = struct {
            fn makeAvailable(p: *anyopaque, allocator: std.mem.Allocator) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.makeAvailable(allocator);
            }
            fn migrate(p: *anyopaque, allocator: std.mem.Allocator, storage_name: []const u8) anyerror![]const u8 {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.migrate(allocator, storage_name);
            }
            fn findOrInsertUser(p: *anyopaque, allocator: std.mem.Allocator, identity_key: []const u8) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.findOrInsertUser(allocator, identity_key);
            }
            fn createAction(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.createAction(allocator, auth, args);
            }
            fn processAction(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.processAction(allocator, auth, args);
            }
            fn abortAction(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.abortAction(allocator, auth, args);
            }
            fn listOutputs(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.listOutputs(allocator, auth, args);
            }
            fn listActions(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.listActions(allocator, auth, args);
            }
            fn internalizeAction(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) anyerror!std.json.Value {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.internalizeAction(allocator, auth, args);
            }
            fn storeKeyShares(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId, shares: []const []const u8) anyerror!void {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.storeKeyShares(allocator, auth, shares);
            }
            fn loadKeyShares(p: *anyopaque, allocator: std.mem.Allocator, auth: types.AuthId) anyerror![][]u8 {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.loadKeyShares(allocator, auth);
            }
            fn destroy(p: *anyopaque) void {
                const self: Ptr = @ptrCast(@alignCast(p));
                self.destroy();
            }
        };
        return .{
            .ptr = ptr,
            .vtable = &.{
                .makeAvailable = impl.makeAvailable,
                .migrate = impl.migrate,
                .findOrInsertUser = impl.findOrInsertUser,
                .createAction = impl.createAction,
                .processAction = impl.processAction,
                .abortAction = impl.abortAction,
                .listOutputs = impl.listOutputs,
                .listActions = impl.listActions,
                .internalizeAction = impl.internalizeAction,
                .storeKeyShares = impl.storeKeyShares,
                .loadKeyShares = impl.loadKeyShares,
                .destroy = impl.destroy,
            },
        };
    }
};
