# zenoh_pubsub — Zenoh publish/subscribe

C client library wrapping zenoh-pico's publisher and subscriber primitives.

**STATUS: scaffolding.** The API surface is final; the implementation against
zenoh-pico is deferred until zenoh-pico is installed on the build host.

## API surface (final)

```c
ZenohPubSub *ps;
ZenohPubSubConfig cfg;
zenoh_pubsub_config_defaults(&cfg);

const char *locators[] = { "udp/127.0.0.1:7447" };
cfg.locators   = locators;
cfg.n_locators = 1;

zenoh_pubsub_create(&ps, &cfg);
zenoh_pubsub_connect(ps);

/* Subscribe */
ZenohPubSubSub *sub;
zenoh_pubsub_subscribe(ps, zt_hash("sensor/temp"), my_cb, ctx, &sub);

/* Publish */
zenoh_pubsub_publish(ps, zt_hash("sensor/temp"), payload, len);

/* Teardown */
zenoh_pubsub_unsubscribe(ps, sub);
zenoh_pubsub_disconnect(ps);
zenoh_pubsub_destroy(ps);
```

## Transports

Selected by locator-string prefix:

```
udp/host:port                           # UDP unicast
tcp/host:port                           # TCP
serial//dev/ttyUSB0#baudrate=921600     # Serial SLIP framing
unix:///var/run/zenoh.sock              # Unix domain socket (loopback-fast)
```

Multiple locators in `cfg.locators` = failover. First reachable wins.

## Topic tokens

Topics are `uint32_t` FNV1a hashes from `zenoh_token`. The wire keyexpr is
the hex representation (`tok/cafebabe`) so traces remain readable.

## Threading model

zenoh-pico spawns two internal pthreads per session (read + lease).
**Subscriber callbacks run on the read thread, not the caller's main thread.**
Caller is responsible for thread-safety of any state the callback mutates.

Common pattern: callback enqueues onto a thread-safe queue, main thread drains.

## Build & test

```bash
make            # builds libs + test binary
make run-test   # runs API-surface tests (no zenoh-pico needed yet)
```

Currently produces:

- `build/libzenoh_pubsub.a` — static (scaffold)
- `build/libzenoh_pubsub.so` — shared (scaffold)
- `build/test_zenoh_pubsub` — test driver

Test driver supports `--transport=udp|tcp|serial` for transport-specific
end-to-end tests (skipped while in scaffold state).

## To finish the implementation

1. Install zenoh-pico:
   ```bash
   git clone https://github.com/eclipse-zenoh/zenoh-pico
   cd zenoh-pico && mkdir build && cd build
   cmake ..
   make && sudo make install && sudo ldconfig
   ```
2. In `Makefile`, uncomment the `ZENOH_LIBS := -lzenohpico` line.
3. In `src/zenoh_pubsub.c`, replace the `TODO` markers with calls to
   `z_open`, `z_declare_publisher`, `z_publisher_put`, `z_declare_subscriber`,
   `z_close`, etc.
4. In `test/test_zenoh_pubsub.c`, implement `run_transport_test()` to spin
   up an `eclipse/zenoh:latest` container on port 17447, publish a few
   messages, subscribe in parallel, verify delivery.
5. `make clean && make run-test`.
