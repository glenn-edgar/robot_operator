--[[
  bit_s_expression.lua — LuaJIT port of bit_s_expression.py

  KB_BIT_DATA data class and S-expression evaluator for flag operations.

  S-expression syntax:  (operator user_name:flag_name ...)
  Operators: bit_changed, and, or, if, cond

  Usage:
    local bse = require('bit_s_expression')

    -- Create data
    local data = bse.KB_BIT_DATA.new({
        user_name   = 'sensor1',
        flag_data   = { temp_high = 1, pressure_ok = 0 },
        flag_change = { temp_high = true, pressure_ok = false },
    })

    -- Evaluate
    local proc = bse.SExpressionProcessor.new()
    local result = proc:execute("(and sensor1:temp_high sensor1:pressure_ok)",
                                { sensor1 = data })
]]

local bit = require('bit')

-- ═══════════════════════════════════════════════════════════════════════
-- KB_BIT_DATA  (dataclass equivalent)
-- ═══════════════════════════════════════════════════════════════════════

local KB_BIT_DATA = {}
KB_BIT_DATA.__index = KB_BIT_DATA

--- Create a new KB_BIT_DATA instance.
-- @param opts table (all fields optional):
--   user_name   (string)
--   bit_size    (int, default 1)
--   flags       (dict)   raw flag definitions from KB properties
--   flags_mask  (dict)   flag_name → integer bitmask
--   flag_data   (dict)   flag_name → 0|1  current values
--   flag_change (dict)   flag_name → bool  changed since last read
--   bit_mask    (int)    raw integer mask from DB
--   node_id     (string) bit_mask_table record_id
function KB_BIT_DATA.new(opts)
    opts = opts or {}
    local self = setmetatable({}, KB_BIT_DATA)
    self.user_name   = opts.user_name   or ''
    self.bit_size    = opts.bit_size    or 1
    self.flags       = opts.flags       or {}
    self.flags_mask  = opts.flags_mask  or {}
    self.flag_data   = opts.flag_data   or {}
    self.flag_change = opts.flag_change or {}
    self.bit_mask    = opts.bit_mask    or 0
    self.node_id     = opts.node_id     or ''
    return self
end

-- ═══════════════════════════════════════════════════════════════════════
-- Token types and Token
-- ═══════════════════════════════════════════════════════════════════════

local TokenType = {
    LPAREN    = 'LPAREN',
    RPAREN    = 'RPAREN',
    OPERATOR  = 'OPERATOR',
    REFERENCE = 'REFERENCE',
    KEYWORD   = 'KEYWORD',
}

local function Token(ttype, value)
    return { type = ttype, value = value }
end

-- ═══════════════════════════════════════════════════════════════════════
-- AST node types
-- ═══════════════════════════════════════════════════════════════════════

local function SExpNode(operator, operands)
    return { tag = 'SExpNode', operator = operator, operands = operands }
end

local function PlainList(items)
    return { tag = 'PlainList', items = items }
end

-- ═══════════════════════════════════════════════════════════════════════
-- SExpressionProcessor
-- ═══════════════════════════════════════════════════════════════════════

local VALID_OPERATORS = {
    bit_changed = true, ['and'] = true, ['or'] = true,
    ['if'] = true, cond = true,
}
local KEYWORDS = { ['else'] = true }

local SExpressionProcessor = {}
SExpressionProcessor.__index = SExpressionProcessor

function SExpressionProcessor.new()
    local self = setmetatable({}, SExpressionProcessor)
    self.tokens   = {}
    self.position = 0
    return self
end

