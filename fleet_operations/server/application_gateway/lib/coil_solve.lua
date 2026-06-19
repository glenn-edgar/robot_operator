-- lib/coil_solve.lua — per-coil current decomposition by weighted least-squares.
--
-- IRRIGATION_CURRENT is a SUM: every run draws the always-on master (1:43,
-- implicit) plus the 1-3 pair members listed in the bin key (1:39 is a normal
-- member). So one run is a linear equation:
--     hold(run) = I_master + Σ I_coil   over the pair members
-- Each valve appears across many different pairs, so the whole set of runs is
-- an over-determined linear system we solve once for every coil AND the master.
--
-- This cleanly removes the master, handles 1/2/3-valve groups, and yields a true
-- per-coil current. Unconnected valves and bad-wiring artifacts solve to ~0 A
-- (natural null points that confirm the fit's calibration); real coils ~0.26 A.
--
-- Pure Lua (normal equations + Gaussian elimination with partial pivoting);
-- the system is small (~40 unknowns) so this is cheap at render time.

local M = {}

-- eqs: array of { members = {valve,...}, b = hold_amps, w = weight (e.g. n runs) }
-- returns: master (number), coil (map valve->amps), ok (bool), rms (residual)
function M.solve(eqs)
    if type(eqs) ~= "table" or #eqs == 0 then return nil, nil, false end

    -- index valves; master is the final column
    local idx, valves = {}, {}
    for _, e in ipairs(eqs) do
        for _, v in ipairs(e.members or {}) do
            if not idx[v] then valves[#valves + 1] = v; idx[v] = #valves end
        end
    end
    local nv = #valves
    local N = nv + 1            -- + master
    local MASTER = N

    -- normal equations: (A^T W A) x = A^T W b, built sparsely
    local ATA, ATb = {}, {}
    for i = 1, N do
        ATA[i] = {}
        for j = 1, N do ATA[i][j] = 0 end
        ATb[i] = 0
    end
    for _, e in ipairs(eqs) do
        local w = e.w or 1
        local cols = {}
        for _, v in ipairs(e.members or {}) do cols[#cols + 1] = idx[v] end
        cols[#cols + 1] = MASTER
        for _, i in ipairs(cols) do
            ATb[i] = ATb[i] + w * e.b
            for _, j in ipairs(cols) do
                ATA[i][j] = ATA[i][j] + w
            end
        end
    end

    -- augmented Gaussian elimination with partial pivoting
    local A = {}
    for i = 1, N do
        A[i] = {}
        for j = 1, N do A[i][j] = ATA[i][j] end
        A[i][N + 1] = ATb[i]
    end
    for c = 1, N do
        local p, best = c, math.abs(A[c][c])
        for r = c + 1, N do
            local a = math.abs(A[r][c])
            if a > best then best, p = a, r end
        end
        if best < 1e-12 then
            -- singular column (e.g. a valve that never varies) — leave at 0
        else
            A[c], A[p] = A[p], A[c]
            local pv = A[c][c]
            for r = 1, N do
                if r ~= c and A[r][c] ~= 0 then
                    local f = A[r][c] / pv
                    for k = c, N + 1 do A[r][k] = A[r][k] - f * A[c][k] end
                end
            end
        end
    end

    local x = {}
    for r = 1, N do
        x[r] = (A[r][r] ~= 0) and (A[r][N + 1] / A[r][r]) or 0
    end

    local coil = {}
    for v, i in pairs(idx) do coil[v] = x[i] end
    local master = x[MASTER]

    -- residual RMS for a fit-quality readout
    local sse, cnt = 0, 0
    for _, e in ipairs(eqs) do
        local pred = master
        for _, v in ipairs(e.members or {}) do pred = pred + (coil[v] or 0) end
        local d = e.b - pred
        sse = sse + d * d; cnt = cnt + 1
    end
    local rms = cnt > 0 and math.sqrt(sse / cnt) or 0

    return master, coil, true, rms
end

return M
