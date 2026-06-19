/**
 * @file test_zenoh_rpc.c
 * @brief Unit + end-to-end tests for zenoh_rpc.
 *
 * Modes:
 *   - API-surface tests always run (no zenohd needed).
 *   - --transport=udp|tcp runs the full server/client round-trip against
 *     a zenohd reachable at the locator (default 127.0.0.1:17447).
 */

#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "zenoh_rpc.h"
#include "zenoh_token.h"

#include <getopt.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    CHECK(strcmp(zrpc_status_str(ZRPC_OK), "OK") == 0, "status string OK");
    CHECK(zrpc_status_str(ZRPC_ERR_TIMEOUT) != NULL,   "status string timeout");
}

static void test_config_defaults(void) {
    ZenohRpcConfig cfg;
    zenoh_rpc_config_defaults(&cfg);
    CHECK(cfg.locators == NULL,           "default locators NULL");
    CHECK(cfg.n_locators == 0,            "default n_locators 0");
    CHECK(strcmp(cfg.mode, "client") == 0,"default mode 'client'");
    CHECK(cfg.enable_scout == false,      "default scout disabled");
}

static void test_create_invalid(void) {
    ZenohRpcServer *srv = NULL;
    ZenohRpcClient *cli = NULL;
    ZenohRpcConfig cfg;
    zenoh_rpc_config_defaults(&cfg);
    CHECK(zenoh_rpc_server_create(NULL, &cfg) == ZRPC_ERR_INVALID_ARG, "server NULL out rejected");
    CHECK(zenoh_rpc_server_create(&srv, NULL) == ZRPC_ERR_INVALID_ARG, "server NULL cfg rejected");
    CHECK(zenoh_rpc_server_create(&srv, &cfg) == ZRPC_ERR_INVALID_ARG, "server no locators rejected");
    CHECK(zenoh_rpc_client_create(NULL, &cfg) == ZRPC_ERR_INVALID_ARG, "client NULL out rejected");
    CHECK(zenoh_rpc_client_create(&cli, NULL) == ZRPC_ERR_INVALID_ARG, "client NULL cfg rejected");
    CHECK(zenoh_rpc_client_create(&cli, &cfg) == ZRPC_ERR_INVALID_ARG, "client no locators rejected");
}

/* ------------------------------------------------------------------ */
/*  E2E round-trip handler                                             */
/* ------------------------------------------------------------------ */

/* Echo + prefix handler: reply with "echo:" + the request bytes. */
static zrpc_status_t echo_handler(uint32_t token, const uint8_t *req, size_t req_len,
                                  uint8_t **resp, size_t *resp_len, void *ctx) {
    (void)token; (void)ctx;
    const char *prefix = "echo:";
    size_t prefix_len = strlen(prefix);
    size_t out_len = prefix_len + req_len;
    uint8_t *out = malloc(out_len);
    if (!out) return ZRPC_ERR_MEMORY;
    memcpy(out, prefix, prefix_len);
    if (req_len > 0) memcpy(out + prefix_len, req, req_len);
    *resp     = out;
    *resp_len = out_len;
    return ZRPC_OK;
}

