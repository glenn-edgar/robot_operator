/**
 * @file zenoh_rpc.c
 * @brief zenoh-pico-backed request/response RPC wrapper.
 *
 * Server side wraps z_declare_queryable; handler is invoked from the
 * zenoh-pico read thread when a query arrives, and its returned payload
 * is sent back via z_query_reply.
 *
 * Client side wraps z_get; the reply closure stores the first reply and
 * signals a pthread_cond; the call blocks on pthread_cond_timedwait with
 * the caller-provided timeout.
 */

#define _POSIX_C_SOURCE 200809L

#include "zenoh_rpc.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <zenoh-pico.h>

/* ------------------------------------------------------------------ */
/*  Status                                                             */
/* ------------------------------------------------------------------ */

const char *zrpc_status_str(zrpc_status_t st) {
    switch (st) {
        case ZRPC_OK:                return "OK";
        case ZRPC_ERR_INVALID_ARG:   return "invalid argument";
        case ZRPC_ERR_CONNECTION:    return "connection error";
        case ZRPC_ERR_TIMEOUT:       return "timeout";
        case ZRPC_ERR_MEMORY:        return "out of memory";
        case ZRPC_ERR_NOT_CONNECTED: return "not connected";
        case ZRPC_ERR_NO_REPLY:      return "no reply received";
        case ZRPC_ERR_HANDLER:       return "handler error";
        case ZRPC_ERR_ZENOH:         return "zenoh-pico error";
    }
    return "unknown";
}

void zenoh_rpc_config_defaults(ZenohRpcConfig *cfg) {
    if (!cfg) return;
    cfg->locators     = NULL;
    cfg->n_locators   = 0;
    cfg->mode         = "client";
    cfg->enable_scout = false;
    cfg->client_name  = NULL;
}

/* ------------------------------------------------------------------ */
/*  Helpers                                                            */
/* ------------------------------------------------------------------ */

static void token_to_keyexpr(uint32_t token, char *buf, size_t n) {
    snprintf(buf, n, "tok/%08x", token);
}

static z_result_t open_session_from_cfg(z_owned_session_t *s, const ZenohRpcConfig *cfg) {
    z_owned_config_t zcfg;
    z_config_default(&zcfg);
    zp_config_insert(z_loan_mut(zcfg), Z_CONFIG_MODE_KEY, cfg->mode);
    for (size_t i = 0; i < cfg->n_locators; ++i) {
        zp_config_insert(z_loan_mut(zcfg), Z_CONFIG_CONNECT_KEY, cfg->locators[i]);
    }
    return z_open(s, z_move(zcfg), NULL);
}

/* ------------------------------------------------------------------ */
/*  Server                                                             */
/* ------------------------------------------------------------------ */

typedef enum { HENTRY_CALLBACK = 0, HENTRY_QUEUE = 1 } hentry_kind_t;

typedef struct handler_entry {
    hentry_kind_t             kind;        /* CALLBACK or QUEUE */
    uint32_t                  token;
    /* Callback-mode fields */
    zenoh_rpc_handler_t       fn;
    void                     *ctx;
    /* Common: queryable handle */
    z_owned_queryable_t       z_qable;
    int                       declared;
    /* Queue-mode pointer (NULL if callback mode) */
    struct ZenohRpcServerQueue *queue;
    struct handler_entry     *next;
} handler_entry_t;

struct ZenohRpcServer {
    ZenohRpcConfig    cfg_copy;
    int               running;
    pthread_mutex_t   lock;
    z_owned_session_t session;
    handler_entry_t  *handlers;
};

struct ZenohRpcRequest {
    uint32_t        token;
    uint8_t        *payload;       /* owned malloc'd copy */
    size_t          payload_len;
    z_owned_query_t z_query;       /* kept alive past the callback */
    int             replied;       /* 1 = reply/drop already happened */
};

struct ZenohRpcServerQueue {
    uint32_t              token;
    handler_entry_t      *owner_entry;     /* back-pointer */
    pthread_mutex_t       lock;
    ZenohRpcRequest     **ring;            /* depth pointers */
    size_t                depth;           /* power of two */
    size_t                mask;
    size_t                head;
    size_t                tail;
    size_t                dropped;
};

