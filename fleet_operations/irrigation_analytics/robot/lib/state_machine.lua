-- state_machine.lua — popup → state.
--
-- Pure function: takes the popup dict + manual_suspend flag, returns one of:
--   SUSPENDED_MANUAL
--   SUSPENDED_CLEAN_FILTER
--   SUSPENDED_RESISTANCE
--   ACTIVE_RUN
--   MASTER_IDLE_CHECK
--   IDLE
--
-- No I/O. No side effects. Single function call.

local M = {}

M.states = {
    SUSPENDED_MANUAL       = "SUSPENDED_MANUAL",
    SUSPENDED_CLEAN_FILTER = "SUSPENDED_CLEAN_FILTER",
    SUSPENDED_RESISTANCE   = "SUSPENDED_RESISTANCE",
    ACTIVE_RUN             = "ACTIVE_RUN",
    MASTER_IDLE_CHECK      = "MASTER_IDLE_CHECK",
    IDLE                   = "IDLE",
}

local function truthy(v)
    if v == true then return true end
    if v == "true" or v == "True" or v == "TRUE" then return true end
    return false
end

function M.classify(popup, manual_suspend)
    if manual_suspend then
        return M.states.SUSPENDED_MANUAL
    end
    local sched = popup and popup.SCHEDULE_NAME or "OFFLINE"
    if sched == "CLEAN_FILTER" then
        return M.states.SUSPENDED_CLEAN_FILTER
    elseif sched == "RESISTANCE_CHECK" then
        return M.states.SUSPENDED_RESISTANCE
    elseif sched ~= "OFFLINE" then
        return M.states.ACTIVE_RUN
    elseif truthy(popup and popup.MASTER_VALVE) then
        return M.states.MASTER_IDLE_CHECK
    else
        return M.states.IDLE
    end
end

-- Edge detection. Returns a list of edge names firing on this transition.
-- Used by main.lua to enable KB2 chains and similar one-shots.
function M.edges(prev_state, cur_state)
    local list = {}
    if prev_state == cur_state then return list end
    -- KB2 trigger: fire whenever we LEAVE RESISTANCE for any non-RESISTANCE
    -- state. The controller chains RESISTANCE → CLEAN_FILTER routinely, and
    -- the valve_test data is final the moment resistance ends — so we must
    -- run KB2 even when the next state is CLEAN_FILTER. Operator-triggered
    -- SUSPENDED_MANUAL during a resistance cycle is rare; if it happens,
    -- firing KB2 with the data we have is still the right call.
    if prev_state == M.states.SUSPENDED_RESISTANCE
       and cur_state ~= M.states.SUSPENDED_RESISTANCE then
        list[#list+1] = "KB2_RUN_RESISTANCE_ANALYSIS"
    end
    list[#list+1] = string.format("%s_TO_%s", prev_state or "INIT", cur_state)
    return list
end

return M
