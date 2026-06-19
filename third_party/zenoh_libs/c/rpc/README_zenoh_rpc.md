# zenoh_rpc — Zenoh request/response RPC

C client library wrapping zenoh-pico's get/queryable primitives.

**STATUS: scaffolding.** The API surface is final; the implementation against
zenoh-pico is deferred until zenoh-pico is installed on the build host.

## API surface (final)

### Server

```c
ZenohRpcServer *srv;
ZenohRpcConfig cfg;
zenoh_rpc_config_defaults(&cfg);

const char *locators[] = { "udp/127.0.0.1:7447" };
cfg.locators = locators; cfg.n_locators = 1;

zenoh_rpc_server_create(&srv, &cfg);

/* Register handlers (each becomes a queryable) */
zenoh_rpc_server_register(srv, zt_hash("math.add"), add_handler, NULL);
zenoh_rpc_server_register(srv, zt_hash("math.mul"), mul_handler, NULL);

zenoh_rpc_server_start(srv);   /* blocks until stop */
```

Handler signature: `req` is borrowed, `*resp` must be malloc'd (library frees after sending).

### Client

```c
ZenohRpcClient *cli;
zenoh_rpc_client_create(&cli, &cfg);
zenoh_rpc_client_connect(cli);

uint8_t *resp = NULL;
size_t resp_len = 0;
zenoh_rpc_client_call(cli, zt_hash("math.add"),
                      req, req_len,
                      5000,        /* timeout ms */
                      &resp, &resp_len);
/* ... use resp ... */
free(resp);
```

## Transports

Same as `zenoh_pubsub` — UDP/TCP/Serial SLIP/Unix socket via the locator string.

## Build & test

```bash
make            # builds libs + test binary
make run-test   # runs API-surface tests (no zenoh-pico needed yet)
```

Currently produces:

- `build/libzenoh_rpc.a` — static (scaffold)
- `build/libzenoh_rpc.so` — shared (scaffold)
- `build/test_zenoh_rpc` — test driver

## To finish the implementation

Same steps as `zenoh_pubsub` — install zenoh-pico, enable `ZENOH_LIBS` in
the Makefile, replace `TODO` markers in `src/zenoh_rpc.c` with `z_get` /
`z_declare_queryable` / `z_query_reply` calls.

Client-side `_call()` will block on a `pthread_cond_t` until the closure
fires for the first reply, with `pthread_cond_timedwait` enforcing the
caller's timeout.
