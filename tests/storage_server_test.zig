const std = @import("std");
const testing = std.testing;
const bsvz = @import("bsvz");
const ec = bsvz.primitives.ec;
const wtb = @import("zig-wallet-toolbox");
const SqliteStorageClient = wtb.storage.SqliteStorageClient;
const StorageServer = wtb.storage.StorageServer;
const RemoteStorageClient = wtb.storage.RemoteStorageClient;
const WalletStorageManager = wtb.storage.WalletStorageManager;
const AuthFetch = wtb.auth.AuthFetch;
const PendingSignActionsRepo = wtb.wallet.pending_sign_actions.PendingSignActionsRepo;
const signer_types = wtb.signer.types;
const Wallet = wtb.wallet.Wallet;

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

/// Open a throwaway loopback connection so a server thread blocked in
/// accept() wakes up after its listener was closed (closing a listening
/// socket does not interrupt a pending accept on Linux).
fn nudgeAcceptLoop(address: *const std.Io.net.IpAddress) void {
    _ = address;
    var nudge_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer nudge_io.deinit();
    const io = nudge_io.io();
    const addr = std.Io.net.IpAddress.parse("127.0.0.1", 39471) catch return;
    _ = std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return;
}

// Full remote storage lifecycle against our own StorageServer over real
// TCP + BRC-103/104 authenticated transport — no external backend needed.
test "StorageServer + RemoteStorageClient end-to-end over TCP" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_server.db";
    try deleteTestDb(test_db_path);

    // Loopback preflight: in environments without loopback configured
    // (e.g. a bare network namespace where lo is DOWN) a TCP connect to
    // 127.0.0.1 silently DROPS (no RST) and the client retries for minutes.
    // Detect that up front and skip instead of hanging the suite.
    {
        var preflight_io = std.Io.Threaded.init(allocator, .{});
        defer preflight_io.deinit();
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", 39471) catch unreachable;
        var probe = std.Io.net.IpAddress.listen(&addr, preflight_io.io(), .{ .reuse_address = true }) catch {
            std.log.info("skip: loopback unavailable; TCP server e2e requires 127.0.0.1", .{});
            return;
        };
        probe.deinit(preflight_io.io());
    }

    // Server side: SQLite storage + server identity key.
    var server_storage = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer server_storage.deinit();

    const server_key = try ec.PrivateKey.generate();

    var server_threaded = std.Io.Threaded.init(allocator, .{});
    defer server_threaded.deinit();
    const server_io = server_threaded.io();

    var server = StorageServer.init(allocator, &server_storage, server_key);
    defer server.deinit();

    // Bind port 0 (kernel-assigned) and read the actual port via... the
    // listen API does not expose it, so use a fixed high port and retry.
    const address = std.Io.net.IpAddress.parse("127.0.0.1", 39471) catch unreachable;

    const ServerThreadCtx = struct {
        server: *StorageServer,
        io: std.Io,
        address: std.Io.net.IpAddress,

        fn entry(ctx: *@This()) void {
            ctx.server.run(ctx.io, ctx.address) catch |err| {
                std.log.err("server run failed: {s}", .{@errorName(err)});
            };
        }
    };
    var server_ctx = ServerThreadCtx{
        .server = &server,
        .io = server_io,
        .address = address,
    };

    const thread = try std.Thread.spawn(.{}, ServerThreadCtx.entry, .{&server_ctx});
    // Closing the listener is NOT enough to unblock a pending accept() on
    // Linux, so after stop() we open a dummy loopback connection to force
    // the accept loop to return (it then sees the closed listener and
    // exits). errdefer keeps the same guarantee on assertion failures.
    errdefer server.stop(server_io);
    defer {
        server.stop(server_io);
        nudgeAcceptLoop(&address);
        thread.join();
    }

    // Client side.
    const client_key = try ec.PrivateKey.generate();
    var client_threaded = std.Io.Threaded.init(allocator, .{});
    defer client_threaded.deinit();
    var auth_fetch = AuthFetch.init(allocator, client_threaded.io(), client_key);
    defer auth_fetch.deinit();

    var client = RemoteStorageClient.init(allocator, &auth_fetch, "http://127.0.0.1:39471");
    defer client.deinit();

    var client_pub = try client_key.publicKey();
    const compressed = client_pub.toCompressedSec1();
    var identity_hex: [66]u8 = undefined;
    _ = try bsvz.primitives.hex.encodeLower(&compressed, &identity_hex);

    // 1. Handshake + makeAvailable via authenticated JSON-RPC.
    const settings = try client.makeAvailable(allocator);
    defer client.freeResult(allocator, settings);
    try testing.expect(settings != .null);

    // 2. findOrInsertUser.
    const user_result = try client.findOrInsertUser(allocator, &identity_hex);
    defer client.freeResult(allocator, user_result);
    try testing.expect(user_result == .object);
    try testing.expect(user_result.object.get("user") != null);

    // 3. createAction through the full RPC path.
    const auth = wtb.storage.types.AuthId{ .identity_key = &identity_hex };
    var outputs_arr = std.json.Array.init(allocator);
    var out0 = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try out0.put(allocator, "lockingScript", .{ .string = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac" });
    try out0.put(allocator, "satoshis", .{ .integer = 1000 });
    try outputs_arr.append(.{ .object = out0 });
    var args_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer args_obj.deinit(allocator);
    try args_obj.put(allocator, "description", .{ .string = "remote e2e" });
    try args_obj.put(allocator, "outputs", .{ .array = outputs_arr });

    const create_result = try client.createAction(allocator, auth, .{ .object = args_obj });
    defer client.freeResult(allocator, create_result);
    try testing.expect(create_result == .object);
    try testing.expect(create_result.object.get("referenceNumber") != null);

    // 4. listActions sees the created action server-side.
    var list_args = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer list_args.deinit(allocator);
    const actions = try client.listActions(allocator, auth, .{ .object = list_args });
    defer client.freeResult(allocator, actions);
    try testing.expect(actions == .object);
    try testing.expect(actions.object.get("actions") != null);

    try deleteTestDb(test_db_path);
}

// Pending sign actions repo: save/get/delete + expiry.
test "PendingSignActionsRepo save/get/delete + TTL expiry" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_pending.db";
    try deleteTestDb(test_db_path);

    var storage = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer storage.deinit();

    var repo = PendingSignActionsRepo.init(allocator, &storage.db);
    // Short TTL for the expiry assertion.
    repo.ttl_secs = 1;

    try repo.save(.{
        .reference = "ref-123",
        .identity_key = "0264a8be...",
        .tx_json = "{\"txid\":\"aa\"}",
        .create_args_json = "{\"description\":\"x\"}",
        .input_beef = "0101beef",
    });

    // Round trip.
    {
        const action = try repo.get("ref-123");
        defer repo.freeAction(action);
        try testing.expectEqualStrings("ref-123", action.reference);
        try testing.expectEqualStrings("{\"txid\":\"aa\"}", action.tx_json);
        try testing.expectEqualStrings("0101beef", action.input_beef.?);
    }

    // Overwrite semantics (Go sync.Map Store).
    try repo.save(.{
        .reference = "ref-123",
        .identity_key = "0264a8be...",
        .tx_json = "{\"txid\":\"bb\"}",
        .create_args_json = "{\"description\":\"y\"}",
        .input_beef = null,
    });
    {
        const action = try repo.get("ref-123");
        defer repo.freeAction(action);
        try testing.expectEqualStrings("{\"txid\":\"bb\"}", action.tx_json);
        try testing.expect(action.input_beef == null);
    }

    // Delete is idempotent; get then fails.
    try repo.delete("ref-123");
    try repo.delete("ref-123");
    try testing.expectError(error.NotFound, repo.get("ref-123"));

    // TTL: save with 1s ttl, wait past expiry, get -> Expired + row removed.
    try repo.save(.{
        .reference = "ref-ttl",
        .identity_key = "0264a8be...",
        .tx_json = "{}",
        .create_args_json = "{}",
    });
    var req: std.posix.timespec = .{ .sec = 2, .nsec = 0 };
    _ = std.os.linux.nanosleep(&req, null);

    try testing.expectError(error.Expired, repo.get("ref-ttl"));
    try testing.expectError(error.NotFound, repo.get("ref-ttl"));

    try deleteTestDb(test_db_path);
}

