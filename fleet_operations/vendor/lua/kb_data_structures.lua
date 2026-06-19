--[[
  kb_data_structures.lua — LuaJIT port of kb_data_structures.py (aggregator only)

  Unified facade that composes all KB runtime modules into a single object.
  Provides flat-namespace access to all sub-module methods via delegation.

  Usage:
    local KB_Data_Structures = require('kb_data_structures')

    local kb = KB_Data_Structures.new('knowledge_base.db', 'knowledge_base')

    -- Search (delegated from KB_Search)
    kb:clear_filters()
    kb:search_label('KB_STATUS_FIELD')
    local results = kb:execute_kb_search()

    -- Status
    kb:set_status_data(path, { key = 'value' })
    local data = kb:get_status_data(path)

    -- Job queue
    kb:push_job_data(job_path, { work = 'data' })
    local job = kb:peak_job_data(job_path)

    -- Stream
    kb:push_stream_data(stream_path, { sensor = 42 })

    -- RPC server
    kb:rpc_server_push_rpc_queue('my.server', nil, 'action', {}, 'tag')

    -- RPC client
    local reply = kb:rpc_client_peak_and_claim_reply_data('my.client')

    -- Bit structures
    local bit_data = kb:find_assemble_bit_data(node_ids, false, {'user_1'})

    -- Link tables
    local names = kb:link_table_find_all_link_names()
]]

local KB_Search           = require('kb_query_support')
local KB_Status_Table     = require('kb_status_table')
local KB_Job_Queue        = require('kb_job_queue')
local KB_Stream           = require('kb_stream')
local KB_RPC_Client       = require('kb_rpc_client')
local KB_RPC_Server       = require('kb_rpc_server')
local KB_Link_Table       = require('kb_link_table')
local KB_Link_Mount_Table = require('kb_link_mount_table')
local KB_Bit_Structures   = require('kb_bit_structures')

-- ═══════════════════════════════════════════════════════════════════════
-- KB_Data_Structures
-- ═══════════════════════════════════════════════════════════════════════

local KB_Data_Structures = {}
KB_Data_Structures.__index = KB_Data_Structures

--- Create a new KB_Data_Structures facade.
-- @param db_file  string: path to SQLite database file
-- @param database string: database/schema name identifier
function KB_Data_Structures.new(db_file, database)
    assert(db_file,  "db_file is required")
    assert(database, "database is required")

    local self = setmetatable({}, KB_Data_Structures)

    -- ── Core search engine ──────────────────────────────────────────────
    self.query_support = KB_Search.new({ db_path = db_file, database = database })
    local _, db = self.query_support:get_db()

    -- ── Sub-modules ─────────────────────────────────────────────────────
    self.status_table     = KB_Status_Table.new(self.query_support, database)
    self.job_queue        = KB_Job_Queue.new(self.query_support, database)
    self.stream           = KB_Stream.new(self.query_support, database)
    self.rpc_client       = KB_RPC_Client.new(self.query_support, database)
    self.rpc_server       = KB_RPC_Server.new(self.query_support, database)
    self.link_table       = KB_Link_Table.new(db, database)
    self.link_mount_table = KB_Link_Mount_Table.new(db, database)
    self.bit_structures   = KB_Bit_Structures.new(self.query_support, database)

    return self
end

-- ── KB_Search delegates ─────────────────────────────────────────────────

function KB_Data_Structures:clear_filters(...)
    return self.query_support:clear_filters(...)
end
function KB_Data_Structures:search_label(...)
    return self.query_support:search_label(...)
end
function KB_Data_Structures:search_name(...)
    return self.query_support:search_name(...)
end
function KB_Data_Structures:search_kb(...)
    return self.query_support:search_kb(...)
end
function KB_Data_Structures:search_property_key(...)
    return self.query_support:search_property_key(...)
end
function KB_Data_Structures:search_property_value(...)
    return self.query_support:search_property_value(...)
end
function KB_Data_Structures:search_has_link(...)
    return self.query_support:search_has_link(...)
end
function KB_Data_Structures:search_has_link_mount(...)
    return self.query_support:search_has_link_mount(...)
end
function KB_Data_Structures:search_path(...)
    return self.query_support:search_path(...)
end
function KB_Data_Structures:search_starting_path(...)
    return self.query_support:search_starting_path(...)
end
function KB_Data_Structures:execute_kb_search(...)
    return self.query_support:execute_query(...)
end
function KB_Data_Structures:find_description(...)
    return self.query_support:find_description(...)
end
function KB_Data_Structures:find_description_paths(...)
    return self.query_support:find_description_paths(...)
end
function KB_Data_Structures:find_path_values(...)
    return self.query_support:find_path_values(...)
