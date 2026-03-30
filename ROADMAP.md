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
- [x] E2e test against live `api.1sat.app`

## Storage

- [ ] Local storage provider (SQLite via C interop or custom file-backed store)
- [ ] GORM-equivalent entity model (Output, Transaction, User, OutputBasket, TxNote, KnownTx)
- [ ] CRUD query builder with typed conditions, filters, pagination
- [ ] Storage server (HTTP server hosting wallet storage for remote clients)
- [ ] BEEF verification in storage layer
- [ ] Script verification in storage layer

## Monitor

- [ ] Background monitor daemon
- [ ] Rebroadcast failed/pending transactions
- [ ] Chain reorganization handling
- [ ] Merkle proof acquisition for confirmed transactions
- [ ] Sync pending transaction statuses

## Certificates

- [ ] Certificate entity model (`TableCertificate`, `TableCertificateField`)
- [ ] Certificate issuance
- [ ] Certificate listing and filtering
- [ ] Certificate relinquishing
- [ ] Certifier server

## Key Management

- [x] Protocol-based key derivation within wallet context (BRC-42/43)
- [ ] `PrivilegedKeyManager` equivalent with Shamir secret sharing
- [ ] Wallet-level encrypt/decrypt operations

## Wallet API Completeness

- [ ] `internalizeAction` (wired but untested)
- [ ] `listFailedActions`
- [ ] `relinquishOutput`
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
- [ ] MockChain for offline testing (mock mining, UTXO tracking, proof generation)
- [ ] CI workflow (GitHub Actions)
- [ ] Examples directory
