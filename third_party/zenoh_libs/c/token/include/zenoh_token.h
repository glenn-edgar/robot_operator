/**
 * @file zenoh_token.h
 * @brief FNV1a-32 topic-token utility for the zenoh build_block.
 *
 * Topics (strings) are hashed to 32-bit tokens for compact wire representation
 * and fast comparison. The algorithm is FNV-1a (Fowler-Noll-Vo), well-known
 * non-cryptographic hash, simple and portable.
 *
 * A small in-memory registry can optionally hold string<->token mappings for
 * debug / reverse lookup.
 *
 * Typical usage:
 *
 *     uint32_t t = zt_hash("robot/42/telemetry");
 *
 *     const char *topics[] = { "sensor/temp", "sensor/hum", "sensor/baro" };
 *     uint32_t tokens[3];
 *     zt_hash_list(topics, 3, tokens);
 */

#ifndef ZENOH_TOKEN_H
#define ZENOH_TOKEN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/*  Status codes                                                       */
/* ------------------------------------------------------------------ */

typedef enum {
    ZT_OK = 0,
    ZT_ERR_INVALID_ARG,
    ZT_ERR_MEMORY,
    ZT_ERR_DUPLICATE,    /**< zt_register: token already maps to a different string */
    ZT_ERR_NOT_FOUND,    /**< zt_lookup: token not registered */
} zt_status_t;

const char *zt_status_str(zt_status_t st);

/* ------------------------------------------------------------------ */
/*  Hash                                                               */
/* ------------------------------------------------------------------ */

/**
 * FNV1a-32 hash of a NUL-terminated string.
 *
 * Deterministic across platforms and zenoh-pico builds; safe to use as a
 * stable token identifier on the wire.
 *
 * @param topic NUL-terminated string. Must not be NULL.
 * @return      32-bit token (0xFFFFFFFF returned only if topic == NULL).
 */
uint32_t zt_hash(const char *topic);

/**
 * Hash a list of strings into a parallel array of tokens.
 *
 * @param topics Array of NUL-terminated strings, length n.
 * @param n      Number of entries.
 * @param out    Caller-provided array of n uint32_t to receive tokens.
 * @return       ZT_OK on success, ZT_ERR_INVALID_ARG if any pointer is NULL.
 */
zt_status_t zt_hash_list(const char *const *topics, size_t n, uint32_t *out);

/* ------------------------------------------------------------------ */
/*  Optional registry (debug / reverse lookup)                         */
/* ------------------------------------------------------------------ */

/**
 * Register a (token, topic) pair so zt_lookup() can recover the string later.
 *
 * Typical usage: register every topic your application uses during init.
 * Useful for debug printing and for tools that decode wire traces.
 *
 * @param token Token value (typically from zt_hash(topic)).
 * @param topic NUL-terminated string. A copy is stored.
 * @return      ZT_OK on success.
 *              ZT_ERR_DUPLICATE if token already maps to a different string.
 *              Registering the same (token, topic) twice is a no-op (returns ZT_OK).
 */
zt_status_t zt_register(uint32_t token, const char *topic);

/**
 * Look up the string previously registered for a token.
 *
 * @param token Token to look up.
 * @return      Pointer to the stored string (owned by the registry — do NOT free).
 *              NULL if the token is not registered.
 */
const char *zt_lookup(uint32_t token);

/**
 * Clear the registry, freeing all stored strings.
 *
 * Safe to call at shutdown.
 */
void zt_registry_clear(void);

/**
 * Return the number of entries currently in the registry. Mainly for tests.
 */
size_t zt_registry_size(void);

#ifdef __cplusplus
}
#endif

#endif /* ZENOH_TOKEN_H */