end
function KB_Data_Structures:decode_link_nodes(...)
    return self.query_support:decode_link_nodes(...)
end

-- ── Status table delegates ──────────────────────────────────────────────

function KB_Data_Structures:find_status_node_ids(...)
    return self.status_table:find_node_ids(...)
end
function KB_Data_Structures:find_status_node_id(...)
    return self.status_table:find_node_id(...)
end
function KB_Data_Structures:get_status_data(...)
    return self.status_table:get_status_data(...)
end
function KB_Data_Structures:set_status_data(...)
    return self.status_table:set_status_data(...)
end
function KB_Data_Structures:get_multiple_status_data(...)
    return self.status_table:get_multiple_status_data(...)
end
function KB_Data_Structures:set_multiple_status_data(...)
    return self.status_table:set_multiple_status_data(...)
end

-- ── Job queue delegates ─────────────────────────────────────────────────

function KB_Data_Structures:find_job_ids(...)
    return self.job_queue:find_job_ids(...)
end
function KB_Data_Structures:find_job_id(...)
    return self.job_queue:find_job_id(...)
end
function KB_Data_Structures:get_queued_number(...)
    return self.job_queue:get_queued_number(...)
end
function KB_Data_Structures:get_free_number(...)
    return self.job_queue:get_free_number(...)
end
function KB_Data_Structures:peak_job_data(...)
    return self.job_queue:peak_job_data(...)
end
function KB_Data_Structures:mark_job_completed(...)
    return self.job_queue:mark_job_completed(...)
end
function KB_Data_Structures:push_job_data(...)
    return self.job_queue:push_job_data(...)
end
function KB_Data_Structures:list_pending_jobs(...)
    return self.job_queue:list_pending_jobs(...)
end
function KB_Data_Structures:list_active_jobs(...)
    return self.job_queue:list_active_jobs(...)
end
function KB_Data_Structures:clear_job_queue(...)
    return self.job_queue:clear_job_queue(...)
end
function KB_Data_Structures:get_job_statistics(...)
    return self.job_queue:get_job_statistics(...)
end
function KB_Data_Structures:get_job_by_id(...)
    return self.job_queue:get_job_by_id(...)
end

-- ── Stream delegates ────────────────────────────────────────────────────

function KB_Data_Structures:find_stream_ids(...)
    return self.stream:find_stream_ids(...)
end
function KB_Data_Structures:find_stream_id(...)
    return self.stream:find_stream_id(...)
end
function KB_Data_Structures:find_stream_table_keys(...)
    return self.stream:find_stream_table_keys(...)
end
function KB_Data_Structures:push_stream_data(...)
    return self.stream:push_stream_data(...)
end
function KB_Data_Structures:list_stream_data(...)
    return self.stream:list_stream_data(...)
end
function KB_Data_Structures:get_latest_stream_data(...)
    return self.stream:get_latest_stream_data(...)
end
function KB_Data_Structures:clear_stream_data(...)
    return self.stream:clear_stream_data(...)
end
function KB_Data_Structures:get_stream_data_count(...)
    return self.stream:get_stream_data_count(...)
end
function KB_Data_Structures:get_stream_data_range(...)
    return self.stream:get_stream_data_range(...)
end
function KB_Data_Structures:get_stream_statistics(...)
    return self.stream:get_stream_statistics(...)
end
function KB_Data_Structures:get_stream_data_by_id(...)
    return self.stream:get_stream_data_by_id(...)
end

-- ── RPC client delegates ────────────────────────────────────────────────

function KB_Data_Structures:rpc_client_find_rpc_client_id(...)
    return self.rpc_client:find_rpc_client_id(...)
end
function KB_Data_Structures:rpc_client_find_rpc_client_ids(...)
    return self.rpc_client:find_rpc_client_ids(...)
end
function KB_Data_Structures:rpc_client_find_rpc_client_keys(...)
    return self.rpc_client:find_rpc_client_keys(...)
end
function KB_Data_Structures:rpc_client_find_free_slots(...)
    return self.rpc_client:find_free_slots(...)
end
function KB_Data_Structures:rpc_client_find_queued_slots(...)
    return self.rpc_client:find_queued_slots(...)
end
function KB_Data_Structures:rpc_client_peak_and_claim_reply_data(...)
    return self.rpc_client:peak_and_claim_reply_data(...)
end
function KB_Data_Structures:rpc_client_clear_reply_queue(...)
    return self.rpc_client:clear_reply_queue(...)
end
function KB_Data_Structures:rpc_client_push_and_claim_reply_data(...)
    return self.rpc_client:push_and_claim_reply_data(...)
