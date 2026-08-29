const std = @import("std");
const sqlite = @import("sqlite");

/// Current schema version. Increment when making breaking schema changes.
pub const SCHEMA_VERSION: u32 = 2;

/// Run all schema migrations up to SCHEMA_VERSION.
/// This is idempotent - safe to call multiple times.
pub fn migrate(db: *sqlite.Db) !void {
    // Create schema_version table first
    try db.exec(
        "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL DEFAULT (strftime('%s','now')))",
        .{},
        .{},
    );

    // Get current version
    var current_version: u32 = 0;
    const row = try db.one(u32, "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1", .{}, .{});
    if (row) |v| current_version = v;

    if (current_version >= SCHEMA_VERSION) {
        return;
    }

    // Apply all schema statements
    const statements = [_][]const u8{
        "CREATE TABLE IF NOT EXISTS users (user_id INTEGER PRIMARY KEY AUTOINCREMENT, identity_key TEXT NOT NULL UNIQUE, active_storage TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')))",
        "CREATE TABLE IF NOT EXISTS output_baskets (user_id INTEGER NOT NULL, name TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), PRIMARY KEY (user_id, name), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS transactions (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, status TEXT NOT NULL, reference TEXT NOT NULL UNIQUE, is_outgoing BOOLEAN NOT NULL DEFAULT 1, satoshis INTEGER NOT NULL DEFAULT 0, description TEXT, version INTEGER NOT NULL DEFAULT 1, lock_time INTEGER NOT NULL DEFAULT 0, txid TEXT UNIQUE, input_beef BLOB, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON transactions(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_txid ON transactions(txid)",
        "CREATE INDEX IF NOT EXISTS idx_transactions_status ON transactions(status)",
        "CREATE TABLE IF NOT EXISTS outputs (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, transaction_id INTEGER NOT NULL, spent_by INTEGER, vout INTEGER NOT NULL, satoshis INTEGER NOT NULL, locking_script BLOB NOT NULL, custom_instructions TEXT, derivation_prefix TEXT, derivation_suffix TEXT, basket_name TEXT, spendable BOOLEAN NOT NULL DEFAULT 1, change BOOLEAN NOT NULL DEFAULT 0, description TEXT, provided_by TEXT, purpose TEXT, type TEXT, sender_identity_key TEXT, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE, FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE, FOREIGN KEY (spent_by) REFERENCES transactions(id) ON DELETE SET NULL, FOREIGN KEY (user_id, basket_name) REFERENCES output_baskets(user_id, name))",
        "CREATE INDEX IF NOT EXISTS idx_outputs_user_id ON outputs(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_outputs_tx_id ON outputs(transaction_id)",
        "CREATE INDEX IF NOT EXISTS idx_outputs_spent_by ON outputs(spent_by)",
        "CREATE INDEX IF NOT EXISTS idx_outputs_spendable ON outputs(spendable)",
        "CREATE INDEX IF NOT EXISTS idx_outputs_user_basket ON outputs(user_id, basket_name)",
        "CREATE INDEX IF NOT EXISTS idx_outputs_vout ON outputs(vout)",
        "CREATE TABLE IF NOT EXISTS tags (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, name TEXT NOT NULL, UNIQUE (user_id, name), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS output_tags (output_id INTEGER NOT NULL, tag_id INTEGER NOT NULL, PRIMARY KEY (output_id, tag_id), FOREIGN KEY (output_id) REFERENCES outputs(id) ON DELETE CASCADE, FOREIGN KEY (tag_id) REFERENCES tags(id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS labels (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, name TEXT NOT NULL, UNIQUE (user_id, name), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS transaction_labels (transaction_id INTEGER NOT NULL, label_id INTEGER NOT NULL, PRIMARY KEY (transaction_id, label_id), FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE, FOREIGN KEY (label_id) REFERENCES labels(id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS known_txs (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, txid TEXT NOT NULL, status TEXT NOT NULL, raw_tx BLOB, beef BLOB, merkle_path BLOB, block_height INTEGER, block_hash TEXT, attempts INTEGER NOT NULL DEFAULT 0, max_rebroadcast_attempts INTEGER NOT NULL DEFAULT 10, was_broadcast BOOLEAN NOT NULL DEFAULT 0, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), UNIQUE (user_id, txid), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE)",
        "CREATE INDEX IF NOT EXISTS idx_known_txs_user_id ON known_txs(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_known_txs_txid ON known_txs(txid)",
        "CREATE INDEX IF NOT EXISTS idx_known_txs_status ON known_txs(status)",
        "CREATE INDEX IF NOT EXISTS idx_known_txs_broadcast ON known_txs(was_broadcast)",
        "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')))",
        "CREATE TABLE IF NOT EXISTS sync_state (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, storage_name TEXT NOT NULL, last_synced_at INTEGER, chunk_size INTEGER NOT NULL DEFAULT 1000, FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS key_value (key TEXT PRIMARY KEY, value BLOB NOT NULL, updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')))",
        "CREATE TABLE IF NOT EXISTS key_shares (identity_key TEXT PRIMARY KEY, shares_json TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')))",
        "CREATE TABLE IF NOT EXISTS commissions (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, transaction_id INTEGER NOT NULL, amount INTEGER NOT NULL, description TEXT, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE, FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS user_utxos (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, output_id INTEGER NOT NULL, reserved_by_id INTEGER, utxo_status TEXT NOT NULL, satoshis INTEGER NOT NULL, FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE, FOREIGN KEY (output_id) REFERENCES outputs(id) ON DELETE CASCADE, FOREIGN KEY (reserved_by_id) REFERENCES transactions(id) ON DELETE SET NULL)",
        "CREATE INDEX IF NOT EXISTS idx_user_utxos_selection ON user_utxos(user_id, utxo_status, satoshis)",
        "CREATE INDEX IF NOT EXISTS idx_user_utxos_reserved ON user_utxos(reserved_by_id)",
        "CREATE TABLE IF NOT EXISTS certificates (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, name TEXT NOT NULL, data BLOB NOT NULL, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS certificate_fields (id INTEGER PRIMARY KEY AUTOINCREMENT, certificate_id INTEGER NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL, FOREIGN KEY (certificate_id) REFERENCES certificates(id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS tx_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_id INTEGER NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE)",
        "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL DEFAULT (strftime('%s','now')))",
    };

    for (statements) |stmt| {
        try db.execDynamic(stmt, .{}, .{});
    }

    // Insert version record
    try db.exec(
        "INSERT OR REPLACE INTO schema_version (version, applied_at) VALUES (?, strftime('%s','now'))",
        .{},
        .{SCHEMA_VERSION},
    );
}

