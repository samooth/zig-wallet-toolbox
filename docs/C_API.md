# C API Reference — zig-wallet-toolbox

C ABI exports for the Zig Wallet Toolbox — a BRC-100 compliant wallet implementation for the BSV blockchain.

## Overview

This library provides a C-compatible interface to the Zig Wallet Toolbox, enabling wallet operations from C, C++, and other languages that can link against a C static library.

### Build Artifacts

| Artifact | Location | Description |
|----------|----------|-------------|
| Header | `include/bsvwallet.h` | C API declarations |
| Static Library | `zig-out/lib/libbsvwallet_c.a` | Linked library (via `zig build`) |

### Requirements

- **Zig 0.16.0+** (tested on 0.16.0 and master)
- C99 or later compiler
- Link against `libbsvwallet_c.a` and include `include/bsvwallet.h`

### Building

```bash
git clone https://github.com/b-open-io/zig-wallet-toolbox.git
cd zig-wallet-toolbox
zig build --summary all
# Output: zig-out/lib/libbsvwallet_c.a
# Header: include/bsvwallet.h
```

---

## Thread Safety Model

**Critical**: Each opaque handle owns its own I/O runtime. There is **no global state**.

- `bsvwallet_t` → owns `std.Io.Threaded` + `AuthFetch` + storage + services
- `bsvauth_t` → owns `std.Io.Threaded` + `AuthFetch`

Multiple handles can be used concurrently from different threads. Do **not** share handles across threads without external synchronization.

---

## Error Codes

All functions return `int`:

| Code | Constant | Description |
|------|----------|-------------|
| 0 | `OK` | Success |
| -1 | `ERR_INVALID_INPUT` | Invalid arguments (null pointers, bad lengths, malformed JSON) |
| -2 | `ERR_WALLET` | Wallet operation failed |
| -3 | `ERR_JSON` | JSON parsing/serialization error |
| -4 | `ERR_ALLOC` | Memory allocation failed |
| -5 | `ERR_NOT_INIT` | Handle is null or already destroyed |
| -6 | `ERR_BUFFER_TOO_SMALL` | Output buffer too small for response |
| -7 | `ERR_HTTP` | HTTP request failed |

---

## Opaque Handles

```c
typedef void* bsvwallet_t;   // Wallet handle
typedef void* bsvauth_t;     // Authenticated HTTP client handle
```

---

## Wallet API (`bsvwallet_t`)

### Lifecycle

#### `bsvwallet_create`
```c
int bsvwallet_create(const unsigned char *privkey, int chain, bsvwallet_t *out_handle);
```
Create a wallet from a 32-byte private key.
- `privkey`: 32-byte private key
- `chain`: 0 = mainnet, 1 = testnet
- `out_handle`: Receives opaque wallet handle
- Returns: `OK` or error code

#### `bsvwallet_create_remote`
```c
int bsvwallet_create_remote(const unsigned char *privkey, int chain,
                             const char *backend_url, size_t backend_url_len,
                             bsvwallet_t *out_handle);
```
Create a wallet connected to a remote 1sat-stack backend (go-wallet-toolbox deployment). Sets up BRC-103/104 authenticated communication.
- `privkey`: 32-byte private key
- `chain`: 0 = mainnet, 1 = testnet
- `backend_url`: Backend URL (e.g., "https://your-backend.example.com")
- `backend_url_len`: Length of backend_url
- `out_handle`: Receives opaque wallet handle
- Returns: `OK` or error code

#### `bsvwallet_destroy`
```c
int bsvwallet_destroy(bsvwallet_t handle);
```
Destroy wallet and free all resources (I/O runtime, auth client, storage, services).
- Returns: `OK` or `ERR_NOT_INIT`

---

### Identity

#### `bsvwallet_get_public_key`
```c
int bsvwallet_get_public_key(bsvwallet_t handle, char *out_buf, size_t *out_len);
```
Get the wallet's identity public key (66-char hex string, compressed secp256k1).
- `out_buf`: Buffer ≥ 66 bytes
- `out_len`: On entry, buffer capacity; on exit, actual length (66)
- Returns: `OK` or `ERR_BUFFER_TOO_SMALL`

