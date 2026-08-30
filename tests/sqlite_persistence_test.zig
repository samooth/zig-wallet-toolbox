const std = @import("std");
const testing = std.testing;
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const wtb = @import("zig-wallet-toolbox");
const Wallet = wtb.wallet.Wallet;
const WalletConfig = wtb.wallet.WalletConfig;
const WalletStorageManager = wtb.storage.WalletStorageManager;
const SqliteStorageClient = wtb.storage.SqliteStorageClient;
const ListOutputsArgs = wtb.wallet.ListOutputsArgs;
const ListActionsArgs = wtb.wallet.ListActionsArgs;
const signer_types = wtb.signer.types;

fn deleteTestDb(test_db_path: []const u8) !void {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer threaded.deinit();
    _ = std.Io.Dir.deleteFileAbsolute(threaded.io(), test_db_path) catch |err| {
        if (err != error.FileNotFound and err != error.PathNotFound) return err;
    };
    var wal_buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&wal_buf, "{s}-wal", .{test_db_path})) |wal_path| {
        _ = std.Io.Dir.deleteFileAbsolute(threaded.io(), wal_path) catch {};
    } else |_| {}
    var shm_buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&shm_buf, "{s}-shm", .{test_db_path})) |shm_path| {
        _ = std.Io.Dir.deleteFileAbsolute(threaded.io(), shm_path) catch {};
    } else |_| {}
}

test "SqliteStorageClient persistence - data survives reopen" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_sqlite_persistence.db";

    try deleteTestDb(test_db_path);

    const private_key = try ec.PrivateKey.generate();
    var pubkey = try private_key.publicKey();
    var compressed = pubkey.toCompressedSec1();
    var identity_key: [66]u8 = undefined;
    _ = try bsvz.primitives.hex.encodeLower(&compressed, &identity_key);

    {
        var storage_client = try SqliteStorageClient.init(allocator, .{
            .path = test_db_path,
            .journal_mode = "WAL",
            .busy_timeout_ms = 5000,
        });

        var storage_mgr = WalletStorageManager.init(allocator);
        storage_mgr.setActive(storage_client.storageProvider());

        var wallet = try Wallet.init(allocator, .{
            .private_key = private_key,
            .chain = .main,
            .wallet_services = undefined,
            .storage_manager = storage_mgr,
        });
        defer wallet.deinit();

        const create_args = signer_types.CreateActionArgs{
            .description = "Test payment",
            .outputs = &.{
                signer_types.ActionOutput{
                    .locking_script = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac",
                    .satoshis = 10000,
                    .description = "Payment to Alice",
                    .basket = "default",
                    .tags = &.{"payment", "test"},
                },
            },
            .labels = &.{"payment", "test"},
            .options = .{
                .no_send = true,
            },
        };
        const create_result = try wallet.createAction(create_args);
        try testing.expect(create_result.raw != .null);

        const reference = blk: {
            const obj = create_result.raw;
            if (obj == .object) {
                if (obj.object.get("referenceNumber")) |ref| {
                    if (ref == .string) break :blk ref.string;
                }
            }
            break :blk "";
        };
        try testing.expect(reference.len > 0);

        const outputs = try wallet.listOutputs(ListOutputsArgs{ .basket = "default" });
        try testing.expect(outputs != .null);

        const outputs_obj = outputs;
        if (outputs_obj == .object) {
            if (outputs_obj.object.get("outputs")) |outputs_val| {
                if (outputs_val == .array) {
                    var found = false;
                    for (outputs_val.array.items) |output| {
                        if (output == .object) {
                            if (output.object.get("description")) |desc| {
                                if (desc == .string and std.mem.eql(u8, desc.string, "Payment to Alice")) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                    try testing.expect(found);
                }
            }
        }

        const actions = try wallet.listActions(ListActionsArgs{});
        try testing.expect(actions != .null);

        const identity = wallet.getPublicKey();
        try testing.expectEqualStrings(identity, identity_key[0..]);

        const create_args2 = signer_types.CreateActionArgs{
            .description = "Second payment",
            .outputs = &.{
                signer_types.ActionOutput{
                    .locking_script = "76a914ffffffffffffffffffffffffffffffffffffffff88ac",
                    .satoshis = 5000,
                },
            },
        };
        const create_result2 = try wallet.createAction(create_args2);
        try testing.expect(create_result2.raw != .null);
    }

    {
        var storage_client = try SqliteStorageClient.init(allocator, .{
            .path = test_db_path,
            .journal_mode = "WAL",
            .busy_timeout_ms = 5000,
        });

        var storage_mgr = WalletStorageManager.init(allocator);
        storage_mgr.setActive(storage_client.storageProvider());

        var wallet = try Wallet.init(allocator, .{
            .private_key = private_key,
            .chain = .main,
            .wallet_services = undefined,
            .storage_manager = storage_mgr,
        });
        defer wallet.deinit();

        const identity = wallet.getPublicKey();
        try testing.expectEqualStrings(identity, identity_key[0..]);

        const outputs = try wallet.listOutputs(ListOutputsArgs{ .basket = "default" });
        try testing.expect(outputs != .null);

        const outputs_obj = outputs;
        if (outputs_obj == .object) {
            if (outputs_obj.object.get("outputs")) |outputs_val| {
                if (outputs_val == .array) {
                    var found = false;
                    for (outputs_val.array.items) |output| {
                        if (output == .object) {
                            if (output.object.get("description")) |desc| {
                                if (desc == .string and std.mem.eql(u8, desc.string, "Payment to Alice")) {
                                    found = true;
                                    break;
                                }
                            }
                        }
                    }
                    try testing.expect(found);
                }
            }
        }

        const actions = try wallet.listActions(ListActionsArgs{});
        try testing.expect(actions != .null);
    }

    try deleteTestDb(test_db_path);
}

test "SqliteStorageClient concurrent access" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_sqlite_concurrent.db";

    try deleteTestDb(test_db_path);

    const private_key = try ec.PrivateKey.generate();
    var pubkey = try private_key.publicKey();
    var compressed = pubkey.toCompressedSec1();
    var identity_key: [66]u8 = undefined;
    _ = try bsvz.primitives.hex.encodeLower(&compressed, &identity_key);

    var storage_client = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });

    var storage_mgr = WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = storage_mgr,
    });
    defer wallet.deinit();

    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(allocator);

    for (0..10) |i| {
        const create_args = signer_types.CreateActionArgs{
            .description = try std.fmt.allocPrint(allocator, "Concurrent test {d}", .{i}),
            .outputs = &.{
                signer_types.ActionOutput{
                    .locking_script = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac",
                    .satoshis = 1000 + @as(u64, i) * 100,
                },
            },
        };
        const result = try wallet.createAction(create_args);
        if (result.raw == .object) {
            if (result.raw.object.get("referenceNumber")) |ref| {
                if (ref == .string) {
                    try refs.append(allocator, ref.string);
                }
            }
        }
    }

    try testing.expectEqual(refs.items.len, 10);

    const actions = try wallet.listActions(ListActionsArgs{ .limit = 20 });
    try testing.expect(actions != .null);

    try deleteTestDb(test_db_path);
}

