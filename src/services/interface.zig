const std = @import("std");
const types = @import("types.zig");

pub const WalletServices = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getMerklePath: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, txid: []const u8) anyerror!types.MerklePathResult,
        getRawTx: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, txid: []const u8) anyerror!types.RawTxResult,
        postBeef: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, beef: []const u8, txids: []const []const u8) anyerror![]types.PostBeefResult,
        getBeefForTxid: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, txid: []const u8) anyerror![]u8,
        getStatusForTxids: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, txids: []const []const u8) anyerror!types.GetStatusForTxidsResult,
        getUtxoStatus: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, outpoint: []const u8) anyerror!types.UtxoStatusResult,
        getHeight: *const fn (ptr: *anyopaque) anyerror!u32,
        getHeaderForHeight: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, height: u32) anyerror!types.BlockHeader,
        findChainTipHeader: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!types.BlockHeader,
        isValidRootForHeight: *const fn (ptr: *anyopaque, root: [32]u8, height: u32) anyerror!bool,
        nLockTimeIsFinal: *const fn (ptr: *anyopaque, n_lock_time: u32) anyerror!bool,
    };

    pub fn getMerklePath(self: WalletServices, allocator: std.mem.Allocator, txid: []const u8) !types.MerklePathResult {
        return self.vtable.getMerklePath(self.ptr, allocator, txid);
    }

    pub fn getRawTx(self: WalletServices, allocator: std.mem.Allocator, txid: []const u8) !types.RawTxResult {
        return self.vtable.getRawTx(self.ptr, allocator, txid);
    }

    pub fn postBeef(self: WalletServices, allocator: std.mem.Allocator, beef: []const u8, txids: []const []const u8) ![]types.PostBeefResult {
        return self.vtable.postBeef(self.ptr, allocator, beef, txids);
    }

    pub fn getBeefForTxid(self: WalletServices, allocator: std.mem.Allocator, txid: []const u8) ![]u8 {
        return self.vtable.getBeefForTxid(self.ptr, allocator, txid);
    }

    pub fn getStatusForTxids(self: WalletServices, allocator: std.mem.Allocator, txids: []const []const u8) !types.GetStatusForTxidsResult {
        return self.vtable.getStatusForTxids(self.ptr, allocator, txids);
    }

    pub fn getUtxoStatus(self: WalletServices, allocator: std.mem.Allocator, outpoint: []const u8) !types.UtxoStatusResult {
        return self.vtable.getUtxoStatus(self.ptr, allocator, outpoint);
    }

    pub fn getHeight(self: WalletServices) !u32 {
        return self.vtable.getHeight(self.ptr);
    }

    pub fn getHeaderForHeight(self: WalletServices, allocator: std.mem.Allocator, height: u32) !types.BlockHeader {
        return self.vtable.getHeaderForHeight(self.ptr, allocator, height);
    }

    pub fn findChainTipHeader(self: WalletServices, allocator: std.mem.Allocator) !types.BlockHeader {
        return self.vtable.findChainTipHeader(self.ptr, allocator);
    }

    pub fn isValidRootForHeight(self: WalletServices, root: [32]u8, height: u32) !bool {
        return self.vtable.isValidRootForHeight(self.ptr, root, height);
    }

    pub fn nLockTimeIsFinal(self: WalletServices, n_lock_time: u32) !bool {
        return self.vtable.nLockTimeIsFinal(self.ptr, n_lock_time);
    }

    pub fn init(ptr: anytype) WalletServices {
        const Ptr = @TypeOf(ptr);
        const impl = struct {
            fn getMerklePath(p: *anyopaque, allocator: std.mem.Allocator, txid: []const u8) anyerror!types.MerklePathResult {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.getMerklePath(allocator, txid);
            }
            fn getRawTx(p: *anyopaque, allocator: std.mem.Allocator, txid: []const u8) anyerror!types.RawTxResult {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.getRawTx(allocator, txid);
            }
            fn postBeef(p: *anyopaque, allocator: std.mem.Allocator, beef: []const u8, txids: []const []const u8) anyerror![]types.PostBeefResult {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.postBeef(allocator, beef, txids);
            }
            fn getBeefForTxid(p: *anyopaque, allocator: std.mem.Allocator, txid: []const u8) anyerror![]u8 {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.getBeefForTxid(allocator, txid);
            }
            fn getStatusForTxids(p: *anyopaque, allocator: std.mem.Allocator, txids: []const []const u8) anyerror!types.GetStatusForTxidsResult {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.getStatusForTxids(allocator, txids);
            }
            fn getUtxoStatus(p: *anyopaque, allocator: std.mem.Allocator, outpoint: []const u8) anyerror!types.UtxoStatusResult {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.getUtxoStatus(allocator, outpoint);
            }
            fn getHeight(p: *anyopaque) anyerror!u32 {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.getHeight();
            }
            fn getHeaderForHeight(p: *anyopaque, allocator: std.mem.Allocator, height: u32) anyerror!types.BlockHeader {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.getHeaderForHeight(allocator, height);
            }
            fn findChainTipHeader(p: *anyopaque, allocator: std.mem.Allocator) anyerror!types.BlockHeader {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.findChainTipHeader(allocator);
            }
            fn isValidRootForHeight(p: *anyopaque, root: [32]u8, height: u32) anyerror!bool {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.isValidRootForHeight(root, height);
            }
            fn nLockTimeIsFinal(p: *anyopaque, n_lock_time: u32) anyerror!bool {
                const self: Ptr = @ptrCast(@alignCast(p));
                return self.nLockTimeIsFinal(n_lock_time);
            }
        };
        return .{
            .ptr = ptr,
            .vtable = &.{
                .getMerklePath = impl.getMerklePath,
                .getRawTx = impl.getRawTx,
                .postBeef = impl.postBeef,
                .getBeefForTxid = impl.getBeefForTxid,
                .getStatusForTxids = impl.getStatusForTxids,
                .getUtxoStatus = impl.getUtxoStatus,
                .getHeight = impl.getHeight,
                .getHeaderForHeight = impl.getHeaderForHeight,
                .findChainTipHeader = impl.findChainTipHeader,
                .isValidRootForHeight = impl.isValidRootForHeight,
                .nLockTimeIsFinal = impl.nLockTimeIsFinal,
            },
        };
    }
};
