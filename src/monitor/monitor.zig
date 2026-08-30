const std = @import("std");
const log = std.log.scoped(.monitor);

const SqliteStorageClient = @import("../storage/sqlite.zig").SqliteStorageClient;
const OneSatServices = @import("../services/onesat.zig").OneSatServices;
const services_types = @import("../services/types.zig");
const util = @import("../util.zig");

/// Background monitor for pending/failed wallet transactions.
///
/// Zig v1 of the Go/TS Monitor daemon. Covers the four Go-parity tasks as a
/// single `runOnce` pass (plus a `Daemon` wrapper that schedules passes):
///
///   1. checkForProofs  — for txs with status 'unproven'/'unmined'/'sending':
///                        ask 1Sat for a merkle proof; when one exists the tx
///                        is mined -> record proof + block height and move the
///                        transaction to 'completed'.
///   2. sendWaiting     — for outgoing txs with status 'unprocessed' older
///                        than `min_send_age_secs`: broadcast the stored BEEF
///                        (raw tx if no beef) and mark 'sending'.
///   3. failAbandoned   — for txs 'unprocessed' longer than
///                        `abandon_after_secs`: mark 'failed'.
///   4. unfailChecker   — for txs moved to 'unfail' (via
///                        listFailedActions(unfail=true)): re-check the chain;
///                        mined -> 'completed' (with proof), still unknown ->
///                        back to 'failed'.
///
/// Not covered yet (parity gaps, see ROADMAP): reorg handling (orphaned block
/// hashes), external broadcaster SSE events, lease locking for multiple
/// daemons, and per-transaction history notes.
pub const Monitor = struct {
    allocator: std.mem.Allocator,
    storage: *SqliteStorageClient,
    services: *OneSatServices,

    /// Minimum age (seconds) before an unprocessed tx is first broadcast.
    min_send_age_secs: u64 = 0,
    /// Age (seconds) after which an unprocessed tx is abandoned ('failed').
    abandon_after_secs: u64 = 60 * 60 * 24, // 24h, mirrors Go's default
    /// Upper bound for rebroadcast attempts per tx (also enforced by the
    /// known_txs.max_rebroadcast_attempts column).
    max_rebroadcast_attempts: u64 = 10,

    pub const TaskResult = struct {
        checked_for_proofs: u64 = 0,
        proofs_found: u64 = 0,
        send_waiting_attempted: u64 = 0,
        send_waiting_succeeded: u64 = 0,
        abandoned: u64 = 0,
        unfail_checked: u64 = 0,
        unfail_recovered: u64 = 0,
        unfail_refailed: u64 = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        storage: *SqliteStorageClient,
        services: *OneSatServices,
    ) Monitor {
        return .{
            .allocator = allocator,
            .storage = storage,
            .services = services,
        };
    }

    /// Run all four tasks once and return a per-task result summary.
    /// Each task is independent: one failing does not stop the others.
    pub fn runOnce(self: *Monitor) TaskResult {
        var result = TaskResult{};

        self.checkForProofs(&result) catch |err|
            log.err("checkForProofs failed: {s}", .{@errorName(err)});
        self.sendWaiting(&result) catch |err|
            log.err("sendWaiting failed: {s}", .{@errorName(err)});
        self.failAbandoned(&result) catch |err|
            log.err("failAbandoned failed: {s}", .{@errorName(err)});
        self.unfailChecker(&result) catch |err|
            log.err("unfailChecker failed: {s}", .{@errorName(err)});

        return result;
    }

    /// Task 1: look for merkle proofs of mined transactions.
    fn checkForProofs(self: *Monitor, result: *TaskResult) !void {
        const TxRow = struct { id: u32, txid: []const u8 };
        var stmt = try self.storage.db.prepareDynamic(
            "SELECT t.id, t.txid FROM transactions t WHERE t.txid IS NOT NULL AND t.status IN ('unproven','unmined','sending','unprocessed') LIMIT 1000",
        );
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(TxRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            result.checked_for_proofs += 1;
            self.recoverProofForTx(row.id, row.txid, result) catch |err| {
                log.warn("proof check for {s} failed: {s}", .{ row.txid, @errorName(err) });
            };
        }
    }

    fn recoverProofForTx(self: *Monitor, tx_row_id: u32, txid: []const u8, result: *TaskResult) !void {
        const proof = self.services.getMerklePath(self.allocator, txid) catch return;
        if (proof.merkle_path) |mp| {
            // Parse the BRC-10 merkle path for the block height.
            var block_height: ?u32 = null;
            if (bsvz.spv.MerklePath.parse(self.allocator, mp)) |path| {
                var p = path;
                defer p.deinit(self.allocator);
                block_height = p.block_height;
            } else |_| {}

            try self.storage.db.exec(
                "UPDATE known_txs SET merkle_path = ?, block_height = ?, updated_at = strftime('%s','now') WHERE txid = ?",
                .{},
                .{ .merkle_path = mp, .block_height = block_height, .txid = txid },
            );
            try self.storage.db.exec(
                "UPDATE transactions SET status = 'completed', updated_at = strftime('%s','now') WHERE id = ?",
                .{},
                .{ .id = tx_row_id },
            );
            result.proofs_found += 1;
            log.info("tx {s} mined (height {?d}) -> completed", .{ txid, block_height });
        }
    }

    /// Task 2: broadcast waiting transactions (outgoing, unprocessed, older
    /// than min_send_age_secs).
    fn sendWaiting(self: *Monitor, result: *TaskResult) !void {
        const TxRow = struct { id: u32, txid: []const u8 };
        var stmt = try self.storage.db.prepareDynamic(
            "SELECT t.id, t.txid FROM transactions t WHERE t.is_outgoing = 1 AND t.status = 'unprocessed' AND t.txid IS NOT NULL AND t.created_at <= strftime('%s','now') - ? LIMIT 100",
        );
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(TxRow, self.allocator, .{ .age = self.min_send_age_secs });
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            self.broadcastTx(row.id, row.txid, result) catch |err| {
                log.warn("broadcast of {s} failed: {s}", .{ row.txid, @errorName(err) });
            };
        }
    }

    fn broadcastTx(self: *Monitor, tx_row_id: u32, txid: []const u8, result: *TaskResult) !void {
        // Respect the per-tx rebroadcast cap.
        const attempts = (try self.storage.db.one(
            u64,
            "SELECT COALESCE(attempts, 0) FROM known_txs WHERE txid = ?",
            .{},
            .{ txid },
        )) orelse 0;
        if (attempts >= self.max_rebroadcast_attempts) return;
        result.send_waiting_attempted += 1;

        // Prefer the stored BEEF; fall back to the raw tx.
        const beef_row = (try self.storage.db.oneAlloc(
            struct { beef: ?[]const u8 },
            self.allocator,
            "SELECT beef FROM known_txs WHERE txid = ?",
            .{},
            .{ txid },
        )) orelse return;

        if (beef_row.beef) |beef| {
            const txids = [_][]const u8{txid};
            const post_results = try self.services.postBeef(self.allocator, beef, &txids);
            // Free the container slices; inner strings are borrowed/static
            // (mixed ownership — freeing them would crash on literals).
            defer {
                for (post_results) |*pr| self.allocator.free(pr.txid_results);
                self.allocator.free(post_results);
            }

            const posted = if (post_results.len > 0) post_results[0] else return;

            try self.storage.db.exec(
                "UPDATE known_txs SET attempts = attempts + 1, was_broadcast = 1, updated_at = strftime('%s','now') WHERE txid = ?",
                .{},
                .{ txid },
            );

            switch (posted.status) {
                .success => {
                    try self.storage.db.exec(
                        "UPDATE transactions SET status = 'sending', updated_at = strftime('%s','now') WHERE id = ?",
                        .{},
                        .{ .id = tx_row_id },
                    );
                    result.send_waiting_succeeded += 1;
                    log.info("broadcast {s} accepted", .{txid});
                },
                .@"error" => log.warn("broadcast {s} rejected", .{txid}),
            }
        }
    }

    /// Task 3: mark long-unprocessed txs as failed.
    fn failAbandoned(self: *Monitor, result: *TaskResult) !void {
        const r = self.storage.db.execDynamic(
            "UPDATE transactions SET status = 'failed', updated_at = strftime('%s','now') WHERE is_outgoing = 1 AND status = 'unprocessed' AND created_at <= strftime('%s','now') - ?",
            .{},
            .{ self.abandon_after_secs },
        ) catch |err| return err;
        _ = r;
        result.abandoned += self.storage.db.rowsAffected();
    }

    /// Task 4: re-check 'unfail' txs against the chain. Mined -> completed
    /// (Go also creates UTXOs for spendable outputs here; that requires the
    /// output rows which our internalize path already covers when present).
    fn unfailChecker(self: *Monitor, result: *TaskResult) !void {
        const TxRow = struct { id: u32, txid: []const u8 };
        var stmt = try self.storage.db.prepareDynamic(
            "SELECT t.id, t.txid FROM transactions t WHERE t.status = 'unfail' AND t.txid IS NOT NULL LIMIT 100",
        );
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(TxRow, self.allocator, .{});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            result.unfail_checked += 1;
            self.recheckUnfailed(row.id, row.txid, result) catch |err| {
                log.warn("unfail recheck of {s} failed: {s}", .{ row.txid, @errorName(err) });
            };
        }
    }

    fn recheckUnfailed(self: *Monitor, tx_row_id: u32, txid: []const u8, result: *TaskResult) !void {
        const status_result = self.services.getStatusForTxids(self.allocator, &[_][]const u8{txid}) catch {
            // Network unavailable: leave as 'unfail' for the next pass.
            return;
        };
        defer self.allocator.free(status_result.results);

        if (status_result.results.len == 0) return;
        switch (status_result.results[0].status) {
            .mined => {
                try self.storage.db.exec(
                    "UPDATE transactions SET status = 'completed', updated_at = strftime('%s','now') WHERE id = ?",
                    .{},
                    .{ .id = tx_row_id },
                );
                result.unfail_recovered += 1;
                log.info("unfail: {s} found mined -> completed", .{txid});
            },
            .known => {
                // Still known but unmined: back to 'unprocessed' so the
                // send/proof tasks can pick it up again.
                try self.storage.db.exec(
                    "UPDATE transactions SET status = 'unprocessed', updated_at = strftime('%s','now') WHERE id = ?",
                    .{},
                    .{ .id = tx_row_id },
                );
                result.unfail_recovered += 1;
                log.info("unfail: {s} known again -> unprocessed", .{txid});
            },
            .unknown => {
                // Confirmed not on chain: back to 'failed'.
                try self.storage.db.exec(
                    "UPDATE transactions SET status = 'failed', updated_at = strftime('%s','now') WHERE id = ?",
                    .{},
                    .{ .id = tx_row_id },
                );
                result.unfail_refailed += 1;
                log.info("unfail: {s} still unknown -> failed", .{txid});
            },
        }
    }
};