// Wallet integration: createAction persists a pending action when the repo
// is configured; signAction/abortAction consume it.
test "Wallet persists pending sign actions via repo" {
    const allocator = std.heap.page_allocator;
    const test_db_path = "/tmp/zig_wallet_test_pending_wallet.db";
    try deleteTestDb(test_db_path);

    var storage = try SqliteStorageClient.init(allocator, .{
        .path = test_db_path,
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    defer storage.deinit();

    var repo = PendingSignActionsRepo.init(allocator, &storage.db);

    var storage_mgr = WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage.storageProvider());

    var wallet = try Wallet.init(allocator, .{
        .private_key = try ec.PrivateKey.generate(),
        .chain = .main,
        .wallet_services = undefined,
        .storage_manager = storage_mgr,
        .pending_actions = &repo,
    });
    defer wallet.deinit();

    // createAction -> pending action saved under the storage reference.
    const create_result = try wallet.createAction(.{
        .description = "pending test",
        .outputs = &.{
            signer_types.ActionOutput{
                .locking_script = "76a91489abcdefabbaabbaabbaabbaabbaabba88ac",
                .satoshis = 1000,
            },
        },
    });
    const ref = create_result.getReference() orelse return error.MissingReference;

    {
        const action = try repo.get(ref);
        defer repo.freeAction(action);
        try testing.expectEqualStrings(ref, action.reference);
        // tx_json holds the serialized create result.
        try testing.expect(std.mem.indexOf(u8, action.tx_json, "referenceNumber") != null);
    }

    // abortAction releases the pending action.
    _ = try wallet.abortAction(ref);
    try testing.expectError(error.NotFound, repo.get(ref));

    try deleteTestDb(test_db_path);
}