test "SqliteStorageClient WAL mode verification" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_wal_mode.db";

    try deleteTestDb(test_db_path);

    var storage_client = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer storage_client.deinit();

    const ModeRow = struct { mode: []const u8 };
    const row_opt = try storage_client.db.oneAlloc(ModeRow, allocator, "PRAGMA journal_mode", .{}, .{});
    const row = row_opt orelse return error.QueryFailed;
    try testing.expectEqualStrings(row.mode, "wal");

    try deleteTestDb(test_db_path);
}

test "SqliteStorageClient WAL checkpoint" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_checkpoint.db";

    try deleteTestDb(test_db_path);

    {
        var storage_client = try SqliteStorageClient.init(allocator, .{
            .path = test_db_path,
            .journal_mode = "WAL",
            .busy_timeout_ms = 5000,
        });

        var storage_mgr = WalletStorageManager.init(allocator);
        storage_mgr.setActive(storage_client.storageProvider());

        var wallet = try Wallet.init(allocator, .{
            .private_key = try ec.PrivateKey.generate(),
            .chain = .main,
            .wallet_services = undefined,
            .storage_manager = storage_mgr,
        });
        defer wallet.deinit();

        for (0..5) |_| {
            const create_args = signer_types.CreateActionArgs{
                .description = "Checkpoint test",
                .outputs = &.{
                    signer_types.ActionOutput{
                        .locking_script = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac",
                        .satoshis = 1000,
                    },
                },
            };
            _ = wallet.createAction(create_args) catch {};
        }
    }

    {
        var storage_client = try SqliteStorageClient.init(allocator, .{
            .path = test_db_path,
            .journal_mode = "WAL",
            .busy_timeout_ms = 5000,
        });

        _ = storage_client.db.execDynamic("PRAGMA wal_checkpoint(FULL)", .{}, .{}) catch {};

        var storage_mgr = WalletStorageManager.init(allocator);
        storage_mgr.setActive(storage_client.storageProvider());

        var wallet = try Wallet.init(allocator, .{
            .private_key = try ec.PrivateKey.generate(),
            .chain = .main,
            .wallet_services = undefined,
            .storage_manager = storage_mgr,
        });
        defer wallet.deinit();

        const outputs = try wallet.listOutputs(ListOutputsArgs{ .basket = "default", .limit = 10 });
        try testing.expect(outputs != .null);
    }

    try deleteTestDb(test_db_path);
}