static int run_e2e_test(const char *locator) {
    fprintf(stderr, "\n=== End-to-end RPC test against %s ===\n", locator);

    const char *locs[] = { locator };
    ZenohRpcConfig cfg;
    zenoh_rpc_config_defaults(&cfg);
    cfg.locators = locs;
    cfg.n_locators = 1;

    ZenohRpcServer *srv = NULL;
    ZenohRpcClient *cli = NULL;
    CHECK(zenoh_rpc_server_create(&srv, &cfg) == ZRPC_OK, "server create");
    CHECK(zenoh_rpc_client_create(&cli, &cfg) == ZRPC_OK, "client create");

    uint32_t method = zt_hash("e2e/test/echo");

    /* Register the handler BEFORE starting — exercises the "register then start" path. */
    CHECK(zenoh_rpc_server_register(srv, method, echo_handler, NULL) == ZRPC_OK,
          "server register echo");

    CHECK(zenoh_rpc_server_start(srv) == ZRPC_OK, "server start");
    CHECK(zenoh_rpc_client_connect(cli) == ZRPC_OK, "client connect");

    /* Allow queryable declaration to propagate. */
    usleep(200000);   /* 200 ms */

    /* Issue a call with a small request. */
    const char *req_str = "hello";
    uint8_t *resp = NULL;
    size_t   resp_len = 0;
    zrpc_status_t st = zenoh_rpc_client_call(cli, method,
                                             (const uint8_t *)req_str, strlen(req_str),
                                             3000,
                                             &resp, &resp_len);
    CHECK(st == ZRPC_OK, "call returned OK");
    CHECK(resp != NULL,  "response payload present");
    CHECK(resp_len == strlen("echo:hello"), "response length matches");
    if (resp_len == strlen("echo:hello")) {
        CHECK(memcmp(resp, "echo:hello", resp_len) == 0, "response payload matches");
    }
    free(resp);

    /* Empty request should still get a reply. */
    resp = NULL; resp_len = 0;
    st = zenoh_rpc_client_call(cli, method, NULL, 0, 3000, &resp, &resp_len);
    CHECK(st == ZRPC_OK, "call with empty req OK");
    CHECK(resp_len == strlen("echo:"), "empty-req response is just the prefix");
    free(resp);

    /* Call against an unregistered method should time out (no queryable). */
    uint32_t bogus = zt_hash("does/not/exist");
    resp = NULL; resp_len = 0;
    st = zenoh_rpc_client_call(cli, bogus, NULL, 0, 500, &resp, &resp_len);
    CHECK(st == ZRPC_ERR_TIMEOUT || st == ZRPC_ERR_NO_REPLY,
          "unregistered method times out or returns no-reply");
    free(resp);

    /* Teardown. */
    CHECK(zenoh_rpc_client_disconnect(cli) == ZRPC_OK, "client disconnect");
    CHECK(zenoh_rpc_server_stop(srv) == ZRPC_OK, "server stop");
    zenoh_rpc_client_destroy(cli);
    zenoh_rpc_server_destroy(srv);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Queue-mode server E2E                                              */
/* ------------------------------------------------------------------ */

static void *queue_poll_thread(void *arg) {
    /* Drain queue, echo-reply, repeat until told to stop. */
    ZenohRpcServerQueue *q = (ZenohRpcServerQueue *)arg;
    for (int i = 0; i < 200; ++i) {     /* ~10s worth of polling */
        ZenohRpcRequest *req = NULL;
        zrpc_status_t st = zenoh_rpc_server_poll(q, &req);
        if (st == ZRPC_OK && req) {
            const uint8_t *p = zenoh_rpc_request_payload(req);
            size_t plen = zenoh_rpc_request_payload_len(req);
            /* Echo with "queue:" prefix */
            size_t out_len = 6 + plen;
            uint8_t *out = malloc(out_len);
            memcpy(out, "queue:", 6);
            if (plen) memcpy(out + 6, p, plen);
            zenoh_rpc_request_reply(req, out, out_len);
            free(out);
        }
        usleep(50000);
    }
    return NULL;
}

static int run_queue_server_e2e_test(const char *locator) {
    fprintf(stderr, "\n=== Queue-mode RPC server E2E against %s ===\n", locator);

    const char *locs[] = { locator };
    ZenohRpcConfig cfg;
    zenoh_rpc_config_defaults(&cfg);
    cfg.locators = locs;
    cfg.n_locators = 1;

    ZenohRpcServer *srv = NULL;
    ZenohRpcClient *cli = NULL;
    CHECK(zenoh_rpc_server_create(&srv, &cfg) == ZRPC_OK, "queue: server create");
    CHECK(zenoh_rpc_client_create(&cli, &cfg) == ZRPC_OK, "queue: client create");

    uint32_t method = zt_hash("e2e/queue_server/echo");
    ZenohRpcServerQueue *q = NULL;
    CHECK(zenoh_rpc_server_register_queue(srv, method, 16, &q) == ZRPC_OK,
          "queue: register_queue");

    CHECK(zenoh_rpc_server_start(srv) == ZRPC_OK, "queue: server start");
    CHECK(zenoh_rpc_client_connect(cli) == ZRPC_OK, "queue: client connect");

    pthread_t tid;
    pthread_create(&tid, NULL, queue_poll_thread, q);

    usleep(200000);   /* propagation */

    /* Issue a few calls. */
    for (int i = 0; i < 3; ++i) {
        char req_buf[16];
        snprintf(req_buf, sizeof(req_buf), "req-%d", i);
        uint8_t *resp = NULL; size_t resp_len = 0;
        zrpc_status_t st = zenoh_rpc_client_call(cli, method,
            (const uint8_t *)req_buf, strlen(req_buf), 3000, &resp, &resp_len);
        CHECK(st == ZRPC_OK, "queue: call returned OK");
        char expected[32];
        snprintf(expected, sizeof(expected), "queue:%s", req_buf);
        CHECK(resp_len == strlen(expected), "queue: reply length matches");
        if (resp_len == strlen(expected)) {
            CHECK(memcmp(resp, expected, resp_len) == 0, "queue: reply content matches");
        }
        free(resp);
    }

    /* Stop polling thread and tear down. */
    /* (poll thread exits after its loop count; just wait for it) */
    pthread_join(tid, NULL);

    zenoh_rpc_client_disconnect(cli);
    zenoh_rpc_server_stop(srv);
    zenoh_rpc_client_destroy(cli);
    zenoh_rpc_server_destroy(srv);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  main                                                               */
/* ------------------------------------------------------------------ */

int main(int argc, char **argv) {
    const char *transport = NULL;
    const char *locator   = "udp/127.0.0.1:17447";
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

    test_status_strings();
    test_config_defaults();
    test_create_invalid();

    if (transport != NULL) {
        if (strcmp(transport, "serial") == 0) {
            fprintf(stderr, "\n[SKIP] serial e2e not implemented here\n");
        } else {
            char locbuf[128];
            if (strcmp(transport, "tcp") == 0) {
                snprintf(locbuf, sizeof(locbuf), "tcp/127.0.0.1:17447");
                locator = locbuf;
            }
            run_e2e_test(locator);
            run_queue_server_e2e_test(locator);
        }
    }

    printf("\nzenoh_rpc tests: %d passed, %d failed\n", pass, fail);
    return fail == 0 ? 0 : 1;
}
