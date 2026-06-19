# vendor/ — Third-party runtime files vendored into fleet_design

These files are **copies** from upstream Lua-side projects under
`~/knowledge_base_assembly/`. They live here so a partial-repo pull
(e.g., to a Pi Zero 2) gets everything the fake_robot / future Linux
robots need at runtime, with no reference to the upstream tree.

Refresh: re-copy from upstream when you intentionally pick up a new
version. Suggested workflow is `tools/vendor_refresh.sh` (not yet
written — manual `cp` for now per the table below).

## File map

| Vendored file | Upstream source | Purpose |
|---|---|---|
| `lua/ct_loader.lua` | `chain_tree_luajit/runtime_dict/ct_loader.lua` | Load compiled JSON IR into runtime handle |
| `lua/ct_runtime.lua` | `chain_tree_luajit/runtime_dict/ct_runtime.lua` | KB lifecycle + handle factory |
| `lua/ct_engine.lua` | `chain_tree_luajit/runtime_dict/ct_engine.lua` | Node execution / event dispatch |
| `lua/ct_builtins.lua` | `chain_tree_luajit/runtime_dict/ct_builtins.lua` | Built-in node functions (CFL_COLUMN_*, watchdog, log, state machine, ...) |
| `lua/ct_definitions.lua` | `chain_tree_luajit/runtime_dict/ct_definitions.lua` | Return-code + event-id enums (CFL_TIMER_EVENT, CFL_SECOND_EVENT, etc.) |
| `lua/ct_common.lua` | `chain_tree_luajit/runtime_dict/ct_common.lua` | Tree helpers (children, parents) |
| `lua/ct_walker.lua` | `chain_tree_luajit/runtime_dict/ct_walker.lua` | Iterative DFS walker |
| `lua/fn_registry.lua` | `ros_planner_ii/runtime/fn_registry.lua` | Maps user-fn names from compiled IR to Lua callables |
| `lua/zenoh_pubsub.lua` | `knowledge_base/zenoh/lib/zenoh_pubsub.lua` | LuaJIT FFI binding for libzenoh_pubsub |
| `lua/zenoh_rpc.lua` | `knowledge_base/zenoh/lib/zenoh_rpc.lua` | LuaJIT FFI binding for libzenoh_rpc |
| `lua/zenoh_token.lua` | `knowledge_base/zenoh/lib/zenoh_token.lua` | LuaJIT FFI binding for libzenoh_token (FNV1a-32 topic hash) |
| `lua/sqlite3_helpers.lua` | `knowledge_base/sqlite3/construct_kb/sqlite3_helpers.lua` | Shared LuaJIT FFI bindings to libsqlite3 + SQL helpers + JSON encode/decode |
| `lua/knowledge_base_manager.lua` | `knowledge_base/sqlite3/construct_kb/knowledge_base_manager.lua` | Core KB CRUD + ltree query methods (uses ltree.so) |
| `lua/construct_kb.lua` | `knowledge_base/sqlite3/construct_kb/construct_kb.lua` | Stack-based KB construction (add_header_node / add_info_node / leave_header_node / paths) |
| `lua/construct_data_tables.lua` | `knowledge_base/sqlite3/construct_kb/construct_data_tables.lua` | Aggregator wiring all construct_* sub-builders into one unified API |
| `lua/construct_status_table.lua` | `knowledge_base/sqlite3/construct_kb/construct_status_table.lua` | Status table construction (add_status_field, UPSERT-by-path) |
| `lua/construct_stream_table.lua` | `knowledge_base/sqlite3/construct_kb/construct_stream_table.lua` | Stream table construction (add_stream_field, circular buffer per path) |
| `lua/construct_job_table.lua` | `knowledge_base/sqlite3/construct_kb/construct_job_table.lua` | Job queue table construction (add_job_field) |
| `lua/construct_rpc_server_table.lua` | `knowledge_base/sqlite3/construct_kb/construct_rpc_server_table.lua` | RPC server queue construction (4-state lifecycle) |
| `lua/construct_rpc_client_table.lua` | `knowledge_base/sqlite3/construct_kb/construct_rpc_client_table.lua` | RPC client reply queue construction (2-state toggle) |
| `lua/construct_bit_mask_store.lua` | `knowledge_base/sqlite3/construct_kb/construct_bit_mask_store.lua` | Bit mask + KB integration |
| `lua/bit_mask_operations.lua` | `knowledge_base/sqlite3/construct_kb/bit_mask_operations.lua` | Bit mask table CRUD (construct-time) |
| `lua/kb_data_structures.lua` | `knowledge_base/sqlite3/data_structures/kb_data_structures.lua` | Runtime aggregator facade — delegates to all subsystems |
| `lua/kb_query_support.lua` | `knowledge_base/sqlite3/data_structures/kb_query_support.lua` | CTE progressive filter chain (KB_Search) |
| `lua/kb_status_table.lua` | `knowledge_base/sqlite3/data_structures/kb_status_table.lua` | Status data CRUD — get/set JSON by path with UPSERT |
| `lua/kb_stream.lua` | `knowledge_base/sqlite3/data_structures/kb_stream.lua` | Circular buffer stream — push_stream_data overwrites oldest row per path; get_latest / list / range |
| `lua/kb_job_queue.lua` | `knowledge_base/sqlite3/data_structures/kb_job_queue.lua` | Job queue runtime — push/peek/complete with priority + FIFO tiebreak |
| `lua/kb_rpc_server.lua` | `knowledge_base/sqlite3/data_structures/kb_rpc_server.lua` | RPC server queue runtime — UUID + 4-state lifecycle |
| `lua/kb_rpc_client.lua` | `knowledge_base/sqlite3/data_structures/kb_rpc_client.lua` | RPC client reply queue runtime |
| `lua/bit_mask_rt_operations.lua` | `knowledge_base/sqlite3/data_structures/bit_mask_rt_operations.lua` | Runtime bit-level operations on bit_mask_store (get/set bit, change tracking) |
| `lua/bit_s_expression.lua` | `knowledge_base/sqlite3/data_structures/bit_s_expression.lua` | S-expression tokenizer + evaluator for bit mask conditions |
| `lua/kb_bit_structures.lua` | `knowledge_base/sqlite3/data_structures/kb_bit_structures.lua` | KB_Search + bit mask ops + S-expr orchestrator |
| `lua/kb_link_table.lua` | `knowledge_base/sqlite3/data_structures/kb_link_table.lua` | Link table queries |
| `lua/kb_link_mount_table.lua` | `knowledge_base/sqlite3/data_structures/kb_link_mount_table.lua` | Link mount table queries |
| `c/ltree/ltree_sqlite.c` | `knowledge_base/sqlite3_ltree_extension/ltree_sqlite.c` | SQLite loadable extension implementing PostgreSQL-style ltree (ltree_match / ancestor / descendant / depth) |
| `c/ltree/test_ltree.c` | `knowledge_base/sqlite3_ltree_extension/test_ltree.c` | Standalone test suite for the ltree extension |
| `c/ltree/Makefile` | `knowledge_base/sqlite3_ltree_extension/Makefile` | Build / test / install (`make install` → /usr/local/lib/ltree.so) |
| `c/ltree/README_LTREE_EXTENSION.md` | `knowledge_base/sqlite3_ltree_extension/README_LTREE_EXTENSION.md` | Extension API documentation |

