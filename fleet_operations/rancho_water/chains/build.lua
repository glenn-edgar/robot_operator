-- chains/build.lua — build driver for the rancho_water class.
--
-- Assembles KB0 (shared — robot_common/chains/connection.lua) plus this
-- class's daily_pull KB into one compiled IR. Build-time only.
--
--   luajit rancho_water/chains/build.lua rancho_water/chains/connection.json

local _dsl = (os.getenv("HOME") or "")
    .. "/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/chain_tree_luajit/lua_dsl/"
local _self = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
package.path = _self .. "?.lua;"
    .. _self .. "../../robot_common/chains/?.lua;"
    .. _dsl .. "?.lua;" .. _dsl .. "lua_support/?.lua;"
    .. package.path

local ChainTreeMaster = require("chain_tree_master")
local kb0        = require("connection")
local daily_pull = require("daily_pull")

if #arg ~= 1 then
    print("Usage: luajit rancho_water/chains/build.lua <json_file>")
    os.exit(1)
end

local ct = ChainTreeMaster.new(arg[1])
kb0.build_kb0(ct, kb0.KB0_NAME)
daily_pull.build_daily_pull(ct, daily_pull.DAILY_PULL_KB_NAME)
ct:check_and_generate()
print("Wrote: " .. arg[1])
print("Total nodes: " .. ct.ctb:get_total_node_count())