/* Extract request payload bytes into a freshly malloc'd buffer.
 * Returns 0 on success; *out_data may be NULL with *out_len == 0 for empty body. */
static int copy_query_payload(z_loaned_query_t *query, uint8_t **out_data, size_t *out_len) {
    const z_loaned_bytes_t *zreq = z_query_payload(query);
    z_owned_slice_t slice;
    if (z_bytes_to_slice(zreq, &slice) < 0) {
        *out_data = NULL; *out_len = 0;
        return -1;
    }
    size_t n = z_slice_len(z_loan(slice));
    if (n == 0) {
        z_drop(z_move(slice));
        *out_data = NULL; *out_len = 0;
        return 0;
    }
    uint8_t *buf = malloc(n);
    if (!buf) {
        z_drop(z_move(slice));
        *out_data = NULL; *out_len = 0;
        return -1;
    }
    memcpy(buf, z_slice_data(z_loan(slice)), n);
    z_drop(z_move(slice));
    *out_data = buf;
    *out_len  = n;
    return 0;
}

/* zenoh-pico query closure adapter — invoked on the read thread.
 * Branches on handler_entry's kind. */
static void server_query_cb(z_loaned_query_t *query, void *ctx) {
    handler_entry_t *h = (handler_entry_t *)ctx;
    if (!h) return;

    if (h->kind == HENTRY_CALLBACK) {
        if (!h->fn) return;
        uint8_t *req_data = NULL;
        size_t   req_len  = 0;
        copy_query_payload(query, &req_data, &req_len);

        uint8_t      *resp     = NULL;
        size_t        resp_len = 0;
        zrpc_status_t st       = h->fn(h->token, req_data, req_len, &resp, &resp_len, h->ctx);
        free(req_data);

        if (st == ZRPC_OK) {
            z_owned_bytes_t reply_body;
            z_bytes_copy_from_buf(&reply_body, resp ? resp : (const uint8_t *)"", resp_len);
            z_query_reply(query, z_query_keyexpr(query), z_move(reply_body), NULL);
            free(resp);
        } else {
            const char *errmsg = zrpc_status_str(st);
            z_owned_bytes_t err_body;
            z_bytes_copy_from_buf(&err_body, (const uint8_t *)errmsg, strlen(errmsg));
            z_query_reply_err(query, z_move(err_body), NULL);
            free(resp);
        }
        return;
    }

    /* Queue mode: take the loaned query into an owned ref, copy payload,
     * push onto the ring buffer. Reply happens later from the polling
     * thread via zenoh_rpc_request_reply(). */
    ZenohRpcServerQueue *q = h->queue;
    if (!q) return;

    ZenohRpcRequest *req = calloc(1, sizeof(*req));
    if (!req) return;
    req->token = h->token;
    if (copy_query_payload(query, &req->payload, &req->payload_len) < 0) {
        free(req);
        return;
    }
    /* Take owns the query so we can reply asynchronously. */
    if (z_query_take_from_loaned(&req->z_query, query) < 0) {
        free(req->payload);
        free(req);
        return;
    }

    pthread_mutex_lock(&q->lock);
    size_t used = q->head - q->tail;
    if (used >= q->depth) {
        /* Overflow: drop oldest (must reply-err so client doesn't hang). */
        ZenohRpcRequest *old = q->ring[q->tail & q->mask];
        q->tail++;
        q->dropped++;
        pthread_mutex_unlock(&q->lock);
        const char *m = "queue overflow";
        z_owned_bytes_t err_body;
        z_bytes_copy_from_buf(&err_body, (const uint8_t *)m, strlen(m));
        z_query_reply_err(z_loan_mut(old->z_query), z_move(err_body), NULL);
        z_drop(z_move(old->z_query));
        free(old->payload);
        free(old);
        pthread_mutex_lock(&q->lock);
    }
    q->ring[q->head & q->mask] = req;
    q->head++;
    pthread_mutex_unlock(&q->lock);
}