---

### Actions

#### `bsvwallet_create_action`
```c
int bsvwallet_create_action(bsvwallet_t handle,
                             const char *args_json, size_t args_len,
                             char *out_buf, size_t *out_len);
```
Create a wallet action (transaction template). Parses full `CreateActionArgs` JSON.

**args_json Schema (CreateActionArgs):**
```json
{
  "description": "string",
  "outputs": [
    {
      "lockingScript": "hex",
      "satoshis": 1000,
      "description": "optional string",
      "basket": "optional string",
      "tags": ["optional", "string", "array"]
    }
  ],
  "inputs": [
    {
      "outpoint": "txid_vout",
      "unlockingScript": "optional hex",
      "unlockingScriptLength": "optional integer",
      "inputDescription": "optional string",
      "sequenceNumber": "optional integer"
    }
  ],
  "labels": ["optional", "string", "array"],
  "options": {
    "noSend": false,
    "signAndProcess": true,
    "acceptDelayedBroadcast": true,
    "returnTXIDOnly": false,
    "randomizeOutputs": true,
    "changeBasket": "optional string",
    "sendWith": ["optional", "txid", "array"]
  }
}
```

- `args_json`: JSON string matching schema above
- `args_len`: Length of args_json
- `out_buf`: Buffer ≥ 4096 bytes for result JSON
- `out_len`: On entry, capacity; on exit, actual length
- Returns: `OK`, `ERR_BUFFER_TOO_SMALL`, `ERR_JSON`, or `ERR_WALLET`

**Result JSON:**
```json
{
  "referenceNumber": "string",
  "txid": "string",
  "inputBeef": "optional hex",
  "noSendChangeOutputVouts": "optional array"
}
```

#### `bsvwallet_sign_action`
```c
int bsvwallet_sign_action(bsvwallet_t handle,
                           const char *args_json, size_t args_len,
                           char *out_buf, size_t *out_len);
```
Sign a wallet action. Parses full `SignActionArgs` JSON.

**args_json Schema (SignActionArgs):**
```json
{
  "reference": "string",
  "spends": {
    "0": {
      "unlockingScript": "hex",
      "sequenceNumber": "optional integer"
    },
    "1": { ... }
  },
  "options": {
    "acceptDelayedBroadcast": "optional boolean",
    "returnTXIDOnly": "optional boolean",
    "noSend": "optional boolean",
    "sendWith": ["optional", "txid", "array"]
  }
}
```

- `out_buf`: Buffer ≥ 4096 bytes
- Returns: `OK`, `ERR_BUFFER_TOO_SMALL`, `ERR_JSON`, or `ERR_WALLET`

**Result JSON:**
```json
{
  "txid": "string"
}
```

---

### Queries

#### `bsvwallet_list_outputs`
```c
int bsvwallet_list_outputs(bsvwallet_t handle,
                            const char *args_json, size_t args_len,
                            char *out_buf, size_t *out_len);
```
List wallet outputs. Optional `args_json` (pass empty string for defaults).

**args_json Schema (ListOutputsArgs):**
```json
{
  "basket": "optional string",
  "tags": ["optional", "string", "array"],
  "spendable": "optional boolean",
  "limit": "optional integer",
  "offset": "optional integer"
}
```

- `out_buf`: Buffer ≥ 8192 bytes
- Returns: `OK`, `ERR_BUFFER_TOO_SMALL`, `ERR_JSON`, or `ERR_WALLET`

#### `bsvwallet_list_actions`
```c
int bsvwallet_list_actions(bsvwallet_t handle,
                            const char *args_json, size_t args_len,
                            char *out_buf, size_t *out_len);
```
List wallet actions.

**args_json Schema (ListActionsArgs):**
```json
{
  "labels": ["optional", "string", "array"],
  "limit": "optional integer",
  "offset": "optional integer"
}
```

