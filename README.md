# Zig Wallet Toolbox

![CI](https://github.com/samooth/zig-wallet-toolbox/actions/workflows/ci.yml/badge.svg)

A [BRC-100](https://github.com/bitcoin-sv/BRCs/blob/master/wallet/0100.md) conforming wallet implementation for the BSV blockchain, built on [bsvz](https://github.com/b-open-io/bsvz). Provides authenticated HTTP transport, remote storage, service integrations, transaction signing, and action management — everything needed to build wallet-powered applications on BSV in Zig.

## Table of Contents

- [Overview](#overview)
- [Getting Started](#getting-started)
- [Quick Example](#quick-example)
- [Module Layout](#module-layout)
- [API](#api)
- [Development](#development)
- [Related SDKs](#related-sdks)
- [License](#license)

## Overview

The Zig Wallet Toolbox is a Zig-native implementation of the BRC-100 wallet interface. It connects [bsvz](https://github.com/b-open-io/bsvz)'s cryptographic primitives to real storage backends and network services so that application developers don't have to wire these layers together themselves.

### What's Inside

| Module | Description |
|--------|-------------|
| **wallet** | Full BRC-100 wallet — action creation, signing, identity key derivation, output and action listing |
| **storage** | Pluggable persistence with a `WalletStorageManager` supporting active and backup providers (non-owning — callers keep ownership of their clients); ships with a `RemoteStorageClient` (JSON-RPC over authenticated HTTP), `LocalStorageClient` (in-memory, test/ephemeral use only — data is lost on exit), and `SqliteStorageClient` (file-backed SQLite with WAL mode, real `internalizeAction`, concurrent + crash-recovery-capable storage) |
| **services** | Network layer — `OneSatServices` integrates Chaintracks (headers), Arcade (broadcast), BEEF (merkle proofs and raw tx), and TXO (UTXO lookups) |
| **auth** | BRC-103/104 mutual authentication — `AuthFetch` handles peer sessions, nonce exchange, request/response payload signing, and authenticated HTTP transport |
| **signer** | Transaction building and signing — `CreateActionArgs`, `SignActionArgs`, signable data extraction, and signed input construction |
| **http** | Low-level HTTP client and JSON-RPC request/response handling |

## Getting Started

**Requirements:** Zig `0.16.0` or newer — CI continuously verifies both the latest stable release and current master (`0.17` dev).

Fetch the dependency:

```bash
zig fetch --save git+https://github.com/b-open-io/zig-wallet-toolbox.git
```

Then expose the module in your `build.zig`:

```zig
const wtb = b.dependency("zig_wallet_toolbox", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zig-wallet-toolbox", wtb.module("zig-wallet-toolbox"));
```

The toolbox depends on [bsvz](https://github.com/b-open-io/bsvz), which is fetched transitively.

## Quick Example

Choose your storage backend — both use the same wallet API:

### Option A: Remote Storage (BRC-100 server)

```zig
const std = @import("std");
const bsvz = @import("bsvz");
const wtb = @import("zig-wallet-toolbox");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. Generate or load a private key
    const private_key = try bsvz.primitives.ec.PrivateKey.generate();

    // 2. Create the Io runtime required by Zig 0.16 HTTP APIs
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // 3. Set up authenticated HTTP transport
    var auth_fetch = wtb.auth.AuthFetch.init(allocator, io, private_key);
    defer auth_fetch.deinit();

    // 4. Create remote storage client pointing at your go-wallet-toolbox
    //    deployment (wallet storage is NOT hosted on api.1sat.app)
    var storage_client = wtb.storage.RemoteStorageClient.init(
        allocator,
        &auth_fetch,
        "https://your-backend.example.com",
    );
    defer storage_client.deinit();

    // 5. Wire up storage manager
    var storage_mgr = wtb.storage.WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    // 6. Create network services
    var services = wtb.services.OneSatServices.init(allocator, .main, null, io);
    defer services.deinit();

    // 7. Build the wallet
    var wallet = try wtb.wallet.Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = services.walletServices(),
        .storage_manager = storage_mgr,
    });
    defer wallet.deinit();

    // Use the wallet
    const identity = wallet.getPublicKey();
    std.debug.print("identity key: {s}\n", .{identity});

    const outputs = try wallet.listOutputs(.{ .basket = "default", .limit = 10 });
    std.debug.print("outputs: {}\n", .{outputs});
}
```

### Option B: Local Storage (offline-first, in-memory)

```zig
const std = @import("std");
const bsvz = @import("bsvz");
const wtb = @import("zig-wallet-toolbox");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. Generate or load a private key
    const private_key = try bsvz.primitives.ec.PrivateKey.generate();

    // 2. Create the Io runtime required by Zig 0.16 HTTP APIs
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    // 3. Set up local in-memory storage
    var storage_client = wtb.storage.LocalStorageClient.init(allocator);
    defer storage_client.deinit();

    var storage_mgr = wtb.storage.WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    // 4. Create network services (for chain queries, broadcasting)
    var services = wtb.services.OneSatServices.init(allocator, .main, null, io);
    defer services.deinit();

    // 5. Build the wallet
    var wallet = try wtb.wallet.Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = services.walletServices(),
        .storage_manager = storage_mgr,
    });
    defer wallet.deinit();

    // Use the wallet
    const identity = wallet.getPublicKey();
    std.debug.print("identity key: {s}\n", .{identity});

    const outputs = try wallet.listOutputs(.{ .basket = "default", .limit = 10 });
    std.debug.print("outputs: {}\n", .{outputs});
}
```

**Note**: `AuthFetch` and `LocalStorageClient` are stateless per-instance and safe to use across threads behind your own synchronization; the `Io` runtime is created and owned by the caller.

### Option C: SQLite Storage (persistent, concurrent)

```zig
const std = @import("std");
const bsvz = @import("bsvz");
const wtb = @import("zig-wallet-toolbox");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const private_key = try bsvz.primitives.ec.PrivateKey.generate();

    // 1. Create persistent SQLite storage (WAL mode for concurrent + crash-safe access)
    var storage_client = try wtb.storage.SqliteStorageClient.init(allocator, .{
        .path = "wallet.db",
        .journal_mode = "WAL",
        .busy_timeout_ms = 5000,
    });
    // The caller owns the storage client: WalletStorageManager only holds a
    // provider reference and does NOT destroy it.
    defer storage_client.deinit();

    var storage_mgr = wtb.storage.WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    // 2. Network services (optional for offline use)
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
    defer threaded.deinit();
    var services = wtb.services.OneSatServices.init(allocator, .main, null, threaded.io());
    defer services.deinit();

    // 3. Build the wallet
    var wallet = try wtb.wallet.Wallet.init(allocator, .{
        .private_key = private_key,
        .chain = .main,
        .wallet_services = services.walletServices(),
        .storage_manager = storage_mgr,
    });
    defer wallet.deinit(); // deinits the wallet only; storage_client is deinited by its own defer above

    // Data persists across restarts — reopen the same .path to recover.
    const identity = wallet.getPublicKey();
    std.debug.print("identity key: {s}\n", .{identity});
}
```

`SqliteStorageClient.Config` accepts `path`, `journal_mode` (`"WAL"`/`"DELETE"`), `busy_timeout_ms`, `foreign_keys`, and `synchronous`. The connection is opened in `MultiThread` mode with WAL + a busy timeout, so multiple wallets/threads can read concurrently and an unclean shutdown is recovered on the next open (WAL checkpoint).

### Key Management: Shamir secret sharing

A `PrivilegedKeyManager` derives a BRC-42 privileged key from the wallet master key, splits it into `total` Shamir shares of which `threshold` are needed to reconstruct, and persists the shares via the active storage provider (e.g. the SQLite `key_shares` table). Any `threshold` shares recover the same key; fewer reveal nothing.

```zig
var pkm = wallet.privilegedKeyManager();

// Split into 5 shares, require 3 to reconstruct; persists under the wallet identity.
try pkm.splitAndStore(5, 3);

// Later / from a different process on the same storage:
const privileged = try pkm.getPrivilegedKey();
```

The share format is `bsvz.primitives.keyshares` (base58-encoded points + threshold + integrity), stored base64-encoded so it round-trips through JSON/text storage. Reconstruction is done with overflow-safe modular arithmetic over the secp256k1 field prime.

`Wallet.encrypt` / `Wallet.decrypt` (and the equivalent `PrivilegedKeyManager.encrypt` / `.decrypt`) use the privileged key as an AES-GCM symmetric key (`bsvz.primitives.symmetric`) to encrypt/decrypt arbitrary data. Encryption derives the privileged key directly from the master key, so it works even before any shares are split and stored.

## Module Layout

| Module | Description |
| --- | --- |
| `wallet.Wallet` | BRC-100 wallet: init from private key, create/sign/abort actions, list outputs and actions, sign and verify data |
| `auth.AuthFetch` | Authenticated HTTP client with automatic peer session management (BRC-103/104) |
| `auth.AuthMessage` | Wire format for mutual authentication messages |
| `auth.PeerSession` | Per-origin session state with nonce tracking |
| `auth.HttpRequestPayload` | Request payload serialization for auth signing |
| `auth.HttpResponsePayload` | Response payload serialization for auth verification |
| `storage.WalletStorageManager` | Storage orchestrator with active provider and backup list |
| `storage.WalletStorageProvider` | Vtable interface for pluggable storage backends |
| `storage.RemoteStorageClient` | JSON-RPC client for remote wallet storage servers |
| `storage.LocalStorageClient` | In-memory local wallet storage (HashMap-backed; TEST/EPHEMERAL USE ONLY — all data lost on deinit/exit) |
| `storage.SqliteStorageClient` | File-backed SQLite local storage (WAL mode, concurrent + crash-recovery capable; `internalizeAction` parses BEEF, records outputs, marks spent inputs, upserts known_txs) |
| `keymanagement.PrivilegedKeyManager` | Derives a BRC-42 privileged key, splits it into Shamir shares (threshold reconstruction), and persists/recovers them via the active storage provider |
| `keymanagement.PrivilegedKeyManager.encrypt` / `.decrypt` | Wallet-level AES-GCM encrypt/decrypt of arbitrary data under the privileged key (also on `Wallet.encrypt` / `Wallet.decrypt`) |
| `keymanagement.splitShares` / `keymanagement.reconstructSecret` | Low-level Shamir split/reconstruct helpers over `bsvz.primitives.keyshares` |
| `monitor.Monitor` / `monitor.Daemon` | Background transaction lifecycle: proof lookup, waiting-tx rebroadcast (attempt-capped), abandonment, and unfail recovery — one `runOnce` pass or a scheduled loop |
| `services.WalletServices` | Vtable interface for blockchain network services |
| `services.OneSatServices` | 1Sat API integration: Chaintracks, Arcade, BEEF, TXO |
| `services.ChaintracksClient` | Block header and chain height queries |
| `services.ArcadeClient` | ARC transaction broadcasting and status |
| `services.BeefClient` | BEEF retrieval, raw tx, and merkle proof lookups |
| `services.TxoClient` | UTXO and transaction output queries |
| `signer.CreateActionArgs` | Transaction creation parameters with outputs, inputs, labels, and options |
| `signer.SignActionArgs` | Signing parameters with spend references and unlocking scripts |
| `signer.extractSignableData` | Extract signable data from a create action result for offline signing |
| `signer.buildSignActionArgs` | Build sign action arguments from signed inputs |
| `http.client` | Low-level HTTP client |
| `http.json_rpc` | JSON-RPC 2.0 request/response encoding and decoding |

## API

### Wallet

```zig
// Initialize
var wallet = try Wallet.init(allocator, config);
defer wallet.deinit();

// Identity
const pubkey = wallet.getPublicKey(); // 66-char compressed hex

// Signatures
const sig = try wallet.createSignature("data to sign");
const valid = try wallet.verifySignature("data to sign", sig, pubkey);

// Actions — full CreateActionArgs
const result = try wallet.createAction(.{
    .description = "Send payment",
    .outputs = &.{
        .{
            .locking_script = "76a914...88ac",
            .satoshis = 1000,
            .description = "Payment to Alice",
            .basket = "default",
            .tags = &.{"payment", "alice"},
        },
    },
    .inputs = &.{  // optional: pre-selected inputs
        .{
            .outpoint = "txid_vout",
            .unlocking_script = "...",
            .sequence_number = 0xffffffff,
        },
    },
    .labels = &.{"payment", "alice"},
    .options = .{
        .no_send = false,
        .sign_and_process = true,
        .accept_delayed_broadcast = true,
        .return_txid_only = false,
        .randomize_outputs = true,
    },
});

// Sign action — full SignActionArgs
const signed = try wallet.signAction(.{
    .reference = result.getReference().?,
    .spends = &.{
        .{
            .input_index = 0,
            .unlocking_script = "4730440220...0220...41",
            .sequence_number = 0xffffffff,
        },
    },
    .options = .{
        .accept_delayed_broadcast = true,
        .return_txid_only = false,
        .no_send = false,
    },
});

// Queries
const outputs = try wallet.listOutputs(.{
    .basket = "default",
    .tags = &.{"payment"},
    .spendable = true,
    .limit = 10,
    .offset = 0,
});
const actions = try wallet.listActions(.{
    .labels = &.{"payment"},
    .limit = 10,
    .offset = 0,
});

// Balance
const balance = try wallet.getBalance(); // { .confirmed = 10000, .unconfirmed = 0 }

// Failed actions (TS-SDK wire-compatible; unfail=true queues them for
// Monitor recovery)
const failed = try wallet.listFailedActions(.{}, false);

// Stop tracking an output without spending it
_ = try wallet.relinquishOutput("default", txid, 0);
```

### Authenticated HTTP

```zig
var threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
defer threaded.deinit();

var auth_fetch = AuthFetch.init(allocator, threaded.io(), private_key);
defer auth_fetch.deinit();

// GET with mutual auth
var response = try auth_fetch.get("https://api.example.com/resource");
defer response.deinit();

// POST JSON with mutual auth
var response = try auth_fetch.postJson("https://api.example.com/action", body);
defer response.deinit();
```

**Note**: The `Io` runtime is created and owned by the caller; `AuthFetch` holds no global state.

### Services

```zig
var services = OneSatServices.init(allocator, .main, null, io);
defer services.deinit();

const height = try services.getHeight();
const header = try services.getHeaderForHeight(allocator, height);
const utxo = try services.getUtxoStatus(allocator, "txid_vout");
```

### Monitor (background transaction lifecycle)

```zig
var monitor = wtb.monitor.Monitor.init(allocator, &storage_client, &services);
// One pass (cron-style):
const summary = monitor.runOnce();

// Or a daemon loop (checked every interval; stop via the atomic flag):
var stop = std.atomic.Value(bool).init(false);
var daemon = wtb.monitor.Daemon{ .monitor = &monitor, .interval_ms = 30_000, .stop_flag = &stop };
try daemon.run();
```

Each pass runs the Go-parity tasks: check for merkle proofs (mined txs -> completed), broadcast waiting transactions (attempt-capped), fail abandoned ones, and re-check 'unfail' rows queued by `listFailedActions(unfail=true)`.

## Development

```bash
git clone https://github.com/b-open-io/zig-wallet-toolbox.git
cd zig-wallet-toolbox
zig build test
```

Build both library and C ABI static lib:

```bash
zig build --summary all
# Output: zig-out/lib/libzig-wallet-toolbox.a
#         zig-out/lib/libbsvwallet_c.a
# Header: include/bsvwallet.h
```

The test suite includes unit tests embedded in source files and integration tests in `tests/`. The e2e test in `tests/e2e_test.zig` runs the full wallet storage lifecycle against the local in-memory `LocalStorageClient` by default, with a soft network check against the public 1Sat service APIs (`api.1sat.app` — skipped when unreachable, so CI stays deterministic). Set `WALLET_STORAGE_URL` to run the storage lifecycle against a remote BRC-100 (go-wallet-toolbox) backend instead:

```bash
# Unit + service tests (storage lifecycle runs locally, network is soft)
zig build test

# Storage lifecycle against a remote BRC-100 backend
WALLET_STORAGE_URL=https://your-backend.example.com zig build test

# Run with logging to see e2e details
zig build test 2>&1 | head -50
```

## Related SDKs

| Language | Repository |
| --- | --- |
| TypeScript | [bsv-blockchain/wallet-toolbox](https://github.com/bsv-blockchain/wallet-toolbox) |
| Go | [bsv-blockchain/go-wallet-toolbox](https://github.com/bsv-blockchain/go-wallet-toolbox) |
| Python | [bsv-blockchain/py-wallet-toolbox](https://github.com/bsv-blockchain/py-wallet-toolbox) |
| Zig (foundation) | [b-open-io/bsvz](https://github.com/b-open-io/bsvz) |
| C (ABI) | [docs/C_API.md](docs/C_API.md) — Header: `include/bsvwallet.h`, Lib: `libbsvwallet_c.a` |

## License

Open BSV License.