zrpc_status_t zenoh_rpc_server_create(ZenohRpcServer **out, const ZenohRpcConfig *cfg) {
    if (!out || !cfg) return ZRPC_ERR_INVALID_ARG;
    if (cfg->n_locators == 0 || cfg->locators == NULL) return ZRPC_ERR_INVALID_ARG;
    ZenohRpcServer *srv = calloc(1, sizeof(*srv));
    if (!srv) return ZRPC_ERR_MEMORY;
    srv->cfg_copy = *cfg;
    pthread_mutex_init(&srv->lock, NULL);
    *out = srv;
    return ZRPC_OK;
}

void zenoh_rpc_server_destroy(ZenohRpcServer *srv) {
    if (!srv) return;
    if (srv->running) zenoh_rpc_server_stop(srv);
    pthread_mutex_lock(&srv->lock);
    handler_entry_t *h = srv->handlers;
    while (h) {
        handler_entry_t *next = h->next;
        if (h->kind == HENTRY_QUEUE && h->queue) {
            /* Drain any unprocessed requests (reply-err each one). */
            ZenohRpcServerQueue *q = h->queue;
            pthread_mutex_lock(&q->lock);
            while (q->tail != q->head) {
                ZenohRpcRequest *r = q->ring[q->tail & q->mask];
                q->ring[q->tail & q->mask] = NULL;
                q->tail++;
                if (r) {
                    pthread_mutex_unlock(&q->lock);
                    zenoh_rpc_request_drop(r);
                    pthread_mutex_lock(&q->lock);
                }
            }
            pthread_mutex_unlock(&q->lock);
            pthread_mutex_destroy(&q->lock);
            free(q->ring);
            free(q);
        }
        free(h);
        h = next;
    }
    pthread_mutex_unlock(&srv->lock);
    pthread_mutex_destroy(&srv->lock);
    free(srv);
}

zrpc_status_t zenoh_rpc_server_register(ZenohRpcServer *srv,
                                        uint32_t token,
                                        zenoh_rpc_handler_t handler,
                                        void *ctx) {
    if (!srv || !handler) return ZRPC_ERR_INVALID_ARG;

    handler_entry_t *h = calloc(1, sizeof(*h));
    if (!h) return ZRPC_ERR_MEMORY;
    h->kind  = HENTRY_CALLBACK;
    h->token = token;
    h->fn    = handler;
    h->ctx   = ctx;

    pthread_mutex_lock(&srv->lock);
    h->next = srv->handlers;
    srv->handlers = h;

    /* If we're already running, declare the queryable now; otherwise
     * declare it later in start(). */
    if (srv->running) {
        char keystr[32];
        token_to_keyexpr(token, keystr, sizeof(keystr));
        z_view_keyexpr_t ke;
        if (z_view_keyexpr_from_str(&ke, keystr) >= 0) {
            z_owned_closure_query_t closure;
            z_closure(&closure, server_query_cb, NULL, h);
            if (z_declare_queryable(z_loan(srv->session), &h->z_qable,
                                    z_loan(ke), z_move(closure), NULL) >= 0) {
                h->declared = 1;
            }
        }
    }
    pthread_mutex_unlock(&srv->lock);
    return ZRPC_OK;
}

zrpc_status_t zenoh_rpc_server_start(ZenohRpcServer *srv) {
    if (!srv) return ZRPC_ERR_INVALID_ARG;
    if (open_session_from_cfg(&srv->session, &srv->cfg_copy) < 0) {
        return ZRPC_ERR_CONNECTION;
    }
    pthread_mutex_lock(&srv->lock);
    srv->running = 1;

    /* Declare queryables for all already-registered handlers. */
    for (handler_entry_t *h = srv->handlers; h != NULL; h = h->next) {
        if (h->declared) continue;
        char keystr[32];
        token_to_keyexpr(h->token, keystr, sizeof(keystr));
        z_view_keyexpr_t ke;
        if (z_view_keyexpr_from_str(&ke, keystr) < 0) continue;
        z_owned_closure_query_t closure;
        z_closure(&closure, server_query_cb, NULL, h);
        if (z_declare_queryable(z_loan(srv->session), &h->z_qable,
                                z_loan(ke), z_move(closure), NULL) >= 0) {
            h->declared = 1;
        }
    }
    pthread_mutex_unlock(&srv->lock);
    return ZRPC_OK;
}