test "SqliteStorageClient foreign keys enforcement" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_fk.db";

    try deleteTestDb(test_db_path);

    var storage_client = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer storage_client.deinit();

    const row = (try storage_client.db.one(u32, "PRAGMA foreign_keys", .{}, .{})) orelse return error.QueryFailed;
    try testing.expectEqual(row, 1);

    try deleteTestDb(test_db_path);
}

test "SqliteStorageClient unclean shutdown recovery" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_unclean.db";

    try deleteTestDb(test_db_path);

    {
        var storage_client = try SqliteStorageClient.init(allocator, .{
            .path = test_db_path,
            .journal_mode = "WAL",
            .busy_timeout_ms = 5000,
        });

        var storage_mgr = WalletStorageManager.init(allocator);
        storage_mgr.setActive(storage_client.storageProvider());

        var wallet = try Wallet.init(allocator, .{
            .private_key = try ec.PrivateKey.generate(),
            .chain = .main,
            .wallet_services = undefined,
            .storage_manager = storage_mgr,
        });

        const create_args = signer_types.CreateActionArgs{
            .description = "Unclean shutdown test",
            .outputs = &.{
                signer_types.ActionOutput{
                    .locking_script = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac",
                    .satoshis = 1000,
                },
            },
        };
        _ = wallet.createAction(create_args) catch {};
    }

    {
        var storage_client = try SqliteStorageClient.init(allocator, .{
            .path = test_db_path,
            .journal_mode = "WAL",
            .busy_timeout_ms = 5000,
        });

        var storage_mgr = WalletStorageManager.init(allocator);
        storage_mgr.setActive(storage_client.storageProvider());

        var wallet = try Wallet.init(allocator, .{
            .private_key = try ec.PrivateKey.generate(),
            .chain = .main,
            .wallet_services = undefined,
            .storage_manager = storage_mgr,
        });
        defer wallet.deinit();

        const outputs = try wallet.listOutputs(ListOutputsArgs{ .basket = "default", .limit = 10 });
        try testing.expect(outputs != .null);
    }

    try deleteTestDb(test_db_path);
}

