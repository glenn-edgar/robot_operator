/**
 * @file zenoh_pubsub.c
 * @brief zenoh-pico-backed publish/subscribe wrapper.
 *
 * Wire keyexpr is "tok/%08x" where %08x is the FNV1a-32 token in lowercase
 * hex. This keeps the on-the-wire keys compact (12 ASCII chars) and human-
 * readable in zenoh-pico traces.
 *
 * Session lifecycle uses z_open / z_drop. Publish uses z_put (one-shot, no
 * publisher caching). Subscribe uses z_declare_subscriber with a closure
 * that adapts zenoh-pico's z_loaned_sample_t to the caller's
 * zenoh_pubsub_callback_t.
 */

#define _POSIX_C_SOURCE 200809L

#include "zenoh_pubsub.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zenoh-pico.h>

/* ------------------------------------------------------------------ */
/*  Status                                                             */
/* ------------------------------------------------------------------ */

const char *zps_status_str(zps_status_t st) {
    switch (st) {
        case ZPS_OK:                return "OK";
        case ZPS_ERR_INVALID_ARG:   return "invalid argument";
        case ZPS_ERR_CONNECTION:    return "connection error";
        case ZPS_ERR_TIMEOUT:       return "timeout";
        case ZPS_ERR_MEMORY:        return "out of memory";
        case ZPS_ERR_NOT_CONNECTED: return "not connected";
        case ZPS_ERR_ZENOH:         return "zenoh-pico error";
        case ZPS_EMPTY:             return "queue empty";
    }
    return "unknown";
}

void zenoh_pubsub_config_defaults(ZenohPubSubConfig *cfg) {
    if (!cfg) return;
    cfg->locators        = NULL;
    cfg->n_locators      = 0;
    cfg->listen_locators = NULL;
    cfg->n_listen        = 0;
    cfg->mode            = "client";
    cfg->enable_scout    = false;
    cfg->client_name     = NULL;
}

/* ------------------------------------------------------------------ */
/*  Handles                                                            */
/* ------------------------------------------------------------------ */

struct ZenohPubSub {
    ZenohPubSubConfig cfg_copy;
    int               connected;
    pthread_mutex_t   lock;
    z_owned_session_t session;
};

/* ------------------------------------------------------------------ */
/*  Subscriber adapter shapes                                          */
/*                                                                     */
/*  Two flavours:                                                      */
/*    1. Callback mode — direct user callback called on the read       */
/*       thread (sub_adapter_t).                                       */
/*    2. Queue mode    — push onto a thread-safe ring buffer; caller   */
/*       drains via zenoh_pubsub_poll() (queue_adapter_t).             */
/*                                                                     */
/*  Both are reachable from the same closure thunk; the variant tag is */
/*  the first field so the thunk can branch on it cheaply.             */
/* ------------------------------------------------------------------ */

typedef enum { ADAPTER_CALLBACK = 0, ADAPTER_QUEUE = 1 } adapter_kind_t;

typedef struct {
    adapter_kind_t kind;        /* must be first */
} sub_adapter_base_t;

typedef struct {
    adapter_kind_t           kind;     /* ADAPTER_CALLBACK */
    uint32_t                 token;
    zenoh_pubsub_callback_t  user_cb;
    void                    *user_ctx;
} sub_adapter_t;

typedef struct {
    uint8_t *data;     /* owned */
    size_t   len;
    uint32_t token;
} queue_msg_t;

typedef struct {
    adapter_kind_t  kind;       /* ADAPTER_QUEUE */
    uint32_t        token;
    pthread_mutex_t lock;
    queue_msg_t    *ring;       /* depth elements                          */
    size_t          depth;      /* power of 2                              */
    size_t          mask;       /* depth - 1                               */
    size_t          head;       /* next write slot                         */
    size_t          tail;       /* next read slot                          */
    size_t          dropped;    /* count of overflow-dropped messages      */
} queue_adapter_t;

struct ZenohPubSubSub {
    z_owned_subscriber_t  z_sub;
    sub_adapter_base_t   *adapter;   /* lifetime tied to closure's drop */
};

/* ------------------------------------------------------------------ */
/*  Helpers                                                            */
/* ------------------------------------------------------------------ */

/* Render an FNV1a token as a stable keyexpr: "tok/cafebabe". */
static void token_to_keyexpr(uint32_t token, char *buf, size_t n) {
    snprintf(buf, n, "tok/%08x", token);
}

