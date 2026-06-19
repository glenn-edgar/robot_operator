/**
 * @file zenoh_rpc.h
 * @brief Zenoh request/response RPC library — C API
 *
 * Thin C wrapper over zenoh-pico's get/queryable primitives.
 *
 *   Client side: z_get(keyexpr, payload) → one or more replies → final marker
 *   Server side: z_declare_queryable + handler that produces a reply
 *
 * Topics (method names) are FNV1a-32 tokens from zenoh_token; wire keyexpr is
 * the hex form (e.g. "tok/cafebabe").
 *
 * Transports: TCP, UDP, Serial SLIP, Unix domain socket — same as pub_sub.
 *
 * Typical usage — server side:
 *
 *   ZenohRpcServer *srv;
 *   zenoh_rpc_server_create(&srv, &cfg);
 *   zenoh_rpc_server_register(srv, zt_hash("math.add"), add_handler, NULL);
 *   zenoh_rpc_server_start(srv);
 *
 * Typical usage — client side:
 *
 *   ZenohRpcClient *cli;
 *   zenoh_rpc_client_create(&cli, &cfg);
 *   zenoh_rpc_client_connect(cli);
 *
 *   uint8_t *reply = NULL;
 *   size_t reply_len = 0;
 *   zenoh_rpc_client_call(cli, zt_hash("math.add"),
 *                         payload, payload_len,
 *                         5000,        // timeout ms
 *                         &reply, &reply_len);
 *   free(reply);
 */

#ifndef ZENOH_RPC_H
#define ZENOH_RPC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/*  Status codes                                                       */
/* ------------------------------------------------------------------ */

typedef enum {
    ZRPC_OK = 0,
    ZRPC_ERR_INVALID_ARG,
    ZRPC_ERR_CONNECTION,
    ZRPC_ERR_TIMEOUT,
    ZRPC_ERR_MEMORY,
    ZRPC_ERR_NOT_CONNECTED,
    ZRPC_ERR_NO_REPLY,         /**< get returned no replies */
    ZRPC_ERR_HANDLER,          /**< handler signalled error */
    ZRPC_ERR_ZENOH,            /**< generic zenoh-pico error */
} zrpc_status_t;

const char *zrpc_status_str(zrpc_status_t st);

/* ------------------------------------------------------------------ */
/*  Configuration                                                      */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *const *locators;     /**< Connect locators                          */
    size_t             n_locators;   /**< Number of entries in locators             */
    const char        *mode;         /**< "client" (default) or "peer"              */
    bool               enable_scout; /**< Default false                              */
    const char        *client_name;  /**< Optional logging name                      */
} ZenohRpcConfig;

void zenoh_rpc_config_defaults(ZenohRpcConfig *cfg);

/* ------------------------------------------------------------------ */
/*  Handler signature (server side)                                    */
/* ------------------------------------------------------------------ */

/**
 * RPC handler.
 *
 * @param token       Token of the method being called.
 * @param req         Borrowed request payload — do NOT free.
 * @param req_len     Length of req.
 * @param resp        OUT: handler must malloc a buffer and store its pointer here.
 *                    Library will free() it after sending the reply.
 * @param resp_len    OUT: length of *resp.
 * @param ctx         Opaque pointer registered alongside the handler.
 * @return            ZRPC_OK on success, ZRPC_ERR_HANDLER on application error.
 *
 * Note: handler runs on zenoh-pico's internal read thread.
 */
typedef zrpc_status_t (*zenoh_rpc_handler_t)(uint32_t token,
                                             const uint8_t *req,
                                             size_t req_len,
                                             uint8_t **resp,
                                             size_t *resp_len,
                                             void *ctx);

/* ------------------------------------------------------------------ */
/*  Server                                                             */
/* ------------------------------------------------------------------ */

typedef struct ZenohRpcServer ZenohRpcServer;

zrpc_status_t zenoh_rpc_server_create(ZenohRpcServer **out, const ZenohRpcConfig *cfg);
void          zenoh_rpc_server_destroy(ZenohRpcServer *srv);

zrpc_status_t zenoh_rpc_server_register(ZenohRpcServer *srv,
                                        uint32_t token,
                                        zenoh_rpc_handler_t handler,
                                        void *ctx);

zrpc_status_t zenoh_rpc_server_start(ZenohRpcServer *srv);
zrpc_status_t zenoh_rpc_server_stop(ZenohRpcServer *srv);

