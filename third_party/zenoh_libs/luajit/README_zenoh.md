# Zenoh — LuaJIT FFI bindings

LuaJIT bindings for the C Zenoh client libraries (built in
`c_programs_and_containers/build_blocks/knowledge_base/zenoh/`). The `.so`
files are committed in this directory; the `.lua` wrappers in `lib/` provide
idiomatic Lua APIs.

## Modules

| Module | C library | What it wraps |
|--------|-----------|---------------|
| `lib/zenoh_token.lua`  | `libzenoh_token.so`  | FNV1a-32 topic-token utility + optional debug registry |
| `lib/zenoh_pubsub.lua` | `libzenoh_pubsub.so` | Publish/subscribe with **queue+poll subscriber** (no foreign-thread Lua callbacks) |
| `lib/zenoh_rpc.lua`    | `libzenoh_rpc.so`    | Synchronous request/response RPC (client side) |

## Why queue+poll for subscribers?

zenoh-pico delivers subscriber messages on its internal read thread.
Calling a Lua callback from a non-main pthread is unsafe in LuaJIT —
LuaJIT's GC and JIT aren't thread-safe, and `ffi.cast` async callbacks
have triggered "bad callback" PANICs in this codebase before (see
`feedback_luajit_signal_safety`, the same issue that drove
`project_phase6_transport`'s deferral of NATS).

The pattern here:

```
zenoh-pico read thread
        │
        │ (sample arrives)
        ▼
C ring buffer (mutex-guarded, in libzenoh_pubsub.so)
        │
        │ (LuaJIT main thread polls)
        ▼
sub:poll() → { token, payload } or nil
```

Messages are heap-allocated C-side; `:poll()` transfers ownership to Lua
(which copies into a Lua string and frees the C buffer).

Server-side RPC handlers (`z_declare_queryable`) are **not** bound here for
the same cross-thread reason. Add a queue-based queryable API to the C
library if/when LuaJIT needs to host RPC servers.

## Usage

### Publish/subscribe

```lua
local zps = require("lib.zenoh_pubsub")
local zt  = require("lib.zenoh_token")

local ps = zps.PubSub.new({
    locators = { "udp/127.0.0.1:7447" },
    mode     = "client",
})
ps:connect()

local TOPIC = zt.hash("sensor/temp")
local sub   = ps:subscribe(TOPIC, 64)   -- queue depth 64

ps:publish(TOPIC, '{"value":23.5}')

while running do
    local msg = sub:poll()
    if msg then
        process(msg.token, msg.payload)
    else
        os.execute("sleep 0.01")
    end
end

ps:unsubscribe(sub)
ps:disconnect()
ps:destroy()
```

### RPC (client)

```lua
local zrpc = require("lib.zenoh_rpc")
local zt   = require("lib.zenoh_token")

local cli = zrpc.Client.new({ locators = { "udp/127.0.0.1:7447" } })
cli:connect()

local reply = cli:call(zt.hash("math.add"), '{"a":5,"b":3}', 5000)
-- reply is a string; deserialize as your app requires

cli:disconnect()
cli:destroy()
```

### Topic tokens

```lua
local zt = require("lib.zenoh_token")

local t = zt.hash("robot/42/telemetry")           -- single
local ts = zt.hash_list({ "a/b", "c/d", "e/f" })  -- batch

-- Optional reverse lookup for debug
zt.register(t, "robot/42/telemetry")
print(zt.lookup(t))      -- "robot/42/telemetry"
```

## Build & test

The `.so` files are committed in this directory. They were built in the
parallel C tree at `c_programs_and_containers/build_blocks/knowledge_base/zenoh/`.
If you rebuild the C tree, copy fresh `.so` files in:

```bash
ZTOP=$(pwd)
CSRC=../../../c_programs_and_containers/build_blocks/knowledge_base/zenoh
cp $CSRC/token/build/libzenoh_token.so     $ZTOP/
cp $CSRC/pub_sub/build/libzenoh_pubsub.so  $ZTOP/
cp $CSRC/rpc/build/libzenoh_rpc.so         $ZTOP/
```

To run the tests:

```bash
./test.sh
```

`test.sh` automatically starts an `eclipse/zenoh:latest` zenohd container on
port 17447 (TCP+UDP listening), runs the three Lua test scripts, and tears
the container down on exit. Override with:

- `ZENOH_LOCATOR=udp/host:port` — use a different zenohd
- `ZENOH_TEST_CONTAINER=name`   — reuse an existing container (won't be removed)
- `ZENOH_PICO_HOME=/path`       — where libzenohpico.so lives (default `~/src/zenoh-pico`)

## Directory layout

```
zenoh/
├── README_zenoh.md
├── mkdocs.yml
├── test.sh                     # runs all LuaJIT tests
├── libzenoh_token.so           # ← copied from c_programs tree
├── libzenoh_pubsub.so
├── libzenoh_rpc.so
├── lib/
│   ├── zenoh_token.lua
│   ├── zenoh_pubsub.lua
│   └── zenoh_rpc.lua
└── test/
    ├── test_zenoh_token.lua
    ├── test_zenoh_pubsub.lua
    └── test_zenoh_rpc.lua
```

## Dependencies

- LuaJIT 2.x (uses `ffi.cdef`, `ffi.load`, `ffi.string`, `ffi.cast`)
- `libzenohpico.so` somewhere on the loader path (built from
  `~/src/zenoh-pico` or `make install`-ed system-wide)
- Docker (for tests only — the test fixture uses `eclipse/zenoh:latest`)
