/**
 * @file zenoh_token.c
 * @brief FNV1a-32 implementation + optional registry.
 */

/* strdup() is POSIX, not C11 — request it explicitly. */
#define _POSIX_C_SOURCE 200809L

#include "zenoh_token.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/*  FNV1a-32                                                           */
/* ------------------------------------------------------------------ */

#define FNV1A_32_OFFSET 0x811c9dc5u
#define FNV1A_32_PRIME  0x01000193u

const char *zt_status_str(zt_status_t st) {
    switch (st) {
        case ZT_OK:                return "OK";
        case ZT_ERR_INVALID_ARG:   return "invalid argument";
        case ZT_ERR_MEMORY:        return "out of memory";
        case ZT_ERR_DUPLICATE:     return "duplicate token, different topic";
        case ZT_ERR_NOT_FOUND:     return "not found";
    }
    return "unknown";
}

uint32_t zt_hash(const char *topic) {
    if (topic == NULL) return 0xFFFFFFFFu;
    uint32_t h = FNV1A_32_OFFSET;
    for (const unsigned char *p = (const unsigned char *)topic; *p; ++p) {
        h ^= (uint32_t)*p;
        h *= FNV1A_32_PRIME;
    }
    return h;
}

zt_status_t zt_hash_list(const char *const *topics, size_t n, uint32_t *out) {
    if (topics == NULL || out == NULL) return ZT_ERR_INVALID_ARG;
    for (size_t i = 0; i < n; ++i) {
        if (topics[i] == NULL) return ZT_ERR_INVALID_ARG;
        out[i] = zt_hash(topics[i]);
    }
    return ZT_OK;
}

/* ------------------------------------------------------------------ */
/*  Registry                                                           */
/*                                                                     */
/*  Simple open-addressed hash table keyed by token. Storage doubles   */
/*  on growth; the entire registry's lifetime is process-scoped so we  */
/*  don't bother with shrinking.                                       */
/* ------------------------------------------------------------------ */

typedef struct {
    uint32_t  token;
    int       used;          /* 0 = empty, 1 = occupied                       */
    char     *topic;         /* owned malloc'd copy                           */
} reg_slot_t;

static pthread_mutex_t reg_lock  = PTHREAD_MUTEX_INITIALIZER;
static reg_slot_t     *reg_slots = NULL;
static size_t          reg_cap   = 0;   /* power of two when non-zero         */
static size_t          reg_count = 0;

static int reg_grow(size_t new_cap) {
    reg_slot_t *fresh = calloc(new_cap, sizeof(*fresh));
    if (!fresh) return -1;
    /* Rehash existing entries into the new table. */
    for (size_t i = 0; i < reg_cap; ++i) {
        if (!reg_slots[i].used) continue;
        size_t mask = new_cap - 1;
        size_t idx  = reg_slots[i].token & mask;
        while (fresh[idx].used) idx = (idx + 1) & mask;
        fresh[idx] = reg_slots[i];
    }
    free(reg_slots);
    reg_slots = fresh;
    reg_cap   = new_cap;
    return 0;
}

zt_status_t zt_register(uint32_t token, const char *topic) {
    if (topic == NULL) return ZT_ERR_INVALID_ARG;

    pthread_mutex_lock(&reg_lock);

    /* Initialise or grow if load factor would exceed 1/2. */
    if (reg_cap == 0) {
        if (reg_grow(16) < 0) {
            pthread_mutex_unlock(&reg_lock);
            return ZT_ERR_MEMORY;
        }
    } else if ((reg_count + 1) * 2 > reg_cap) {
        if (reg_grow(reg_cap * 2) < 0) {
            pthread_mutex_unlock(&reg_lock);
            return ZT_ERR_MEMORY;
        }
    }

    size_t mask = reg_cap - 1;
    size_t idx  = token & mask;
    while (reg_slots[idx].used) {
        if (reg_slots[idx].token == token) {
            int same = (strcmp(reg_slots[idx].topic, topic) == 0);
            pthread_mutex_unlock(&reg_lock);
            return same ? ZT_OK : ZT_ERR_DUPLICATE;
        }
        idx = (idx + 1) & mask;
    }

    char *copy = strdup(topic);
    if (!copy) {
        pthread_mutex_unlock(&reg_lock);
        return ZT_ERR_MEMORY;
    }
    reg_slots[idx].token = token;
    reg_slots[idx].used  = 1;
    reg_slots[idx].topic = copy;
    reg_count++;

    pthread_mutex_unlock(&reg_lock);
    return ZT_OK;
}

const char *zt_lookup(uint32_t token) {
    pthread_mutex_lock(&reg_lock);
    if (reg_cap == 0) {
        pthread_mutex_unlock(&reg_lock);
        return NULL;
    }
    size_t mask = reg_cap - 1;
    size_t idx  = token & mask;
    while (reg_slots[idx].used) {
        if (reg_slots[idx].token == token) {
            const char *t = reg_slots[idx].topic;
            pthread_mutex_unlock(&reg_lock);
            return t;
        }
        idx = (idx + 1) & mask;
    }
    pthread_mutex_unlock(&reg_lock);
    return NULL;
}

void zt_registry_clear(void) {
    pthread_mutex_lock(&reg_lock);
    for (size_t i = 0; i < reg_cap; ++i) {
        if (reg_slots[i].used) free(reg_slots[i].topic);
    }
    free(reg_slots);
    reg_slots = NULL;
    reg_cap   = 0;
    reg_count = 0;
    pthread_mutex_unlock(&reg_lock);
}

size_t zt_registry_size(void) {
    pthread_mutex_lock(&reg_lock);
    size_t n = reg_count;
    pthread_mutex_unlock(&reg_lock);
    return n;
}
