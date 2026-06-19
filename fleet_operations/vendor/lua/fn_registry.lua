-- fn_registry.lua -- Function registration (no cjson dependency)
--
-- Extracted from ct_loader.lua: register_functions and validate.
-- Used when building handle_data programmatically via tree_builder
-- instead of loading from JSON.

local M = {}

function M.register_functions(handle_data, ...)
  local merged = {}
  for _, reg in ipairs({...}) do
    if reg.main then
      for name, fn in pairs(reg.main) do
        merged[name:upper()] = { fn = fn, slot = "main" }
      end
    end
    if reg.one_shot then
      for name, fn in pairs(reg.one_shot) do
        merged[name:upper()] = { fn = fn, slot = "one_shot" }
      end
    end
    if reg.boolean then
      for name, fn in pairs(reg.boolean) do
        merged[name:upper()] = { fn = fn, slot = "boolean" }
      end
    end
  end

  for name in pairs(handle_data.main_names) do
    local entry = merged[name:upper()]
    if entry and entry.fn then
      handle_data.main_functions[name] = entry.fn
    end
  end
  for name in pairs(handle_data.oneshot_names) do
    local entry = merged[name:upper()]
    if entry and entry.fn then
      handle_data.one_shot_functions[name] = entry.fn
    end
  end
  for name in pairs(handle_data.boolean_names) do
    local entry = merged[name:upper()]
    if entry and entry.fn then
      handle_data.boolean_functions[name] = entry.fn
    end
  end

  -- Also register functions not in name sets
  for uname, entry in pairs(merged) do
    if entry.fn then
      if entry.slot == "main" and not handle_data.main_functions[uname] then
        handle_data.main_functions[uname] = entry.fn
      elseif entry.slot == "one_shot" and not handle_data.one_shot_functions[uname] then
        handle_data.one_shot_functions[uname] = entry.fn
      elseif entry.slot == "boolean" and not handle_data.boolean_functions[uname] then
        handle_data.boolean_functions[uname] = entry.fn
      end
    end
  end
end

function M.validate(handle_data)
  local missing = {}
  for name in pairs(handle_data.main_names) do
    if not handle_data.main_functions[name] then
      missing[#missing + 1] = "main:" .. name
    end
  end
  for name in pairs(handle_data.oneshot_names) do
    if not handle_data.one_shot_functions[name] then
      missing[#missing + 1] = "one_shot:" .. name
    end
  end
  for name in pairs(handle_data.boolean_names) do
    if not handle_data.boolean_functions[name] then
      missing[#missing + 1] = "boolean:" .. name
    end
  end
  if #missing > 0 then
    return false, missing
  end
  return true, {}
end

return M