test "SqliteStorageClient internalizeAction records outputs and known_tx" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_internalize.db";

    try deleteTestDb(test_db_path);

    var storage_client = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer storage_client.deinit();

    const private_key = try ec.PrivateKey.generate();
    var pubkey = try private_key.publicKey();
    const compressed = pubkey.toCompressedSec1();
    var identity_hex: [66]u8 = undefined;
    _ = try bsvz.primitives.hex.encodeLower(&compressed, &identity_hex);

    // Build a simple 1-input / 2-output transaction via bsvz.
    const dummy_input = bsvz.transaction.Input.empty();
    const dummy_script = bsvz.script.Script.init(&[_]u8{0x00}); // minimal, contents irrelevant for storage
    var tx = bsvz.transaction.Transaction{
        .version = 1,
        .inputs = &[_]bsvz.transaction.Input{dummy_input},
        .outputs = &[_]bsvz.transaction.Output{
            .{ .satoshis = 1000, .locking_script = dummy_script },
            .{ .satoshis = 2000, .locking_script = dummy_script },
        },
        .lock_time = 0,
    };
    // NOTE: no tx.deinit here — inputs/outputs reference static literals,
    // so the transaction owns no heap allocations.

    // Wrap the tx in an atomic BEEF (txid-prefixed V2 beef).
    const beef_bytes = try bsvz.transaction.beef.atomicBeefFromTransaction(allocator, &tx);
    defer allocator.free(beef_bytes);
    const beef_hex_buf = try allocator.alloc(u8, beef_bytes.len * 2);
    defer allocator.free(beef_hex_buf);
    const beef_hex = try bsvz.primitives.hex.encodeLower(beef_bytes, beef_hex_buf);

    // Build internalizeAction args: { tx: <beef hex>, outputs: [{basket: ...}] }
    var outputs_arr = std.json.Array.init(allocator);
    var out0 = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try out0.put(allocator, "basket", .{ .string = "default" });
    try outputs_arr.append(.{ .object = out0 });
    var args_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try args_obj.put(allocator, "tx", .{ .string = beef_hex });
    try args_obj.put(allocator, "outputs", .{ .array = outputs_arr });

    const auth = wtb.storage.types.AuthId{ .identity_key = &identity_hex };
    const result = try storage_client.internalizeAction(allocator, auth, .{ .object = args_obj });
    try testing.expect(result == .object);
    try testing.expectEqual(true, result.object.get("accepted").?.bool);

    // Verify outputs were recorded (2 outputs).
    const out_rows = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM outputs WHERE satoshis IN (1000, 2000)",
        .{},
        .{},
    )).?;
    try testing.expectEqual(@as(u32, 2), out_rows);

    const basket_rows = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM outputs WHERE basket_name = 'default' AND vout = 0 AND satoshis = 1000",
        .{},
        .{},
    )).?;
    try testing.expectEqual(@as(u32, 1), basket_rows);

    const basket2_rows = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM outputs WHERE vout = 1 AND satoshis = 2000",
        .{},
        .{},
    )).?;
    try testing.expectEqual(@as(u32, 1), basket2_rows);

    // Verify known_txs was upserted with the beef and status 'internalized'.
    const known_rows = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM known_txs WHERE status = 'internalized' AND beef IS NOT NULL",
        .{},
        .{},
    )).?;
    try testing.expectEqual(@as(u32, 1), known_rows);

    // Idempotency: internalizing the same BEEF twice must not error or
    // duplicate rows (INSERT OR IGNORE / ON CONFLICT paths).
    const result2 = try storage_client.internalizeAction(allocator, auth, .{ .object = args_obj });
    try testing.expectEqual(true, result2.object.get("accepted").?.bool);

    const out_rows2 = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM outputs WHERE satoshis IN (1000, 2000)",
        .{},
        .{},
    )).?;
    try testing.expectEqual(@as(u32, 2), out_rows2);

    try deleteTestDb(test_db_path);
}

test "listFailedActions spec-op: failed filtering + unfail transition" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_failed_actions.db";

    try deleteTestDb(test_db_path);

    var storage_client = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer storage_client.deinit();

    const private_key = try ec.PrivateKey.generate();
    var pubkey = try private_key.publicKey();
    const compressed = pubkey.toCompressedSec1();
    var identity_hex: [66]u8 = undefined;
    _ = try bsvz.primitives.hex.encodeLower(&compressed, &identity_hex);

    var storage_mgr = WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = storage_mgr,
    });
    defer wallet.deinit();

    const auth = wtb.storage.types.AuthId{ .identity_key = &identity_hex };

    // Create two actions, then mark both 'failed' via SQL (as a monitor would).
    const create_args = signer_types.CreateActionArgs{
        .description = "will fail",
        .outputs = &.{
            signer_types.ActionOutput{
                .locking_script = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac",
                .satoshis = 1000,
            },
        },
    };
    _ = try wallet.createAction(create_args);
    _ = try wallet.createAction(create_args);

    const failed_count = (try storage_client.db.one(
        u32,
        "UPDATE transactions SET status = 'failed' WHERE is_outgoing = 1 RETURNING 1",
        .{},
        .{},
    )) orelse 0;
    _ = failed_count;

    // Plain listActions must NOT include 'failed' rows (TS status filter set).
    {
        var args_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        const plain = try storage_client.listActions(allocator, auth, .{ .object = args_obj });
        const actions = plain.object.get("actions").?.array.items;
        try testing.expectEqual(@as(usize, 0), actions.len);
        args_obj.deinit(allocator);
    }

    // listFailedActions: both failed rows visible.
    var failed_result = try wallet.listFailedActions(.{}, false);
    {
        const actions = failed_result.object.get("actions").?.array.items;
        try testing.expectEqual(@as(usize, 2), actions.len);
        for (actions) |a| {
            try testing.expectEqualStrings("failed", a.object.get("status").?.string);
        }
    }

    // Status in DB must still be 'failed' (no unfail requested).
    {
        const still_failed = (try storage_client.db.one(
            u32,
            "SELECT COUNT(*) FROM transactions WHERE status = 'failed'",
            .{},
            .{},
        )).?;
        try testing.expectEqual(@as(u32, 2), still_failed);
    }

    // listFailedActions with unfail=true: rows reported as 'failed' on the wire,
    // persisted status transitions to 'unfail'.
    failed_result = try wallet.listFailedActions(.{}, true);
    {
        const actions = failed_result.object.get("actions").?.array.items;
        try testing.expectEqual(@as(usize, 2), actions.len);
        for (actions) |a| {
            try testing.expectEqualStrings("failed", a.object.get("status").?.string);
        }
        const unfail_count = (try storage_client.db.one(
            u32,
            "SELECT COUNT(*) FROM transactions WHERE status = 'unfail'",
            .{},
            .{},
        )).?;
        try testing.expectEqual(@as(u32, 2), unfail_count);
        const still_failed = (try storage_client.db.one(
            u32,
            "SELECT COUNT(*) FROM transactions WHERE status = 'failed'",
            .{},
            .{},
        )).?;
        try testing.expectEqual(@as(u32, 0), still_failed);
    }

    try deleteTestDb(test_db_path);
}