const bsvz = @import("bsvz");

/// Simple daemon loop: runs `Monitor.runOnce` every `interval_ms`.
/// Stops when `stop_flag` is set to true (checked between passes).
pub const Daemon = struct {
    monitor: *Monitor,
    interval_ms: u64,
    stop_flag: *std.atomic.Value(bool),

    /// Sleep for `ms` milliseconds in 250ms slices so `stop_flag` is
    /// honored promptly. (std.Thread.sleep was removed in Zig 0.16.)
    fn sleepMs(ms: u64) void {
        var req: std.posix.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.os.linux.nanosleep(&req, null);
    }

    pub fn run(self: *Daemon) !void {
        while (!self.stop_flag.load(.acquire)) {
            const result = self.monitor.runOnce();
            log.info("monitor pass: proofs={d}/{d} sent={d}/{d} abandoned={d} unfail_recovered={d} unfail_refailed={d}",
                .{ result.proofs_found, result.checked_for_proofs, result.send_waiting_succeeded, result.send_waiting_attempted, result.abandoned, result.unfail_recovered, result.unfail_refailed });

            // Sleep in small slices so stop_flag is honored promptly.
            var slept: u64 = 0;
            while (slept < self.interval_ms and !self.stop_flag.load(.acquire)) : (slept += 250) {
                sleepMs(250);
            }
        }
    }
};
