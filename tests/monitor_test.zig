const std = @import("std");
const testing = std.testing;
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const wtb = @import("zig-wallet-toolbox");
const Wallet = wtb.wallet.Wallet;
const WalletStorageManager = wtb.storage.WalletStorageManager;
const SqliteStorageClient = wtb.storage.SqliteStorageClient;
const Monitor = wtb.monitor.Monitor;
const OneSatServices = wtb.services.OneSatServices;
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

test "Monitor: failAbandoned marks stale unprocessed txs failed" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_monitor_abandon.db";
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
    const auth = wtb.storage.types.AuthId{ .identity_key = &identity_hex };

    // Create two outgoing actions (status 'unsigned' from createAction).
    var outputs_arr = std.json.Array.init(allocator);
    var out0 = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try out0.put(allocator, "lockingScript", .{ .string = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac" });
    try out0.put(allocator, "satoshis", .{ .integer = 1000 });
    try outputs_arr.append(.{ .object = out0 });
    var args_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer args_obj.deinit(allocator);
    try args_obj.put(allocator, "description", .{ .string = "monitor test" });
    try args_obj.put(allocator, "outputs", .{ .array = outputs_arr });
    const create_result = try storage_client.createAction(allocator, auth, .{ .object = args_obj });
    const ref = create_result.object.get("referenceNumber").?.string;

    // Simulate the normal lifecycle: mark unprocessed, then age it out.
    try storage_client.db.exec(
        "UPDATE transactions SET status = 'unprocessed', created_at = strftime('%s','now') - 100000 WHERE reference = ?",
        .{},
        .{ .reference = ref },
    );

    // Monitor against an unreachable service (network tasks fail soft; DB
    // tasks must still run).
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var services = OneSatServices.init(allocator, .main, "http://127.0.0.1:1", threaded.io());
    defer services.deinit();

    var monitor = Monitor.init(allocator, &storage_client, &services);
    monitor.abandon_after_secs = 10; // the row is 100000s old

    const result = monitor.runOnce();

    // The aged tx must now be 'failed'.
    const failed = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM transactions WHERE reference = ? AND status = 'failed'",
        .{},
        .{ .reference = ref },
    )).?;
    try testing.expectEqual(@as(u32, 1), failed);
    try testing.expect(result.abandoned >= 1);

    // A second pass must not touch it again (status no longer unprocessed).
    const result2 = monitor.runOnce();
    const still_failed = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM transactions WHERE reference = ? AND status = 'failed'",
        .{},
        .{ .reference = ref },
    )).?;
    try testing.expectEqual(@as(u32, 1), still_failed);
    _ = result2;

    try deleteTestDb(test_db_path);
}

test "Monitor: unfailChecker rechecks and re-fails unknown txs" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_monitor_unfail.db";
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
    const auth = wtb.storage.types.AuthId{ .identity_key = &identity_hex };

    // Create an action and move it through failed -> unfail, with a txid set
    // (needed for the on-chain recheck).
    var outputs_arr = std.json.Array.init(allocator);
    var out0 = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try out0.put(allocator, "lockingScript", .{ .string = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac" });
    try out0.put(allocator, "satoshis", .{ .integer = 1000 });
    try outputs_arr.append(.{ .object = out0 });
    var args_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer args_obj.deinit(allocator);
    try args_obj.put(allocator, "description", .{ .string = "unfail test" });
    try args_obj.put(allocator, "outputs", .{ .array = outputs_arr });
    const create_result = try storage_client.createAction(allocator, auth, .{ .object = args_obj });
    const ref = create_result.object.get("referenceNumber").?.string;

    try storage_client.db.exec(
        "UPDATE transactions SET status = 'unfail', txid = '1111111111111111111111111111111111111111111111111111111111111111' WHERE reference = ?",
        .{},
        .{ .reference = ref },
    );

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    // Unreachable service. NOTE: getStatusForTxids maps per-txid network
    // errors to status .unknown, so the monitor cannot distinguish
    // 'not on chain' from 'network down' (documented limitation). Per Go
    // UnFail semantics, unknown -> back to 'failed'.
    var services = OneSatServices.init(allocator, .main, "http://127.0.0.1:1", threaded.io());
    defer services.deinit();

    var monitor = Monitor.init(allocator, &storage_client, &services);
    const result = monitor.runOnce();

    const refailed = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM transactions WHERE reference = ? AND status = 'failed'",
        .{},
        .{ .reference = ref },
    )).?;
    try testing.expectEqual(@as(u32, 1), refailed);
    try testing.expectEqual(@as(u64, 0), result.unfail_recovered);
    try testing.expectEqual(@as(u64, 1), result.unfail_refailed);

    try deleteTestDb(test_db_path);
}

test "Monitor: sendWaiting respects the rebroadcast attempt cap" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_monitor_send.db";
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
    const auth = wtb.storage.types.AuthId{ .identity_key = &identity_hex };

    // Create an action, mark it unprocessed+aged with a txid and a known_txs
    // beef row already at the attempt cap.
    var outputs_arr = std.json.Array.init(allocator);
    var out0 = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try out0.put(allocator, "lockingScript", .{ .string = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac" });
    try out0.put(allocator, "satoshis", .{ .integer = 1000 });
    try outputs_arr.append(.{ .object = out0 });
    var args_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer args_obj.deinit(allocator);
    try args_obj.put(allocator, "description", .{ .string = "send test" });
    try args_obj.put(allocator, "outputs", .{ .array = outputs_arr });
    const create_result = try storage_client.createAction(allocator, auth, .{ .object = args_obj });
    const ref = create_result.object.get("referenceNumber").?.string;

    try storage_client.db.exec(
        "UPDATE transactions SET status = 'unprocessed', txid = '2222222222222222222222222222222222222222222222222222222222222222', created_at = strftime('%s','now') - 1000 WHERE reference = ?",
        .{},
        .{ .reference = ref },
    );
    const user_id = (try storage_client.db.one(u32, "SELECT user_id FROM users WHERE identity_key = ?", .{}, .{ .identity_key = &identity_hex })).?;
    try storage_client.db.exec(
        "INSERT INTO known_txs (user_id, txid, status, beef, attempts, max_rebroadcast_attempts) VALUES (?, '2222222222222222222222222222222222222222222222222222222222222222', 'sending', x'01020304', 10, 10)",
        .{},
        .{ .user_id = user_id },
    );

    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var services = OneSatServices.init(allocator, .main, "http://127.0.0.1:1", threaded.io());
    defer services.deinit();

    var monitor = Monitor.init(allocator, &storage_client, &services);
    monitor.min_send_age_secs = 0;
    const result = monitor.runOnce();

    // Attempt cap already reached: no broadcast attempted, status unchanged.
    try testing.expectEqual(@as(u64, 0), result.send_waiting_attempted);
    const still_unprocessed = (try storage_client.db.one(
        u32,
        "SELECT COUNT(*) FROM transactions WHERE reference = ? AND status = 'unprocessed'",
        .{},
        .{ .reference = ref },
    )).?;
    try testing.expectEqual(@as(u32, 1), still_unprocessed);

    try deleteTestDb(test_db_path);
}
