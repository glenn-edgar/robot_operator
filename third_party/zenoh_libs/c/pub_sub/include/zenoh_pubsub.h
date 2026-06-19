/**
 * @file zenoh_pubsub.h
 * @brief Zenoh publish/subscribe library — C API
 *
 * Thin C wrapper over zenoh-pico's publisher/subscriber primitives.
 *
 * Transports: TCP, UDP, Serial SLIP, Unix domain socket — selected at
 * session-open time via the locator string.
 *
 * Topics are uint32_t FNV1a tokens from zenoh_token; the wire keyexpr is
 * the hex form of the token (e.g., "tok/cafebabe") so it remains compact
 * and human-readable in trace tools.
 *
 * Typical usage:
 *
 *   ZenohPubSub *ps;
 *   ZenohPubSubConfig cfg;
 *   zenoh_pubsub_config_defaults(&cfg);
 *   cfg.locators = (const char *[]){ "udp/127.0.0.1:7447" };
 *   cfg.n_locators = 1;
 *
 *   zenoh_pubsub_create(&ps, &cfg);
 *   zenoh_pubsub_connect(ps);
 *
 *   ZenohPubSubSub *sub;
 *   zenoh_pubsub_subscribe(ps, zt_hash("sensor/temp"), my_callback, ctx, &sub);
 *
 *   zenoh_pubsub_publish(ps, zt_hash("sensor/temp"), payload, len);
 *
 *   zenoh_pubsub_unsubscribe(ps, sub);
 *   zenoh_pubsub_disconnect(ps);
 *   zenoh_pubsub_destroy(ps);
 */

#ifndef ZENOH_PUBSUB_H
#define ZENOH_PUBSUB_H

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
    ZPS_OK = 0,
    ZPS_ERR_INVALID_ARG,
    ZPS_ERR_CONNECTION,
    ZPS_ERR_TIMEOUT,
    ZPS_ERR_MEMORY,
    ZPS_ERR_NOT_CONNECTED,
    ZPS_ERR_ZENOH,            /**< Generic zenoh-pico error             */
    ZPS_EMPTY,                /**< zenoh_pubsub_poll: queue empty       */
} zps_status_t;

const char *zps_status_str(zps_status_t st);

/* ------------------------------------------------------------------ */
/*  Configuration                                                      */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *const *locators;     /**< Connect locators, e.g. {"udp/host:7447"} */
    size_t             n_locators;   /**< Number of entries in locators            */

    /**
     * Listen locators (optional). Mainly used for peer-mode topologies,
     * notably serial (point-to-point) where one side must listen on its
     * local TTY for the other side to connect.
     */
    const char *const *listen_locators;
    size_t             n_listen;

    const char        *mode;         /**< "client" (default) or "peer"             */
    bool               enable_scout; /**< Default false (fixed-set commissioning) */
    const char        *client_name;  /**< Optional, used in zenoh logs              */
} ZenohPubSubConfig;

void zenoh_pubsub_config_defaults(ZenohPubSubConfig *cfg);

/* ------------------------------------------------------------------ */
/*  Handles (opaque)                                                   */
/* ------------------------------------------------------------------ */

typedef struct ZenohPubSub    ZenohPubSub;
typedef struct ZenohPubSubSub ZenohPubSubSub;

/**
 * Subscriber callback.
 *
 * @param token   Token of the matching topic.
 * @param payload Borrowed pointer to message bytes — do NOT free.
 * @param len     Length of payload.
 * @param ctx     Opaque pointer registered alongside the subscriber.
 *
 * Note: callback runs on zenoh-pico's internal read thread. Caller is
 * responsible for any thread-safety in shared state mutation.
 */
typedef void (*zenoh_pubsub_callback_t)(uint32_t token,
                                        const uint8_t *payload,
                                        size_t len,
                                        void *ctx);

/* ------------------------------------------------------------------ */
/*  Lifecycle                                                          */
/* ------------------------------------------------------------------ */

zps_status_t zenoh_pubsub_create(ZenohPubSub **out, const ZenohPubSubConfig *cfg);
void         zenoh_pubsub_destroy(ZenohPubSub *ps);

zps_status_t zenoh_pubsub_connect(ZenohPubSub *ps);
zps_status_t zenoh_pubsub_disconnect(ZenohPubSub *ps);

/* ------------------------------------------------------------------ */
/*  Publish / subscribe                                                */
/* ------------------------------------------------------------------ */

zps_status_t zenoh_pubsub_publish(ZenohPubSub *ps,
                                  uint32_t token,
                                  const uint8_t *payload,
                                  size_t len);

zps_status_t zenoh_pubsub_subscribe(ZenohPubSub *ps,
                                    uint32_t token,
                                    zenoh_pubsub_callback_t cb,
                                    void *ctx,
                                    ZenohPubSubSub **out);

zps_status_t zenoh_pubsub_unsubscribe(ZenohPubSub *ps, ZenohPubSubSub *sub);

/* ------------------------------------------------------------------ */
/*  Queue/poll subscribe — safe for LuaJIT and other no-cross-thread- */
/*  callback hosts.                                                    */
/*                                                                     */
/*  The subscriber pushes incoming messages onto an internal           */
/*  thread-safe ring buffer; the caller drains them with               */
/*  zenoh_pubsub_poll() from any thread (typically the main loop).     */
/*  When the queue overflows, oldest messages are dropped silently —   */
/*  use a queue_depth large enough for your worst-case burst.          */
/* ------------------------------------------------------------------ */

/**
 * Subscribe with a queue-backed delivery model (no callback).
 *
 * @param ps           Connected session.
 * @param token        FNV1a topic token to subscribe to.
 * @param queue_depth  Max number of pending messages (rounded up to power of 2).
 *                     0 = use default (64).
 * @param[out] out_sub Subscriber handle.
 */
zps_status_t zenoh_pubsub_subscribe_queue(ZenohPubSub *ps,
                                          uint32_t token,
                                          size_t queue_depth,
                                          ZenohPubSubSub **out_sub);

/**
 * Drain one message from a queue subscriber, non-blocking.
 *
 * On success, *out_payload is a malloc'd buffer the caller must free().
 *
 * @param sub          Queue subscriber.
 * @param[out] out_token    Token of received message.
 * @param[out] out_payload  Malloc'd payload bytes (caller frees).
 * @param[out] out_len      Payload length.
 * @return ZPS_OK on success, ZPS_EMPTY if queue is empty,
 *         ZPS_ERR_INVALID_ARG on bad args.
 */
zps_status_t zenoh_pubsub_poll(ZenohPubSubSub *sub,
                               uint32_t *out_token,
                               uint8_t **out_payload,
                               size_t *out_len);

/**
 * Return current queue depth (number of pending unread messages).
 * Useful for diagnostics and back-pressure decisions.
 */
size_t zenoh_pubsub_pending(ZenohPubSubSub *sub);

/**
 * Return count of messages that were dropped due to queue overflow,
 * since creation. Reset to 0 by zenoh_pubsub_reset_dropped().
 */
size_t zenoh_pubsub_dropped(ZenohPubSubSub *sub);
void   zenoh_pubsub_reset_dropped(ZenohPubSubSub *sub);

#ifdef __cplusplus
}
#endif

#endif /* ZENOH_PUBSUB_H */
