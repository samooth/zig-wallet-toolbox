# Roadmap

Implementation progress toward parity with [go-wallet-toolbox](https://github.com/bsv-blockchain/go-wallet-toolbox) and [wallet-toolbox](https://github.com/bsv-blockchain/wallet-toolbox) (TypeScript).

## Implemented

- [x] Core wallet lifecycle (init, identity key derivation, deinit)
- [x] `createAction` / `signAction` / `abortAction`
- [x] `listOutputs` / `listActions`
- [x] Signature creation and verification (`createSignature`, `verifySignature`)
- [x] BRC-103/104 mutual authentication (`AuthFetch`, peer sessions, nonce exchange)
- [x] Request/response payload serialization (compatible with Go/TS)
- [x] Remote storage client (JSON-RPC over authenticated HTTP)
- [x] `WalletStorageManager` with active + backup providers
- [x] `WalletStorageProvider` vtable interface
- [x] `OneSatServices` integration (Chaintracks, Arcade, BEEF, TXO)
- [x] Chain height, block header, merkle path, raw tx lookups
- [x] UTXO status queries
- [x] BEEF retrieval and transaction broadcast via Arcade
- [x] Transaction status checks (Arcade + BEEF fallback)
- [x] Signer types (`CreateActionArgs`, `SignActionArgs`, options)
- [x] Signable data extraction and signed input construction
- [x] HTTP client and JSON-RPC request/response handling
- [x] E2e test against live `api.1sat.app` services (soft network check; storage lifecycle runs locally by default, remote via `WALLET_STORAGE_URL`)

## Storage

- [x] Local storage provider (in-memory HashMap via LocalStorageClient)
- [x] SQLite-backed local storage provider (file persistence, WAL mode, concurrent + crash-recovery capable)
- [x] Entity model (users, transactions, outputs, output baskets, labels, tags, known_txs, tx_notes, commissions, certificates, key_value) — schema + idempotent migrations
- [ ] CRUD query builder with typed conditions, filters, pagination
- [ ] Storage server (HTTP server hosting wallet storage for remote clients)
- [ ] BEEF verification in storage layer (internalizeAction parses and persists BEEF; full verification pending)
- [ ] Script verification in storage layer

## Monitor

- [x] Background monitor (`monitor.Monitor` + `monitor.Daemon` loop) with Go-parity tasks:
  - [x] checkForProofs (merkle proof lookup -> completed + proof/height recorded)
  - [x] sendWaiting (broadcast aged unprocessed txs, per-tx attempt cap)
  - [x] failAbandoned (stale unprocessed -> failed)
  - [x] unfailChecker ('unfail' recheck: mined -> completed, known -> unprocessed, unknown -> failed)
- [ ] Reorg handling (orphaned block hashes, re-proving)
- [ ] External broadcaster SSE events (Arcade push instead of polling)
- [ ] Lease locking for multi-daemon deployments
- [ ] Per-transaction history notes

## Certificates

- [ ] Certificate entity model (`TableCertificate`, `TableCertificateField`)
- [ ] Certificate issuance
- [ ] Certificate listing and filtering
- [ ] Certificate relinquishing
- [ ] Certifier server

## Key Management

- [x] Protocol-based key derivation within wallet context (BRC-42/43)
- [x] `PrivilegedKeyManager` equivalent with Shamir secret sharing (BRC-42 privileged key split into threshold shares via `bsvz.primitives.keyshares`, persisted in the `key_shares` SQLite table)
- [x] Wallet-level encrypt/decrypt operations (privileged key → AES-GCM via `bsvz.primitives.symmetric`)

## Wallet API Completeness

- [x] `internalizeAction` (BEEF parse, outputs recorded, inputs marked spent, known_txs upsert; SQLite backend; tests)
- [x] `listFailedActions` (spec-op label, wire-compatible with TS/Go; `unfail` transitions for Monitor recovery)
- [x] `relinquishOutput` (clear basket membership; SQLite + remote RPC; tests)
- [x] `getBalance` (sum spendable outputs)
- [ ] `requestSyncChunk` / sync state management
- [ ] Pending sign actions local repo

## Domain Model

- [ ] Typed result structs replacing raw `std.json.Value` returns
- [ ] Typed error set with structured error codes
- [ ] Output entity with basket, tags, spend status
- [ ] Transaction entity with labels, status, proof
- [ ] Commission entity and tracking
- [ ] `AuthId` with full storage identity key support

## Services

- [ ] Exchange rate service (fiat conversion)
- [ ] Script hash history (`getScriptHashHistory`)
- [ ] BRC-29 payment address templates
- [ ] WhatsOnChain integration (alternative to 1Sat TXO)

## Infrastructure

- [ ] Pluggable randomizer interface (for deterministic testing)
- [ ] OpenTelemetry tracing
- [ ] Structured logging beyond `std.log.scoped`
- [ ] Permissions manager (per-app, per-protocol access control)
- [ ] Mock HTTP server for offline service tests (previous attempt was removed; rewrite against the Zig 0.16/0.17 `std.Io` API)
- [x] CI workflow (GitHub Actions; Zig 0.16.0 + 0.17 master, both required)
- [ ] Examples directory