- `out_buf`: Buffer ≥ 8192 bytes
- Returns: `OK`, `ERR_BUFFER_TOO_SMALL`, `ERR_JSON`, or `ERR_WALLET`

---

### Cryptography

#### `bsvwallet_sign_data`
```c
int bsvwallet_sign_data(bsvwallet_t handle,
                         const char *data, size_t data_len,
                         unsigned char *out_sig, size_t *out_sig_len);
```
Create DER signature over arbitrary data (SHA-256d + ECDSA).
- `out_sig`: Buffer ≥ 72 bytes (max DER sig)
- `out_sig_len`: On entry, capacity; on exit, actual length
- Returns: `OK` or `ERR_BUFFER_TOO_SMALL`

#### `bsvwallet_get_balance`
```c
int bsvwallet_get_balance(bsvwallet_t handle,
                           long long *out_confirmed,
                           long long *out_unconfirmed);
```
Get wallet balance (sum of spendable outputs from default basket).
- `out_confirmed`: Receives confirmed satoshis
- `out_unconfirmed`: Receives unconfirmed (always 0 currently)
- Returns: `OK` or `ERR_WALLET`

#### `bsvwallet_get_balance_remote`
```c
int bsvwallet_get_balance_remote(const unsigned char *privkey, int chain,
                                  const char *backend_url, size_t backend_url_len,
                                  long long *out_confirmed,
                                  long long *out_unconfirmed);
```
Get balance without a pre-existing handle. Creates temporary remote wallet, fetches balance, tears down.

#### `bsvwallet_get_derived_public_key`
```c
int bsvwallet_get_derived_public_key(bsvwallet_t handle,
                                      const char *protocol_id, size_t protocol_id_len,
                                      const char *key_id, size_t key_id_len,
                                      unsigned char security_level,
                                      int for_self,
                                      const char *counterparty, size_t counterparty_len,
                                      char *out_pubkey, size_t *out_pubkey_len);
```
Derive protocol-scoped public key (BRC-42/43).
- `security_level`: 0, 1, or 2
- `for_self`: 1 = derive for self, 0 = for counterparty
- `counterparty`: Hex pubkey (ignored if for_self=1, pass 0 length)
- `out_pubkey`: Buffer ≥ 66 bytes
- `out_pubkey_len`: On entry, capacity; on exit, 66
- Returns: `OK` or `ERR_BUFFER_TOO_SMALL`

---

### Remote Helpers (No Handle Required)

These create temporary remote connections, execute the operation, and tear down.

#### `bsvwallet_create_action_remote`
```c
int bsvwallet_create_action_remote(const unsigned char *privkey, int chain,
                                    const char *backend_url, size_t backend_url_len,
                                    const char *args_json, size_t args_json_len,
                                    char *out_buf, size_t *out_buf_len);
```
- `args_json`: Full CreateActionArgs JSON (see above)
- `out_buf`: Buffer ≥ 8192 bytes

#### `bsvwallet_sign_action_remote`
```c
int bsvwallet_sign_action_remote(const unsigned char *privkey, int chain,
                                  const char *backend_url, size_t backend_url_len,
                                  const char *args_json, size_t args_json_len,
                                  char *out_buf, size_t *out_buf_len);
```
- `args_json`: Full SignActionArgs JSON (see above)
- `out_buf`: Buffer ≥ 8192 bytes

#### `bsvwallet_inscribe_remote`
```c
int bsvwallet_inscribe_remote(const unsigned char *privkey, int chain,
                               const char *backend_url, size_t backend_url_len,
                               const unsigned char *content, size_t content_len,
                               const char *content_type, size_t ct_len,
                               const char *app_name, size_t name_len,
                               char *out_buf, size_t *out_buf_len);
```
Create ordinal inscription (1-sat output with inscription envelope).
- `content`: Raw inscription content bytes
- `content_type`: MIME type (e.g., "text/plain")
- `app_name`: Optional label (pass NULL/0 to skip)
- `out_buf`: Buffer ≥ 8192 bytes