/* Closure callback: zenoh-pico delivers a sample. We route to either the
 * user callback (ADAPTER_CALLBACK) or the ring buffer (ADAPTER_QUEUE). */
static void sample_handler(z_loaned_sample_t *sample, void *ctx) {
    sub_adapter_base_t *base = (sub_adapter_base_t *)ctx;
    if (!base) return;

    const z_loaned_bytes_t *bytes = z_sample_payload(sample);
    z_owned_slice_t slice;
    if (z_bytes_to_slice(bytes, &slice) < 0) return;
    const uint8_t *data = z_slice_data(z_loan(slice));
    size_t         len  = z_slice_len(z_loan(slice));

    if (base->kind == ADAPTER_CALLBACK) {
        sub_adapter_t *ad = (sub_adapter_t *)base;
        if (ad->user_cb) ad->user_cb(ad->token, data, len, ad->user_ctx);
    } else {
        queue_adapter_t *q = (queue_adapter_t *)base;
        pthread_mutex_lock(&q->lock);
        size_t used = q->head - q->tail;
        if (used >= q->depth) {
            /* Overflow: drop the oldest. */
            free(q->ring[q->tail & q->mask].data);
            q->tail++;
            q->dropped++;
        }
        uint8_t *copy = malloc(len);
        if (copy) {
            if (len > 0) memcpy(copy, data, len);
            queue_msg_t *slot = &q->ring[q->head & q->mask];
            slot->data  = copy;
            slot->len   = len;
            slot->token = q->token;
            q->head++;
        }
        pthread_mutex_unlock(&q->lock);
    }
    z_drop(z_move(slice));
}

/* Closure drop: free adapter (and ring buffer contents if queue). */
static void sample_dropper(void *ctx) {
    sub_adapter_base_t *base = (sub_adapter_base_t *)ctx;
    if (!base) return;
    if (base->kind == ADAPTER_QUEUE) {
        queue_adapter_t *q = (queue_adapter_t *)base;
        pthread_mutex_lock(&q->lock);
        for (size_t i = q->tail; i != q->head; ++i) {
            free(q->ring[i & q->mask].data);
        }
        pthread_mutex_unlock(&q->lock);
        pthread_mutex_destroy(&q->lock);
        free(q->ring);
    }
    free(base);
}

/* ------------------------------------------------------------------ */
/*  Lifecycle                                                          */
/* ------------------------------------------------------------------ */

zps_status_t zenoh_pubsub_create(ZenohPubSub **out, const ZenohPubSubConfig *cfg) {
    if (!out || !cfg) return ZPS_ERR_INVALID_ARG;
    /* Require at least one connect OR listen locator. */
    int has_connect = (cfg->n_locators > 0 && cfg->locators != NULL);
    int has_listen  = (cfg->n_listen   > 0 && cfg->listen_locators != NULL);
    if (!has_connect && !has_listen) return ZPS_ERR_INVALID_ARG;

    ZenohPubSub *ps = calloc(1, sizeof(*ps));
    if (!ps) return ZPS_ERR_MEMORY;
    ps->cfg_copy = *cfg;
    pthread_mutex_init(&ps->lock, NULL);
    *out = ps;
    return ZPS_OK;
}

void zenoh_pubsub_destroy(ZenohPubSub *ps) {
    if (!ps) return;
    if (ps->connected) zenoh_pubsub_disconnect(ps);
    pthread_mutex_destroy(&ps->lock);
    free(ps);
}

zps_status_t zenoh_pubsub_connect(ZenohPubSub *ps) {
    if (!ps) return ZPS_ERR_INVALID_ARG;

    z_owned_config_t cfg;
    z_config_default(&cfg);
    zp_config_insert(z_loan_mut(cfg), Z_CONFIG_MODE_KEY, ps->cfg_copy.mode);
    for (size_t i = 0; i < ps->cfg_copy.n_locators; ++i) {
        zp_config_insert(z_loan_mut(cfg), Z_CONFIG_CONNECT_KEY, ps->cfg_copy.locators[i]);
    }
    for (size_t i = 0; i < ps->cfg_copy.n_listen; ++i) {
        zp_config_insert(z_loan_mut(cfg), Z_CONFIG_LISTEN_KEY, ps->cfg_copy.listen_locators[i]);
    }
    /* Scouting: zenoh-pico defaults to no multicast scouting on TCP/UDP unicast,
     * so leaving enable_scout as false requires no extra config. */

    if (z_open(&ps->session, z_move(cfg), NULL) < 0) {
        return ZPS_ERR_CONNECTION;
    }

    pthread_mutex_lock(&ps->lock);
    ps->connected = 1;
    pthread_mutex_unlock(&ps->lock);
    return ZPS_OK;
}

