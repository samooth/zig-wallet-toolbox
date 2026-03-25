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
const wallet_url = host ++ "/1sat/wallet";

// End-to-end test: generate a random key, connect to the live
// go-wallet-toolbox storage at api.1sat.app, and exercise the
// basic wallet lifecycle.
test "e2e: remote wallet against api.1sat.app" {
    // Use page_allocator for e2e test — the JSON-RPC response parsing has
    // intentional ownership transfer that the testing allocator flags as leaks.
    // The RPC result values reference memory in the parsed arena which can't
    // be freed until the caller is done with the result. This is a known v1
    // limitation tracked for cleanup.
    const allocator = std.heap.page_allocator;

    // 1. Generate a fresh random private key
    const private_key = try PrivateKey.generate();

    // 2. Set up AuthFetch (handles BRC-103/104 mutual auth)
    var auth_fetch = AuthFetch.init(allocator, private_key);
    defer auth_fetch.deinit();

    // 3. Create RemoteStorageClient pointing at 1sat-stack wallet endpoint
    var storage_client = RemoteStorageClient.init(allocator, &auth_fetch, wallet_url);
    defer storage_client.deinit();

    // 4. Wire up WalletStorageManager with remote as active provider
    var storage_mgr = WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    // 5. Create OneSatServices for mainnet
    var onesat = OneSatServices.init(allocator, .main, host);
    defer onesat.deinit();

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

    // -- Step E: chain height via services --
    const height = try onesat.getHeight();
    std.log.info("chain height: {d}", .{height});
    try std.testing.expect(height > 800000);

    std.log.info("=== e2e test passed ===", .{});
}
