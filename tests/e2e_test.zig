const std = @import("std");
const wtb = @import("zig-wallet-toolbox");
const bsvz = @import("bsvz");

const PrivateKey = bsvz.primitives.ec.PrivateKey;
const AuthFetch = wtb.auth.AuthFetch;
const RemoteStorageClient = wtb.storage.RemoteStorageClient;
const LocalStorageClient = wtb.storage.LocalStorageClient;
const WalletStorageManager = wtb.storage.WalletStorageManager;
const OneSatServices = wtb.services.OneSatServices;
const Wallet = wtb.wallet.Wallet;
const WalletConfig = wtb.wallet.WalletConfig;

const host = "https://api.1sat.app";

// Storage endpoints are NOT hosted on api.1sat.app — they belong to a
// go-wallet-toolbox deployment. Set WALLET_STORAGE_URL (e.g.
// "https://your-backend.example.com") to run the storage lifecycle against a
// remote BRC-100 storage backend; without it the lifecycle runs fully locally
// against the in-memory LocalStorageClient.
const env_storage_url = "WALLET_STORAGE_URL";

fn getStorageUrl(allocator: std.mem.Allocator) !?[]u8 {
    const io = getIo();
    if (@import("builtin").os.tag != .linux) return null;
    var proc_dir = std.Io.Dir.openDirAbsolute(io, "/proc/self", .{}) catch return null;
    defer proc_dir.close(io);
    const data = proc_dir.readFileAlloc(io, "environ", allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (!std.mem.eql(u8, entry[0..eq], env_storage_url)) continue;
        const value = entry[eq + 1 ..];
        if (value.len == 0) return null;
        return try allocator.dupe(u8, value);
    }
    return null;
}

var global_threaded: ?std.Io.Threaded = null;

fn getIo() std.Io {
    if (global_threaded == null) {
        global_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = .empty });
    }
    return global_threaded.?.io();
}

// End-to-end test: generate a random key and exercise the wallet lifecycle
// against the 1Sat service APIs plus a storage backend — remote
// (WALLET_STORAGE_URL) or, by default, the local in-memory LocalStorageClient.
// The live network call is soft: on failure it logs and skips the chain-height
// assertion so CI stays deterministic; the storage lifecycle always runs.
test "e2e: wallet storage lifecycle (local by default, remote via WALLET_STORAGE_URL)" {
    // Storage-provider results are heap JSON with mixed ownership (some
    // backends embed static literals, remote results are deep-copied). An
    // arena makes lifetime management trivial and leak-free for the whole
    // test scope; the old page_allocator workaround for the JSON-RPC parse
    // arena (which leaked per-RPC) is gone — rpcCall now deep-copies and
    // frees its parse arena on every call (see remote.zig).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const gpa = std.heap.page_allocator;

    const storage_url_owned = try getStorageUrl(gpa);
    defer if (storage_url_owned) |u| gpa.free(u);
    const remote_mode = storage_url_owned != null;

    // 1. Generate a fresh random private key
    const private_key = try PrivateKey.generate();

    // 1b. Create the Io runtime required by Zig 0.16 HTTP APIs
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // 2. Set up AuthFetch (handles BRC-103/104 mutual auth) — remote only
    var auth_fetch = AuthFetch.init(allocator, io, private_key);
    defer auth_fetch.deinit();

    // 3. Chain height via services (public API, no auth needed) — soft check
    var onesat = OneSatServices.init(allocator, .main, host, io);
    defer onesat.deinit();
    if (onesat.getHeight()) |height| {
        std.log.info("chain height: {d}", .{height});
        try std.testing.expect(height > 800000);
    } else |err| {
        std.log.info("skip: api.1sat.app unreachable ({s}); network checks ignored", .{@errorName(err)});
    }

    // 4. Pick storage backend: remote when WALLET_STORAGE_URL is set,
    //    otherwise the local in-memory client.
    var storage_local: LocalStorageClient = undefined;
    var storage_remote: RemoteStorageClient = undefined;
    if (remote_mode) {
        storage_remote = RemoteStorageClient.init(allocator, &auth_fetch, storage_url_owned.?);
    } else {
        storage_local = LocalStorageClient.init(allocator);
    }
    defer if (remote_mode) storage_remote.deinit() else storage_local.deinit();

    // 5. Wire up WalletStorageManager with the chosen provider as active
    var storage_mgr = WalletStorageManager.init(allocator);
    const provider = if (remote_mode)
        storage_remote.storageProvider()
    else
        storage_local.storageProvider();
    storage_mgr.setActive(provider);

    // 6. Build the Wallet
    var wallet = try Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = onesat.walletServices(),
        .storage_manager = storage_mgr,
    });
    defer wallet.deinit();

    const identity = wallet.getPublicKey();
    std.log.info("identity key: {s}", .{identity});

    // Direct storage calls go through the provider interface (works for both
    // remote and local backends).
    const storage = provider;

    // -- Step A: makeAvailable --
    // Remote should return the server's TableSettings; local returns a
    // simple availability object.
    const settings = try storage.makeAvailable(allocator);
    std.log.info("makeAvailable: {}", .{settings});
    try std.testing.expect(settings != .null);

    // -- Step B: findOrInsertUser --
    // Auto-creates the user since this is a brand new key
    const user_result = try storage.findOrInsertUser(allocator, identity);
    std.log.info("findOrInsertUser: {}", .{user_result});

    switch (user_result) {
        .object => |obj| {
            // Should have a "user" field
            const user = obj.get("user");
            try std.testing.expect(user != null);

            // Should be a new user
            const is_new = obj.get("isNew");
            if (is_new) |n| {
                switch (n) {
                    .bool => |b| try std.testing.expect(b),
                    else => {},
                }
            }
        },
        else => return error.UnexpectedResponse,
    }

    // -- Step C: listOutputs --
    // A brand new wallet should have no outputs
    const outputs = try wallet.listOutputs(.{ .basket = "default", .limit = 10 });
    std.log.info("listOutputs: {}", .{outputs});

    // -- Step D: listActions --
    // A brand new wallet should have no actions
    const actions = try wallet.listActions(.{ .limit = 10 });
    std.log.info("listActions: {}", .{actions});

    std.log.info("=== e2e test passed (mode: {s}) ===", .{if (remote_mode) "remote" else "local"});
}
