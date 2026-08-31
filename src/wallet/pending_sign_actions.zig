const std = @import("std");
const sqlite = @import("sqlite");
const util = @import("../util.zig");

/// SQLite-backed repository of pending sign actions (Go SDK parity:
/// pkg/wallet/pending.SignActionsRepository, upgraded to durable storage
/// per this repo's design decision).
///
/// `createAction` saves the assembled transaction + original creation args
/// (and input BEEF) under the storage reference; `signAction` retrieves it
/// to merge args and build the final tx; `abortAction` / successful signing
/// delete it. Rows expire after `ttl_secs` (lazy cleanup on access; the
/// Monitor's failAbandoned path also benefits since a stale pending action
/// no longer resurrects).
pub const PendingSignActionsRepo = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Db,
    /// Time-to-live for pending actions in seconds (Go default: 24h).
    ttl_secs: u64 = 24 * 60 * 60,

    pub const PendingSignAction = struct {
        reference: []const u8,
        identity_key: []const u8,
        /// Serialized transaction JSON (owned by caller).
        tx_json: []const u8,
        /// Original CreateActionArgs JSON (owned by caller).
        create_args_json: []const u8,
        /// Input BEEF hex, when present (owned by caller).
        input_beef: ?[]const u8,
    };

    pub const SaveArgs = struct {
        reference: []const u8,
        identity_key: []const u8,
        tx_json: []const u8,
        create_args_json: []const u8,
        input_beef: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Db) PendingSignActionsRepo {
        return .{ .allocator = allocator, .db = db };
    }

    /// Store a pending sign action. Re-saving the same reference replaces it
    /// (mirrors Go's sync.Map Store semantics).
    pub fn save(self: *PendingSignActionsRepo, args: SaveArgs) !void {
        try self.db.exec(
            "INSERT INTO pending_sign_actions (reference, identity_key, tx_json, create_args_json, input_beef, expires_at) VALUES (?, ?, ?, ?, ?, strftime('%s','now') + ?) ON CONFLICT(reference) DO UPDATE SET identity_key = excluded.identity_key, tx_json = excluded.tx_json, create_args_json = excluded.create_args_json, input_beef = excluded.input_beef, created_at = strftime('%s','now'), expires_at = excluded.expires_at",
            .{},
            .{
                .reference = args.reference,
                .identity_key = args.identity_key,
                .tx_json = args.tx_json,
                .create_args_json = args.create_args_json,
                .input_beef = args.input_beef,
                .ttl = @as(i64, @intCast(self.ttl_secs)),
            },
        );
        try self.cleanupExpired();
    }

    pub const GetError = error{ NotFound, Expired };

    /// Retrieve a pending sign action by reference. All returned strings are
    /// freshly allocated (caller frees via `freeAction`). Fails with
    /// `error.Expired` (and removes the row) when past its TTL.
    pub fn get(self: *PendingSignActionsRepo, reference: []const u8) GetError!PendingSignAction {
        const Row = struct {
            reference: []const u8,
            identity_key: []const u8,
            tx_json: []const u8,
            create_args_json: []const u8,
            input_beef: ?[]const u8,
            expires_at: i64,
        };

        const row = self.db.oneAlloc(
            Row,
            self.allocator,
            "SELECT reference, identity_key, tx_json, create_args_json, input_beef, expires_at FROM pending_sign_actions WHERE reference = ?",
            .{},
            .{reference},
        ) catch return error.NotFound;

        const owned = row orelse return error.NotFound;

        if (owned.expires_at <= @as(i64, @intCast(util.nowSecs()))) {
            // Expired: drop it and report not-found to the caller.
            self.db.exec(
                "DELETE FROM pending_sign_actions WHERE reference = ?",
                .{},
                .{reference},
            ) catch {};
            freeRow(self.allocator, owned);
            return error.Expired;
        }

        return .{
            .reference = owned.reference,
            .identity_key = owned.identity_key,
            .tx_json = owned.tx_json,
            .create_args_json = owned.create_args_json,
            .input_beef = owned.input_beef,
        };
    }

    /// Remove a pending sign action (idempotent).
    pub fn delete(self: *PendingSignActionsRepo, reference: []const u8) !void {
        try self.db.exec(
            "DELETE FROM pending_sign_actions WHERE reference = ?",
            .{},
            .{reference},
        );
    }

    /// Free a PendingSignAction returned by `get`.
    pub fn freeAction(self: *PendingSignActionsRepo, action: PendingSignAction) void {
        self.allocator.free(action.reference);
        self.allocator.free(action.identity_key);
        self.allocator.free(action.tx_json);
        self.allocator.free(action.create_args_json);
        if (action.input_beef) |b| self.allocator.free(b);
    }

    fn freeRow(allocator: std.mem.Allocator, row: anytype) void {
        allocator.free(row.reference);
        allocator.free(row.identity_key);
        allocator.free(row.tx_json);
        allocator.free(row.create_args_json);
        if (row.input_beef) |b| allocator.free(b);
    }

    fn cleanupExpired(self: *PendingSignActionsRepo) !void {
        try self.db.exec(
            "DELETE FROM pending_sign_actions WHERE expires_at <= strftime('%s','now')",
            .{},
            .{},
        );
    }
};