zrpc_status_t zenoh_rpc_server_stop(ZenohRpcServer *srv) {
    if (!srv) return ZRPC_ERR_INVALID_ARG;
    pthread_mutex_lock(&srv->lock);
    int was_running = srv->running;
    srv->running = 0;
    if (was_running) {
        for (handler_entry_t *h = srv->handlers; h != NULL; h = h->next) {
            if (h->declared) {
                z_drop(z_move(h->z_qable));
                h->declared = 0;
            }
        }
    }
    pthread_mutex_unlock(&srv->lock);
    if (was_running) z_drop(z_move(srv->session));
    return ZRPC_OK;
}

/* ------------------------------------------------------------------ */
/*  Queue + poll server-side API (LuaJIT-safe)                         */
/* ------------------------------------------------------------------ */

static size_t round_up_pow2(size_t v) {
    if (v <= 1) return 1;
    size_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

zrpc_status_t zenoh_rpc_server_register_queue(ZenohRpcServer *srv,
                                              uint32_t token,
                                              size_t queue_depth,
                                              ZenohRpcServerQueue **out_q) {
    if (!srv || !out_q) return ZRPC_ERR_INVALID_ARG;

    size_t depth = round_up_pow2(queue_depth == 0 ? 32 : queue_depth);

    handler_entry_t *h = calloc(1, sizeof(*h));
    if (!h) return ZRPC_ERR_MEMORY;

    ZenohRpcServerQueue *q = calloc(1, sizeof(*q));
    if (!q) { free(h); return ZRPC_ERR_MEMORY; }
    q->ring = calloc(depth, sizeof(ZenohRpcRequest *));
    if (!q->ring) { free(q); free(h); return ZRPC_ERR_MEMORY; }
    q->depth       = depth;
    q->mask        = depth - 1;
    q->token       = token;
    q->owner_entry = h;
    pthread_mutex_init(&q->lock, NULL);

    h->kind  = HENTRY_QUEUE;
    h->token = token;
    h->queue = q;

    pthread_mutex_lock(&srv->lock);
    h->next = srv->handlers;
    srv->handlers = h;

    if (srv->running) {
        char keystr[32];
        token_to_keyexpr(token, keystr, sizeof(keystr));
        z_view_keyexpr_t ke;
        if (z_view_keyexpr_from_str(&ke, keystr) >= 0) {
            z_owned_closure_query_t closure;
            z_closure(&closure, server_query_cb, NULL, h);
            if (z_declare_queryable(z_loan(srv->session), &h->z_qable,
                                    z_loan(ke), z_move(closure), NULL) >= 0) {
                h->declared = 1;
            }
        }
    }
    pthread_mutex_unlock(&srv->lock);

    *out_q = q;
    return ZRPC_OK;
}

zrpc_status_t zenoh_rpc_server_poll(ZenohRpcServerQueue *q,
                                    ZenohRpcRequest **out_req) {
    if (!q || !out_req) return ZRPC_ERR_INVALID_ARG;
    pthread_mutex_lock(&q->lock);
    if (q->head == q->tail) {
        pthread_mutex_unlock(&q->lock);
        *out_req = NULL;
        return ZRPC_ERR_NO_REPLY;     /* reused for "queue empty" */
    }
    ZenohRpcRequest *r = q->ring[q->tail & q->mask];
    q->ring[q->tail & q->mask] = NULL;
    q->tail++;
    pthread_mutex_unlock(&q->lock);
    *out_req = r;
    return ZRPC_OK;
}

size_t zenoh_rpc_server_pending(ZenohRpcServerQueue *q) {
    if (!q) return 0;
    pthread_mutex_lock(&q->lock);
    size_t n = q->head - q->tail;
    pthread_mutex_unlock(&q->lock);
    return n;
}

size_t zenoh_rpc_server_dropped(ZenohRpcServerQueue *q) {
    if (!q) return 0;
    pthread_mutex_lock(&q->lock);
    size_t n = q->dropped;
    pthread_mutex_unlock(&q->lock);
    return n;
}

/* ------------------------------------------------------------------ */
/*  Request accessors                                                  */
/* ------------------------------------------------------------------ */

uint32_t zenoh_rpc_request_token(const ZenohRpcRequest *req) {
    return req ? req->token : 0;
}

const uint8_t *zenoh_rpc_request_payload(const ZenohRpcRequest *req) {
    return req ? req->payload : NULL;
}

size_t zenoh_rpc_request_payload_len(const ZenohRpcRequest *req) {
    return req ? req->payload_len : 0;
}

zrpc_status_t zenoh_rpc_request_reply(ZenohRpcRequest *req,
                                      const uint8_t *payload,
                                      size_t len) {
    if (!req) return ZRPC_ERR_INVALID_ARG;
    if (req->replied) return ZRPC_ERR_INVALID_ARG;
    z_owned_bytes_t body;
    if (z_bytes_copy_from_buf(&body, payload ? payload : (const uint8_t *)"", len) < 0) {
        return ZRPC_ERR_MEMORY;
    }
    int rc = z_query_reply(z_loan(req->z_query),
                           z_query_keyexpr(z_loan(req->z_query)),
                           z_move(body), NULL);
    req->replied = 1;
    z_drop(z_move(req->z_query));
    free(req->payload);
    free(req);
    return rc < 0 ? ZRPC_ERR_ZENOH : ZRPC_OK;
}

zrpc_status_t zenoh_rpc_request_reply_error(ZenohRpcRequest *req,
                                            const char *errmsg) {
    if (!req) return ZRPC_ERR_INVALID_ARG;
    if (req->replied) return ZRPC_ERR_INVALID_ARG;
    const char *m = errmsg ? errmsg : "error";
    z_owned_bytes_t body;
    if (z_bytes_copy_from_buf(&body, (const uint8_t *)m, strlen(m)) < 0) {
        return ZRPC_ERR_MEMORY;
    }
    int rc = z_query_reply_err(z_loan(req->z_query), z_move(body), NULL);
    req->replied = 1;
    z_drop(z_move(req->z_query));
    free(req->payload);
    free(req);
    return rc < 0 ? ZRPC_ERR_ZENOH : ZRPC_OK;
}

void zenoh_rpc_request_drop(ZenohRpcRequest *req) {
    if (!req) return;
    if (!req->replied) {
        /* Best effort: reply_err so client doesn't hang on timeout. */
        z_owned_bytes_t body;
        const char *m = "dropped";
        if (z_bytes_copy_from_buf(&body, (const uint8_t *)m, strlen(m)) == 0) {
            z_query_reply_err(z_loan(req->z_query), z_move(body), NULL);
        }
    }
    z_drop(z_move(req->z_query));
    free(req->payload);
    free(req);
}

/* ------------------------------------------------------------------ */
/*  Client                                                             */
/* ------------------------------------------------------------------ */

struct ZenohRpcClient {
    ZenohRpcConfig    cfg_copy;
    int               connected;
    pthread_mutex_t   lock;
    z_owned_session_t session;
};

/* Per-call reply collector — heap-allocated so it survives the call
 * frame across the timedwait deadline path.
 *
 * Refcounted because the closure context (passed to z_get) is owned
 * jointly by:
 *   - the caller (zenoh_rpc_client_call), which releases at return
 *   - the closure itself, which is released by client_reply_dropper
 *     when zenoh-pico finalizes the query (on the read thread)
 *
 * Whichever release runs last calls collector_free. This eliminates
 * the use-after-free where _call returned and freed the collector
 * BEFORE the read thread fired the dropper (or, in the timeout path,
 * before any late reply arrived). The refcount itself is guarded by
 * its own mutex (collector_refcount_lock) — independent of the
 * collector's data lock — so a refcount release does not need to
 * acquire the data lock and we cannot deadlock against the dropper
 * which always holds the data lock briefly. */
typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t  cond;
    pthread_mutex_t refcount_lock;
    int             refcount;
    int             reply_seen;
    int             final_seen;
    int             is_err;
    uint8_t        *payload;
    size_t          payload_len;
} reply_collector_t;

