# zenoh_token — FNV1a-32 topic-token utility

Hashes topic strings to 32-bit tokens. Used by `zenoh_pubsub` and `zenoh_rpc` to
build compact wire keys, and optionally registered for debug reverse-lookup.

Pure C99 — no external dependencies beyond pthreads.

## API

```c
#include "zenoh_token.h"

/* Hash a single topic */
uint32_t t = zt_hash("robot/42/telemetry");

/* Hash a list */
const char *topics[] = { "sensor/temp", "sensor/hum" };
uint32_t tokens[2];
zt_hash_list(topics, 2, tokens);

/* Optional registry for reverse lookup */
zt_register(t, "robot/42/telemetry");
const char *s = zt_lookup(t);    /* returns "robot/42/telemetry" */
zt_registry_clear();             /* tear down at shutdown */
```

See `include/zenoh_token.h` for full API including status codes.

## Algorithm

FNV-1a 32-bit (RFC draft-eastlake-fnv). Initial offset basis `0x811c9dc5`,
prime `0x01000193`. Standard byte-by-byte XOR-then-multiply.

Test vectors:

| Input     | Token (hex) |
|-----------|-------------|
| `""`      | `0x811c9dc5` |
| `"a"`     | `0xe40c292c` |
| `"foobar"`| `0xbf9cf968` |

## Build & test

```bash
make            # builds libs + test binary
make run-test   # builds and runs unit tests
```

No external dependencies. Produces:

- `build/libzenoh_token.a` — static
- `build/libzenoh_token.so` — shared
- `build/test_zenoh_token` — test driver

## Thread safety

`zt_hash` and `zt_hash_list` are pure functions — no state, safe from any thread.

The registry (`zt_register`, `zt_lookup`, `zt_registry_clear`, `zt_registry_size`)
is guarded by an internal `pthread_mutex_t` and safe to call from multiple threads.

## Collision behaviour

FNV1a-32 is non-cryptographic and *will* eventually collide if you hash enough
distinct strings. The birthday-paradox crossover is around ~65 000 distinct
topics. For typical topic counts (hundreds to a few thousand), collisions are
vanishingly rare.

If you register a token that already maps to a different topic,
`zt_register` returns `ZT_ERR_DUPLICATE` — you'll know at registration time,
not silently at runtime.
