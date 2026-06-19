-- chains/build.lua — build driver for the irrigation_analytics class.
--
-- Assembles KB0 (shared — robot_common/chains/connection.lua) plus this
-- class's monitor KB into one compiled IR. Build-time only.
--
--   luajit irrigation_analytics/chains/build.lua irrigation_analytics/chains/connection.json

local _dsl = (os.getenv("HOME") or "")
    .. "/knowledge_base_assembly/luajit_programs_and_containers/building_blocks/chain_tree_luajit/lua_dsl/"
local _self = (arg and arg[0] and arg[0]:match("(.*/)")) or "./"
package.path = _self .. "?.lua;"
    .. _self .. "../../robot_common/chains/?.lua;"
    .. _dsl .. "?.lua;" .. _dsl .. "lua_support/?.lua;"
    .. package.path

local ChainTreeMaster = require("chain_tree_master")
local kb0      = require("connection")
local monitor  = require("monitor")
local detector = require("detector")
local kb4_clog = require("kb4_clog")
local kb2_resistance = require("kb2_resistance")
local kb1_overcurrent = require("kb1_overcurrent")
local kb2_within_run = require("kb2_within_run")
local kb3_sustained = require("kb3_sustained")
local kb4_v2 = require("kb4_v2")
local digest = require("digest")

if #arg ~= 1 then
    print("Usage: luajit irrigation_analytics/chains/build.lua <json_file>")
    os.exit(1)
end

local ct = ChainTreeMaster.new(arg[1])
kb0.build_kb0(ct, kb0.KB0_NAME)
monitor.build_monitor(ct, monitor.MONITOR_KB_NAME)
detector.build_detector(ct, detector.DETECTOR_KB_NAME)
kb4_clog.build_kb4_clog(ct, kb4_clog.KB4_CLOG_KB_NAME)
kb2_resistance.build_kb2_resistance(ct, kb2_resistance.KB2_RESISTANCE_KB_NAME)
kb1_overcurrent.build_kb1_overcurrent(ct, kb1_overcurrent.KB1_OVERCURRENT_KB_NAME)
kb2_within_run.build_kb2_within_run(ct, kb2_within_run.KB2_WITHIN_RUN_KB_NAME)
kb3_sustained.build_kb3_sustained(ct, kb3_sustained.KB3_SUSTAINED_KB_NAME)
kb4_v2.build_kb4_v2(ct, kb4_v2.KB4_V2_KB_NAME)
digest.build_digest(ct, digest.DIGEST_KB_NAME)
ct:check_and_generate()
print("Wrote: " .. arg[1])
print("Total nodes: " .. ct.ctb:get_total_node_count())
