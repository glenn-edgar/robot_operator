-- ct_definitions.lua — constants for the dictionary-based ChainTree runtime

local M = {}

-- Main function return codes (strings, Python-style)
M.CFL_CONTINUE         = "CFL_CONTINUE"
M.CFL_HALT             = "CFL_HALT"
M.CFL_TERMINATE        = "CFL_TERMINATE"
M.CFL_RESET            = "CFL_RESET"
M.CFL_DISABLE          = "CFL_DISABLE"
M.CFL_SKIP_CONTINUE    = "CFL_SKIP_CONTINUE"
M.CFL_TERMINATE_SYSTEM = "CFL_TERMINATE_SYSTEM"

-- Walker control codes
M.CT_CONTINUE      = true
M.CT_SKIP_CHILDREN = "SKIP_CHILDREN"
M.CT_STOP_SIBLINGS = "STOP_SIBLINGS"
M.CT_STOP_BRANCH   = "STOP_BRANCH"
M.CT_STOP_ALL      = "STOP_ALL"

-- System event IDs (integers, matching event_string_table in JSON IR)
M.CFL_INIT_EVENT                    = 0
M.CFL_TERMINATE_EVENT               = 1
M.CFL_START_TESTS                   = 2
M.CFL_TERMINATE_TESTS               = 3
M.CFL_TIMER_EVENT                   = 4
M.CFL_SECOND_EVENT                  = 5
M.CFL_MINUTE_EVENT                  = 6
M.CFL_HOUR_EVENT                    = 7
M.CFL_DAY_EVENT                     = 8
M.CFL_WEEK_EVENT                    = 9
M.CFL_MONTH_EVENT                   = 10
M.CFL_YEAR_EVENT                    = 11
M.CFL_RAISE_EXCEPTION_EVENT         = 12
M.CFL_TURN_HEARTBEAT_ON_EVENT       = 13
M.CFL_TURN_HEARTBEAT_OFF_EVENT      = 14
M.CFL_HEARTBEAT_EVENT               = 15
M.CFL_SET_EXCEPTION_STEP_EVENT      = 16
M.CFL_CHANGE_STATE_EVENT            = 17
M.CFL_RESET_STATE_MACHINE_EVENT     = 18
M.CFL_TERMINATE_STATE_MACHINE_EVENT = 19

-- Event priorities
M.CFL_EVENT_PRIORITY_LOW  = "low"
M.CFL_EVENT_PRIORITY_HIGH = "high"

return M