---

## Authenticated HTTP API (`bsvauth_t`)

### Lifecycle

#### `bsvauth_create`
```c
int bsvauth_create(const unsigned char *privkey, bsvauth_t *out_handle);
```
Create authenticated HTTP client from 32-byte private key. Each handle owns its I/O runtime.
- `out_handle`: Receives opaque auth handle
- Returns: `OK` or error code

#### `bsvauth_destroy`
```c
int bsvauth_destroy(bsvauth_t handle);
```
Destroy auth client and free resources.
- Returns: `OK` or `ERR_NOT_INIT`

---

### Transport

#### `bsvauth_get`
```c
int bsvauth_get(bsvauth_t handle,
                 const char *url, size_t url_len,
                 unsigned short *out_status,
                 char *out_body, size_t *out_body_len);
```
Authenticated GET request with mutual auth (BRC-103/104).
- `out_body_len`: On entry, buffer capacity; on exit, actual body length
- Returns `ERR_BUFFER_TOO_SMALL` (-6) if response exceeds capacity
- Returns: `OK`, `ERR_BUFFER_TOO_SMALL`, `ERR_HTTP`, or `ERR_NOT_INIT`

#### `bsvauth_post_json`
```c
int bsvauth_post_json(bsvauth_t handle,
                       const char *url, size_t url_len,
                       const char *body, size_t body_len,
                       unsigned short *out_status,
                       char *out_body, size_t *out_body_len);
```
Authenticated POST with JSON body.
- `body`: JSON request body
- `out_body_len`: On entry, buffer capacity; on exit, actual body length
- Returns: `OK`, `ERR_BUFFER_TOO_SMALL`, `ERR_HTTP`, or `ERR_NOT_INIT`

---

## Buffer Sizing Quick Reference

| Function | Minimum Buffer | Notes |
|----------|----------------|-------|
| `get_public_key` | 66 bytes | 66-char hex compressed pubkey |
| `sign_data` | 72 bytes | Max DER signature |
| `get_derived_public_key` | 66 bytes | 66-char hex compressed pubkey |
| `create_action` | 4096 bytes | Result includes reference, txid, optional beef |
| `sign_action` | 4096 bytes | Result includes txid |
| `list_outputs` | 8192 bytes | Can include many outputs |
| `list_actions` | 8192 bytes | Can include many actions |
| Remote helpers | 8192 bytes | Larger responses with proofs |
| `bsvauth_get/post_json` | Caller-defined | Returns `ERR_BUFFER_TOO_SMALL` if insufficient |

*Sizes based on current BRC-100 schemas; increase if needed.*

---

## Complete C Example

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bsvwallet.h"

void check(int rc, const char *msg) {
    if (rc != 0) {
        fprintf(stderr, "ERROR %s: %d\n", msg, rc);
        exit(1);
    }
}

