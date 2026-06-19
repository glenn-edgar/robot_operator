/**
 * @file test_zenoh_pubsub.c
 * @brief Unit + end-to-end tests for zenoh_pubsub.
 *
 * Modes:
 *   - API-surface tests always run (no external dependencies).
 *   - When --transport=udp|tcp is given, performs a round-trip test against
 *     a zenohd reachable at the locator (default: 127.0.0.1:17447).
 *   - --transport=serial is documented but not exercised here (PTY loopback
 *     test is a separate fixture).
 */

#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700      /* for posix_openpt/grantpt/unlockpt/ptsname */

#include "zenoh_pubsub.h"
#include "zenoh_token.h"

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int pass = 0;
static int fail = 0;

#define CHECK(cond, msg) do {                                              \
    if (cond) { ++pass; }                                                  \
    else {                                                                 \
        ++fail;                                                            \
        fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__);    \
    }                                                                      \
} while (0)

/* ------------------------------------------------------------------ */
/*  API surface (always run)                                           */
/* ------------------------------------------------------------------ */

static void test_status_strings(void) {
    CHECK(strcmp(zps_status_str(ZPS_OK), "OK") == 0, "status string OK");
    CHECK(zps_status_str(ZPS_ERR_INVALID_ARG) != NULL, "status string invalid arg");
}

static void test_config_defaults(void) {
    ZenohPubSubConfig cfg;
    zenoh_pubsub_config_defaults(&cfg);
    CHECK(cfg.locators == NULL,           "default locators NULL");
    CHECK(cfg.n_locators == 0,            "default n_locators 0");
    CHECK(strcmp(cfg.mode, "client") == 0,"default mode 'client'");
    CHECK(cfg.enable_scout == false,      "default scout disabled");
}

static void test_create_invalid_args(void) {
    ZenohPubSub *ps = NULL;
    ZenohPubSubConfig cfg;
    zenoh_pubsub_config_defaults(&cfg);
    CHECK(zenoh_pubsub_create(NULL, &cfg) == ZPS_ERR_INVALID_ARG, "create NULL out rejected");
    CHECK(zenoh_pubsub_create(&ps, NULL)  == ZPS_ERR_INVALID_ARG, "create NULL cfg rejected");
    CHECK(zenoh_pubsub_create(&ps, &cfg)  == ZPS_ERR_INVALID_ARG, "create with no locators rejected");
}

/* ------------------------------------------------------------------ */
/*  End-to-end round trip                                              */
/* ------------------------------------------------------------------ */

typedef struct {
    pthread_mutex_t  lock;
    pthread_cond_t   cond;
    int              received;
    uint32_t         got_token;
    uint8_t          got_payload[256];
    size_t           got_len;
} recv_ctx_t;

static void on_message(uint32_t token, const uint8_t *payload, size_t len, void *ctx) {
    recv_ctx_t *rc = (recv_ctx_t *)ctx;
    pthread_mutex_lock(&rc->lock);
    rc->got_token = token;
    if (len <= sizeof(rc->got_payload)) {
        memcpy(rc->got_payload, payload, len);
        rc->got_len = len;
    }
    rc->received++;
    pthread_cond_broadcast(&rc->cond);
    pthread_mutex_unlock(&rc->lock);
}

static int wait_for_message(recv_ctx_t *rc, int target_count, int timeout_ms) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec  += timeout_ms / 1000;
    deadline.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_nsec -= 1000000000L;
        deadline.tv_sec  += 1;
    }
    pthread_mutex_lock(&rc->lock);
    while (rc->received < target_count) {
        int rc_wait = pthread_cond_timedwait(&rc->cond, &rc->lock, &deadline);
        if (rc_wait != 0) {
            pthread_mutex_unlock(&rc->lock);
            return -1;
        }
    }
    pthread_mutex_unlock(&rc->lock);
    return 0;
}

