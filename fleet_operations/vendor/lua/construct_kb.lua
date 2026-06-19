--[[
    Construct_KB - LuaJIT Implementation
    
    Stack-based knowledge base construction class.
    Inherits from KnowledgeBaseManager (via composition + delegation).
    
    Translated from Python Construct_KB class.
    
    Usage:
        local Construct_KB = require('construct_kb')
        local kb = Construct_KB.new('knowledge_base.db', 'knowledge_base')
        kb:add_kb('kb1', 'First knowledge base')
        kb:select_kb('kb1')
        kb:add_header_node('link', 'name', {prop='val'}, {data='val'})
        kb:add_info_node('link', 'name', {prop='val'}, {data='val'})
        kb:leave_header_node('link', 'name')
        kb:check_installation()
        kb:disconnect()
--]]

local KBM = require('knowledge_base_manager')

-- ============================================================
-- Construct_KB class
-- ============================================================
local Construct_KB = {}
Construct_KB.__index = Construct_KB

--- Constructor
--- @param db_path              string   Path to SQLite database file
--- @param table_name           string?  Base table name (default: 'knowledge_base')
--- @param ltree_extension_path string?  Path to ltree extension (without suffix)
--- @param upload_flag          boolean? If true, skip table creation
--- @return Construct_KB
function Construct_KB.new(db_path, table_name, ltree_extension_path, upload_flag)
    table_name = table_name or 'knowledge_base'

    local self = setmetatable({}, Construct_KB)

    self.path = {}          -- kb_name -> array of path segments (stack)
    self.path_values = {}   -- kb_name -> set of known paths
    self.working_kb = nil   -- currently selected knowledge base

    -- Initialize parent (KnowledgeBaseManager)
    self._kb = KBM.new(table_name, db_path, ltree_extension_path, upload_flag)

    -- Expose db handle for get_db_objects compatibility
    self.db = self._kb.db
    self.table_name = table_name

    return self
end

-- ============================================================
-- Delegate all KnowledgeBaseManager query methods to self._kb
-- ============================================================
local delegated_methods = {
    'find_by_pattern',
    'find_descendants',
    'find_ancestors',
    'get_node_depth',
    'find_by_depth',
    'find_children',
    'disconnect',
}

for _, method in ipairs(delegated_methods) do
    Construct_KB[method] = function(self, ...)
        return self._kb[method](self._kb, ...)
    end
end

--- Returns the database object (for compatibility with Python's get_db_objects)
--- @return userdata  sqlite3* database handle
function Construct_KB:get_db_objects()
    return self._kb.db
end

-- ============================================================
-- Knowledge base management
-- ============================================================

--- Add a new knowledge base
--- @param kb_name    string  Knowledge base name
--- @param description string? Optional description
function Construct_KB:add_kb(kb_name, description)
    description = description or ""

    if self.path[kb_name] then
        error(string.format("Knowledge base %s already exists", kb_name))
    end

    self.path[kb_name] = { kb_name }
    self.path_values[kb_name] = {}

    self._kb:add_kb(kb_name, description)
end

--- Select a knowledge base as the active working KB
--- @param kb_name string  Knowledge base name
function Construct_KB:select_kb(kb_name)
    if not self.path[kb_name] then
        error(string.format("Knowledge base %s does not exist", kb_name))
    end
    self.working_kb = kb_name
end

-- ============================================================
-- Node construction (stack-based)
-- ============================================================

--- Join path segments with '.'
--- @param segments table  Array of path segments
--- @return string
local function join_path(segments)
    return table.concat(segments, '.')
end

--- Add a header node (pushes link + name onto the path stack)
--- @param link            string  Link/label for the node
--- @param node_name       string  Name of the node
--- @param node_properties table   Properties dictionary
--- @param node_data       table   Data dictionary
--- @param description     string? Optional description
function Construct_KB:add_header_node(link, node_name, node_properties, node_data, description)
    description = description or ""
    assert(type(description) == 'string', 'description must be a string')
    assert(type(node_properties) == 'table', 'node_properties must be a table')

    if description ~= "" then
        node_properties.description = description
    end

    local stack = self.path[self.working_kb]
    stack[#stack + 1] = link
    stack[#stack + 1] = node_name

    local node_path = join_path(stack)

    if self.path_values[self.working_kb][node_path] then
        error(string.format("Path %s already exists in knowledge base", node_path))
    end

    self.path_values[self.working_kb][node_path] = true

    local path = join_path(stack)
    print("path", path)

    self._kb:add_node(self.working_kb, link, node_name, node_properties, node_data, path)
end

--- Add an info node (pushes then immediately pops link + name)
--- @param link            string  Link/label for the node
--- @param node_name       string  Name of the node
--- @param node_properties table   Properties dictionary
--- @param node_data       table   Data dictionary
--- @param description     string? Optional description
function Construct_KB:add_info_node(link, node_name, node_properties, node_data, description)
    self:add_header_node(link, node_name, node_properties, node_data, description)

    local stack = self.path[self.working_kb]
    stack[#stack] = nil  -- pop node_name
    stack[#stack] = nil  -- pop link
end

--- Leave a header node, verifying label and name match
--- @param label string  Expected link/label
--- @param name  string  Expected node name
function Construct_KB:leave_header_node(label, name)
    local stack = self.path[self.working_kb]

    if not stack or #stack == 0 then
        error("Cannot leave a header node: path is empty")
    end

    local ref_name = stack[#stack]
    stack[#stack] = nil  -- pop name

    if #stack == 0 then
        -- Put the name back and raise error
        stack[#stack + 1] = ref_name
        error("Cannot leave a header node: not enough elements in path")
    end

    local ref_label = stack[#stack]
    stack[#stack] = nil  -- pop label

    -- Verify
    if ref_name ~= name or ref_label ~= label then
        local msgs = {}
        if ref_name ~= name then
            msgs[#msgs + 1] = string.format("Expected name '%s', but got '%s'", name, ref_name)
        end
        if ref_label ~= label then
            msgs[#msgs + 1] = string.format("Expected label '%s', but got '%s'", label, ref_label)
        end
        error(table.concat(msgs, ", "))
    end
end

--- Add a link node at the current path
--- @param link_name string  Link name
function Construct_KB:add_link_node(link_name)
    self._kb:add_link(self.working_kb, join_path(self.path[self.working_kb]), link_name)
end

--- Add a link mount at the current path
--- @param link_mount_name string  Link mount name
--- @param description     string? Optional description
function Construct_KB:add_link_mount(link_mount_name, description)
    description = description or ""
    self._kb:add_link_mount(self.working_kb, join_path(self.path[self.working_kb]),
        link_mount_name, description)
end

--- Check that all knowledge bases have been properly closed (path stack = just kb_name)
--- @return boolean  true if check passed
function Construct_KB:check_installation()
    for kb_name, stack in pairs(self.path) do
        if #stack ~= 1 then
            error(string.format(
                "Installation check failed: Path is not empty for knowledge base %s. Path: {%s}",
                kb_name, join_path(stack)))
        end
        if stack[1] ~= kb_name then
            error(string.format(
                "Installation check failed: Path is not empty for knowledge base %s. Path: {%s}",
                kb_name, join_path(stack)))
        end
    end
    return true
end

-- ============================================================
-- Module export
-- ============================================================
return Construct_KB

