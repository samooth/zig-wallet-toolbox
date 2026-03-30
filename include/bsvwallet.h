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

#ifdef __cplusplus
}
#endif

#endif /* BSVWALLET_H */