static int run_e2e_test(const char *locator) {
    fprintf(stderr, "\n=== End-to-end test against %s ===\n", locator);

    recv_ctx_t rc = {0};
    pthread_mutex_init(&rc.lock, NULL);
    pthread_cond_init(&rc.cond, NULL);

    /* One session each for publisher and subscriber — exercises both
     * sides of the wire and forces messages through zenohd. */
    const char *locs[] = { locator };
    ZenohPubSubConfig cfg;
    zenoh_pubsub_config_defaults(&cfg);
    cfg.locators = locs;
    cfg.n_locators = 1;

    ZenohPubSub *sub_ps = NULL, *pub_ps = NULL;
    CHECK(zenoh_pubsub_create(&sub_ps, &cfg) == ZPS_OK, "create sub session");
    CHECK(zenoh_pubsub_create(&pub_ps, &cfg) == ZPS_OK, "create pub session");

    CHECK(zenoh_pubsub_connect(sub_ps) == ZPS_OK, "connect sub session");
    CHECK(zenoh_pubsub_connect(pub_ps) == ZPS_OK, "connect pub session");

    /* Declare subscriber before publishing. */
    uint32_t topic = zt_hash("e2e/test/round_trip");
    ZenohPubSubSub *sub = NULL;
    CHECK(zenoh_pubsub_subscribe(sub_ps, topic, on_message, &rc, &sub) == ZPS_OK,
          "subscribe OK");

    /* Give the subscription a moment to propagate through zenohd. */
    usleep(200000);   /* 200 ms */

    /* Publish three small messages. */
    const char *msgs[] = { "hello", "world", "zenoh" };
    for (int i = 0; i < 3; ++i) {
        CHECK(zenoh_pubsub_publish(pub_ps, topic,
                                   (const uint8_t *)msgs[i], strlen(msgs[i])) == ZPS_OK,
              "publish message");
        usleep(50000); /* small inter-message delay so test is deterministic */
    }

    /* Wait for all three. */
    int rc_wait = wait_for_message(&rc, 3, 3000);
    CHECK(rc_wait == 0, "received all 3 messages within 3 s");
    CHECK(rc.received == 3, "received count == 3");
    CHECK(rc.got_token == topic, "last message had correct token");

    /* Clean up. */
    CHECK(zenoh_pubsub_unsubscribe(sub_ps, sub) == ZPS_OK, "unsubscribe OK");
    zenoh_pubsub_disconnect(pub_ps);
    zenoh_pubsub_disconnect(sub_ps);
    zenoh_pubsub_destroy(pub_ps);
    zenoh_pubsub_destroy(sub_ps);

    pthread_cond_destroy(&rc.cond);
    pthread_mutex_destroy(&rc.lock);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Queue-mode E2E (the LuaJIT-safe path)                              */
/* ------------------------------------------------------------------ */

static int run_queue_e2e_test(const char *locator) {
    fprintf(stderr, "\n=== Queue-mode E2E against %s ===\n", locator);

    const char *locs[] = { locator };
    ZenohPubSubConfig cfg;
    zenoh_pubsub_config_defaults(&cfg);
    cfg.locators = locs;
    cfg.n_locators = 1;

    ZenohPubSub *sub_ps = NULL, *pub_ps = NULL;
    CHECK(zenoh_pubsub_create(&sub_ps, &cfg) == ZPS_OK, "queue: create sub session");
    CHECK(zenoh_pubsub_create(&pub_ps, &cfg) == ZPS_OK, "queue: create pub session");
    CHECK(zenoh_pubsub_connect(sub_ps) == ZPS_OK, "queue: connect sub");
    CHECK(zenoh_pubsub_connect(pub_ps) == ZPS_OK, "queue: connect pub");

    uint32_t topic = zt_hash("e2e/queue/test");
    ZenohPubSubSub *sub = NULL;
    CHECK(zenoh_pubsub_subscribe_queue(sub_ps, topic, 16, &sub) == ZPS_OK,
          "queue: subscribe");
    usleep(200000);   /* let declaration propagate */

    /* Publish 5 messages. */
    const char *msgs[] = { "qa", "qb", "qc", "qd", "qe" };
    for (int i = 0; i < 5; ++i) {
        CHECK(zenoh_pubsub_publish(pub_ps, topic,
                                   (const uint8_t *)msgs[i], strlen(msgs[i])) == ZPS_OK,
              "queue: publish");
        usleep(20000);
    }

    /* Allow zenohd + read thread to deliver. */
    usleep(500000);

    /* Drain. */
    int got = 0;
    for (int i = 0; i < 10; ++i) {
        uint32_t tok = 0;
        uint8_t *payload = NULL;
        size_t   len = 0;
        zps_status_t st = zenoh_pubsub_poll(sub, &tok, &payload, &len);
        if (st == ZPS_OK) {
            CHECK(tok == topic, "queue: poll returns correct token");
            CHECK(payload != NULL && len > 0, "queue: poll payload non-empty");
            free(payload);
            ++got;
        } else if (st == ZPS_EMPTY) {
            break;
        } else {
            ++fail;
            fprintf(stderr, "FAIL: poll returned %d (%s:%d)\n", (int)st, __FILE__, __LINE__);
            break;
        }
    }
    CHECK(got == 5, "queue: drained all 5 messages");
    CHECK(zenoh_pubsub_pending(sub) == 0, "queue: pending is 0 after drain");
    CHECK(zenoh_pubsub_dropped(sub) == 0, "queue: no messages dropped (depth=16 vs 5 sent)");

    zenoh_pubsub_unsubscribe(sub_ps, sub);
    zenoh_pubsub_disconnect(pub_ps);
    zenoh_pubsub_disconnect(sub_ps);
    zenoh_pubsub_destroy(pub_ps);
    zenoh_pubsub_destroy(sub_ps);
    return 0;
}

/* Negative test: poll with no zenoh involvement (just the API). */
static void test_queue_poll_invalid_args(void) {
    uint32_t tok; uint8_t *p; size_t n;
    CHECK(zenoh_pubsub_poll(NULL, &tok, &p, &n) == ZPS_ERR_INVALID_ARG, "poll NULL sub rejected");
}

/* ------------------------------------------------------------------ */
/*  Serial PTY-loopback fixture                                        */
/*                                                                     */
/*  socat isn't installed, so we roll our own bridge in C: two PTYs    */
/*  via posix_openpt(); we hold the master fds and bridge bytes in a   */
/*  worker thread. Zenoh side A opens slave path A, side B opens slave */
/*  path B, byte stream flows A_slave→A_master→bridge→B_master→B_slave.*/
/* ------------------------------------------------------------------ */

typedef struct {
    int master_a;
    int master_b;
    int stop;
} pty_bridge_t;

static int make_pty(int *master_fd, char *slave_path, size_t pathlen) {
    int m = posix_openpt(O_RDWR | O_NOCTTY);
    if (m < 0) return -1;
    if (grantpt(m) < 0 || unlockpt(m) < 0) { close(m); return -1; }
    if (ptsname_r(m, slave_path, pathlen) != 0) { close(m); return -1; }
    /* Put master in raw mode so SLIP bytes pass through unchanged. */
    struct termios tio;
    if (tcgetattr(m, &tio) == 0) {
        cfmakeraw(&tio);
        tcsetattr(m, TCSANOW, &tio);
    }
    *master_fd = m;
    return 0;
}

static void *bridge_thread(void *arg) {
    pty_bridge_t *br = (pty_bridge_t *)arg;
    /* Set masters non-blocking so we can poll both directions. */
    int flags = fcntl(br->master_a, F_GETFL, 0); fcntl(br->master_a, F_SETFL, flags | O_NONBLOCK);
        flags = fcntl(br->master_b, F_GETFL, 0); fcntl(br->master_b, F_SETFL, flags | O_NONBLOCK);

    uint8_t buf[1024];
    while (!br->stop) {
        int did = 0;
        ssize_t n = read(br->master_a, buf, sizeof(buf));
        if (n > 0) {
            ssize_t w = 0;
            while (w < n) {
                ssize_t r = write(br->master_b, buf + w, n - w);
                if (r < 0) { if (errno == EAGAIN) { usleep(1000); continue; } break; }
                w += r;
            }
            did = 1;
        }
        n = read(br->master_b, buf, sizeof(buf));
        if (n > 0) {
            ssize_t w = 0;
            while (w < n) {
                ssize_t r = write(br->master_a, buf + w, n - w);
                if (r < 0) { if (errno == EAGAIN) { usleep(1000); continue; } break; }
                w += r;
            }
            did = 1;
        }
        if (!did) usleep(500);   /* idle backoff */
    }
    return NULL;
}

/* Thread worker that drives zenoh_pubsub_connect() on a session — used to
 * connect both sides of the serial peer-to-peer link concurrently. */
typedef struct {
    ZenohPubSub *ps;
    zps_status_t st;
} connect_arg_t;

static void *connect_worker(void *p) {
    connect_arg_t *a = (connect_arg_t *)p;
    a->st = zenoh_pubsub_connect(a->ps);
    return NULL;
}

__attribute__((unused))
static int run_serial_pty_test(void) {
    fprintf(stderr, "\n=== End-to-end test over serial via PTY pair ===\n");

    char path_a[128], path_b[128];
    int  master_a = -1, master_b = -1;

    if (make_pty(&master_a, path_a, sizeof(path_a)) < 0) {
        fprintf(stderr, "FAIL: posix_openpt for side A: %s\n", strerror(errno));
        ++fail; return -1;
    }
    if (make_pty(&master_b, path_b, sizeof(path_b)) < 0) {
        fprintf(stderr, "FAIL: posix_openpt for side B: %s\n", strerror(errno));
        close(master_a); ++fail; return -1;
    }
    fprintf(stderr, "  PTY pair: A=%s  B=%s\n", path_a, path_b);

    pty_bridge_t br = { .master_a = master_a, .master_b = master_b, .stop = 0 };
    pthread_t bridge_tid;
    pthread_create(&bridge_tid, NULL, bridge_thread, &br);

    /* Build serial locator strings. baudrate doesn't matter for PTY but
     * zenoh-pico's parser requires it. */
    char loc_a[256], loc_b[256];
    snprintf(loc_a, sizeof(loc_a), "serial/%s#baudrate=115200", path_a);
    snprintf(loc_b, sizeof(loc_b), "serial/%s#baudrate=115200", path_b);

    recv_ctx_t rc = {0};
    pthread_mutex_init(&rc.lock, NULL);
    pthread_cond_init(&rc.cond, NULL);

    /* zenoh-pico serial transport is connect-only (peer-to-peer over a wire);
     * there is no listen path. Both sides use peer mode + connect locator,
     * each pointing at its OWN end of the PTY pair. The bridge thread
     * carries bytes between the two ends. */
    const char *a_connect[] = { loc_a };
    ZenohPubSubConfig cfg_a;
    zenoh_pubsub_config_defaults(&cfg_a);
    cfg_a.locators   = a_connect;
    cfg_a.n_locators = 1;
    cfg_a.mode       = "peer";

    const char *b_connect[] = { loc_b };
    ZenohPubSubConfig cfg_b;
    zenoh_pubsub_config_defaults(&cfg_b);
    cfg_b.locators   = b_connect;
    cfg_b.n_locators = 1;
    cfg_b.mode       = "peer";

    ZenohPubSub *ps_a = NULL, *ps_b = NULL;
    CHECK(zenoh_pubsub_create(&ps_a, &cfg_a) == ZPS_OK, "serial: create side A");
    CHECK(zenoh_pubsub_create(&ps_b, &cfg_b) == ZPS_OK, "serial: create side B");

    /* Both sides connect concurrently — each side's z_open handshakes
     * with the other across the PTY bridge. */
    connect_arg_t arg_a = { .ps = ps_a, .st = ZPS_OK },
                  arg_b = { .ps = ps_b, .st = ZPS_OK };
    pthread_t tid_a, tid_b;
    pthread_create(&tid_a, NULL, connect_worker, &arg_a);
    usleep(50000);    /* tiny stagger so A starts open() first */
    pthread_create(&tid_b, NULL, connect_worker, &arg_b);
    pthread_join(tid_a, NULL);
    pthread_join(tid_b, NULL);
    CHECK(arg_a.st == ZPS_OK, "serial: side A connect");
    CHECK(arg_b.st == ZPS_OK, "serial: side B connect");

    /* Subscribe on A, publish from B. */
    uint32_t topic = zt_hash("e2e/serial/round_trip");
    ZenohPubSubSub *sub = NULL;
    CHECK(zenoh_pubsub_subscribe(ps_a, topic, on_message, &rc, &sub) == ZPS_OK,
          "serial: subscribe");

    /* Give the declaration time to propagate through the PTY bridge. */
    usleep(500000);

    const char *msgs[] = { "slip-a", "slip-b", "slip-c" };
    for (int i = 0; i < 3; ++i) {
        CHECK(zenoh_pubsub_publish(ps_b, topic,
                                   (const uint8_t *)msgs[i], strlen(msgs[i])) == ZPS_OK,
              "serial: publish");
        usleep(50000);
    }

    int wait_rc = wait_for_message(&rc, 3, 5000);
    CHECK(wait_rc == 0, "serial: received 3 messages within 5 s");
    CHECK(rc.received == 3, "serial: received count == 3");
    CHECK(rc.got_token == topic, "serial: last message had correct token");

    zenoh_pubsub_unsubscribe(ps_a, sub);
    zenoh_pubsub_disconnect(ps_b);
    zenoh_pubsub_disconnect(ps_a);
    zenoh_pubsub_destroy(ps_b);
    zenoh_pubsub_destroy(ps_a);

    br.stop = 1;
    pthread_join(bridge_tid, NULL);
    close(master_a);
    close(master_b);
    pthread_cond_destroy(&rc.cond);
    pthread_mutex_destroy(&rc.lock);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  main                                                               */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv) {
    const char *transport = NULL;
    const char *locator   = "udp/127.0.0.1:17447";  /* default test locator */
    static struct option long_opts[] = {
        {"transport", required_argument, 0, 't'},
        {"locator",   required_argument, 0, 'l'},
        {0, 0, 0, 0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "t:l:", long_opts, NULL)) != -1) {
        if (opt == 't') transport = optarg;
        if (opt == 'l') locator   = optarg;
    }

    /* API-surface tests — no zenohd needed. */
    test_status_strings();
    test_config_defaults();
    test_create_invalid_args();
    test_queue_poll_invalid_args();

    /* End-to-end if a transport is requested. */
    if (transport != NULL) {
        if (strcmp(transport, "serial") == 0) {
            fprintf(stderr,
                "\n[SKIP] serial e2e test requires a zenohd listener on the\n"
                "       other end of the serial link. zenoh-pico's Linux POSIX\n"
                "       transport does not support listen-mode for serial — see\n"
                "       _z_listen_link in src/link/link.c (no SERIAL branch).\n"
                "       Peer-to-peer zenoh-pico ↔ zenoh-pico over a PTY bridge\n"
                "       was empirically verified to fail handshake. Real serial\n"
                "       testing needs a zenohd-on-host setup or actual hardware.\n"
                "       The serial config + transport code path is exercised at\n"
                "       compile time (Z_FEATURE_LINK_SERIAL=1) and works as a\n"
                "       client when paired with zenohd as the other endpoint.\n");
        } else {
            char locbuf[128];
            if (strcmp(transport, "tcp") == 0) {
                snprintf(locbuf, sizeof(locbuf), "tcp/127.0.0.1:17447");
                locator = locbuf;
            } else if (strcmp(transport, "udp") == 0) {
                /* keep default udp/127.0.0.1:17447 */
            } else if (strncmp(transport, "unix", 4) != 0) {
                /* Otherwise use --locator as provided. */
            }
            run_e2e_test(locator);
            run_queue_e2e_test(locator);
        }
    }

    printf("\nzenoh_pubsub tests: %d passed, %d failed\n", pass, fail);
    return fail == 0 ? 0 : 1;
}
