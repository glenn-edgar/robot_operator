/**
 * stress_rpc.c — sustained-call stress test for zenoh_rpc.
 *
 * Spins up a server + client in the same process against an external
 * zenohd, then loops client_call N times. With ASan, any UAF in the
 * reply-collector / closure-context lifecycle aborts with a backtrace
 * pointing at exactly which line is wrong.
 *
 * Build:
 *     make -C ../.. stress (see Makefile target added alongside this file)
 *
 * Run:
 *     ./build/stress_rpc                          # default 200 iters, 7447
 *     ./build/stress_rpc -n 5000 -l tcp/127.0.0.1:7447
 *     ./build/stress_rpc -n 200 --short-timeout   # force frequent timeouts
 */

#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "zenoh_rpc.h"
#include "zenoh_token.h"

#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

int main(int argc, char **argv) {
    const char *locator    = "tcp/127.0.0.1:7447";
    int iterations         = 200;
    int short_timeout      = 0;          /* force frequent timeouts? */
    int unregistered_only  = 0;          /* call against a bogus token? */
    static struct option opts[] = {
        {"locator",          required_argument, 0, 'l'},
        {"iterations",       required_argument, 0, 'n'},
        {"short-timeout",    no_argument,       0, 's'},
        {"unregistered",     no_argument,       0, 'u'},
        {0, 0, 0, 0}
    };
    int opt;
    while ((opt = getopt_long(argc, argv, "l:n:su", opts, NULL)) != -1) {
        if (opt == 'l') locator = optarg;
        if (opt == 'n') iterations = atoi(optarg);
        if (opt == 's') short_timeout = 1;
        if (opt == 'u') unregistered_only = 1;
    }

    fprintf(stderr, "stress_rpc: locator=%s iterations=%d short_timeout=%d unregistered_only=%d\n",
            locator, iterations, short_timeout, unregistered_only);

    const char *locs[] = { locator };
    ZenohRpcConfig cfg;
    zenoh_rpc_config_defaults(&cfg);
    cfg.locators   = locs;
    cfg.n_locators = 1;

    ZenohRpcServer *srv = NULL;
    ZenohRpcClient *cli = NULL;
    if (zenoh_rpc_server_create(&srv, &cfg) != ZRPC_OK) { fprintf(stderr, "server create failed\n"); return 2; }
    if (zenoh_rpc_client_create(&cli, &cfg) != ZRPC_OK) { fprintf(stderr, "client create failed\n"); return 2; }

    uint32_t method = zt_hash("stress/rpc/echo");
    uint32_t bogus  = zt_hash("stress/rpc/no_such_method");

    if (!unregistered_only) {
        if (zenoh_rpc_server_register(srv, method, echo_handler, NULL) != ZRPC_OK) {
            fprintf(stderr, "server register failed\n"); return 2;
        }
    }
    if (zenoh_rpc_server_start(srv) != ZRPC_OK)  { fprintf(stderr, "server start failed\n");  return 2; }
    if (zenoh_rpc_client_connect(cli) != ZRPC_OK) { fprintf(stderr, "client connect failed\n"); return 2; }

    usleep(300000);   /* let queryable propagate */

    int ok_count = 0, timeout_count = 0, err_count = 0;
    for (int i = 0; i < iterations; ++i) {
        uint8_t *resp = NULL; size_t resp_len = 0;
        uint32_t token = unregistered_only ? bogus : method;
        uint32_t to_ms = short_timeout ? 30 : 2000;
        char req[32];
        int n = snprintf(req, sizeof(req), "msg-%d", i);

        zrpc_status_t st = zenoh_rpc_client_call(cli, token,
                                                 (const uint8_t *)req, (size_t)n,
                                                 to_ms,
                                                 &resp, &resp_len);
        if (st == ZRPC_OK) {
            ok_count++;
        } else if (st == ZRPC_ERR_TIMEOUT || st == ZRPC_ERR_NO_REPLY) {
            timeout_count++;
        } else {
            err_count++;
            fprintf(stderr, "iter %d: unexpected status %d (%s)\n", i, st, zrpc_status_str(st));
        }
        free(resp);

        /* Brief breath every so often so we don't pin the read thread. */
        if ((i % 50) == 49) usleep(1000);

        if ((i % 100) == 99) {
            fprintf(stderr, "  iter %d: ok=%d timeout=%d err=%d\n",
                    i + 1, ok_count, timeout_count, err_count);
        }
    }

    fprintf(stderr, "\nstress_rpc DONE: ok=%d timeout=%d err=%d (total=%d)\n",
            ok_count, timeout_count, err_count, iterations);

    zenoh_rpc_client_disconnect(cli);
    zenoh_rpc_server_stop(srv);
    zenoh_rpc_client_destroy(cli);
    zenoh_rpc_server_destroy(srv);

    /* Hold briefly so any late-firing read-thread closures have time to
     * fire BEFORE the process exits — gives ASan a chance to see the UAF. */
    usleep(500000);

    return 0;
}
