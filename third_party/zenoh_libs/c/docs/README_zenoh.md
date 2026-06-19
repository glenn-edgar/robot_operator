# Zenoh C Client Libraries

C client libraries for building distributed systems on [Eclipse Zenoh](https://zenoh.io/),
built on top of [zenoh-pico](https://github.com/eclipse-zenoh/zenoh-pico) (pure C99 — **no Rust toolchain required**).

Each module is independently compiled and tested, sharing a common design:
`_create/_destroy` lifecycle, status-code returns, caller-frees-strings ownership,
zenoh-pico for transport.

This build_block ships **only the C client drivers**. The zenoh router (`zenohd`) is
used as a prebuilt container during testing; we do not build or repackage it.

## Modules

| Module | Library | Description |
|--------|---------|-------------|
| `token/` | `libzenoh_token` | FNV1a-32 hash utility — string → uint32 token, batch list conversion, optional debug reverse-lookup |
| `pub_sub/` | `libzenoh_pubsub` | Publish/subscribe — wraps `z_declare_publisher`/`z_declare_subscriber`, namespace prefixing, wildcards |
| `rpc/` | `libzenoh_rpc` | Request/response — wraps `z_get` (client) and `z_declare_queryable` (server) |

Each module produces a static `.a` and a shared `.so`, plus a test driver.

## Transports

The client libraries support **TCP, UDP, and Serial SLIP** transports, selected at
session-open time via the locator string:

```
udp/10.0.0.5:7447                       # UDP unicast
tcp/10.0.0.5:7447                       # TCP
serial//dev/ttyUSB0#baudrate=921600     # serial with SLIP framing
unix:///var/run/zenoh.sock              # Unix domain socket (also supported)
```

## Prerequisites

### zenoh-pico (required for pub_sub and rpc; not for token)

```bash
git clone https://github.com/eclipse-zenoh/zenoh-pico.git
cd zenoh-pico
mkdir build && cd build
cmake ..
make
sudo make install
sudo ldconfig
```

### Docker (required for end-to-end tests)

Tests for `pub_sub` and `rpc` need a running zenohd router. Pull the official image:

```bash
docker pull eclipse/zenoh:latest
```

The Makefiles spin up a test instance on port 17447 (to avoid clashing with any
production zenohd on 7447).

**Serial transport caveat:** zenoh-pico's Linux POSIX serial transport supports
CONNECT but not LISTEN. End-to-end serial testing therefore needs zenohd as the
listener (e.g. `zenohd -l serial//dev/ttyACM0#baudrate=115200`) or actual Pico 2 W
hardware over USB CDC. The library compiles + links serial-capable; pure
zenoh-pico ↔ zenoh-pico over a software PTY bridge will fail handshake.
See `continue.md` for the full investigation.

## Build & Test

Each module builds independently:

```bash
cd token   && make && make run-test     # no external dependencies
cd pub_sub && make && make run-test     # needs zenoh-pico installed + docker
cd rpc     && make && make run-test     # needs zenoh-pico installed + docker
```

## Directory Layout

```
zenoh/
├── README_zenoh.md
├── mkdocs.yml
├── docs/                  # collected per-module READMEs for site build
├── token/
│   ├── include/zenoh_token.h
│   ├── src/zenoh_token.c
│   ├── test/test_zenoh_token.c
│   ├── build/
│   ├── Makefile
│   └── README_zenoh_token.md
├── pub_sub/
│   ├── include/zenoh_pubsub.h
│   ├── src/zenoh_pubsub.c
│   ├── test/test_zenoh_pubsub.c
│   ├── build/
│   ├── Makefile
│   └── README_zenoh_pubsub.md
└── rpc/
    ├── include/zenoh_rpc.h
    ├── src/zenoh_rpc.c
    ├── test/test_zenoh_rpc.c
    ├── build/
    ├── Makefile
    └── README_zenoh_rpc.md
```

## Common API Patterns

- **Lifecycle:** `xxx_create()` allocates, `xxx_destroy()` frees
- **Status codes:** every function returns a `_status_t` enum; `_OK = 0`
- **String ownership:** output strings are `malloc`'d by the library; caller calls `free()`
- **Opaque handles:** internal structs hidden behind forward-declared typedefs
- **Thread safety:** `pthread_mutex_t` guards shared state; zenoh-pico callbacks run on internal threads — subscriber callbacks are responsible for their own thread-safety

## Topology

The client libraries connect to a zenohd router (or to each other in peer mode).
In production deployment, zenohd runs as a separate container; clients open
sessions via UDP/TCP locators. See the architectural memo for downstream usage
patterns (robot controller, MQTT-zenoh gateway, etc.) — none of that is built here.
