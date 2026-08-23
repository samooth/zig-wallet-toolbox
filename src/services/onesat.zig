const std = @import("std");
const types = @import("types.zig");
const util = @import("../util.zig");
const WalletServices = @import("interface.zig").WalletServices;
const ChaintracksClient = @import("chaintracks.zig").ChaintracksClient;
const BeefClient = @import("beef.zig").BeefClient;
const ArcadeClient = @import("arcade.zig").ArcadeClient;
const TxoClient = @import("txo.zig").TxoClient;

pub const OneSatServices = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    host_owned: bool,
    chain: Chain,
    chaintracks: ChaintracksClient,
    beef: BeefClient,
    arcade: ArcadeClient,
    txo: TxoClient,

    pub const Chain = enum { main, @"test" };

    const mainnet_host = "https://api.1sat.app";
    const testnet_host = "https://testnet.api.1sat.app";
    const service_name = "1sat-api";

    pub fn init(allocator: std.mem.Allocator, chain: Chain, host: ?[]const u8, io: std.Io) OneSatServices {
        const h = host orelse switch (chain) {
            .main => mainnet_host,
            .@"test" => testnet_host,
        };
        const owned = host != null;
        return .{
            .allocator = allocator,
            .host = h,
            .host_owned = owned,
            .chain = chain,
            .chaintracks = ChaintracksClient.init(allocator, io, h),
            .beef = BeefClient.init(allocator, io, h),
            .arcade = ArcadeClient.init(allocator, io, h),
            .txo = TxoClient.init(allocator, io, h),
        };
    }

    pub fn deinit(self: *OneSatServices) void {
        self.chaintracks.deinit();
        self.beef.deinit();
        self.arcade.deinit();
        self.txo.deinit();
    }

    pub fn storageUrl(self: *const OneSatServices, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/1sat/wallet", .{self.host});
    }

    /// Returns a WalletServices interface backed by this instance.
    pub fn walletServices(self: *OneSatServices) WalletServices {
        return WalletServices.init(self);
    }

    // --- WalletServices vtable methods ---

    pub fn getMerklePath(self: *OneSatServices, allocator: std.mem.Allocator, txid: []const u8) !types.MerklePathResult {
        const proof_bytes = self.beef.getProof(txid) catch {
            return .{
                .name = service_name,
                .merkle_path = null,
                .block_header = null,
            };
        };

        // Parse block height from the proof binary (BRC-10 MerklePath format):
        // The first 4 bytes after a varint blockHeight.
        // For now, return proof bytes directly; block header lookup requires parsing blockHeight.
        // TODO: Parse blockHeight from merkle path binary to fetch the corresponding header.
        _ = allocator;
        return .{
            .name = service_name,
            .merkle_path = proof_bytes,
            .block_header = null,
        };
    }

    pub fn getRawTx(self: *OneSatServices, allocator: std.mem.Allocator, txid: []const u8) !types.RawTxResult {
        _ = allocator;
        const raw = self.beef.getRawTx(txid) catch {
            return .{
                .txid = txid,
                .name = service_name,
                .raw_tx = null,
            };
        };
        return .{
            .txid = txid,
            .name = service_name,
            .raw_tx = raw,
        };
    }

    pub fn postBeef(self: *OneSatServices, allocator: std.mem.Allocator, beef: []const u8, txids: []const []const u8) ![]types.PostBeefResult {
        var results: std.ArrayList(types.PostBeefResult) = .empty;
        try results.ensureTotalCapacity(allocator, txids.len);

        for (txids) |txid| {
            const status = self.arcade.submitTransaction(beef, .{}) catch {
                results.appendAssumeCapacity(.{
                    .name = service_name,
                    .status = .@"error",
                    .txid_results = &.{},
                    .@"error" = "Network error submitting transaction",
                });
                continue;
            };

            const tx_status: types.PostedTxid.ResultStatus = switch (status.tx_status) {
                .MINED, .SEEN_ON_NETWORK, .ACCEPTED_BY_NETWORK, .RECEIVED, .SENT_TO_NETWORK => .success,
                .REJECTED => .@"error",
                .DOUBLE_SPEND_ATTEMPTED => .double_spend,
                .UNKNOWN => .@"error",
                .IMMUTABLE => .success,
            };

            const overall: types.PostBeefResult.Status = switch (status.tx_status) {
                .REJECTED, .DOUBLE_SPEND_ATTEMPTED => .@"error",
                else => .success,
            };

            const posted = try allocator.alloc(types.PostedTxid, 1);
            posted[0] = .{
                .txid = status.txid orelse txid,
                .result = tx_status,
                .already_known = false,
                .double_spend = status.tx_status == .DOUBLE_SPEND_ATTEMPTED,
                .block_hash = status.block_hash,
                .block_height = status.block_height,
                .merkle_path = null,
                .competing_txs = status.competing_txs,
                .data = null,
                .@"error" = status.extra_info,
            };

            results.appendAssumeCapacity(.{
                .name = service_name,
                .status = overall,
                .txid_results = posted,
                .@"error" = if (overall == .@"error") (status.extra_info orelse "Transaction rejected") else null,
            });
        }

        return results.toOwnedSlice(allocator);
    }

    pub fn getBeefForTxid(self: *OneSatServices, allocator: std.mem.Allocator, txid: []const u8) ![]u8 {
        _ = allocator;
        return self.beef.getBeef(txid);
    }

    pub fn getStatusForTxids(self: *OneSatServices, allocator: std.mem.Allocator, txids: []const []const u8) !types.GetStatusForTxidsResult {
        var results: std.ArrayList(types.TxStatusDetail) = .empty;
        try results.ensureTotalCapacity(allocator, txids.len);
        var current_height: ?u32 = null;

        for (txids) |txid| {
            const detail = self.getStatusForSingleTxid(txid, &current_height) catch types.TxStatusDetail{
                .txid = txid,
                .depth = null,
                .status = .unknown,
            };
            results.appendAssumeCapacity(detail);
        }

        return .{
            .name = service_name,
            .status = .success,
            .results = results.toOwnedSlice(allocator) catch &.{},
        };
    }

    fn getStatusForSingleTxid(self: *OneSatServices, txid: []const u8, current_height: *?u32) !types.TxStatusDetail {
        // Try Arcade first
        if (self.arcade.getStatus(txid)) |status| {
            switch (status.tx_status) {
                .MINED, .IMMUTABLE => {
                    if (current_height.* == null) {
                        current_height.* = try self.chaintracks.currentHeight();
                    }
                    const depth = if (status.block_height) |bh|
                        current_height.*.? - bh + 1
                    else
                        1;
                    return .{ .txid = txid, .depth = depth, .status = .mined };
                },
                .SEEN_ON_NETWORK, .ACCEPTED_BY_NETWORK, .SENT_TO_NETWORK, .RECEIVED => {
                    return .{ .txid = txid, .depth = 0, .status = .known };
                },
                else => {},
            }
        } else |_| {}

        // Fall back to beef storage
        _ = self.beef.getBeef(txid) catch {
            return .{ .txid = txid, .depth = null, .status = .unknown };
        };
        // If beef returned data, tx is at least known.
        // TODO: Parse BEEF to check for merkle proof (mined) vs no proof (known).
        return .{ .txid = txid, .depth = 0, .status = .known };
    }

    pub fn getUtxoStatus(self: *OneSatServices, allocator: std.mem.Allocator, outpoint: []const u8) !types.UtxoStatusResult {
        const txo_result = self.txo.get(outpoint, .{ .sats = true, .spend = true, .block = true }) catch {
            return .{
                .name = service_name,
                .status = .success,
                .is_utxo = false,
                .details = &.{},
            };
        };

        const is_utxo = txo_result.spend == null;

        if (!is_utxo) {
            return .{
                .name = service_name,
                .status = .success,
                .is_utxo = false,
                .details = &.{},
            };
        }

        // Parse txid and vout from outpoint (format: "txid_vout")
        var txid: []const u8 = outpoint;
        var vout: u32 = 0;
        if (std.mem.indexOfScalar(u8, outpoint, '_')) |sep| {
            txid = outpoint[0..sep];
            vout = std.fmt.parseInt(u32, outpoint[sep + 1 ..], 10) catch 0;
        }

        const details = try allocator.alloc(types.UtxoDetail, 1);
        details[0] = .{
            .txid = txid,
            .index = vout,
            .satoshis = txo_result.satoshis,
            .height = txo_result.block_height,
        };

        return .{
            .name = service_name,
            .status = .success,
            .is_utxo = true,
            .details = details,
        };
    }

    pub fn getHeight(self: *OneSatServices) !u32 {
        return self.chaintracks.currentHeight();
    }

    pub fn getHeaderForHeight(self: *OneSatServices, allocator: std.mem.Allocator, height: u32) !types.BlockHeader {
        _ = allocator;
        return (try self.chaintracks.findHeaderForHeight(height)) orelse error.HeaderNotFound;
    }

    pub fn findChainTipHeader(self: *OneSatServices, allocator: std.mem.Allocator) !types.BlockHeader {
        const height = try self.chaintracks.currentHeight();
        return self.getHeaderForHeight(allocator, height);
    }

    pub fn isValidRootForHeight(self: *OneSatServices, root: [32]u8, height: u32) !bool {
        return self.chaintracks.isValidRootForHeight(root, height);
    }

    pub fn nLockTimeIsFinal(self: *OneSatServices, n_lock_time: u32) !bool {
        const block_limit: u32 = 500_000_000;

        if (n_lock_time >= block_limit) {
            const now = util.nowSecs();
            return n_lock_time < now;
        }

        const height = try self.chaintracks.currentHeight();
        return n_lock_time < height;
    }
};
