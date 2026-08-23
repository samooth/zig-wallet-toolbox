const std = @import("std");
const wtb = @import("zig-wallet-toolbox");
const bsvz = @import("bsvz");

const PrivateKey = bsvz.primitives.ec.PrivateKey;
const AuthFetch = wtb.auth.AuthFetch;
const RemoteStorageClient = wtb.storage.RemoteStorageClient;
const WalletStorageManager = wtb.storage.WalletStorageManager;
const OneSatServices = wtb.services.OneSatServices;
const Wallet = wtb.wallet.Wallet;
const WalletConfig = wtb.wallet.WalletConfig;

const host = "https://api.1sat.app";

// Storage endpoints are NOT hosted on api.1sat.app — they belong to a
// go-wallet-toolbox deployment. Set WALLET_STORAGE_URL (e.g.
// "https://your-backend.example.com") to run the storage-dependent parts;
// without it the test only exercises the public 1Sat service APIs.
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
// against the 1Sat service APIs plus (when WALLET_STORAGE_URL is set) a
// remote BRC-100 storage backend.
test "e2e: remote wallet against api.1sat.app" {
    // Use page_allocator for e2e test — the JSON-RPC response parsing has
    // intentional ownership transfer that the testing allocator flags as leaks.
    // The RPC result values reference memory in the parsed arena which can't
    // be freed until the caller is done with the result. This is a known v1
    // limitation tracked for cleanup.
    const allocator = std.heap.page_allocator;
    const gpa = std.heap.page_allocator;

    const storage_url_owned = try getStorageUrl(gpa);
    defer if (storage_url_owned) |u| gpa.free(u);

    // 1. Generate a fresh random private key
    const private_key = try PrivateKey.generate();

    // 1b. Create the Io runtime required by Zig 0.16 HTTP APIs
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // 2. Set up AuthFetch (handles BRC-103/104 mutual auth)
    var auth_fetch = AuthFetch.init(allocator, io, private_key);
    defer auth_fetch.deinit();

    // 3. Chain height via services (public API, no auth needed)
    var onesat = OneSatServices.init(allocator, .main, host, io);
    defer onesat.deinit();
    const height = try onesat.getHeight();
    std.log.info("chain height: {d}", .{height});
    try std.testing.expect(height > 800000);

    const wallet_url = storage_url_owned orelse {
        std.log.info("skip: set WALLET_STORAGE_URL to run the remote storage lifecycle against a go-wallet-toolbox backend", .{});
        return;
    };

    var storage_client = RemoteStorageClient.init(allocator, &auth_fetch, wallet_url);
    defer storage_client.deinit();

    // 4. Wire up WalletStorageManager with remote as active provider
    var storage_mgr = WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

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

    // -- Step A: makeAvailable --
    // This should return the server's TableSettings
    const settings = try storage_client.makeAvailable(allocator);
    std.log.info("makeAvailable: {}", .{settings});
    try std.testing.expect(settings != .null);

    // -- Step B: findOrInsertUser --
    // Auto-creates the user on the server since this is a brand new key
    const user_result = try storage_client.findOrInsertUser(allocator, identity);
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

    std.log.info("=== e2e test passed ===", .{});
}