zps_status_t zenoh_pubsub_disconnect(ZenohPubSub *ps) {
    if (!ps) return ZPS_ERR_INVALID_ARG;

    pthread_mutex_lock(&ps->lock);
    int was_connected = ps->connected;
    ps->connected = 0;
    pthread_mutex_unlock(&ps->lock);

    if (was_connected) {
        z_drop(z_move(ps->session));
    }
    return ZPS_OK;
}

/* ------------------------------------------------------------------ */
/*  Publish                                                            */
/* ------------------------------------------------------------------ */

zps_status_t zenoh_pubsub_publish(ZenohPubSub *ps,
                                  uint32_t token,
                                  const uint8_t *payload,
                                  size_t len) {
    if (!ps) return ZPS_ERR_INVALID_ARG;
    if (len > 0 && payload == NULL) return ZPS_ERR_INVALID_ARG;
    if (!ps->connected) return ZPS_ERR_NOT_CONNECTED;

    char keystr[32];
    token_to_keyexpr(token, keystr, sizeof(keystr));

    z_view_keyexpr_t ke;
    if (z_view_keyexpr_from_str(&ke, keystr) < 0) return ZPS_ERR_INVALID_ARG;

    z_owned_bytes_t body;
    if (z_bytes_copy_from_buf(&body, payload, len) < 0) return ZPS_ERR_MEMORY;

    if (z_put(z_loan(ps->session), z_loan(ke), z_move(body), NULL) < 0) {
        return ZPS_ERR_ZENOH;
    }
    return ZPS_OK;
}

/* ------------------------------------------------------------------ */
/*  Subscribe                                                          */
/* ------------------------------------------------------------------ */

zps_status_t zenoh_pubsub_subscribe(ZenohPubSub *ps,
                                    uint32_t token,
                                    zenoh_pubsub_callback_t cb,
                                    void *ctx,
                                    ZenohPubSubSub **out) {
    if (!ps || !cb || !out) return ZPS_ERR_INVALID_ARG;
    if (!ps->connected) return ZPS_ERR_NOT_CONNECTED;

    char keystr[32];
    token_to_keyexpr(token, keystr, sizeof(keystr));

    z_view_keyexpr_t ke;
    if (z_view_keyexpr_from_str(&ke, keystr) < 0) return ZPS_ERR_INVALID_ARG;

    ZenohPubSubSub *sub = calloc(1, sizeof(*sub));
    if (!sub) return ZPS_ERR_MEMORY;

    sub_adapter_t *ad = calloc(1, sizeof(*ad));
    if (!ad) { free(sub); return ZPS_ERR_MEMORY; }
    ad->kind     = ADAPTER_CALLBACK;
    ad->token    = token;
    ad->user_cb  = cb;
    ad->user_ctx = ctx;

    z_owned_closure_sample_t closure;
    z_closure(&closure, sample_handler, sample_dropper, ad);
    sub->adapter = (sub_adapter_base_t *)ad;

    if (z_declare_subscriber(z_loan(ps->session),
                             &sub->z_sub,
                             z_loan(ke),
                             z_move(closure),
                             NULL) < 0) {
        /* zenoh-pico drops the closure (and the adapter via sample_dropper) on
         * failure, so don't free(ad) here. */
        free(sub);
        return ZPS_ERR_ZENOH;
    }
    *out = sub;
    return ZPS_OK;
}

/* ------------------------------------------------------------------ */
/*  Queue / poll                                                       */
/* ------------------------------------------------------------------ */