--- Tokenize an S-expression string.
-- @return list of Token tables
function SExpressionProcessor:tokenize(s_expr)
    local tokens = {}
    local i = 1
    s_expr = s_expr:match('^%s*(.-)%s*$')  -- trim
    local len = #s_expr

    while i <= len do
        local ch = s_expr:sub(i, i)

        -- Skip whitespace
        if ch:match('%s') then
            i = i + 1

        -- Parentheses
        elseif ch == '(' then
            tokens[#tokens + 1] = Token(TokenType.LPAREN, '(')
            i = i + 1
        elseif ch == ')' then
            tokens[#tokens + 1] = Token(TokenType.RPAREN, ')')
            i = i + 1

        -- Symbol
        else
            local start = i
            while i <= len and not s_expr:sub(i, i):match('[%s%(%)]') do
                i = i + 1
            end
            local symbol = s_expr:sub(start, i - 1)

            if VALID_OPERATORS[symbol] then
                tokens[#tokens + 1] = Token(TokenType.OPERATOR, symbol)
            elseif KEYWORDS[symbol] then
                tokens[#tokens + 1] = Token(TokenType.KEYWORD, symbol)
            elseif symbol:find(':', 1, true) then
                tokens[#tokens + 1] = Token(TokenType.REFERENCE, symbol)
            else
                error(string.format(
                    "Invalid symbol: '%s'. Must be an operator, keyword, "
                    .. "or user_name:flag_name reference.", symbol))
            end
        end
    end
    return tokens
end

--- Parse a token list into an AST.
function SExpressionProcessor:_parse_tokens(tokens)
    self.tokens   = tokens
    self.position = 1  -- Lua 1-based
    return self:_parse_expression()
end

function SExpressionProcessor:_parse_expression()
    if self.position > #self.tokens then
        error("Unexpected end of expression")
    end

    local tok = self.tokens[self.position]

    if tok.type == TokenType.LPAREN then
        self.position = self.position + 1
        if self.position > #self.tokens then
            error("Expected content after '('")
        end

        local next_tok = self.tokens[self.position]

        if next_tok.type == TokenType.OPERATOR then
            -- (operator operand ...)
            local op = next_tok.value
            self.position = self.position + 1
            local operands = {}
            while self.position <= #self.tokens
                  and self.tokens[self.position].type ~= TokenType.RPAREN do
                operands[#operands + 1] = self:_parse_expression()
            end
            if self.position > #self.tokens then
                error("Missing closing parenthesis")
            end
            self.position = self.position + 1  -- consume RPAREN
            return SExpNode(op, operands)
        else
            -- Plain list
            local items = {}
            while self.position <= #self.tokens
                  and self.tokens[self.position].type ~= TokenType.RPAREN do
                items[#items + 1] = self:_parse_expression()
            end
            if self.position > #self.tokens then
                error("Missing closing parenthesis")
            end
            self.position = self.position + 1
            return PlainList(items)
        end

    elseif tok.type == TokenType.REFERENCE then
        self.position = self.position + 1
        return tok.value

    elseif tok.type == TokenType.KEYWORD then
        self.position = self.position + 1
        return tok.value

    else
        error("Unexpected token: " .. tok.value)
    end
end

--- Execute an S-expression (string or token list) against kb_data.
-- @param s_expr  string or token list
-- @param kb_data dict mapping user_name → KB_BIT_DATA
-- @return boolean
function SExpressionProcessor:execute(s_expr, kb_data)
    local tokens
    if type(s_expr) == 'string' then
        tokens = self:tokenize(s_expr)
    else
        tokens = s_expr
    end
    local tree = self:_parse_tokens(tokens)
    return self:_evaluate(tree, kb_data)
end

--- Recursive evaluator.
function SExpressionProcessor:_evaluate(node, kb_data)
    -- Plain list in wrong context
    if type(node) == 'table' and node.tag == 'PlainList' then
        error("Plain list used in invalid context")
    end

    -- Leaf reference string
    if type(node) == 'string' then
        if KEYWORDS[node] then
            error(string.format("Keyword '%s' used in invalid context", node))
        end
        return self:_lookup_reference(node, kb_data, true, false)
    end

    -- Operator node
    local op       = node.operator
    local operands = node.operands

    if op == 'bit_changed' then
        for _, operand in ipairs(operands) do
            if not self:_check_bit_changed(operand, kb_data) then
                return false
            end
        end
        return true

    elseif op == 'and' then
        for _, operand in ipairs(operands) do
            if not self:_evaluate(operand, kb_data) then
                return false
            end
        end
        return true

    elseif op == 'or' then
        for _, operand in ipairs(operands) do
            if self:_evaluate(operand, kb_data) then
                return true
            end
        end
        return false

    elseif op == 'if' then
        if #operands ~= 3 then
            error(string.format(
                "'if' requires exactly 3 operands (condition, then, else), got %d",
                #operands))
        end
        if self:_evaluate(operands[1], kb_data) then
            return self:_evaluate(operands[2], kb_data)
        else
            return self:_evaluate(operands[3], kb_data)
        end

    elseif op == 'cond' then
        for _, operand in ipairs(operands) do
            if type(operand) ~= 'table' or operand.tag ~= 'PlainList' then
                error("'cond' clauses must be lists")
            end
            if #operand.items ~= 2 then
                error(string.format(
                    "'cond' clause must have 2 elements (test, expression), got %d",
                    #operand.items))
            end
            local test = operand.items[1]
            local expr = operand.items[2]

            -- else clause
            if type(test) == 'string' and test == 'else' then
                return self:_evaluate(expr, kb_data)
            end

            if self:_evaluate(test, kb_data) then
                return self:_evaluate(expr, kb_data)
            end
        end
        error("'cond' expression: no conditions matched and no 'else' clause provided")

    else
        error("Unknown operator: " .. tostring(op))
    end
end

function SExpressionProcessor:_check_bit_changed(operand, kb_data)
    if type(operand) == 'string' then
        return self:_lookup_reference(operand, kb_data, false, true)
    elseif type(operand) == 'table' and operand.tag == 'PlainList' then
        error("Plain list used in bit_changed context")
    else
        return self:_evaluate(operand, kb_data)
    end
end

--- Look up user_name:flag_name in kb_data.
-- @param need_value  if true, return flag_data[flag] == 1
-- @param need_change if true, return flag_change[flag]
function SExpressionProcessor:_lookup_reference(reference, kb_data, need_value, need_change)
    if not reference:find(':', 1, true) then
        error(string.format(
            "Invalid reference format: '%s'. Expected 'user_name:flag_name'",
            reference))
    end

    local user_name, flag_name = reference:match('^([^:]+):(.+)$')

    if not kb_data[user_name] then
        error(string.format("User '%s' not found in KB data", user_name))
    end

    local entry = kb_data[user_name]

    if need_change then
        if entry.flag_change[flag_name] == nil then
            error(string.format(
                "Flag '%s' not found in flag_change for user '%s'",
                flag_name, user_name))
        end
        return entry.flag_change[flag_name]
    end

    if need_value then
        if entry.flag_data[flag_name] == nil then
            error(string.format(
                "Flag '%s' not found in flag_data for user '%s'",
                flag_name, user_name))
        end
        return entry.flag_data[flag_name] == 1
    end

    -- default: flag_data value
    if entry.flag_data[flag_name] == nil then
        error(string.format(
            "Flag '%s' not found in flag_data for user '%s'",
            flag_name, user_name))
    end
    return entry.flag_data[flag_name] == 1
end

-- ═══════════════════════════════════════════════════════════════════════
-- Module exports
-- ═══════════════════════════════════════════════════════════════════════

return {
    KB_BIT_DATA          = KB_BIT_DATA,
    TokenType            = TokenType,
    Token                = Token,
    SExpNode             = SExpNode,
    PlainList            = PlainList,
    SExpressionProcessor = SExpressionProcessor,
}