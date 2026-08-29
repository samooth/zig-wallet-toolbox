const std = @import("std");
const testing = std.testing;
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const wtb = @import("zig-wallet-toolbox");
const Wallet = wtb.wallet.Wallet;
const WalletStorageManager = wtb.storage.WalletStorageManager;
const SqliteStorageClient = wtb.storage.SqliteStorageClient;
const km = wtb.keymanagement;

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

test "shamir split and reconstruct recovers the secret" {
    const allocator = std.heap.page_allocator;

    const secret: [32]u8 = @as([32]u8, @splat(0x42));

    const shares = try km.splitShares(allocator, secret, 5, 3);
    defer allocator.free(shares.points);

    const backup = try shares.toBackupFormat(allocator);
    defer {
        for (backup) |s| allocator.free(s);
        allocator.free(backup);
    }

    try testing.expectEqual(@as(usize, 5), backup.len);

    // Reconstruct from any 3 of the 5 shares.
    const recovered = try km.reconstructSecret(allocator, backup[0..3]);
    try testing.expectEqualSlices(u8, &secret, &recovered);

    // A different subset also recovers the same secret.
    const recovered2 = try km.reconstructSecret(allocator, backup[2..5]);
    try testing.expectEqualSlices(u8, &secret, &recovered2);
}

test "shamir insufficient shares fails" {
    const allocator = std.heap.page_allocator;

    const secret: [32]u8 = @as([32]u8, @splat(0x42));

    const shares = try km.splitShares(allocator, secret, 5, 3);
    defer allocator.free(shares.points);

    const backup = try shares.toBackupFormat(allocator);
    defer {
        for (backup) |s| allocator.free(s);
        allocator.free(backup);
    }

    // Only 2 shares, but threshold is 3.
    try testing.expectError(error.NotEnoughShares, km.reconstructSecret(allocator, backup[0..2]));
}

test "shamir invalid threshold rejected" {
    const allocator = std.heap.page_allocator;
    const secret: [32]u8 = @as([32]u8, @splat(0x42));
    try testing.expectError(error.InvalidThreshold, km.splitShares(allocator, secret, 2, 1));
    try testing.expectError(error.InvalidThreshold, km.splitShares(allocator, secret, 2, 3));
}

test "PrivilegedKeyManager splits, stores, and recovers via SQLite" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_privkey.db";
    try deleteTestDb(test_db_path);
    defer deleteTestDb(test_db_path) catch {};

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

    const id = &identity_key;

    var pkm = wallet.privilegedKeyManager();
    const expected = try pkm.derivePrivilegedKey();

    // Split into 5 shares, threshold 3.
    try pkm.splitAndStore(5, 3);

    // Recover from storage.
    const recovered = try pkm.getPrivilegedKey();
    try testing.expectEqualSlices(u8, &expected.toBytes(), &recovered.toBytes());

    // Direct reconstruction from 3 of the 5 persisted shares.
    const loaded = try storage_mgr.loadKeyShares(allocator, .{ .identity_key = id });
    defer {
        for (loaded) |s| allocator.free(s);
        allocator.free(loaded);
    }
    try testing.expectEqual(@as(usize, 5), loaded.len);

    const secret = try km.reconstructSecret(allocator, loaded[0..3]);
    try testing.expectEqualSlices(u8, &expected.toBytes(), &secret);
}