Upstream root on dev: `~/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/`

## What is NOT vendored

- **`chain_tree_luajit/lua_dsl/`** — DSL builder. Build-time only; runs on the
  dev machine to regenerate `connection.json` from `connection.lua`. The Pi
  consumes the compiled IR; it never builds.
- **Native shared libraries `libzenoh_*.so` / `libzenohpico.so`**. Per-arch
  builds. Bench dev uses external `LD_LIBRARY_PATH`; Pi Zero 2 deploy will
  need aarch64 builds copied into `vendor/lib-aarch64/` (directory not yet
  created — wait until the deploy work begins).
- **The built `ltree.so`** — built from `c/ltree/` source on whatever host
  runs the persistence layer. Bench: `cd vendor/c/ltree && sudo make install`
  drops it at `/usr/local/lib/ltree.so` (sqlite3 `load_extension('ltree')`
  finds it via its default search path). Container/Pi: build step in
  Dockerfile or run.sh. See `c/ltree/README_LTREE_EXTENSION.md`.

## Freshness

| Date | Action |
|---|---|
| 2026-05-19 | Initial vendor copy from local upstream. |
| 2026-05-22 | Re-vendored `ct_builtins.lua` — added the `CFL_WAIT_UNTIL_{IN,OUT_OF}_TIME_WINDOW` time-of-day wait leaves (ported from the Python `ct_builtins`). |
| 2026-05-23 | Vendored the full `knowledge_base/sqlite3/` stack (11 construct + 12 runtime Lua files) + the `sqlite3_ltree_extension/` C source. Foundation for the layer-30 persistence service. |