static size_t round_up_pow2(size_t v) {
    if (v <= 1) return 1;
    size_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

zps_status_t zenoh_pubsub_subscribe_queue(ZenohPubSub *ps,
                                          uint32_t token,
                                          size_t queue_depth,
                                          ZenohPubSubSub **out) {
    if (!ps || !out) return ZPS_ERR_INVALID_ARG;
    if (!ps->connected) return ZPS_ERR_NOT_CONNECTED;

    char keystr[32];
    token_to_keyexpr(token, keystr, sizeof(keystr));

    z_view_keyexpr_t ke;
    if (z_view_keyexpr_from_str(&ke, keystr) < 0) return ZPS_ERR_INVALID_ARG;

    size_t depth = round_up_pow2(queue_depth == 0 ? 64 : queue_depth);

    ZenohPubSubSub *sub = calloc(1, sizeof(*sub));
    if (!sub) return ZPS_ERR_MEMORY;

    queue_adapter_t *q = calloc(1, sizeof(*q));
    if (!q) { free(sub); return ZPS_ERR_MEMORY; }
    q->kind  = ADAPTER_QUEUE;
    q->token = token;
    q->ring  = calloc(depth, sizeof(queue_msg_t));
    if (!q->ring) { free(q); free(sub); return ZPS_ERR_MEMORY; }
    q->depth = depth;
    q->mask  = depth - 1;
    pthread_mutex_init(&q->lock, NULL);

    z_owned_closure_sample_t closure;
    z_closure(&closure, sample_handler, sample_dropper, q);
    sub->adapter = (sub_adapter_base_t *)q;

    if (z_declare_subscriber(z_loan(ps->session),
                             &sub->z_sub,
                             z_loan(ke),
                             z_move(closure),
                             NULL) < 0) {
        free(sub);
        return ZPS_ERR_ZENOH;
    }
    *out = sub;
    return ZPS_OK;
}

zps_status_t zenoh_pubsub_poll(ZenohPubSubSub *sub,
                               uint32_t *out_token,
                               uint8_t **out_payload,
                               size_t *out_len) {
    if (!sub || !out_payload || !out_len) return ZPS_ERR_INVALID_ARG;
    if (!sub->adapter || sub->adapter->kind != ADAPTER_QUEUE) return ZPS_ERR_INVALID_ARG;
    queue_adapter_t *q = (queue_adapter_t *)sub->adapter;

    pthread_mutex_lock(&q->lock);
    if (q->head == q->tail) {
        pthread_mutex_unlock(&q->lock);
        *out_payload = NULL;
        *out_len     = 0;
        if (out_token) *out_token = 0;
        return ZPS_EMPTY;
    }
    queue_msg_t *slot = &q->ring[q->tail & q->mask];
    if (out_token) *out_token = slot->token;
    *out_payload = slot->data;        /* transfer ownership to caller */
    *out_len     = slot->len;
    slot->data = NULL;
    slot->len  = 0;
    q->tail++;
    pthread_mutex_unlock(&q->lock);
    return ZPS_OK;
}

size_t zenoh_pubsub_pending(ZenohPubSubSub *sub) {
    if (!sub || !sub->adapter || sub->adapter->kind != ADAPTER_QUEUE) return 0;
    queue_adapter_t *q = (queue_adapter_t *)sub->adapter;
    pthread_mutex_lock(&q->lock);
    size_t n = q->head - q->tail;
    pthread_mutex_unlock(&q->lock);
    return n;
}

size_t zenoh_pubsub_dropped(ZenohPubSubSub *sub) {
    if (!sub || !sub->adapter || sub->adapter->kind != ADAPTER_QUEUE) return 0;
    queue_adapter_t *q = (queue_adapter_t *)sub->adapter;
    pthread_mutex_lock(&q->lock);
    size_t n = q->dropped;
    pthread_mutex_unlock(&q->lock);
    return n;
}

void zenoh_pubsub_reset_dropped(ZenohPubSubSub *sub) {
    if (!sub || !sub->adapter || sub->adapter->kind != ADAPTER_QUEUE) return;
    queue_adapter_t *q = (queue_adapter_t *)sub->adapter;
    pthread_mutex_lock(&q->lock);
    q->dropped = 0;
    pthread_mutex_unlock(&q->lock);
}

zps_status_t zenoh_pubsub_unsubscribe(ZenohPubSub *ps, ZenohPubSubSub *sub) {
    if (!ps || !sub) return ZPS_ERR_INVALID_ARG;
    z_drop(z_move(sub->z_sub));   /* sample_dropper fires here, freeing adapter */
    free(sub);
    return ZPS_OK;
}