test "PrivilegedKeyManager shares persist across reopen" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_privkey_reopen.db";
    try deleteTestDb(test_db_path);
    defer deleteTestDb(test_db_path) catch {};

    const private_key = try ec.PrivateKey.generate();
    var pubkey = try private_key.publicKey();
    var compressed = pubkey.toCompressedSec1();
    var identity_key: [66]u8 = undefined;
    _ = try bsvz.primitives.hex.encodeLower(&compressed, &identity_key);

    var expected: [32]u8 = undefined;

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

        var pkm = wallet.privilegedKeyManager();
        const expected_key = try pkm.derivePrivilegedKey();
        expected = expected_key.toBytes();
        try pkm.splitAndStore(5, 3);
    }

    // Reopen with a fresh storage client on the same database.
    var storage_client2 = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    var storage_mgr2 = WalletStorageManager.init(allocator);
    storage_mgr2.setActive(storage_client2.storageProvider());
    var wallet2 = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = storage_mgr2,
    });
    defer wallet2.deinit();

    var pkm2 = wallet2.privilegedKeyManager();
    const recovered = try pkm2.getPrivilegedKey();
    try testing.expectEqualSlices(u8, &expected, &recovered.toBytes());
}

test "privileged key derivation is deterministic" {
    const allocator = std.heap.page_allocator;
    const private_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x07)));

    var storage_mgr = WalletStorageManager.init(allocator);
    var pkm = km.PrivilegedKeyManager.init(allocator, private_key, &storage_mgr, "id1");

    const a = try pkm.derivePrivilegedKey();
    const b = try pkm.derivePrivilegedKey();
    try testing.expectEqualSlices(u8, &a.toBytes(), &b.toBytes());
}

test "encrypt and decrypt roundtrip without storing shares" {
    const allocator = std.heap.page_allocator;
    const private_key = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x07)));

    var storage_mgr = WalletStorageManager.init(allocator);
    var pkm = km.PrivilegedKeyManager.init(allocator, private_key, &storage_mgr, "id1");

    // Encryption derives the privileged key directly; no Shamir split required.
    const plaintext = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 250, 251 };
    const ciphertext = try pkm.encrypt(allocator, &plaintext);
    defer allocator.free(ciphertext);

    // Non-empty and different from plaintext (GCM IV/format prepended).
    try testing.expect(ciphertext.len > plaintext.len);

    const decrypted = try pkm.decrypt(allocator, ciphertext);
    defer allocator.free(decrypted);
    try testing.expectEqualSlices(u8, &plaintext, decrypted);
}

test "Wallet encrypt/decrypt matches shares-reconstructed key" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_encrypt.db";
    try deleteTestDb(test_db_path);
    defer deleteTestDb(test_db_path) catch {};

    const private_key = try ec.PrivateKey.generate();
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

    const plaintext = "bitcoin is the firewall against authoritarian monetary control";
    const ciphertext = try wallet.encrypt(allocator, plaintext);
    defer allocator.free(ciphertext);

    // A freshly reconstructed privileged key (from shares) decrypts data encrypted by the
    // directly-derived key, proving split/store/reconstruct yields the same symmetric key.
    var pkm = wallet.privilegedKeyManager();
    try pkm.splitAndStore(5, 3);
    const decrypted = try pkm.decrypt(allocator, ciphertext);
    defer allocator.free(decrypted);
    try testing.expectEqualSlices(u8, plaintext, decrypted);
}

test "decrypt with wrong wallet key fails" {
    const allocator = std.heap.page_allocator;

    const alice = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x11)));
    var alice_mgr = WalletStorageManager.init(allocator);
    var alice_pkm = km.PrivilegedKeyManager.init(allocator, alice, &alice_mgr, "alice");

    const plaintext = [_]u8{ 42, 43, 44 };
    const ciphertext = try alice_pkm.encrypt(allocator, &plaintext);
    defer allocator.free(ciphertext);

    const bob = try ec.PrivateKey.fromBytes(@as([32]u8, @splat(0x22)));
    var bob_mgr = WalletStorageManager.init(allocator);
    var bob_pkm = km.PrivilegedKeyManager.init(allocator, bob, &bob_mgr, "bob");

    // Decryption with the wrong wallet's key must fail (GCM auth tag won't verify).
    if (bob_pkm.decrypt(allocator, ciphertext)) |_| {
        try testing.expect(false);
    } else |_| {}
}