end
function KB_Data_Structures:rpc_client_list_waiting_jobs(...)
    return self.rpc_client:list_waiting_jobs(...)
end

-- ── RPC server delegates ────────────────────────────────────────────────

function KB_Data_Structures:rpc_server_id_find(...)
    return self.rpc_server:find_rpc_server_id(...)
end
function KB_Data_Structures:rpc_server_ids_find(...)
    return self.rpc_server:find_rpc_server_ids(...)
end
function KB_Data_Structures:rpc_server_table_keys_find(...)
    return self.rpc_server:find_rpc_server_table_keys(...)
end
function KB_Data_Structures:rpc_server_list_jobs_job_types(...)
    return self.rpc_server:list_jobs_job_types(...)
end
function KB_Data_Structures:rpc_server_count_all_jobs(...)
    return self.rpc_server:count_all_jobs(...)
end
function KB_Data_Structures:rpc_server_count_empty_jobs(...)
    return self.rpc_server:count_empty_jobs(...)
end
function KB_Data_Structures:rpc_server_count_new_jobs(...)
    return self.rpc_server:count_new_jobs(...)
end
function KB_Data_Structures:rpc_server_count_processing_jobs(...)
    return self.rpc_server:count_processing_jobs(...)
end
function KB_Data_Structures:rpc_server_count_jobs_job_types(...)
    return self.rpc_server:count_jobs_job_types(...)
end
function KB_Data_Structures:rpc_server_push_rpc_queue(...)
    return self.rpc_server:push_rpc_queue(...)
end
function KB_Data_Structures:rpc_server_peak_server_queue(...)
    return self.rpc_server:peak_server_queue(...)
end
function KB_Data_Structures:rpc_server_mark_job_completion(...)
    return self.rpc_server:mark_job_completion(...)
end
function KB_Data_Structures:rpc_server_clear_server_queue(...)
    return self.rpc_server:clear_server_queue(...)
end

-- ── Link table delegates ────────────────────────────────────────────────

function KB_Data_Structures:link_table_find_records_by_link_name(...)
    return self.link_table:find_records_by_link_name(...)
end
function KB_Data_Structures:link_table_find_records_by_node_path(...)
    return self.link_table:find_records_by_node_path(...)
end
function KB_Data_Structures:link_table_find_all_link_names(...)
    return self.link_table:find_all_link_names(...)
end
function KB_Data_Structures:link_table_find_all_node_names(...)
    return self.link_table:find_all_node_names(...)
end

-- ── Link mount table delegates ──────────────────────────────────────────

function KB_Data_Structures:link_mount_table_find_records_by_link_name(...)
    return self.link_mount_table:find_records_by_link_name(...)
end
function KB_Data_Structures:link_mount_table_find_records_by_mount_path(...)
    return self.link_mount_table:find_records_by_mount_path(...)
end
function KB_Data_Structures:link_mount_table_find_all_link_names(...)
    return self.link_mount_table:find_all_link_names(...)
end
function KB_Data_Structures:link_mount_table_find_all_mount_paths(...)
    return self.link_mount_table:find_all_mount_paths(...)
end

-- ── Bit structures delegates ────────────────────────────────────────────

function KB_Data_Structures:find_bit_structure_ids(...)
    return self.bit_structures:find_bit_structure_ids(...)
end
function KB_Data_Structures:find_bit_structure_id(...)
    return self.bit_structures:find_bit_structure_id(...)
end
function KB_Data_Structures:get_bit_mask(...)
    return self.bit_structures:get_bit_mask(...)
end
function KB_Data_Structures:set_bit_mask(...)
    return self.bit_structures:set_bit_mask(...)
end
function KB_Data_Structures:find_assemble_bit_data(...)
    return self.bit_structures:find_assemble_bit_data(...)
end
function KB_Data_Structures:assemble_bit_data(...)
    return self.bit_structures:assemble_bit_data(...)
end
function KB_Data_Structures:set_flag_data(...)
    return self.bit_structures:set_flag_data(...)
end
function KB_Data_Structures:get_flag_data(...)
    return self.bit_structures:get_flag_data(...)
end
function KB_Data_Structures:s_tokenize(...)
    return self.bit_structures:tokenize(...)
end
function KB_Data_Structures:s_execute(...)
    return self.bit_structures:execute(...)
end
function KB_Data_Structures:set_all_ones(...)
    return self.bit_structures:set_all_ones(...)
end
function KB_Data_Structures:set_all_zeros(...)
    return self.bit_structures:set_all_zeros(...)
end

-- ── Disconnect ──────────────────────────────────────────────────────────

function KB_Data_Structures:disconnect()
    if self.query_support and self.query_support.disconnect then
        self.query_support:disconnect()
    end
end

return KB_Data_Structures