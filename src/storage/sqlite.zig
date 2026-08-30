const std = @import("std");
const sqlite = @import("sqlite");
const WalletStorageProvider = @import("interface.zig").WalletStorageProvider;
const types = @import("types.zig");
const schema = @import("sqlite_schema.zig");
const util = @import("../util.zig");
const signer_types = @import("../signer/types.zig");
const json = std.json;
const sqlite_types = @import("sqlite_types.zig");

/// SQLite-backed wallet storage provider.
/// Implements the WalletStorageProvider interface for persistent local storage.
pub const SqliteStorageClient = struct {
    allocator: std.mem.Allocator,
    db: sqlite.Db,
    db_path: []u8,
    user_id: ?u32 = null,
    identity_key: []u8,

    pub const Config = schema.Config;

pub fn init(allocator: std.mem.Allocator, config: Config) !SqliteStorageClient {
        // Convert path to sentinel-terminated for zig-sqlite (dupeSentinel returns [:0]const u8)
        const path_sentinel = try allocator.dupeSentinel(u8, config.path, 0);
        defer allocator.free(path_sentinel);

        var db = try sqlite.Db.init(.{
            .mode = .{ .File = path_sentinel },
            .open_flags = .{ .write = true, .create = true },
            .threading_mode = .MultiThread,
        });

        // Initialize with pragmas and schema
        try schema.initialize(&db, config);

        return SqliteStorageClient{
            .allocator = allocator,
            .db = db,
            .db_path = try allocator.dupe(u8, config.path),
            .identity_key = try allocator.dupe(u8, ""),
        };
    }

    fn getUserId(self: *SqliteStorageClient, identity_key: []const u8) !u32 {
        // Try to find existing user
        const row = try self.db.one(
            u32,
            "SELECT user_id FROM users WHERE identity_key = ?",
            .{},
            .{ .identity_key = identity_key },
        );
        if (row) |user_id| {
            return user_id;
        }

        // Create new user
        try self.db.exec(
            "INSERT INTO users (identity_key, active_storage, created_at, updated_at) VALUES (?, '', strftime('%s','now'), strftime('%s','now'))",
            .{},
            .{ .identity_key = identity_key },
        );

        const new_id = (try self.db.one(
            u32,
            "SELECT user_id FROM users WHERE identity_key = ?",
            .{},
            .{ .identity_key = identity_key },
        )) orelse unreachable;

        return new_id;
    }

    fn ensureUser(self: *SqliteStorageClient, identity_key: []const u8) !u32 {
        if (self.user_id) |uid| {
            if (std.mem.eql(u8, identity_key, self.identity_key)) {
                return uid;
            }
        }
        const uid = try self.getUserId(identity_key);
        self.user_id = uid;
        if (self.identity_key.len > 0) self.allocator.free(self.identity_key);
        self.identity_key = try self.allocator.dupe(u8, identity_key);
        return uid;
    }

    fn nowSecs() u32 {
        return @intCast(util.nowSecs());
    }

    fn nowMillis() u64 {
        return @intCast(util.nowMilli());
    }

    // ===================== WalletStorageProvider Interface =====================

    pub fn makeAvailable(self: *SqliteStorageClient, _: std.mem.Allocator) !std.json.Value {
        var obj = try json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]json.Value{});
        try obj.put(self.allocator, "available", .{ .bool = true });
        try obj.put(self.allocator, "version", .{ .integer = schema.SCHEMA_VERSION });
        return .{ .object = obj };
    }

    pub fn migrate(_: *SqliteStorageClient, _: std.mem.Allocator, _: []const u8) ![]const u8 {
        // Migration is handled automatically on init
        return "migrated";
    }

    pub fn findOrInsertUser(self: *SqliteStorageClient, allocator: std.mem.Allocator, identity_key: []const u8) !std.json.Value {
        const user_id = try self.ensureUser(identity_key);

        var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
        try obj.put(allocator, "user", .{ .string = identity_key });
        try obj.put(allocator, "user_id", .{ .integer = user_id });
        try obj.put(allocator, "isNew", .{ .bool = false }); // We don't track "isNew" in SQLite version yet
        return .{ .object = obj };
    }

    pub fn createAction(self: *SqliteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        const user_id = try self.ensureUser(auth.identity_key);

        // Parse args manually from JSON
        const args_obj = switch (args) {
            .object => |obj| obj,
            else => return error.InvalidJsonArgs,
        };

        const description = blk: {
            if (args_obj.get("description")) |d| {
                if (d == .string) break :blk d.string;
            }
            break :blk "";
        };

        const outputs_val = args_obj.get("outputs") orelse return error.InvalidJsonArgs;
        const outputs_arr = if (outputs_val == .array) outputs_val.array.items else return error.InvalidJsonArgs;

        // Parse outputs
        var outputs_list: std.ArrayList(signer_types.ActionOutput) = .empty;
try outputs_list.ensureTotalCapacity(self.allocator, outputs_arr.len);
        defer outputs_list.deinit(self.allocator);

        for (outputs_arr) |output_val| {
            if (output_val != .object) return error.InvalidJsonArgs;
            const output_obj = output_val.object;

            const locking_script = blk: {
                if (output_obj.get("lockingScript")) |ls| {
                    if (ls == .string) break :blk ls.string;
                }
                break :blk "";
            };
            const satoshis: u64 = blk: {
                if (output_obj.get("satoshis")) |s| {
                    if (s == .integer) break :blk @intCast(s.integer);
                }
                break :blk 0;
            };

            const out_description = blk: {
                if (output_obj.get("description")) |d| {
                    if (d == .string) break :blk d.string;
                }
                break :blk null;
            };
            const basket = blk: {
                if (output_obj.get("basket")) |b| {
                    if (b == .string) break :blk b.string;
                }
                break :blk null;
            };
            const tags = blk: {
                if (args_obj.get("tags")) |t| {
                    if (t == .array) {
                        var tag_list: std.ArrayList([]const u8) = .empty;
                        try tag_list.ensureTotalCapacity(self.allocator, t.array.items.len);
                        for (t.array.items) |tv| {
                            if (tv == .string) try tag_list.append(self.allocator, tv.string);
                        }
                        break :blk try tag_list.toOwnedSlice(self.allocator);
                    }
                }
                break :blk null;
            };

            try outputs_list.append(self.allocator, .{
                .locking_script = locking_script,
                .satoshis = satoshis,
                .description = out_description,
                .basket = basket,
                .tags = tags,
            });
        }

        // Parse labels
        var labels_list: ?[]const []const u8 = null;
        if (args_obj.get("labels")) |labels_val| {
            if (labels_val == .array) {
                var labels_arr: std.ArrayList([]const u8) = .empty;
try labels_arr.ensureTotalCapacity(self.allocator, 8);
                defer labels_arr.deinit(self.allocator);
                for (labels_val.array.items) |label_val| {
                    if (label_val == .string) {
                        try labels_arr.append(self.allocator, label_val.string);
                    }
                }
                labels_list = labels_arr.toOwnedSlice(self.allocator) catch null;
            }
        }

        // Parse options
        var options = signer_types.CreateActionOptions{};
        if (args_obj.get("options")) |opts_val| {
            if (opts_val == .object) {
                const opts_obj = opts_val.object;
                if (opts_obj.get("noSend")) |v| {
                if (v == .bool) options.no_send = v.bool;
            }
            if (opts_obj.get("signAndProcess")) |v| {
                if (v == .bool) options.sign_and_process = v.bool;
            }
            if (opts_obj.get("acceptDelayedBroadcast")) |v| {
                if (v == .bool) options.accept_delayed_broadcast = v.bool;
            }
            if (opts_obj.get("returnTXIDOnly")) |v| {
                if (v == .bool) options.return_txid_only = v.bool;
            }
            if (opts_obj.get("randomizeOutputs")) |v| {
                if (v == .bool) options.randomize_outputs = v.bool;
            }
            }
        }

        const outputs = try outputs_list.toOwnedSlice(self.allocator);

        // Generate reference number (unique: millis + random bytes)
        var ref_rand: [8]u8 = undefined;
        util.randomBytes(&ref_rand);
        const ref_rand_u64: u64 = @bitCast(ref_rand);
        const reference = try std.fmt.allocPrint(self.allocator, "ref_{d}{x}", .{ nowMillis(), ref_rand_u64 });

        // Begin transaction
        try self.db.exec("BEGIN", .{}, .{});
        errdefer self.db.exec("ROLLBACK", .{}, .{}) catch {};

        // Insert transaction
        try self.db.exec(
            "INSERT INTO transactions (user_id, status, reference, is_outgoing, satoshis, description, version, lock_time, created_at, updated_at) VALUES (?, 'unsigned', ?, 1, 0, ?, 1, 0, strftime('%s','now'), strftime('%s','now'))",
            .{},
            .{ .user_id = user_id, .reference = reference, .description = description },
        );

        const tx_id = self.db.getLastInsertRowID();
        const tx_id_u32: u32 = @intCast(tx_id);

        // Insert outputs
        var total_satoshis: u64 = 0;
        for (outputs, 0..) |output, out_idx| {
            total_satoshis += output.satoshis;

            // Ensure basket exists
            if (output.basket) |b| {
                try self.db.exec(
                    "INSERT OR IGNORE INTO output_baskets (user_id, name, created_at) VALUES (?, ?, strftime('%s','now'))",
                    .{},
                    .{ .user_id = user_id, .name = b },
                );
            }

            try self.db.exec(
                "INSERT INTO outputs (user_id, transaction_id, vout, satoshis, locking_script, custom_instructions, basket_name, spendable, change, description, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, strftime('%s','now'), strftime('%s','now'))",
                .{},
                .{ .user_id = user_id, .transaction_id = tx_id_u32, .vout = @as(u32, @intCast(out_idx)), .satoshis = output.satoshis, .locking_script = output.locking_script, .custom_instructions = output.description, .basket_name = output.basket, .description = output.description },
            );
        }

        // Update transaction satoshis
        try self.db.exec(
            "UPDATE transactions SET satoshis = ? WHERE id = ?",
            .{},
            .{ .satoshis = @as(i64, @intCast(total_satoshis)), .id = tx_id_u32 },
        );

        // Insert labels
        if (labels_list) |labels| {
            for (labels) |label| {
                const label_id = try self.upsertLabel(user_id, label);
                try self.db.exec(
                    "INSERT OR IGNORE INTO transaction_labels (transaction_id, label_id) VALUES (?, ?)",
                    .{},
                    .{ .transaction_id = tx_id_u32, .label_id = label_id },
                );
            }
        }

        // Insert options if present
        if (options.no_send) {
            try self.db.exec(
                "UPDATE transactions SET status = 'nosend' WHERE id = ?",
                .{},
                .{ .id = tx_id_u32 },
            );
        }

        try self.db.exec("COMMIT", .{}, .{});

        // Return result
        var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
        try obj.put(self.allocator, "referenceNumber", .{ .string = reference });
        try obj.put(self.allocator, "txid", .{ .string = try std.fmt.allocPrint(self.allocator, "local_tx_{d}", .{nowMillis()}) });
        return .{ .object = obj };
    }

    fn upsertLabel(self: *SqliteStorageClient, user_id: u32, label: []const u8) !u32 {
        const existing = try self.db.one(
            u32,
            "SELECT id FROM labels WHERE user_id = ? AND name = ?",
            .{},
            .{ .user_id = user_id, .name = label },
        );
        if (existing) |id| return id;

        try self.db.exec(
            "INSERT INTO labels (user_id, name) VALUES (?, ?)",
            .{},
            .{ .user_id = user_id, .name = label },
        );
        return @intCast(self.db.getLastInsertRowID());
    }

    pub fn processAction(self: *SqliteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        const user_id = try self.ensureUser(auth.identity_key);

        // Parse args manually from JSON
        const args_obj = switch (args) {
            .object => |obj| obj,
            else => return error.InvalidJsonArgs,
        };

        const reference = blk: {
            if (args_obj.get("reference")) |r| {
                if (r == .string) break :blk r.string;
            }
            break :blk "";
        };

        // Parse spends
        var spends_list: std.ArrayList(signer_types.SignActionSpend) = .empty;
        defer spends_list.deinit(self.allocator);

        if (args_obj.get("spends")) |spends_val| {
            if (spends_val == .object) {
                var it = spends_val.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val = entry.value_ptr.*;
                    if (val != .object) return error.InvalidJsonArgs;
                    const spend_obj = val.object;

                    const input_index: u32 = std.fmt.parseInt(u32, key, 10) catch return error.InvalidJsonArgs;

                    const unlocking_script = blk: {
                        if (spend_obj.get("unlockingScript")) |us| {
                            if (us == .string) break :blk us.string;
                        }
                        return error.InvalidJsonArgs;
                    };

                    const sequence_number: ?u32 = blk: {
                        if (spend_obj.get("sequenceNumber")) |sn| {
                            if (sn == .integer) break :blk @intCast(sn.integer);
                        }
                        break :blk null;
                    };

                    try spends_list.append(self.allocator, .{
                        .input_index = input_index,
                        .unlocking_script = unlocking_script,
                        .sequence_number = sequence_number,
                    });
                }
            }
        }

        // Parse options
        var options = signer_types.SignActionOptions{};
        if (args_obj.get("options")) |opts_val| {
            if (opts_val == .object) {
                const opts_obj = opts_val.object;
                if (opts_obj.get("acceptDelayedBroadcast")) |v| {
                    if (v == .bool) options.accept_delayed_broadcast = v.bool;
                }
                if (opts_obj.get("returnTXIDOnly")) |v| {
                    if (v == .bool) options.return_txid_only = v.bool;
                }
                if (opts_obj.get("noSend")) |v| {
                    if (v == .bool) options.no_send = v.bool;
                }
            }
        }

        const spends = try spends_list.toOwnedSlice(self.allocator);

        // Find transaction by reference
        const tx_row_opt = try self.db.oneAlloc(
            TransactionRow,
            allocator,
            "SELECT id, user_id, status, reference, is_outgoing, satoshis, description, version, lock_time, txid, input_beef, created_at, updated_at FROM transactions WHERE reference = ? AND user_id = ?",
            .{},
            .{ reference, user_id },
        );
        const tx_row = tx_row_opt orelse return error.NotFound;

        // Update transaction status
        try self.db.exec(
            "UPDATE transactions SET status = 'unprocessed', updated_at = strftime('%s','now') WHERE id = ?",
            .{},
            .{ .id = tx_row.id },
        );

        // Process spends - mark outputs as spent
        for (spends) |spend| {
            // Find output by transaction_id and vout
            try self.db.exec(
                "UPDATE outputs SET spent_by = ?, spendable = 0, updated_at = strftime('%s','now') WHERE transaction_id = ? AND vout = ?",
                .{},
                .{ .spent_by = tx_row.id, .transaction_id = tx_row.id, .vout = spend.input_index },
            );

            // Update user_utxos
            try self.db.exec(
                "UPDATE user_utxos SET utxo_status = 'spent', reserved_by_id = ? WHERE output_id IN (SELECT id FROM outputs WHERE transaction_id = ? AND vout = ?)",
                .{},
                .{ .reserved_by_id = tx_row.id, .transaction_id = tx_row.id, .vout = spend.input_index },
            );
        }

        // Create new outputs as spendable (change outputs)
        // For now, we'll just mark the transaction as completed
        try self.db.exec(
            "UPDATE transactions SET status = 'completed', updated_at = strftime('%s','now') WHERE id = ?",
            .{},
            .{ .id = tx_row.id },
        );

        // Return result
        var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
        try obj.put(self.allocator, "txid", .{ .string = try std.fmt.allocPrint(self.allocator, "local_tx_{d}", .{nowMillis()}) });
        return .{ .object = obj };
    }

    pub fn abortAction(self: *SqliteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        const user_id = try self.ensureUser(auth.identity_key);

        var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});

        const obj_val = args;
        const reference: ?[]const u8 = blk: {
            if (obj_val == .object) {
                if (obj_val.object.get("reference")) |ref| {
                    if (ref == .string) break :blk ref.string;
                    break :blk null;
                }
                break :blk null;
            }
            break :blk null;
        };

        if (reference) |ref| {
            try self.db.exec(
                "UPDATE transactions SET status = 'aborted', updated_at = strftime('%s','now') WHERE reference = ? AND user_id = ?",
                .{},
                .{ .reference = ref, .user_id = user_id },
            );

            // Release reserved UTXOs
            try self.db.exec(
                "UPDATE outputs SET spent_by = NULL, spendable = 1, updated_at = strftime('%s','now') WHERE transaction_id IN (SELECT id FROM transactions WHERE reference = ? AND user_id = ?)",
                .{},
                .{ .reference = ref, .user_id = user_id },
            );

            try obj.put(self.allocator, "status", .{ .string = "aborted" });
        } else {
            try obj.put(self.allocator, "status", .{ .string = "error" });
            try obj.put(self.allocator, "error", .{ .string = "Invalid reference" });
        }

        return .{ .object = obj };
    }

    pub fn listOutputs(self: *SqliteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        const user_id = try self.ensureUser(auth.identity_key);

        // Parse args manually from JSON
        const args_obj = switch (args) {
            .object => |obj| obj,
            else => return error.InvalidJsonArgs,
        };

        var query_buf: std.ArrayList(u8) = .empty;
        try query_buf.ensureTotalCapacity(self.allocator, 256);
        defer query_buf.deinit(self.allocator);

        try query_buf.appendSlice(self.allocator, "SELECT id, user_id, transaction_id, spent_by, vout, satoshis, locking_script, custom_instructions, basket_name, spendable, change, description, provided_by, purpose, type, sender_identity_key FROM outputs WHERE user_id = :user_id AND (:basket IS NULL OR basket_name = :basket) AND (:spendable IS NULL OR spendable = :spendable) ORDER BY created_at DESC LIMIT COALESCE(:limit, 1000) OFFSET COALESCE(:offset, 0)");

        // Parse list args manually
        var basket: ?[]const u8 = null;
        if (args_obj.get("basket")) |b| {
            if (b == .string) basket = b.string;
        }

        var spendable: ?bool = null;
        if (args_obj.get("spendable")) |s| {
            if (s == .bool) spendable = s.bool;
        }

        var limit: ?usize = null;
        if (args_obj.get("limit")) |l| {
            if (l == .integer) limit = @intCast(l.integer);
        }

        var offset: ?usize = null;
        if (args_obj.get("offset")) |o| {
            if (o == .integer) offset = @intCast(o.integer);
        }

        var outputs_array = json.Array.init(allocator);

        var stmt = try self.db.prepareDynamic(query_buf.items);
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(OutputRow, allocator, .{ .user_id = user_id, .basket = basket, .spendable = spendable, .limit = limit, .offset = offset });
        while (try iter.nextAlloc(allocator, .{})) |row| {
            var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
            try obj.put(self.allocator, "id", .{ .integer = row.id });
            try obj.put(self.allocator, "user_id", .{ .integer = row.user_id });
            try obj.put(self.allocator, "transaction_id", .{ .integer = row.transaction_id });
            try obj.put(self.allocator, "vout", .{ .integer = row.vout });
            try obj.put(self.allocator, "satoshis", .{ .integer = row.satoshis });
            try obj.put(self.allocator, "lockingScript", .{ .string = row.locking_script });
            if (row.basket_name) |bn| try obj.put(self.allocator, "basket", .{ .string = bn });
            try obj.put(self.allocator, "spendable", .{ .bool = row.spendable });
            try obj.put(self.allocator, "change", .{ .bool = row.change });
            try obj.put(self.allocator, "description", .{ .string = row.description orelse "" });
            try outputs_array.append(.{ .object = obj });
        }

        var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
        try obj.put(self.allocator, "outputs", .{ .array = outputs_array });
        return .{ .object = obj };
    }

    pub fn listActions(self: *SqliteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, args: std.json.Value) !std.json.Value {
        const user_id = try self.ensureUser(auth.identity_key);

        // Parse args manually from JSON
        const args_obj = switch (args) {
            .object => |obj| obj,
            else => return error.InvalidJsonArgs,
        };

        const user_id_param = user_id;

        // Parse list args manually
        var limit: ?usize = null;
        if (args_obj.get("limit")) |l| {
            if (l == .integer) limit = @intCast(l.integer);
        }
        var offset: ?usize = null;
        if (args_obj.get("offset")) |o| {
            if (o == .integer) offset = @intCast(o.integer);
        }

        var query_buf: std.ArrayList(u8) = .empty;
        try query_buf.ensureTotalCapacity(self.allocator, 256);
        defer query_buf.deinit(self.allocator);

        try query_buf.appendSlice(self.allocator, "SELECT id, user_id, status, reference, is_outgoing, satoshis, description, version, lock_time, txid, input_beef, created_at, updated_at FROM transactions WHERE user_id = :user_id ORDER BY created_at DESC LIMIT COALESCE(:limit, 1000) OFFSET COALESCE(:offset, 0)");

        var actions_array = json.Array.init(allocator);

        var stmt = try self.db.prepareDynamic(query_buf.items);
        defer stmt.deinit();
        var iter = try stmt.iteratorAlloc(TransactionRow, allocator, .{ .user_id = user_id_param, .limit = limit, .offset = offset });
        while (try iter.nextAlloc(allocator, .{})) |row| {
            // Filter by labels if needed
            if (args_obj.get("labels")) |labels_val| {
                if (labels_val == .array) {
                    const tx_labels = try self.getTransactionLabels(row.id);
                    var has_label = false;
                    for (labels_val.array.items) |label| {
                        if (label != .string) continue;
                        for (tx_labels) |tl| {
                            if (std.mem.eql(u8, label.string, tl)) {
                                has_label = true;
                                break;
                            }
                        }
                        if (has_label) break;
                    }
                    if (!has_label) continue;
                }
            }

            var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
            try obj.put(self.allocator, "id", .{ .integer = row.id });
            try obj.put(self.allocator, "reference", .{ .string = row.reference });
            try obj.put(self.allocator, "status", .{ .string = row.status });
            try obj.put(self.allocator, "satoshis", .{ .integer = row.satoshis });
            try obj.put(self.allocator, "description", .{ .string = row.description orelse "" });
            if (row.txid) |txid| try obj.put(self.allocator, "txid", .{ .string = txid });
            try actions_array.append(.{ .object = obj });
        }

        var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
        try obj.put(self.allocator, "actions", .{ .array = actions_array });
        return .{ .object = obj };
    }

    fn getTransactionLabels(self: *SqliteStorageClient, tx_id: u32) ![]const []const u8 {
        const LabelRow = struct { name: []const u8 };
        var labels_list: std.ArrayList([]const u8) = .empty;
        try labels_list.ensureTotalCapacity(self.allocator, 8);
        defer labels_list.deinit(self.allocator);

        var stmt = try self.db.prepare("SELECT l.name FROM labels l JOIN transaction_labels tl ON l.id = tl.label_id WHERE tl.transaction_id = ?");
        defer stmt.deinit();

        var iter = try stmt.iteratorAlloc(LabelRow, self.allocator, .{tx_id});
        while (try iter.nextAlloc(self.allocator, .{})) |row| {
            try labels_list.append(self.allocator, row.name);
        }

        return try labels_list.toOwnedSlice(self.allocator);
    }

    pub fn internalizeAction(self: *SqliteStorageClient, _: std.mem.Allocator, _: types.AuthId, _: std.json.Value) !std.json.Value {
        // For now, just return success
        var obj = try json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]json.Value{});
        try obj.put(self.allocator, "status", .{ .string = "internalized" });
        return .{ .object = obj };
    }

    pub fn storeKeyShares(self: *SqliteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId, shares: []const []const u8) !void {
        _ = try self.ensureUser(auth.identity_key);

        const shares_json = try types.serializeShares(allocator, shares);
        defer allocator.free(shares_json);

        try self.db.exec(
            "INSERT INTO key_shares (identity_key, shares_json, created_at, updated_at) VALUES (?, ?, strftime('%s','now'), strftime('%s','now')) ON CONFLICT(identity_key) DO UPDATE SET shares_json = excluded.shares_json, updated_at = strftime('%s','now')",
            .{},
            .{ .identity_key = auth.identity_key, .shares_json = shares_json },
        );
    }

    pub fn loadKeyShares(self: *SqliteStorageClient, allocator: std.mem.Allocator, auth: types.AuthId) ![][]u8 {
        _ = try self.ensureUser(auth.identity_key);

        const row = try self.db.oneAlloc(
            KeySharesRow,
            allocator,
            "SELECT shares_json FROM key_shares WHERE identity_key = ?",
            .{},
            .{ .identity_key = auth.identity_key },
        );
        if (row == null) return error.KeySharesNotFound;

        return types.parseSharesJson(allocator, row.?.shares_json);
    }

    pub fn destroy(self: *SqliteStorageClient) void {
        if (self.identity_key.len > 0) {
            self.allocator.free(self.identity_key);
        }
        self.allocator.free(self.db_path);
        self.db.deinit();
    }

    pub fn storageProvider(self: *SqliteStorageClient) WalletStorageProvider {
        return WalletStorageProvider.init(self);
    }

    pub fn deinit(self: *SqliteStorageClient) void {
        self.destroy();
    }
};

/// Transaction row for querying
const TransactionRow = struct {
    id: u32,
    user_id: u32,
    status: []const u8,
    reference: []const u8,
    is_outgoing: bool,
    satoshis: i64,
    description: ?[]const u8,
    version: u32,
    lock_time: u32,
    txid: ?[]const u8,
    input_beef: ?[]const u8,
    created_at: i64,
    updated_at: i64,
};

/// Output row for querying (matches listOutputs SELECT column order)
const OutputRow = struct {
    id: u32,
    user_id: u32,
    transaction_id: u32,
    spent_by: ?u32,
    vout: u32,
    satoshis: i64,
    locking_script: []const u8,
    custom_instructions: ?[]const u8,
    basket_name: ?[]const u8,
    spendable: bool,
    change: bool,
    description: ?[]const u8,
    provided_by: ?[]const u8,
    purpose: ?[]const u8,
    type: ?[]const u8,
    sender_identity_key: ?[]const u8,
};

/// Row for loading stored key shares
const KeySharesRow = struct {
    shares_json: []const u8,
};