static reply_collector_t *collector_new(void) {
    reply_collector_t *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->cond, NULL);
    pthread_mutex_init(&c->refcount_lock, NULL);
    c->refcount = 2;            /* one for caller, one for closure */
    return c;
}

static void collector_free(reply_collector_t *c) {
    if (!c) return;
    pthread_cond_destroy(&c->cond);
    pthread_mutex_destroy(&c->lock);
    pthread_mutex_destroy(&c->refcount_lock);
    free(c->payload);
    free(c);
}

/* Drop one reference. Frees the collector if this was the last one. */
static void collector_release(reply_collector_t *c) {
    if (!c) return;
    pthread_mutex_lock(&c->refcount_lock);
    int gone = (--c->refcount == 0);
    pthread_mutex_unlock(&c->refcount_lock);
    if (gone) collector_free(c);
}

static void client_reply_cb(z_loaned_reply_t *reply, void *ctx) {
    reply_collector_t *c = (reply_collector_t *)ctx;
    pthread_mutex_lock(&c->lock);
    /* Only capture the first reply (matches synchronous _call() semantics). */
    if (!c->reply_seen) {
        if (z_reply_is_ok(reply)) {
            const z_loaned_sample_t *sample = z_reply_ok(reply);
            const z_loaned_bytes_t  *bytes  = z_sample_payload(sample);
            z_owned_slice_t slice;
            if (z_bytes_to_slice(bytes, &slice) >= 0) {
                size_t n = z_slice_len(z_loan(slice));
                c->payload     = malloc(n);
                if (c->payload) {
                    memcpy(c->payload, z_slice_data(z_loan(slice)), n);
                    c->payload_len = n;
                }
                z_drop(z_move(slice));
            }
            c->is_err = 0;
        } else {
            const z_loaned_reply_err_t *err   = z_reply_err(reply);
            const z_loaned_bytes_t     *bytes = z_reply_err_payload(err);
            z_owned_slice_t slice;
            if (z_bytes_to_slice(bytes, &slice) >= 0) {
                size_t n = z_slice_len(z_loan(slice));
                c->payload     = malloc(n);
                if (c->payload) {
                    memcpy(c->payload, z_slice_data(z_loan(slice)), n);
                    c->payload_len = n;
                }
                z_drop(z_move(slice));
            }
            c->is_err = 1;
        }
        c->reply_seen = 1;
        pthread_cond_broadcast(&c->cond);
    }
    pthread_mutex_unlock(&c->lock);
}