/* ------------------------------------------------------------------ */
/*  Client                                                             */
/* ------------------------------------------------------------------ */

typedef struct ZenohRpcClient ZenohRpcClient;

zrpc_status_t zenoh_rpc_client_create(ZenohRpcClient **out, const ZenohRpcConfig *cfg);
void          zenoh_rpc_client_destroy(ZenohRpcClient *cli);

zrpc_status_t zenoh_rpc_client_connect(ZenohRpcClient *cli);
zrpc_status_t zenoh_rpc_client_disconnect(ZenohRpcClient *cli);

/**
 * Synchronous RPC call.
 *
 * @param cli         Connected client.
 * @param token       Method token.
 * @param req         Request payload (may be NULL if req_len == 0).
 * @param req_len     Request length.
 * @param timeout_ms  How long to wait for a reply.
 * @param resp        OUT: malloc'd reply payload. Caller must free.
 * @param resp_len    OUT: reply length.
 * @return            ZRPC_OK on success, ZRPC_ERR_TIMEOUT if no reply in time.
 */
zrpc_status_t zenoh_rpc_client_call(ZenohRpcClient *cli,
                                    uint32_t token,
                                    const uint8_t *req,
                                    size_t req_len,
                                    uint32_t timeout_ms,
                                    uint8_t **resp,
                                    size_t *resp_len);

/* ------------------------------------------------------------------ */
/*  Server-side queue+poll API — safe for LuaJIT and any host that    */
/*  can't tolerate Lua-callbacks-on-foreign-threads.                  */
/*                                                                     */
/*  Flow:                                                              */
/*    register_queue(srv, token, depth, &q)                            */
/*    loop:                                                            */
/*      poll(q, &request)                                              */
/*      ... process request->payload ...                               */
/*      request_reply(request, response_payload, len)                  */
/*      // request is dropped after reply                              */
/* ------------------------------------------------------------------ */

typedef struct ZenohRpcServerQueue ZenohRpcServerQueue;
typedef struct ZenohRpcRequest     ZenohRpcRequest;

/**
 * Register a queue-backed queryable for a method token. Pushes incoming
 * queries to an internal ring buffer; drain with zenoh_rpc_server_poll.
 *
 * If the server is already running, the queryable is declared immediately.
 * Otherwise it is declared on zenoh_rpc_server_start.
 *
 * @param queue_depth  Power-of-2-rounded ring size; 0 = default 32.
 */
zrpc_status_t zenoh_rpc_server_register_queue(ZenohRpcServer *srv,
                                              uint32_t token,
                                              size_t queue_depth,
                                              ZenohRpcServerQueue **out_q);

/**
 * Drain one request from a queue, non-blocking.
 *
 * On success, *out_req owns the request; caller MUST eventually call
 * zenoh_rpc_request_reply (or zenoh_rpc_request_drop) to release it.
 *
 * @return ZRPC_OK on success, ZRPC_ERR_NO_REPLY if queue is empty.
 */
zrpc_status_t zenoh_rpc_server_poll(ZenohRpcServerQueue *q,
                                    ZenohRpcRequest **out_req);

/** Number of pending unhandled requests in the queue. */
size_t zenoh_rpc_server_pending(ZenohRpcServerQueue *q);

/** Number of requests dropped due to queue overflow since creation. */
size_t zenoh_rpc_server_dropped(ZenohRpcServerQueue *q);

/* ----- Request accessors ----- */
uint32_t       zenoh_rpc_request_token(const ZenohRpcRequest *req);
const uint8_t *zenoh_rpc_request_payload(const ZenohRpcRequest *req);
size_t         zenoh_rpc_request_payload_len(const ZenohRpcRequest *req);

/**
 * Send a successful reply for the request. Frees the request.
 * After this call, req is invalid.
 */
zrpc_status_t zenoh_rpc_request_reply(ZenohRpcRequest *req,
                                      const uint8_t *payload,
                                      size_t len);

/**
 * Send an error reply for the request. Frees the request.
 */
zrpc_status_t zenoh_rpc_request_reply_error(ZenohRpcRequest *req,
                                            const char *errmsg);

/**
 * Drop a request without replying (e.g., shutdown, malformed input).
 * Frees the request.
 */
void zenoh_rpc_request_drop(ZenohRpcRequest *req);

#ifdef __cplusplus
}
#endif

#endif /* ZENOH_RPC_H */