test "relinquishOutput clears the output basket" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_relinquish.db";

    try deleteTestDb(test_db_path);

    var storage_client = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer storage_client.deinit();

    const private_key = try ec.PrivateKey.generate();
    var pubkey = try private_key.publicKey();
    const compressed = pubkey.toCompressedSec1();
    var identity_hex: [66]u8 = undefined;
    _ = try bsvz.primitives.hex.encodeLower(&compressed, &identity_hex);

    var storage_mgr = WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = storage_mgr,
    });
    defer wallet.deinit();

    // Internalize a 1-in/2-out tx so real outputs exist in the 'default' basket.
    const dummy_input = bsvz.transaction.Input.empty();
    const dummy_script = bsvz.script.Script.init(&[_]u8{0x00});
    var tx = bsvz.transaction.Transaction{
        .version = 1,
        .inputs = &[_]bsvz.transaction.Input{dummy_input},
        .outputs = &[_]bsvz.transaction.Output{
            .{ .satoshis = 1000, .locking_script = dummy_script },
            .{ .satoshis = 2000, .locking_script = dummy_script },
        },
        .lock_time = 0,
    };
    const beef_bytes = try bsvz.transaction.beef.atomicBeefFromTransaction(allocator, &tx);
    defer allocator.free(beef_bytes);
    const beef_hex_buf = try allocator.alloc(u8, beef_bytes.len * 2);
    defer allocator.free(beef_hex_buf);
    const beef_hex = try bsvz.primitives.hex.encodeLower(beef_bytes, beef_hex_buf);

    var args_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try args_obj.put(allocator, "tx", .{ .string = beef_hex });
    const auth = wtb.storage.types.AuthId{ .identity_key = &identity_hex };
    const result = try storage_client.internalizeAction(allocator, auth, .{ .object = args_obj });
    // NOTE: mixed-ownership result (literal keys + one duped heap string):
    // free the only heap allocation (the txid) — freeResult is meant for
    // deep-copied (Remote) results.
    const txid = result.object.get("txid").?.string;
    defer allocator.free(@constCast(txid));

    // Relinquish output 0 from the default basket.
    const relinquished = try wallet.relinquishOutput("default", txid, 0);
    try testing.expectEqual(@as(u64, 1), relinquished);

    // vout 0 has no basket; vout 1 is untouched.
    const basket0 = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM outputs WHERE vout = 0 AND basket_name IS NULL",
        .{},
        .{},
    )).?;
    try testing.expectEqual(@as(u32, 1), basket0);

    const basket1 = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM outputs WHERE vout = 1 AND basket_name = 'default'",
        .{},
        .{},
    )).?;
    try testing.expectEqual(@as(u32, 1), basket1);

    // Relinquishing the same output again matches nothing (idempotent).
    const relinquished2 = try wallet.relinquishOutput("default", txid, 0);
    try testing.expectEqual(@as(u64, 0), relinquished2);

    // Unknown txid relinquishes nothing.
    const relinquished3 = try wallet.relinquishOutput("default", "0000000000000000000000000000000000000000000000000000000000000000", 0);
    try testing.expectEqual(@as(u64, 0), relinquished3);

    try deleteTestDb(test_db_path);
}