static void client_reply_dropper(void *ctx) {
    reply_collector_t *c = (reply_collector_t *)ctx;
    pthread_mutex_lock(&c->lock);
    c->final_seen = 1;
    pthread_cond_broadcast(&c->cond);
    pthread_mutex_unlock(&c->lock);
    /* Release the closure's reference. If _call has already returned and
     * released its reference, this frees the collector here. Otherwise
     * _call's later release will be the one that frees. Either way, the
     * collector lives until both sides are done with it — no UAF on the
     * read thread. */
    collector_release(c);
}

zrpc_status_t zenoh_rpc_client_create(ZenohRpcClient **out, const ZenohRpcConfig *cfg) {
    if (!out || !cfg) return ZRPC_ERR_INVALID_ARG;
    if (cfg->n_locators == 0 || cfg->locators == NULL) return ZRPC_ERR_INVALID_ARG;
    ZenohRpcClient *cli = calloc(1, sizeof(*cli));
    if (!cli) return ZRPC_ERR_MEMORY;
    cli->cfg_copy = *cfg;
    pthread_mutex_init(&cli->lock, NULL);
    *out = cli;
    return ZRPC_OK;
}

void zenoh_rpc_client_destroy(ZenohRpcClient *cli) {
    if (!cli) return;
    if (cli->connected) zenoh_rpc_client_disconnect(cli);
    pthread_mutex_destroy(&cli->lock);
    free(cli);
}

zrpc_status_t zenoh_rpc_client_connect(ZenohRpcClient *cli) {
    if (!cli) return ZRPC_ERR_INVALID_ARG;
    if (open_session_from_cfg(&cli->session, &cli->cfg_copy) < 0) {
        return ZRPC_ERR_CONNECTION;
    }
    pthread_mutex_lock(&cli->lock);
    cli->connected = 1;
    pthread_mutex_unlock(&cli->lock);
    return ZRPC_OK;
}

