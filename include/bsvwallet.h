/*
 * bsvwallet — C ABI for the zig-wallet-toolbox BRC-100 wallet.
 * Link against libbsvwallet_c.a produced by `zig build`.
 *
 * Wallet state is managed via opaque handles.
 * JSON strings are used for complex args/results.
 *
 * Returns 0 on success, negative on failure:
 *   -1  ERR_INVALID_INPUT
 *   -2  ERR_WALLET
 *   -3  ERR_JSON
 *   -4  ERR_ALLOC
 *   -5  ERR_NOT_INIT
 *   -6  ERR_BUFFER_TOO_SMALL
 *   -7  ERR_HTTP
 */

#ifndef BSVWALLET_H
#define BSVWALLET_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque wallet handle */
typedef void* bsvwallet_t;

/* ── Lifecycle ─────────────────────────────────────────────────────── */

/* Create a wallet from 32-byte private key. chain: 0=mainnet, 1=testnet. */
int bsvwallet_create(const unsigned char *privkey, int chain, bsvwallet_t *out_handle);

/* Create a wallet connected to a remote 1sat-stack backend.
 * Sets up BRC-103/104 authenticated communication. */
int bsvwallet_create_remote(const unsigned char *privkey, int chain,
                             const char *backend_url, size_t backend_url_len,
                             bsvwallet_t *out_handle);

/* Destroy wallet and free resources. */
int bsvwallet_destroy(bsvwallet_t handle);

/* ── Wallet operations ─────────────────────────────────────────────── */

/* Get identity public key (66-char hex). out_buf >= 66 bytes. */
int bsvwallet_get_public_key(bsvwallet_t handle, char *out_buf, size_t *out_len);

/* Create a wallet action. args_json: CreateActionArgs JSON string.
 * out_buf >= 4096 bytes for result JSON. */
int bsvwallet_create_action(bsvwallet_t handle,
                             const char *args_json, size_t args_len,
                             char *out_buf, size_t *out_len);

/* Sign a wallet action. args_json: SignActionArgs JSON string.
 * out_buf >= 4096 bytes for result JSON. */
int bsvwallet_sign_action(bsvwallet_t handle,
                           const char *args_json, size_t args_len,
                           char *out_buf, size_t *out_len);

/* List wallet outputs. args_json: optional ListOutputsArgs JSON (or empty).
 * out_buf >= 8192 bytes for result JSON. */
int bsvwallet_list_outputs(bsvwallet_t handle,
                            const char *args_json, size_t args_len,
                            char *out_buf, size_t *out_len);

/* List wallet actions. args_json: optional ListActionsArgs JSON (or empty).
 * out_buf >= 8192 bytes for result JSON. */
int bsvwallet_list_actions(bsvwallet_t handle,
                            const char *args_json, size_t args_len,
                            char *out_buf, size_t *out_len);

/* Sign data with wallet key. DER signature output.
 * out_sig >= 72 bytes. */
int bsvwallet_sign_data(bsvwallet_t handle,
                         const char *data, size_t data_len,
                         unsigned char *out_sig, size_t *out_sig_len);

/* Get wallet balance (sum of spendable outputs).
 * Writes confirmed satoshis to out_confirmed, unconfirmed to out_unconfirmed. */
int bsvwallet_get_balance(bsvwallet_t handle,
                           long long *out_confirmed,
                           long long *out_unconfirmed);

/* Get balance without a pre-existing handle. Creates a temporary remote
 * wallet connection, fetches balance, and tears down.
 * privkey: 32-byte key, backend_url + len: remote URL. */
int bsvwallet_get_balance_remote(const unsigned char *privkey, int chain,
                                  const char *backend_url, size_t backend_url_len,
                                  long long *out_confirmed,
                                  long long *out_unconfirmed);

/* Derive a protocol-scoped public key (BRC-42/43).
 * protocol_id + len: protocol name, key_id + len: key identifier.
 * security_level: 0-2. for_self: true for own key, false for counterparty.
 * counterparty + len: hex pubkey (0 len if for_self).
 * out_pubkey >= 66 bytes for hex-encoded compressed pubkey. */
int bsvwallet_get_derived_public_key(bsvwallet_t handle,
                                      const char *protocol_id, size_t protocol_id_len,
                                      const char *key_id, size_t key_id_len,
                                      unsigned char security_level,
                                      int for_self,
                                      const char *counterparty, size_t counterparty_len,
                                      char *out_pubkey, size_t *out_pubkey_len);

/* ── Authenticated HTTP (BRC-100) ─────────────────────────────────── */

/* Opaque auth client handle */
typedef void* bsvauth_t;

/* Create an authenticated HTTP client from 32-byte private key. */
int bsvauth_create(const unsigned char *privkey, bsvauth_t *out_handle);

/* Destroy auth client and free resources. */
int bsvauth_destroy(bsvauth_t handle);

/* Authenticated GET request.
 * out_body_len: on entry, capacity of out_body; on exit, actual body length.
 * Returns -6 (ERR_BUFFER_TOO_SMALL) if response exceeds capacity. */
int bsvauth_get(bsvauth_t handle,
                const char *url, size_t url_len,
                unsigned short *out_status,
                char *out_body, size_t *out_body_len);

/* Authenticated POST with JSON body.
 * out_body_len: on entry, capacity of out_body; on exit, actual body length.
 * Returns -6 (ERR_BUFFER_TOO_SMALL) if response exceeds capacity. */
int bsvauth_post_json(bsvauth_t handle,
                       const char *url, size_t url_len,
                       const char *body, size_t body_len,
                       unsigned short *out_status,
                       char *out_body, size_t *out_body_len);

#ifdef __cplusplus
}
#endif

#endif /* BSVWALLET_H */