/// Initialize database with pragmas and schema.
/// Call this immediately after opening the database.
pub fn initialize(db: *sqlite.Db, config: Config) !void {
    // Enable foreign keys
    db.exec("PRAGMA foreign_keys = ON", .{}, .{}) catch {};

    // Set journal mode (WAL for concurrent access)
    if (config.journal_mode) |mode| {
        var buf: [64]u8 = undefined;
        const pragma = try std.fmt.bufPrint(&buf, "PRAGMA journal_mode = {s}", .{mode});
        // PRAGMA setters return a row, which exec reports as ExecReturnedData.
        db.execDynamic(pragma, .{}, .{}) catch {};
    }

    // Busy timeout for concurrent access
    if (config.busy_timeout_ms) |ms| {
        var buf: [64]u8 = undefined;
        const pragma = try std.fmt.bufPrint(&buf, "PRAGMA busy_timeout = {d}", .{ms});
        db.execDynamic(pragma, .{}, .{}) catch {};
    }

    // Synchronous mode
    if (config.synchronous) |sync| {
        var buf: [64]u8 = undefined;
        const pragma = try std.fmt.bufPrint(&buf, "PRAGMA synchronous = {s}", .{sync});
        db.execDynamic(pragma, .{}, .{}) catch {};
    }

    // Run migrations
    try migrate(db);
}

/// Configuration for database initialization.
pub const Config = struct {
    path: []const u8,
    journal_mode: ?[]const u8 = "WAL",
    busy_timeout_ms: ?u32 = 5000,
    foreign_keys: bool = true,
    synchronous: ?[]const u8 = "NORMAL",
};