int main() {
    // 1. Generate or load 32-byte private key (example uses fixed key for demo)
    unsigned char privkey[32] = {
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20
    };

    // 2. Create wallet with local (in-memory) storage
    bsvwallet_t wallet;
    check(bsvwallet_create(privkey, 0, &wallet), "create wallet");

    // 3. Get identity public key
    char pubkey[66];
    size_t pubkey_len = sizeof(pubkey);
    check(bsvwallet_get_public_key(wallet, pubkey, &pubkey_len), "get pubkey");
    printf("Identity: %.*s\n", (int)pubkey_len, pubkey);

    // 4. Create action with full JSON args
    const char *create_args = "{\n"
        "  \"description\": \"Send payment\",\n"
        "  \"outputs\": [\n"
        "    {\"lockingScript\": \"76a91489abcdef...88ac\", \"satoshis\": 10000}\n"
        "  ],\n"
        "  \"labels\": [\"payment\"],\n"
        "  \"options\": {\"noSend\": true}\n"
        "}";

    char result[4096];
    size_t result_len = sizeof(result);
    check(bsvwallet_create_action(wallet, create_args, strlen(create_args), result, &result_len),
          "create action");
    printf("Create result: %.*s\n", (int)result_len, result);

    // 5. Sign the action (requires unlocking scripts from external signer)
    const char *sign_args = "{\n"
        "  \"reference\": \"ref_12345\",\n"
        "  \"spends\": {\n"
        "    \"0\": {\"unlockingScript\": \"4730440220...0220...41\"}\n"
        "  }\n"
        "}";

    result_len = sizeof(result);
    check(bsvwallet_sign_action(wallet, sign_args, strlen(sign_args), result, &result_len),
          "sign action");
    printf("Sign result: %.*s\n", (int)result_len, result);

    // 6. Get balance
    long long confirmed, unconfirmed;
    check(bsvwallet_get_balance(wallet, &confirmed, &unconfirmed), "get balance");
    printf("Balance: %lld confirmed, %lld unconfirmed\n", confirmed, unconfirmed);

    // 7. Authenticated HTTP (separate handle)
    bsvauth_t auth;
    check(bsvauth_create(privkey, &auth), "create auth");

    char response[8192];
    size_t resp_len = sizeof(response);
    unsigned short status;
    check(bsvauth_get(auth, "https://api.example.com/health", 35, &status, response, &resp_len),
          "auth GET");
    printf("HTTP %u: %.*s\n", status, (int)resp_len, response);

    // 8. Cleanup
    check(bsvauth_destroy(auth), "destroy auth");
    check(bsvwallet_destroy(wallet), "destroy wallet");

    printf("Done.\n");
    return 0;
}
```

### Compile & Run

```bash
# Assuming libbsvwallet_c.a in ./zig-out/lib/ and header in ./include/
gcc -I./include -o wallet_example example.c -L./zig-out/lib -lbsvwallet_c
./wallet_example
```

---

## JSON Schema Reference

### CreateActionArgs
```json
{
  "description": "string (required)",
  "outputs": [
    {
      "lockingScript": "hex (required)",
      "satoshis": "integer (required)",
      "description": "string (optional)",
      "basket": "string (optional)",
      "tags": "string[] (optional)"
    }
  ],
  "inputs": [
    {
      "outpoint": "string (required, format: txid_vout)",
      "unlockingScript": "hex (optional)",
      "unlockingScriptLength": "integer (optional)",
      "inputDescription": "string (optional)",
      "sequenceNumber": "integer (optional)"
    }
  ],
  "labels": "string[] (optional)",
  "options": {
    "noSend": "boolean (default: false)",
    "signAndProcess": "boolean (default: true)",
    "acceptDelayedBroadcast": "boolean (default: true)",
    "returnTXIDOnly": "boolean (default: false)",
    "randomizeOutputs": "boolean (default: true)",
    "changeBasket": "string (optional)",
    "sendWith": "string[] (optional)"
  }
}
```

### SignActionArgs
```json
{
  "reference": "string (required, from createAction result)",
  "spends": {
    "0": {
      "unlockingScript": "hex (required)",
      "sequenceNumber": "integer (optional)"
    }
  },
  "options": {
    "acceptDelayedBroadcast": "boolean (optional)",
    "returnTXIDOnly": "boolean (optional)",
    "noSend": "boolean (optional)",
    "sendWith": "string[] (optional)"
  }
}
```

### ListOutputsArgs
```json
{
  "basket": "string (optional)",
  "tags": "string[] (optional)",
  "spendable": "boolean (optional)",
  "limit": "integer (optional)",
  "offset": "integer (optional)"
}
```

### ListActionsArgs
```json
{
  "labels": "string[] (optional)",
  "limit": "integer (optional)",
  "offset": "integer (optional)"
}
```

---

## Version Compatibility

| zig-wallet-toolbox | Zig Version | C API Version |
|-------------------|-------------|---------------|
| 0.1.x | 0.16.0+ | v1 (current) |

---

## License

Open BSV License.