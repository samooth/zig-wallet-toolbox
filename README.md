# Zig Wallet Toolbox

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
| **storage** | Pluggable persistence with a `WalletStorageManager` supporting active and backup providers; ships with a `RemoteStorageClient` that speaks JSON-RPC over authenticated HTTP |
| **services** | Network layer — `OneSatServices` integrates Chaintracks (headers), Arcade (broadcast), BEEF (merkle proofs and raw tx), and TXO (UTXO lookups) |
| **auth** | BRC-103/104 mutual authentication — `AuthFetch` handles peer sessions, nonce exchange, request/response payload signing, and authenticated HTTP transport |
| **signer** | Transaction building and signing — `CreateActionArgs`, `SignActionArgs`, signable data extraction, and signed input construction |
| **http** | Low-level HTTP client and JSON-RPC request/response handling |

## Getting Started

**Requirements:** Zig `0.15.2`

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

```zig
const std = @import("std");
const bsvz = @import("bsvz");
const wtb = @import("zig-wallet-toolbox");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // 1. Generate or load a private key
    const private_key = try bsvz.primitives.ec.PrivateKey.generate();

    // 2. Set up authenticated HTTP transport
    var auth_fetch = wtb.auth.AuthFetch.init(allocator, private_key);
    defer auth_fetch.deinit();

    // 3. Create remote storage client pointing at a wallet endpoint
    var storage_client = wtb.storage.RemoteStorageClient.init(
        allocator,
        &auth_fetch,
        "https://api.1sat.app/1sat/wallet",
    );
    defer storage_client.deinit();

    // 4. Wire up storage manager
    var storage_mgr = wtb.storage.WalletStorageManager.init(allocator);
    storage_mgr.setActive(storage_client.storageProvider());

    // 5. Create network services
    var services = wtb.services.OneSatServices.init(allocator, .main, null);
    defer services.deinit();

    // 6. Build the wallet
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

// Actions
const result = try wallet.createAction(.{
    .description = "Send payment",
    .outputs = &.{.{
        .locking_script = "76a914...88ac",
        .satoshis = 1000,
    }},
});

const signed = try wallet.signAction(.{
    .reference = result.getReference().?,
    .spends = &.{.{
        .input_index = 0,
        .unlocking_script = "...",
    }},
});

// Queries
const outputs = try wallet.listOutputs(.{ .basket = "default", .limit = 10 });
const actions = try wallet.listActions(.{ .labels = &.{"payment"}, .limit = 10 });
```

### Authenticated HTTP

```zig
var auth_fetch = AuthFetch.init(allocator, private_key);
defer auth_fetch.deinit();

// GET with mutual auth
var response = try auth_fetch.get("https://api.example.com/resource");
defer response.deinit();

// POST JSON with mutual auth
var response = try auth_fetch.postJson("https://api.example.com/action", body);
defer response.deinit();
```

### Services

```zig
var services = OneSatServices.init(allocator, .main, null);
defer services.deinit();

const height = try services.getHeight();
const header = try services.getHeaderForHeight(allocator, height);
const utxo = try services.getUtxoStatus(allocator, "txid_vout");
```

## Development

```bash
git clone https://github.com/b-open-io/zig-wallet-toolbox.git
cd zig-wallet-toolbox
zig build test
```

The test suite includes unit tests embedded in source files and integration tests in `tests/`. The e2e test in `tests/e2e_test.zig` runs against the live `api.1sat.app` endpoint.

```bash
# Unit tests only
zig build test

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

## License

Open BSV License.