zrpc_status_t zenoh_rpc_client_disconnect(ZenohRpcClient *cli) {
    if (!cli) return ZRPC_ERR_INVALID_ARG;
    pthread_mutex_lock(&cli->lock);
    int was_connected = cli->connected;
    cli->connected = 0;
    pthread_mutex_unlock(&cli->lock);
    if (was_connected) z_drop(z_move(cli->session));
    return ZRPC_OK;
}

zrpc_status_t zenoh_rpc_client_call(ZenohRpcClient *cli,
                                    uint32_t token,
                                    const uint8_t *req,
                                    size_t req_len,
                                    uint32_t timeout_ms,
                                    uint8_t **resp,
                                    size_t *resp_len) {
    if (!cli || !resp || !resp_len) return ZRPC_ERR_INVALID_ARG;
    if (req_len > 0 && req == NULL) return ZRPC_ERR_INVALID_ARG;
    if (!cli->connected) return ZRPC_ERR_NOT_CONNECTED;

    char keystr[32];
    token_to_keyexpr(token, keystr, sizeof(keystr));

    z_view_keyexpr_t ke;
    if (z_view_keyexpr_from_str(&ke, keystr) < 0) return ZRPC_ERR_INVALID_ARG;

    reply_collector_t *col = collector_new();
    if (!col) return ZRPC_ERR_MEMORY;

    z_get_options_t opts;
    z_get_options_default(&opts);
    if (timeout_ms > 0) opts.timeout_ms = timeout_ms;

    z_owned_bytes_t reqbody;
    if (req_len > 0) {
        if (z_bytes_copy_from_buf(&reqbody, req, req_len) < 0) {
            /* Closure never installed — no read-thread reference exists.
             * Drop both references (init was 2) before freeing. */
            collector_release(col);
            collector_release(col);
            return ZRPC_ERR_MEMORY;
        }
        opts.payload = z_move(reqbody);
    }

    z_owned_closure_reply_t closure;
    z_closure(&closure, client_reply_cb, client_reply_dropper, col);
    if (z_get(z_loan(cli->session), z_loan(ke), "", z_move(closure), &opts) < 0) {
        /* z_get failed: did it consume the closure? zenoh-pico's contract
         * is ambiguous here — but on failure the dropper should NOT have
         * been invoked. Release both refs (caller's + the closure ref
         * that nobody will release) to avoid leaking. If a future
         * zenoh-pico version DOES drop the closure on failure, we'd
         * under-free by one ref; that's a leak, not a UAF, and we'd
         * catch it under ASan's leak detector. */
        collector_release(col);
        collector_release(col);
        return ZRPC_ERR_ZENOH;
    }

    /* Wait for first reply or final marker, with the timeout deadline. */
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec  += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_nsec -= 1000000000L;
        deadline.tv_sec  += 1;
    }

    pthread_mutex_lock(&col->lock);
    while (!col->reply_seen && !col->final_seen) {
        int rc = pthread_cond_timedwait(&col->cond, &col->lock, &deadline);
        if (rc == ETIMEDOUT) {
            pthread_mutex_unlock(&col->lock);
            /* Caller releases its ref. The closure still holds the other
             * ref; the dropper releases it whenever zenoh-pico finalizes
             * the (still pending) query, possibly long after we return.
             * That late release frees the collector — safe now. */
            collector_release(col);
            return ZRPC_ERR_TIMEOUT;
        }
    }

    zrpc_status_t result;
    if (col->reply_seen) {
        if (col->is_err) {
            result = ZRPC_ERR_HANDLER;
            *resp     = col->payload;   /* hand error message to caller */
            *resp_len = col->payload_len;
            col->payload = NULL;        /* prevent free in collector_free */
        } else {
            result = ZRPC_OK;
            *resp     = col->payload;
            *resp_len = col->payload_len;
            col->payload = NULL;
        }
    } else {
        result    = ZRPC_ERR_NO_REPLY;
        *resp     = NULL;
        *resp_len = 0;
    }
    pthread_mutex_unlock(&col->lock);

    collector_release(col);
    return result;
}
