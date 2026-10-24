-- ddbridge.lua  v1.89.82  (Dragon's Dogma 2 / REFramework)
-- Command bridge for the Arisen's Toolbox companion app.
-- Install: <DD2 folder>\reframework\autorun\ddbridge.lua
-- The app writes a command to reframework\data\ddbridge\cmd.txt, this script runs it
-- INSIDE the game through REFramework and writes the answer to resp.txt (big lists go to items.txt).
-- Only the fixed commands listed in COMMANDS below are accepted - it never runs text as code.

local TAG = "[ddbridge] "
local DIR = "ddbridge/"
local NAMES_FILE = "dd2_item_names.txt"

-- Unique per game process. Commands must carry this token, so a cmd.txt left
-- over from a previous session is rejected instead of being executed again.
local BOOT = string.format("%d-%s", os.time(),
  (tostring({}):match("0x(%x+)") or "0"))


local function try(f, ...) local ok, r = pcall(f, ...) if ok then return r end return nil end
local function tname(o)
  local td = try(function() return o:get_type_definition() end)
  return td and td:get_full_name() or ""
end

---------------------------------------------------------------- file helpers
local function rd(path)
  if fs and fs.read then
    local ok, r = pcall(fs.read, path)
    if ok and type(r) == "string" then return r end
  end
  local ok, f = pcall(io.open, "reframework/data/" .. path, "r")
  if ok and f then local t = f:read("*a") f:close() return t end
  return nil
end

local function wr(path, text)
  if fs and fs.write then
    local ok = pcall(fs.write, path, text)
    if ok then return true end
  end
  local ok, f = pcall(io.open, "reframework/data/" .. path, "w")
  if ok and f then f:write(text) f:close() return true end
  return false
end

local function split(s, sep)
  local t = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do t[#t + 1] = part end
  return t
end

-- Write a complete response. The |END sentinel lets the client reject a
-- partial read, and the temp+rename keeps resp.txt whole whenever possible.
local function write_resp(id, ok, res)
  local body = id .. "|" .. (ok and "OK" or "ERR") .. "|" ..
    tostring(res):gsub("[\r\n]+", " ") .. "|END"
  local tmp = DIR .. "resp.tmp"
  if wr(tmp, body) then
    local src = "reframework/data/" .. tmp
    local dst = "reframework/data/" .. DIR .. "resp.txt"
    pcall(os.remove, dst)
    if pcall(os.rename, src, dst) then return true end
  end
  -- os.rename is unavailable/blocked on some setups: the sentinel still
  -- makes a partial response detectable by the client.
  return wr(DIR .. "resp.txt", body)
end

local function elems_of(arr)
  local t = try(function() return arr:get_elements() end)
  if t then return t end
  local n = try(function() return arr:call("get_Length") end)
      or try(function() return arr:call("get_Count") end) or 0
  t = {}
  for i = 0, n - 1 do
    t[#t + 1] = try(function() return arr:call("GetValue", i) end)
        or try(function() return arr:call("get_Item", i) end)
  end
  return t
end

local function find_method(td, name, ptypes)
  if not td then return nil end
  for _, m in ipairs(td:get_methods()) do
    if m:get_name() == name then
      local types = try(function() return m:get_param_types() end)
      if types and #types == #ptypes then
        local match = true
        for i, t in ipairs(types) do
          if t:get_full_name() ~= ptypes[i] then match = false break end
        end
        if match then return m end
      end
    end
  end
  return nil
end

---------------------------------------------------------------- items
local function load_names()
  local names = {}
  local text = rd(NAMES_FILE)
  if text then
    for id, name in text:gmatch('(%d+)[^%d:]*:%s*"([^"]*)"') do names[tonumber(id)] = name end
  end
  return names
end

local function build_items()
  local itemmgr = sdk.get_managed_singleton("app.ItemManager")
  if not itemmgr then error("ItemManager not available (load into the game first)") end
  local names = load_names()
  local items = {}
  local function add(id, r)
    local name = names[id]
    if not name then
      local n = try(function() return r:call("get_Name") end)
      if type(n) == "string" and n ~= "" then name = n end
    end
    items[#items + 1] = { id = id, name = (name or "(unnamed)"):gsub("[\t\r\n]", " ") }
  end
  local dict = try(function() return itemmgr:get_field("_ItemDataDict") end)
  if dict then
    local entries = try(function() return dict:get_field("_entries") end)
    local count = try(function() return dict:get_field("_count") end) or 0
    if entries then
      local els = elems_of(entries)
      for i = 1, math.min(count, #els) do
        local e = els[i]
        local id = try(function() return e:get_field("key") end)
        local r = try(function() return e:get_field("value") end)
        if type(id) == "number" and type(r) == "userdata" then add(id, r) end
      end
    end
  end
  if #items == 0 then
    local m = find_method(sdk.find_type_definition("app.ItemManager"), "getItemData", { "System.Int32" })
    if not m then error("item table unreadable and getItemData not found") end
    for id = 0, 40000 do
      local r = try(function() return m:call(itemmgr, id) end)
      if type(r) == "userdata" then add(id, r) end
    end
  end
  table.sort(items, function(a, b) return a.id < b.id end)
  local lines = {}
  for _, it in ipairs(items) do lines[#lines + 1] = it.id .. "\t" .. it.name end
  if not wr(DIR .. "items.txt", table.concat(lines, "\n")) then error("could not write items.txt") end
  return #items
end

local function give_item(id, qty, to_storage)
  local itemmgr = sdk.get_managed_singleton("app.ItemManager")
  if not itemmgr then error("ItemManager not available") end
  local td = sdk.find_type_definition("app.ItemManager")
  if to_storage then
    local m = find_method(td, "forceGetItemToWarehouse", { "System.Int32", "System.Int32" })
    if not m then error("forceGetItemToWarehouse not found") end
    m:call(itemmgr, id, qty)
    return "sent to storage"
  end
  local cm = sdk.get_managed_singleton("app.CharacterManager")
  local player = cm and try(function() return cm:call("get_ManualPlayer") end)
  if not player then error("player not found") end
  local m = find_method(td, "getItem", { "System.Int32", "System.Int32", "app.Character" })
  if not m then error("getItem not found") end
  m:call(itemmgr, id, qty, player)
  return "given"
end

---------------------------------------------------------------- main pawn contexts
-- v1.3: "the pawn" every pawn command works on = the one picked with select_pawn (default: main pawn)
local PW = { list = {}, sel = nil }

local function current_pawn(pm)
  if PW.sel then
    local e = PW.list[PW.sel]
    if e and try(function() return e.src:get_address() end) then return e.src end
  end
  return try(function() return pm:call("get_MainPawn") end)
end

local function human_from(o)
  local t = tname(o)
  if t == "app.Human" then return o end
  if t == "app.Character" then return try(function() return o:call("get_Human") end) end
end

local function find_human(pawn)
  for _, n in ipairs({ "get_Human", "get_Chara", "get_Character", "get_CachedCharacter" }) do
    local o = try(function() return pawn:call(n) end)
    if type(o) == "userdata" then
      local h = human_from(o)
      if h then return h end
    end
  end
  for _, m in ipairs(pawn:get_type_definition():get_methods() or {}) do
    local n = m:get_name()
    if n:sub(1, 4) == "get_" and #(m:get_param_types() or {}) == 0 then
      local o = try(function() return pawn:call(n) end)
      if type(o) == "userdata" then
        local h = human_from(o)
        if h then return h end
      end
    end
  end
end

local function find_context(human, typename)
  local holder = try(function() return human:call("get_Context") end)
  local dict = holder and (try(function() return holder:get_field("Contexts") end)
      or try(function() return holder:call("get_Contexts") end))
  local entries = dict and try(function() return dict:get_field("_entries"):get_elements() end)
  for _, e in ipairs(entries or {}) do
    local val = try(function() return e:get_field("value") end)
    if type(val) == "userdata" then
      local cur = try(function() return val:get_field("<CurrentContext>k__BackingField") end)
          or try(function() return val:call("get_CurrentContext") end)
      if cur and tname(cur) == typename then return cur end
    end
  end
end

local function pawn_ctx()
  local pm = sdk.get_managed_singleton("app.PawnManager")
  if not pm then error("PawnManager not found (load into a save first)") end
  local pawn = current_pawn(pm)
  if not pawn then error("no pawn selected / no main pawn") end
  local h = find_human(pawn)
  if not h then error("could not find the selected pawn's Human") end
  return {
    pm = pm, human = h,
    pdata = try(function() return h:call("get_PawnDataContext") end),
    counts = find_context(h, "app.PawnCountDataContext"),
  }
end

local function enum_by_val(typename)
  local t = {}
  local td = sdk.find_type_definition(typename)
  for _, f in ipairs(td and td:get_fields() or {}) do
    if f:is_static() then
      local ok, v = pcall(f.get_data, f, nil)
      if ok and type(v) == "number" then t[v] = f:get_name() end
    end
  end
  return t
end

local function badge_quotas(pm)
  local q = {}
  local bd = try(function() return pm:call("get_PawnBadgeData") end) or try(function() return pm:get_field("_PawnBadgeData") end)
  local list = bd and (try(function() return bd:get_field("_DataList") end) or try(function() return bd:call("get_DataList") end))
  for _, e in ipairs(list and elems_of(list) or {}) do
    local id = try(function() return e:get_field("_ID") end)
    local c = try(function() return e:get_field("_Count") end)
    if id then q[id] = c end
  end
  return q
end

local function toint(v) return (math.tointeger and math.tointeger(v)) or v end

---------------------------------------------------------------- commands
-- each command gets the argument list (strings) and returns a one-line string payload
local COMMANDS = {}

COMMANDS.ping = function() return "pong ddbridge 1.89.82 boot=" .. BOOT end

COMMANDS.list_items = function() return tostring(build_items()) end

COMMANDS.give_item = function(a)
  local id, qty, st = tonumber(a[1]), tonumber(a[2]), a[3] == "1"
  if not id or not qty or id < 1 or qty < 1 or qty > 9999 then
    error("bad arguments (need item id >= 1, qty 1-9999)")
  end
  return give_item(math.floor(id), math.floor(qty), st)
end

COMMANDS.get_rating = function()
  local c = pawn_ctx()
  if not c.pdata then error("PawnDataContext not found") end
  return tostring(c.pdata:call("get_GoodReviewNum")) .. "," .. tostring(c.pdata:call("get_LikeReviewNum"))
end

COMMANDS.set_rating = function(a)
  local good, like = tonumber(a[1]), tonumber(a[2])
  if not good or not like then error("bad arguments") end
  local c = pawn_ctx()
  if not c.pdata then error("PawnDataContext not found") end
  c.pdata:call("setGoodReviewNum", math.floor(good))
  c.pdata:call("setLikeReviewNum", math.floor(like))
  return "ok"
end

COMMANDS.get_badges = function()
  local c = pawn_ctx()
  if not c.counts then error("PawnCountDataContext not found") end
  local q = badge_quotas(c.pm)
  local names = enum_by_val("app.PawnDefine.BadgeID")
  local out = {}
  for n = 1, 50 do
    local cur = try(function() return c.counts:get_field(string.format("_PB%03dCount", n)) end)
    if type(cur) == "number" then
      local id = 2 ^ (n - 1)
      out[#out + 1] = string.format("%d,%d,%s,%s", n, cur, tostring(q[id] or "?"),
        tostring(names[id] or ("badge " .. n)):gsub("[,;|]", " "))
    end
  end
  return table.concat(out, ";")
end

COMMANDS.set_badge = function(a)
  local n, v = tonumber(a[1]), tonumber(a[2])
  if not n or not v or n < 1 or n > 50 or v < 0 then error("bad arguments") end
  local c = pawn_ctx()
  if not c.counts then error("PawnCountDataContext not found") end
  local f = string.format("_PB%03dCount", math.floor(n))
  if type(try(function() return c.counts:get_field(f) end)) ~= "number" then error("no field " .. f) end
  c.counts:set_field(f, math.floor(v))
  return "ok"
end

COMMANDS.fill_badges = function()
  local c = pawn_ctx()
  if not c.counts then error("PawnCountDataContext not found") end
  local q = badge_quotas(c.pm)
  local n_done = 0
  for n = 1, 50 do
    local f = string.format("_PB%03dCount", n)
    local cur = try(function() return c.counts:get_field(f) end)
    local quota = q[2 ^ (n - 1)]
    if type(cur) == "number" and quota then c.counts:set_field(f, quota) n_done = n_done + 1 end
  end
  return tostring(n_done)
end

-- Dump all fields of the first badge-data entry to find real badge names.
COMMANDS.badge_probe = function(a)
  local c = pawn_ctx()
  if not c.pm then error("pawn manager not found") end
  local bd = try(function() return c.pm:call("get_PawnBadgeData") end)
    or try(function() return c.pm:get_field("_PawnBadgeData") end)
  if not bd then error("PawnBadgeData not found") end
  local list = try(function() return bd:get_field("_DataList") end)
    or try(function() return bd:call("get_DataList") end)
  local elems = list and elems_of(list) or {}
  if #elems == 0 then error("badge data list empty") end
  local e = elems[1]
  local td = try(function() return e:get_type_definition() end)
  local tname = td and try(function() return td:get_full_name() end) or "?"
  local out = { "type=" .. tostring(tname), "entries=" .. tostring(#elems) }
  if td then
    for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
      local fn = try(function() return f:get_name() end) or "?"
      local v = try(function() return f:get_data(e) end)
      local vs
      if type(v) == "string" then vs = string.format("%q", v)
      elseif type(v) == "number" or type(v) == "boolean" then vs = tostring(v)
      elseif v == nil then vs = "nil"
      else
        local mt = try(function() return v:get_type_definition() end)
        vs = "<" .. tostring(mt and mt:get_full_name() or type(v)) .. ">"
      end
      if #vs > 120 then vs = vs:sub(1, 120) .. "..." end
      out[#out + 1] = "field " .. fn .. " = " .. vs
    end
    for _, m in ipairs(try(function() return td:get_methods() end) or {}) do
      local mn = try(function() return m:get_name() end) or ""
      local l = mn:lower()
      if l:find("name", 1, true) or l:find("message", 1, true)
         or l:find("text", 1, true) or l:find("label", 1, true)
         or l:find("title", 1, true) then
        out[#out + 1] = "method " .. mn
      end
    end
  end
  -- also dump every entry's ID + count for the PB mapping
  for i, en in ipairs(elems) do
    local id = try(function() return en:get_field("_ID") end)
    local co = try(function() return en:get_field("_Count") end)
    out[#out + 1] = string.format("entry %d: _ID=%s _Count=%s",
      i, tostring(id), tostring(co))
    if i >= 60 then break end
  end
  return table.concat(out, "\n"):gsub("[\r\n]+", " | ")
end

-- Dump PawnBadgeData's own fields + hunt for badge name tables.
COMMANDS.badge_probe2 = function(a)
  local c = pawn_ctx()
  if not c.pm then error("pawn manager not found") end
  local out = {}
  local bd = try(function() return c.pm:call("get_PawnBadgeData") end)
    or try(function() return c.pm:get_field("_PawnBadgeData") end)
  if not bd then error("PawnBadgeData not found") end
  local td = try(function() return bd:get_type_definition() end)
  out[#out + 1] = "badgedata=" .. tostring(td and td:get_full_name())
  if td then
    for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
      local fn = try(function() return f:get_name() end) or "?"
      local v = try(function() return f:get_data(bd) end)
      local vs
      if type(v) == "string" then vs = string.format("%q", v)
      elseif type(v) == "number" or type(v) == "boolean" then vs = tostring(v)
      elseif v == nil then vs = "nil"
      else
        local mt = try(function() return v:get_type_definition() end)
        local mn = tostring(mt and mt:get_full_name() or type(v))
        -- peek into list-like values: count + first element type
        local cnt = try(function() return v:get_Count() end)
          or try(function() return #elems_of(v) end)
        vs = "<" .. mn .. (cnt and (" count=" .. tostring(cnt)) or "") .. ">"
      end
      if #vs > 160 then vs = vs:sub(1, 160) .. "..." end
      out[#out + 1] = "field " .. fn .. " = " .. vs
    end
  end
  -- hunt for other Badge-related types that might hold names
  local cands = { "app.PawnBadgeDefine", "app.PawnBadgeData.BadgeData",
    "app.PawnDefine", "app.BadgeDefine", "app.PawnBadgeManager" }
  for _, tn in ipairs(cands) do
    local t2 = try(function() return sdk.find_type_definition(tn) end)
    if t2 then
      local fns = {}
      for _, f in ipairs(try(function() return t2:get_fields() end) or {}) do
        fns[#fns + 1] = try(function() return f:get_name() end) or "?"
        if #fns >= 25 then break end
      end
      out[#out + 1] = "type " .. tn .. " fields: " .. table.concat(fns, ",")
    else
      out[#out + 1] = "type " .. tn .. " NOT FOUND"
    end
  end
  return table.concat(out, " | ")
end

-- Dump app.PawnDefine.BadgeIDEnums entries and their fields.
COMMANDS.badge_probe3 = function(a)
  local out = {}
  local pd = try(function() return sdk.find_type_definition("app.PawnDefine") end)
  if not pd then error("app.PawnDefine not found") end
  -- BadgeIDEnums may be static; try both static and instance access
  local benums = try(function() return pd:get_field("BadgeIDEnums"):get_data(nil) end)
    or try(function()
      local f = pd:get_field("BadgeIDEnums")
      return f:get_data(nil)
    end)
  if benums == nil then
    -- try via a managed singleton or default object if any
    out[#out + 1] = "BadgeIDEnums static read = nil, trying harder..."
    local m = try(function() return pd:get_method("get_BadgeIDEnums") end)
    if m then out[#out + 1] = "get_BadgeIDEnums method exists" end
  end
  local bt = benums ~= nil and try(function() return benums:get_type_definition() end)
  out[#out + 1] = "BadgeIDEnums type=" .. tostring(bt and bt:get_full_name())
  local elems = benums ~= nil and elems_of(benums) or {}
  out[#out + 1] = "count=" .. tostring(#elems)
  for i, e in ipairs(elems) do
    local et = try(function() return e:get_type_definition() end)
    local parts = { "entry " .. i .. " type=" .. tostring(et and et:get_full_name()) }
    if et then
      for _, f in ipairs(try(function() return et:get_fields() end) or {}) do
        local fn = try(function() return f:get_name() end) or "?"
        local v = try(function() return f:get_data(e) end)
        local vs
        if type(v) == "string" then vs = string.format("%q", v)
        elseif type(v) == "number" or type(v) == "boolean" then vs = tostring(v)
        elseif v == nil then vs = "nil"
        else vs = "<" .. tostring(try(function()
          return v:get_type_definition():get_full_name() end) or type(v)) .. ">"
        end
        if #vs > 100 then vs = vs:sub(1, 100) .. "..." end
        parts[#parts + 1] = fn .. "=" .. vs
        if #parts > 12 then parts[#parts + 1] = "..."; break end
      end
    end
    out[#out + 1] = table.concat(parts, " ")
    if i >= 40 then out[#out + 1] = "... (truncated)"; break end
  end
  return table.concat(out, " | ")
end

COMMANDS.grant_badge = function(a)
  local n = tonumber(a[1])
  if not n or n < 1 or n > 50 then error("bad arguments") end
  local c = pawn_ctx()
  if not c.pdata then error("PawnDataContext not found") end
  c.pdata:call("addBadge", toint(2 ^ (math.floor(n) - 1)))
  return "ok"
end

---------------------------------------------------------------- v1.1 shared helpers
local function int(v)
  local n = tonumber(v)
  if not n then error("bad number: " .. tostring(v)) end
  return math.floor(n)
end

local function clean(s) return (tostring(s):gsub("[\t\r\n|;,]", " ")) end

local function fmt_int(v)
  return tostring((math.tointeger and math.tointeger(v)) or v)
end

local function dict_iter(d, fn)
  if not d then return end
  local entries = try(function() return d:get_field("_entries") end)
  local count = try(function() return d:get_field("_count") end) or 0
  if not entries then return end
  local els = elems_of(entries)
  for i = 1, math.min(count, #els) do
    local e = els[i]
    local k = try(function() return e:get_field("key") end)
    local v = try(function() return e:get_field("value") end)
    if v ~= nil and k ~= nil then fn(k, v) end
  end
end

-- overload-safe call: pick the method by name, parameter count and a substring of the 1st parameter type
local function call_ov(obj, name, first_sub, nparams, ...)
  local found
  for _, m in ipairs(obj:get_type_definition():get_methods() or {}) do
    if m:get_name() == name then
      local pts = m:get_param_types() or {}
      if #pts == nparams then
        local ok = true
        if first_sub then
          local n = try(function() return pts[1]:get_full_name() end) or ""
          if not n:find(first_sub, 1, true) or n:find("IEnumerable", 1, true) then ok = false end
        end
        if ok then found = m break end
      end
    end
  end
  if not found then error("method not found: " .. name) end
  return found:call(obj, ...)
end

local function follow(obj, path)
  for _, n in ipairs(path) do
    if type(obj) ~= "userdata" then return nil end
    obj = try(function() return obj:get_field(n) end)
  end
  return obj
end

local function enum_list(typename)
  local out = {}
  local td = sdk.find_type_definition(typename)
  for _, f in ipairs(td and td:get_fields() or {}) do
    if f:is_static() then
      local ok, v = pcall(f.get_data, f, nil)
      if ok and type(v) == "number" then out[#out + 1] = { name = f:get_name(), value = v } end
    end
  end
  table.sort(out, function(a, b) return a.value < b.value end)
  return out
end

local function job_of(name)
  local j = name:match("^Job(%d%d)_")
  return j and tonumber(j)
end

local ENUMS = {
  { "custom", "app.HumanCustomSkillID" },
  { "normal", "app.HumanNormalSkillID" },
  { "ability", "app.HumanAbilityID" },
  { "badge", "app.PawnDefine.BadgeID" },
  { "level", "app.HumanCustomSkillLevelNo" },
  { "equipskill", "app.EquipmentAbilityID" },
  { "enhance", "app.EnhanceType" },
}

---------------------------------------------------------------- v1.3 all pawns
local function coll_elems(c)
  local out = {}
  local items = try(function() return c:get_field("_items") end)
  if items then
    local size = try(function() return c:get_field("_size") end) or 0
    local els = elems_of(items)
    for i = 1, math.min(size, #els) do if els[i] ~= nil then out[#out + 1] = els[i] end end
    return out
  end
  if try(function() return c:get_field("_entries") end) then
    dict_iter(c, function(_, v) if type(v) == "userdata" then out[#out + 1] = v end end)
    return out
  end
  local t = try(function() return c:get_elements() end)
  if t then for _, e in ipairs(t) do if e ~= nil then out[#out + 1] = e end end end
  return out
end

local function pawn_label(e, is_main)
  local h = e.human
  local name
  for _, n in ipairs({ "get_Name", "get_PawnName", "get_CharaName" }) do
    name = try(function() return e.src:call(n) end) or try(function() return h:call(n) end)
    if type(name) == "string" and name ~= "" then break end
    name = nil
  end
  local st = try(function() return h:call("get_StatusContext") end)
  local jc = try(function() return h:call("get_JobContext") end)
  local lvl = st and try(function() return st:call("get_Level") end)
  local job = jc and try(function() return jc:call("get_Job") end)
  return clean(string.format("%s%s  Lv %s  job %s", is_main and "[MAIN] " or "", name or tname(e.src):gsub("^app%.", ""),
    tostring(lvl or "?"), tostring(job or "?")))
end

-- finds every pawn object reachable from PawnManager / CharacterManager collections; logs what it scanned
COMMANDS.list_pawns = function()
  local pm = sdk.get_managed_singleton("app.PawnManager")
  if not pm then error("PawnManager not found (load into a save first)") end
  local main = try(function() return pm:call("get_MainPawn") end)
  local main_addr = main and try(function() return main:get_address() end)
  local found, seen = {}, {}
  local function consider(e, where)
    if type(e) ~= "userdata" then return end
    local tn = tname(e)
    if not tn:find("Pawn", 1, true) then return end
    local h = try(function() return human_from(e) or find_human(e) end)
    if not h then return end
    local ha = try(function() return h:get_address() end)
    if ha and seen[ha] then return end
    if ha then seen[ha] = true end
    found[#found + 1] = { src = e, human = h, where = where, main = (main_addr ~= nil and try(function() return e:get_address() end) == main_addr) }
  end
  if main then consider(main, "get_MainPawn") end
  for _, sname in ipairs({ "app.PawnManager", "app.CharacterManager" }) do
    local mgr = sdk.get_managed_singleton(sname)
    local td = mgr and mgr:get_type_definition()
    while td do
      for _, f in ipairs(td:get_fields() or {}) do
        if not f:is_static() then
          local n = f:get_name()
          local v = try(function() return mgr:get_field(n) end)
          if type(v) == "userdata" then
            local tn = tname(v)
            if tn:find("List", 1, true) or tn:find("Dictionary", 1, true) or tn:find("[]", 1, true) or n:lower():find("pawn", 1, true) then
              local els = coll_elems(v)
              if #els > 0 then
                log.info(TAG .. "pawns: " .. sname .. " field " .. n .. " (" .. tn .. ") n=" .. #els .. " first=" .. tname(els[1]))
                for _, e in ipairs(els) do consider(e, sname .. "." .. n) end
              end
            end
          end
        end
      end
      for _, m in ipairs(td:get_methods() or {}) do
        local n = m:get_name()
        local ln = n:lower()
        if n:sub(1, 4) == "get_" and #(m:get_param_types() or {}) == 0 and ln:find("pawn", 1, true)
            and not ln:find("main", 1, true) then
          local v = try(function() return mgr:call(n) end)
          if type(v) == "userdata" then
            local tn = tname(v)
            local els = (tn:find("List", 1, true) or tn:find("Dictionary", 1, true) or tn:find("[]", 1, true)) and coll_elems(v) or { v }
            if #els > 0 then
              log.info(TAG .. "pawns: " .. sname .. " method " .. n .. " (" .. tn .. ") n=" .. #els .. " first=" .. tname(els[1]))
              for _, e in ipairs(els) do consider(e, sname .. "." .. n) end
            end
          end
        end
      end
      td = try(function() return td:get_parent_type() end)
    end
  end
  table.sort(found, function(x, y) return x.main and not y.main end)
  PW.list = found
  local out = {}
  for i, e in ipairs(found) do
    local lab = pawn_label(e, e.main)
    log.info(TAG .. "pawns: #" .. i .. " " .. lab .. " via " .. e.where)
    out[#out + 1] = i .. "," .. lab
  end
  if #found == 0 then error("no pawns found - see the [ddbridge] pawns lines in the REFramework log") end
  return table.concat(out, ";")
end

-- arg: index into the last list_pawns result (0 = main pawn). Every pawn command then targets that pawn.
COMMANDS.select_pawn = function(a)
  local i = int(a[1])
  if i == 0 then PW.sel = nil return "main pawn" end
  if not PW.list[i] then error("pawn not in the list - refresh the pawn list") end
  PW.sel = i
  return "selected pawn #" .. i
end

---------------------------------------------------------------- v1.1 target (main pawn or the player)
local hcache = {}

local function get_target(kind)
  local src
  if kind == "player" then
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then error("CharacterManager not found (load into the game first)") end
    for _, g in ipairs({ "get_ManualPlayer", "getManualPlayer", "get_ManualPlayerNoCheck" }) do
      src = try(function() return cm:call(g) end)
      if src then break end
    end
    if not src then error("player not found") end
  else
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then error("PawnManager not found (load into a save first)") end
    src = current_pawn(pm)
    if not src then error("no pawn selected / no main pawn") end
  end
  local addr = try(function() return src:get_address() end)
  local c = hcache[kind]
  if not (c and c.addr == addr and c.human) then
    c = { addr = addr, human = human_from(src) or find_human(src) }
    hcache[kind] = c
  end
  local h = c.human
  if not h then error("could not find the " .. tostring(kind) .. "'s Human") end
  local skill = try(function() return h:call("get_SkillContext") end)
  if not skill then hcache[kind] = nil error("SkillContext missing (character reloading?)") end
  return {
    kind = kind, src = src, human = h, skill = skill,
    ability = try(function() return h:call("get_AbilityContext") end),
    job = try(function() return h:call("get_JobContext") end),
    status = try(function() return h:call("get_StatusContext") end),
    pdata = try(function() return h:call("get_PawnDataContext") end),
    mdata = kind ~= "player" and try(function() return src:call("get_MainPawnDataContext") end) or nil,
  }
end

---------------------------------------------------------------- v1.36 name editing
-- Name contexts: chara:get_Context().Contexts[RuntimeType]:get_CurrentContext().
-- Arisen -> app.PlayerPersonalDataContext, getter get_NameProp.
-- Pawns  -> app.PawnDataContext, getter get_Name.
-- A renamed name only shows in-game when stamped with the current game
-- language (setLanguageOnEdit / LanguageOnEdit fields). Renames live in
-- memory until the game is saved and reloaded.

local function name_context_of(chara, type_name)
  if type(chara) ~= "userdata" then return nil end
  local holder = try(function() return chara:call("get_Context") end)
  if type(holder) ~= "userdata" then return nil end
  local info = try(function()
    local td = sdk.find_type_definition(type_name)
    return holder.Contexts[td:get_runtime_type()]
  end)
  if type(info) ~= "userdata" then
    info = try(function()
      local td = sdk.find_type_definition(type_name)
      return holder:call("get_Contexts"):call("get_Item", td:get_runtime_type())
    end)
  end
  if type(info) ~= "userdata" then return nil end
  return try(function() return info:call("get_CurrentContext") end)
end

local function arisen_name_ctx()
  local cm = sdk.get_managed_singleton("app.CharacterManager")
  local player = cm and try(function() return cm:call("get_ManualPlayer") end)
  return name_context_of(player, "app.PlayerPersonalDataContext")
end

local function pawn_name_ctx(chara, human)
  local ctx = name_context_of(chara, "app.PawnDataContext")
  if type(ctx) == "userdata" then return ctx end
  -- Fallback: the Human's PawnDataContext (probe-proven 2026-10-12).
  ctx = human and try(function() return human:call("get_PawnDataContext") end)
  if type(ctx) == "userdata" then return ctx end
  return try(function() return chara:call("get_PawnDataContext") end)
end

-- All non-static fields of a type and its parents.
local function all_fields(td)
  local list = {}
  while td do
    for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
      if not try(function() return f:is_static() end) then list[#list + 1] = f end
    end
    td = try(function() return td:get_parent_type() end)
  end
  return list
end

local function call_set(ctx, method, value)
  local td = try(function() return ctx:get_type_definition() end)
  if not (td and try(function() return td:get_method(method) end)) then return false end
  if try(function() ctx:call(method, value) return true end) then return true end
  return try(function() ctx:call(method, sdk.create_managed_string(value)) return true end) or false
end

local function language_of(ctx)
  for _, m in ipairs({ "get_LanguageOnEditProp", "get_LanguageOnEdit" }) do
    local v = try(function() return ctx:call(m) end)
    if v ~= nil then return v end
  end
  for _, n in ipairs({ "LanguageOnEdit", "_LanguageOnEdit" }) do
    local v = try(function() return ctx:get_field(n) end)
    if v ~= nil then return v end
  end
  return nil
end

local function stamp_language(ctx, value)
  if value == nil then return end
  call_set(ctx, "setLanguageOnEdit", value)
  for _, n in ipairs({ "LanguageOnEdit", "_LanguageOnEdit" }) do
    try(function()
      if ctx:get_field(n) ~= nil then ctx:set_field(n, value) end
    end)
  end
end

-- Clean a name the way the game expects: max 12 chars, no < > or controls.
local function clean_name(s)
  s = tostring(s or "")
  local out, n = {}, 0
  for _, cp in utf8.codes(s) do
    if n >= 12 then break end
    if cp >= 32 and cp ~= 127 and cp ~= 60 and cp ~= 62 then
      out[#out + 1] = utf8.char(cp)
      n = n + 1
    end
  end
  return table.concat(out)
end

-- Rename through a name context. Returns the applied name.
local function rename_on_ctx(ctx, getter, name)
  if type(ctx) ~= "userdata" then error("name context not found (load into a save first)") end
  name = clean_name(name)
  if name == "" then error("name is empty") end
  local old = try(function() return ctx:call(getter) end)
  local lang = language_of(ctx)
  call_set(ctx, "setName", name)
  if type(old) == "string" and old ~= "" and old ~= name then
    local td = try(function() return ctx:get_type_definition() end)
    for _, f in ipairs(all_fields(td)) do
      local fn = try(function() return f:get_name() end) or ""
      if not fn:lower():find("nick", 1, true) then
        local v = try(function() return f:get_data(ctx) end)
        if v == old then try(function() ctx:set_field(fn, name) end) end
      end
    end
  end
  stamp_language(ctx, lang)
  return name
end

local function check_name(a, npos)
  local name = a[npos] or ""
  if name:match("^%s*$") then error("name is empty") end
  return name
end

COMMANDS.get_arisen_name = function()
  local ctx = arisen_name_ctx()
  local n = ctx and try(function() return ctx:call("get_NameProp") end)
  return clean(type(n) == "string" and n ~= "" and n or "?")
end

COMMANDS.set_arisen_name = function(a)
  local applied = rename_on_ctx(arisen_name_ctx(), "get_NameProp", check_name(a, 1))
  return 'Arisen renamed to "' .. applied .. '" (save + reload the game to keep it)'
end

COMMANDS.get_main_pawn_name = function()
  local pm = sdk.get_managed_singleton("app.PawnManager")
  if not pm then error("PawnManager not found (load into a save first)") end
  local mp = try(function() return pm:call("get_MainPawn") end)
  if not mp then error("main pawn not found") end
  local h = try(function() return human_from(mp) end) or try(function() return find_human(mp) end)
  local ctx = pawn_name_ctx(mp, h)
  local n = ctx and try(function() return ctx:call("get_Name") end)
  return clean(type(n) == "string" and n ~= "" and n or "?")
end

-- args: idx (0 = main pawn, else index into the last list_pawns result), name
COMMANDS.set_pawn_name = function(a)
  local idx = int(a[1])
  local name = check_name(a, 2)
  local chara, human
  if idx == 0 then
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then error("PawnManager not found (load into a save first)") end
    chara = try(function() return pm:call("get_MainPawn") end)
    if not chara then error("main pawn not found") end
    human = try(function() return human_from(chara) end)
      or try(function() return find_human(chara) end)
  else
    local e = PW.list[idx]
    if not e then error("pawn not in the list - refresh the pawn list") end
    chara, human = e.src, e.human
  end
  local applied = rename_on_ctx(pawn_name_ctx(chara, human), "get_Name", name)
  return 'Pawn renamed to "' .. applied .. '" (save + reload the game to keep it)'
end

---------------------------------------------------------------- v1.34 name probe
-- Summarize name-ish accessors on one object into `out`.
local function probe_name_on(obj, label, out)
  if type(obj) ~= "userdata" then out[#out + 1] = label .. ": <nil>"; return end
  local td = try(function() return obj:get_type_definition() end)
  if not td then out[#out + 1] = label .. ": <no typedef>"; return end
  local tname = try(function() return td:get_full_name() end) or "?"
  local parts = {}
  local methods = try(function() return td:get_methods() end) or {}
  for _, m in ipairs(methods) do
    local mn = try(function() return m:get_name() end) or ""
    if mn:lower():find("name", 1, true) then
      local info = mn
      if mn:lower():match("^get_") then
        local ok, v = pcall(function() return obj:call(mn) end)
        if ok then
          if type(v) == "string" then info = mn .. '="' .. v:sub(1, 40) .. '"'
          else info = mn .. "->" .. type(v) end
        else info = mn .. "->ERR" end
      end
      parts[#parts + 1] = "m:" .. info
    end
  end
  local fields = try(function() return td:get_fields() end) or {}
  for _, f in ipairs(fields) do
    local fn = try(function() return f:get_name() end) or ""
    if fn:lower():find("name", 1, true) then
      local v = try(function() return obj:get_field(fn) end)
      local vs = (v == nil) and "<nil>" or tostring(v):sub(1, 40)
      parts[#parts + 1] = "f:" .. fn .. "=" .. vs
    end
  end
  out[#out + 1] = label .. "(" .. tname .. "): " ..
    (#parts > 0 and table.concat(parts, ", ") or "<no name-ish members>")
end

-- args: which ("arisen" or "main"). Reports where display names live.
COMMANDS.probe_name = function(a)
  local which = a[1] or "arisen"
  local char
  if which == "main" then
    local pm = sdk.get_managed_singleton("app.PawnManager")
    if not pm then error("PawnManager not found (load into a save first)") end
    char = try(function() return pm:call("get_MainPawn") end)
    if not char then error("main pawn not found") end
  else
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then error("CharacterManager not found (load into the game first)") end
    for _, g in ipairs({ "get_ManualPlayer", "getManualPlayer", "get_ManualPlayerNoCheck" }) do
      char = try(function() return cm:call(g) end)
      if char then break end
    end
    if not char then error("player not found") end
  end
  local human = try(function() return human_from(char) end)
    or try(function() return find_human(char) end)
  local out = {}
  probe_name_on(char, "char", out)
  probe_name_on(human, "human", out)
  probe_name_on(human and try(function() return human:call("get_PawnDataContext") end),
    "human_pdata", out)
  probe_name_on(try(function() return char:call("get_PawnDataContext") end),
    "char_pdata", out)
  if which == "main" then
    probe_name_on(try(function() return char:call("get_MainPawnDataContext") end),
      "main_pdata", out)
  end
  return (table.concat(out, " // "):gsub("[|;\r\n\t]", " "))
end

---------------------------------------------------------------- v1.35 arisen name hunt
-- The Arisen's name container has no 'name' in its accessor names, so the
-- v1.34 probe couldn't see it. This enumerates data/player/context/profile
-- getters on CharacterManager, the Arisen char and human, then name-probes
-- whatever objects they return.
COMMANDS.probe_arisen = function()
  local cm = sdk.get_managed_singleton("app.CharacterManager")
  if not cm then error("CharacterManager not found (load into the game first)") end
  local char
  for _, g in ipairs({ "get_ManualPlayer", "getManualPlayer", "get_ManualPlayerNoCheck" }) do
    char = try(function() return cm:call(g) end)
    if char then break end
  end
  if not char then error("player not found") end
  local human = try(function() return human_from(char) end)
    or try(function() return find_human(char) end)
  local out = {}
  local function children(obj, label)
    if type(obj) ~= "userdata" then return end
    local td = try(function() return obj:get_type_definition() end)
    if not td then return end
    local methods = try(function() return td:get_methods() end) or {}
    for _, m in ipairs(methods) do
      local mn = try(function() return m:get_name() end) or ""
      local ml = mn:lower()
      if ml:match("^get_") and (ml:find("data", 1, true) or ml:find("player", 1, true)
          or ml:find("context", 1, true) or ml:find("profile", 1, true)) then
        local ok, v = pcall(function() return obj:call(mn) end)
        if ok and type(v) == "userdata" then
          probe_name_on(v, label .. "." .. mn, out)
        elseif ok and type(v) == "string" and v ~= "" then
          out[#out + 1] = label .. "." .. mn .. '="' .. v:sub(1, 40) .. '"'
        end
      end
    end
  end
  children(cm, "charman")
  children(char, "char")
  children(human, "human")
  if #out == 0 then out[#out + 1] = "<no data/player/context getters found>" end
  return (table.concat(out, " // "):gsub("[|;\r\n\t]", " "))
end

---------------------------------------------------------------- v1.1 enums
COMMANDS.list_enums = function()
  local lines = {}
  for _, e in ipairs(ENUMS) do
    for _, ent in ipairs(enum_list(e[2])) do
      lines[#lines + 1] = e[1] .. "\t" .. fmt_int(ent.value) .. "\t" .. ent.name
    end
  end
  if not wr(DIR .. "enums.txt", table.concat(lines, "\n")) then error("could not write enums.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.1 weapon skills
COMMANDS.get_wskills = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local t = {}
  for slot = 0, 5 do
    t[#t + 1] = fmt_int(try(function() return c.skill:call("getSkillID", job, slot) end) or 0)
  end
  return table.concat(t, ",")
end

-- args: target, job, slot, skill id, unlock level (-1 = do not auto-unlock)
COMMANDS.set_wskill = function(a)
  local c = get_target(a[1])
  local job, slot, id, lvl = int(a[2]), int(a[3]), int(a[4]), int(a[5])
  if lvl >= 0 and id ~= 0 then
    local en = try(function() return c.skill:call("isCustomSkillEnable", id) end)
    if en == false then
      try(function() call_ov(c.skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, id, lvl) end)
    end
  end
  c.skill:call("setSkill", job, id, slot)
  return "ok"
end

COMMANDS.clear_wskills = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  for slot = 0, 5 do c.skill:call("setSkill", job, 0, slot) end
  return "ok"
end

-- args: target, job (0 = every vocation), level
COMMANDS.unlock_wskills = function(a)
  local c = get_target(a[1])
  local job, lvl = int(a[2]), int(a[3])
  local n, total = 0, 0
  for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
    if ent.value ~= 0 and (job == 0 or job_of(ent.name) == job) then
      total = total + 1
      if pcall(call_ov, c.skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, ent.value, lvl) then n = n + 1 end
    end
  end
  return n .. "/" .. total
end

COMMANDS.unlock_wskill = function(a)
  local c = get_target(a[1])
  call_ov(c.skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, int(a[2]), int(a[3]))
  return "ok"
end

------------------------------------------------ v1.89.81 unlearn weapon skills
-- A learned weapon skill is an entry in SkillContext.EnabledCustomSkills
-- (app.HumanSkillContext.EnabledCustomSkill: CustomSkillID + Level). Removing
-- the entry is the unlearn route; every id is verified with
-- isCustomSkillEnable afterwards. If direct removal is not exposed on this
-- build, the list is rebuilt from the still-enabled skills with their levels.
-- Equipped skills are never removed: a slot that points at a forgotten skill
-- would leave the loadout in a state the game UI cannot fix.
do
  local function w_list(c)
    return try(function() return c.skill:get_field("EnabledCustomSkills") end)
  end

  local function w_enabled(c, id)
    return try(function() return c.skill:call("isCustomSkillEnable", id) end)
  end

  local function w_level(c, id)
    return tonumber(try(function() return c.skill:call("getCustomSkillLevel", id) end)) or 1
  end

  local function w_equipped(c)
    local out = {}
    for j = 1, 10 do
      for slot = 0, 5 do
        local id = tonumber(try(function() return c.skill:call("getSkillID", j, slot) end)) or 0
        if id ~= 0 then out[id] = true end
      end
    end
    return out
  end

  local function w_entries(list)
    local els = coll_elems(list)
    if #els > 0 then return els end
    local cnt = tonumber(try(function() return list:call("get_Count") end)) or 0
    for i = 0, cnt - 1 do
      local e = try(function() return list:call("get_Item", i) end)
      if e ~= nil then els[#els + 1] = e end
    end
    return els
  end

  local function w_entry_id(e)
    if type(e) ~= "userdata" then return nil end
    return tonumber(try(function() return e:get_field("CustomSkillID") end))
  end

  local function w_remove(list, id)
    local els = w_entries(list)
    for i, e in ipairs(els) do
      if w_entry_id(e) == id then
        if pcall(function() list:call("RemoveAt", i - 1) end) then
          return true, "RemoveAt(" .. (i - 1) .. ")"
        end
        if pcall(function() list:call("Remove", e) end) then
          return true, "Remove(entry)"
        end
        break
      end
    end
    return false, "no removal method"
  end

  local function w_clear(list)
    if pcall(function() list:call("Clear") end) then return true end
    if pcall(function() list:call("Clear()") end) then return true end
    return false
  end

  local function w_add_entry(list, id, lvl)
    local td = sdk.find_type_definition("app.HumanSkillContext.EnabledCustomSkill")
    local obj
    pcall(function() if td and td.create_instance then obj = td:create_instance() end end)
    if type(obj) ~= "userdata" and sdk.create_instance then
      pcall(function() obj = sdk.create_instance("app.HumanSkillContext.EnabledCustomSkill") end)
    end
    if type(obj) ~= "userdata" then return false end
    pcall(function() obj:set_field("CustomSkillID", id) end)
    pcall(function() obj:set_field("Level", lvl) end)
    pcall(function() obj:set_field("IsViewedNew", false) end)
    return pcall(function() list:call("Add", obj) end)
  end

  local function w_unlearn(c, ids)
    local list = w_list(c)
    if type(list) ~= "userdata" then error("SkillContext.EnabledCustomSkills not found") end
    local equipped = w_equipped(c)
    local remove, skipped = {}, 0
    for _, id in ipairs(ids) do
      if equipped[id] then skipped = skipped + 1 else remove[#remove + 1] = id end
    end
    if #remove == 0 then
      return "nothing to unlearn - " .. skipped .. " learned skill(s) are equipped; clear their slots first"
    end

    local steps, removed = {}, 0
    for _, id in ipairs(remove) do
      local ok, how = w_remove(list, id)
      if ok then
        removed = removed + 1
        steps[#steps + 1] = tostring(id) .. " " .. how
      end
    end

    local function still_enabled()
      local out = {}
      for _, id in ipairs(remove) do
        if w_enabled(c, id) == true then out[#out + 1] = id end
      end
      return out
    end

    local still = still_enabled()
    local lost = {}
    if #still > 0 then
      local keep = {}
      for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
        if ent.value ~= 0 and w_enabled(c, ent.value) == true then
          local wanted = false
          for _, id in ipairs(remove) do
            if id == ent.value then wanted = true break end
          end
          if not wanted then
            keep[#keep + 1] = { id = ent.value, lvl = w_level(c, ent.value) }
          end
        end
      end
      if not w_clear(list) then
        error("could not clear EnabledCustomSkills (still enabled: "
              .. table.concat(still, ",") .. ")")
      end
      for _, k in ipairs(keep) do
        w_add_entry(list, k.id, k.lvl)
        if w_enabled(c, k.id) ~= true then lost[#lost + 1] = k.id end
      end
      steps[#steps + 1] = "rebuilt list, kept " .. tostring(#keep)
      still = still_enabled()
    end

    local verified = 0
    for _, id in ipairs(remove) do
      if w_enabled(c, id) == false then verified = verified + 1 end
    end
    local r = verified .. "/" .. #remove .. " unlearned"
    if #steps > 0 then r = r .. " (" .. table.concat(steps, ", ") .. ")" end
    if skipped > 0 then r = r .. "; skipped " .. skipped .. " equipped" end
    if #still > 0 then r = r .. "; STILL ENABLED: " .. table.concat(still, ",") end
    if #lost > 0 then r = r .. "; WARNING: re-enable failed for " .. table.concat(lost, ",") end
    log.info(TAG .. "wskill unlearn: " .. r)
    return r
  end

  COMMANDS.disable_wskill = function(a)
    local c = get_target(a[1])
    local id = int(a[2])
    if w_enabled(c, id) == false then return "already unlearned" end
    return w_unlearn(c, { id })
  end

  COMMANDS.disable_wskills = function(a)
    local c = get_target(a[1])
    local job = int(a[2])
    local ids = {}
    for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
      if ent.value ~= 0 and (job == 0 or job_of(ent.name) == job)
          and w_enabled(c, ent.value) == true then
        ids[#ids + 1] = ent.value
      end
    end
    if #ids == 0 then return "nothing to unlearn - no weapon skill is learned" end
    return w_unlearn(c, ids)
  end
end

-- rows "id,enabled,level;..." for the weapon skills of one vocation
COMMANDS.get_wstate = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local out = {}
  for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
    if ent.value ~= 0 and job_of(ent.name) == job then
      local en = try(function() return c.skill:call("isCustomSkillEnable", ent.value) end)
      local lv = try(function() return c.skill:call("getCustomSkillLevel", ent.value) end)
      out[#out + 1] = fmt_int(ent.value) .. "," .. tostring(en) .. "," .. tostring(lv)
    end
  end
  return table.concat(out, ";")
end

---------------------------------------------------------------- v1.4 weapon skill level / upgrade probe
-- Finds out, from the game itself, which read-only SkillContext functions describe a weapon skill
-- (max level, upgraded/enhanced flag, ...) by calling every getter that takes a HumanCustomSkillID,
-- for every skill of the vocation. Results go to wskill_info.txt and to the REFramework log.
local function probe_name_ok(ln)
  return ln:match("^get") or ln:match("^is") or ln:match("^can") or ln:match("^has") or ln:match("^need") or ln:match("^check")
end

COMMANDS.wskill_probe = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local meths, seen, interesting = {}, {}, {}
  local t = c.skill:get_type_definition()
  log.info(TAG .. "wskill_probe: SkillContext type " .. tostring(t:get_full_name()))
  while t do
    for _, m in ipairs(t:get_methods() or {}) do
      local n = m:get_name()
      local ln = n:lower()
      local pts = m:get_param_types() or {}
      if ln:find("level", 1, true) or ln:find("enhance", 1, true) or ln:find("upgrade", 1, true)
          or ln:find("awaken", 1, true) or ln:find("max", 1, true) or ln:find("rank", 1, true) then
        local ps = {}
        for _, p in ipairs(pts) do ps[#ps + 1] = try(function() return p:get_full_name() end) or "?" end
        local rt = try(function() return m:get_return_type():get_full_name() end) or "?"
        log.info(TAG .. "wskill_probe: ctx method " .. n .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt)
        interesting[#interesting + 1] = n
      end
      if #pts == 1 and not seen[n] and probe_name_ok(ln) then
        local pn = try(function() return pts[1]:get_full_name() end) or ""
        if pn:find("HumanCustomSkillID", 1, true) then
          seen[n] = true
          meths[#meths + 1] = { name = n, m = m }
        end
      end
    end
    t = try(function() return t:get_parent_type() end)
  end
  for _, td in ipairs({ "app.HumanCustomSkillLevelNo" }) do
    for _, ent in ipairs(enum_list(td)) do
      log.info(TAG .. "wskill_probe: enum " .. td .. " " .. ent.name .. " = " .. fmt_int(ent.value))
    end
  end
  table.sort(meths, function(x, y) return x.name < y.name end)
  local lines = {}
  for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
    if ent.value ~= 0 and (job == 0 or job_of(ent.name) == job) then
      local parts = {}
      for _, mm in ipairs(meths) do
        local ok, v = pcall(function() return mm.m:call(c.skill, ent.value) end)
        if ok and (type(v) == "number" or type(v) == "boolean") then
          parts[#parts + 1] = (mm.name:gsub("CustomSkill", ""):gsub("^get", "")) .. "=" .. tostring(v)
        end
      end
      local row = fmt_int(ent.value) .. "\t" .. ent.name .. "\t" .. table.concat(parts, " ")
      lines[#lines + 1] = row
      log.info(TAG .. "wskill_probe: " .. row)
    end
  end
  if not wr(DIR .. "wskill_info.txt", table.concat(lines, "\n")) then error("could not write wskill_info.txt") end
  local names = {}
  for _, mm in ipairs(meths) do names[#names + 1] = mm.name end
  return string.format("%d skills, %d getters (%s); %d level/enhance-related methods logged",
    #lines, #meths, table.concat(names, " "), #interesting)
end

---------------------------------------------------------------- v1.5 set the level of ONE weapon skill (verified)
-- args: target, skill id, level. Uses a dedicated "set...CustomSkillLevel(id, level)" if the game has one,
-- then setCustomSkillEnable(id, level), and finally reads the level back so you see what really happened.
COMMANDS.set_wlevel = function(a)
  local c = get_target(a[1])
  local id, lvl = int(a[2]), int(a[3])
  local before = try(function() return c.skill:call("getCustomSkillLevel", id) end)
  local used = {}
  local t = c.skill:get_type_definition()
  while t do
    for _, m in ipairs(t:get_methods() or {}) do
      local n = m:get_name()
      local pts = m:get_param_types() or {}
      if n:sub(1, 3) == "set" and n:lower():find("customskilllevel", 1, true) and #pts == 2 then
        local p1 = try(function() return pts[1]:get_full_name() end) or ""
        log.info(TAG .. "set_wlevel: candidate " .. n .. "(" .. p1 .. ", ...)")
        if p1:find("HumanCustomSkillID", 1, true) and pcall(function() m:call(c.skill, id, lvl) end) then
          used[#used + 1] = n
        end
      end
    end
    t = try(function() return t:get_parent_type() end)
  end
  if pcall(call_ov, c.skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, id, lvl) then
    used[#used + 1] = "setCustomSkillEnable"
  end
  local after = try(function() return c.skill:call("getCustomSkillLevel", id) end)
  return string.format("requested level %d: game now reports %s (was %s) via %s%s", lvl, tostring(after), tostring(before),
    #used > 0 and table.concat(used, "+") or "nothing", (after == lvl) and "" or "  - NOT applied: the game keeps its own rule for this skill")
end

---------------------------------------------------------------- v1.87 skill detail probe (read-only)
-- args: target, job. Lists every CustomSkill method + every SkillContext field + the LevelNo enum
-- + every read-only 1-arg CustomSkill getter per skill of the vocation. Never calls a setter.
-- Results go to wskill_detail.txt. Built to find what is different about one skill (SmokeGiants).
COMMANDS.wskill_detail = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local skill = c.skill
  if type(skill) ~= "userdata" then error("SkillContext not found") end
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local t0 = try(function() return skill:get_type_definition() end)
  L("SkillContext type: " .. tostring(t0 and try(function() return t0:get_full_name() end) or "?"))
  L("--- METHODS containing CustomSkill (all parents, sorted) ---")
  local mseen = {}
  local mlist = {}
  local t = t0
  while t do
    for _, m in ipairs(t:get_methods() or {}) do
      local n = m:get_name()
      if n:find("CustomSkill", 1, true) then
        local pts = m:get_param_types() or {}
        local ps = {}
        for _, p in ipairs(pts) do ps[#ps + 1] = try(function() return p:get_full_name() end) or "?" end
        local rt = try(function() return m:get_return_type():get_full_name() end) or "?"
        local key = n .. "(" .. table.concat(ps, ",") .. ") -> " .. rt
        if not mseen[key] then mseen[key] = true mlist[#mlist + 1] = key end
      end
    end
    t = try(function() return t:get_parent_type() end)
  end
  table.sort(mlist)
  for _, s in ipairs(mlist) do L("METHOD " .. s) end
  L("methods: " .. tostring(#mlist))
  L("--- FIELDS of SkillContext (non-static, all parents) ---")
  local fseen = {}
  local flist = {}
  t = t0
  while t do
    for _, f in ipairs(try(function() return t:get_fields() end) or {}) do
      if not try(function() return f:is_static() end) then
        local fn = try(function() return f:get_name() end) or "?"
        if not fseen[fn] then
          fseen[fn] = true
          local ftype = try(function() return f:get_type():get_full_name() end) or "?"
          local v = try(function() return skill:get_field(fn) end)
          if v == nil then v = try(function() return f:get_data(skill) end) end
          local vs = ""
          if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            vs = " = " .. clean(v):sub(1, 120)
          elseif type(v) == "userdata" then
            local vt = try(function() return v:get_type_definition():get_full_name() end) or "userdata"
            local cnt = try(function() return v:call("get_Count") end)
            if cnt == nil then cnt = try(function() return v:call("get_Length") end) end
            if cnt == nil then cnt = try(function() return v:get_field("_count") end) end
            if cnt == nil then cnt = try(function() return v:get_field("_size") end) end
            if cnt == nil then
              local els = try(function() return v:get_elements() end)
              if type(els) == "table" then cnt = #els end
            end
            vs = " = <" .. vt .. ">" .. (cnt ~= nil and (" count=" .. tostring(cnt)) or "")
          elseif v == nil then
            vs = " = <nil>"
          else
            vs = " = <" .. type(v) .. ">"
          end
          flist[#flist + 1] = "FIELD " .. fn .. " : " .. ftype .. vs
        end
      end
    end
    t = try(function() return t:get_parent_type() end)
  end
  table.sort(flist)
  for _, s in ipairs(flist) do L(s) end
  L("--- HumanCustomSkillLevelNo ---")
  for _, ent in ipairs(enum_list("app.HumanCustomSkillLevelNo")) do
    L("LEVELNO " .. fmt_int(ent.value) .. " " .. ent.name)
  end
  L("--- GETTERS per skill (read-only, set* skipped) ---")
  local getters = {}
  local gseen = {}
  t = t0
  while t do
    for _, m in ipairs(t:get_methods() or {}) do
      local n = m:get_name()
      if n:sub(1, 3) ~= "set" then
        local pts = m:get_param_types() or {}
        if #pts == 1 then
          local pn = try(function() return pts[1]:get_full_name() end) or ""
          if pn:find("HumanCustomSkillID", 1, true) and not gseen[n] then
            gseen[n] = true
            getters[#getters + 1] = { name = n, m = m }
          end
        end
      end
    end
    t = try(function() return t:get_parent_type() end)
  end
  table.sort(getters, function(x, y) return x.name < y.name end)
  local gnames = {}
  for _, g in ipairs(getters) do gnames[#gnames + 1] = g.name end
  L("getters: " .. table.concat(gnames, " "))
  for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
    if ent.value ~= 0 and job_of(ent.name) == job then
      local parts = {}
      for _, g in ipairs(getters) do
        local ok, v = pcall(function() return g.m:call(skill, ent.value) end)
        if ok and (type(v) == "number" or type(v) == "boolean" or type(v) == "string") then
          parts[#parts + 1] = g.name .. "=" .. clean(v):sub(1, 60)
        end
      end
      L(fmt_int(ent.value) .. " " .. ent.name .. " " .. table.concat(parts, " "))
    end
  end
  for _, s in ipairs(lines) do log.info(TAG .. "wskill_detail: " .. s) end
  if not wr(DIR .. "wskill_detail.txt", table.concat(lines, "\n")) then error("could not write wskill_detail.txt") end
  return string.format("%d methods, %d fields, %d getters; %d lines", #mlist, #flist, #getters, #lines)
end

---------------------------------------------------------------- v1.88 enabled-list dump (read-only)
-- args: target, job. Dumps every EnabledCustomSkills entry (its fields) + ReachLevel per skill.
-- Read-only: never calls a setter. Results go to wskill_enabled.txt.
COMMANDS.wskill_enabled_dump = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local skill = c.skill
  if type(skill) ~= "userdata" then error("SkillContext not found") end
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local list = try(function() return skill:get_field("EnabledCustomSkills") end)
  if type(list) ~= "userdata" then error("EnabledCustomSkills not found") end
  local els = coll_elems(list)
  if #els == 0 then
    local cnt = try(function() return list:call("get_Count") end) or 0
    for i = 0, cnt - 1 do
      local e = try(function() return list:call("get_Item", i) end)
      if e ~= nil then els[#els + 1] = e end
    end
  end
  L("EnabledCustomSkills entries: " .. tostring(#els))
  for i, e in ipairs(els) do
    if type(e) ~= "userdata" then
      L("ENTRY " .. tostring(i) .. " <not userdata: " .. type(e) .. ">")
    else
      local td = try(function() return e:get_type_definition() end)
      local tname = (td and try(function() return td:get_full_name() end)) or "?"
      local parts = {}
      local seen = {}
      local t2 = td
      while t2 do
        for _, f in ipairs(try(function() return t2:get_fields() end) or {}) do
          if not try(function() return f:is_static() end) then
            local fn = try(function() return f:get_name() end) or "?"
            if not seen[fn] then
              seen[fn] = true
              local v = try(function() return e:get_field(fn) end)
              if v == nil then v = try(function() return f:get_data(e) end) end
              if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                parts[#parts + 1] = fn .. "=" .. clean(v):sub(1, 60)
              elseif type(v) == "userdata" then
                parts[#parts + 1] = fn .. "=<" .. (try(function() return v:get_type_definition():get_full_name() end) or "userdata") .. ">"
              elseif v == nil then
                parts[#parts + 1] = fn .. "=<nil>"
              else
                parts[#parts + 1] = fn .. "=<" .. type(v) .. ">"
              end
            end
          end
        end
        t2 = try(function() return t2:get_parent_type() end)
      end
      L("ENTRY " .. tostring(i) .. " type=" .. tname .. " " .. table.concat(parts, " "))
    end
  end
  L("--- isCustomSkillReachLevel per skill ---")
  for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
    if ent.value ~= 0 and job_of(ent.name) == job then
      local r1 = try(function() return skill:call("isCustomSkillReachLevel", ent.value, 1) end)
      local r2 = try(function() return skill:call("isCustomSkillReachLevel", ent.value, 2) end)
      local en = try(function() return skill:call("isCustomSkillEnable", ent.value) end)
      local lv = try(function() return skill:call("getCustomSkillLevel", ent.value) end)
      L(fmt_int(ent.value) .. " " .. ent.name .. " enable=" .. tostring(en) .. " level=" .. tostring(lv)
        .. " ReachLv1=" .. tostring(r1) .. " ReachLv2=" .. tostring(r2))
    end
  end
  for _, s in ipairs(lines) do log.info(TAG .. "wskill_enabled_dump: " .. s) end
  if not wr(DIR .. "wskill_enabled.txt", table.concat(lines, "\n")) then error("could not write wskill_enabled.txt") end
  return tostring(#els) .. " entries, " .. tostring(#lines) .. " lines"
end

---------------------------------------------------------------- v1.88 try-fix for one skill (writes, with read-backs)
-- args: target, skill id, level. Tries prepareEnableCustomSkillList, then setCustomSkillEnable,
-- then (only if still disabled) setCustomSkillLevelUp + setCustomSkillEnable again. Reads back
-- after every step and reports whether any OTHER skill of the same vocation changed.
COMMANDS.wskill_try_fix = function(a)
  local c = get_target(a[1])
  local id, lvl = int(a[2]), int(a[3])
  local skill = c.skill
  if type(skill) ~= "userdata" then error("SkillContext not found") end
  local job = nil
  for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
    if ent.value == id then job = job_of(ent.name) break end
  end
  if job == nil then error("skill id not in HumanCustomSkillID") end
  local function snap()
    local m = {}
    for _, ent in ipairs(enum_list("app.HumanCustomSkillID")) do
      if ent.value ~= 0 and job_of(ent.name) == job then
        local en = try(function() return skill:call("isCustomSkillEnable", ent.value) end)
        local lv = try(function() return skill:call("getCustomSkillLevel", ent.value) end)
        m[ent.value] = tostring(en) .. "/" .. tostring(lv)
      end
    end
    return m
  end
  local function cur()
    local en = try(function() return skill:call("isCustomSkillEnable", id) end)
    local lv = try(function() return skill:call("getCustomSkillLevel", id) end)
    return tostring(en) .. "/" .. tostring(lv)
  end
  local before = snap()
  local steps = {}
  steps[#steps + 1] = "start enable/level=" .. cur()
  local ok1 = pcall(function() skill:call("prepareEnableCustomSkillList") end)
  steps[#steps + 1] = "prepareEnableCustomSkillList ok=" .. tostring(ok1) .. " now=" .. cur()
  local ok2 = pcall(call_ov, skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, id, lvl)
  steps[#steps + 1] = "setCustomSkillEnable ok=" .. tostring(ok2) .. " now=" .. cur()
  local en = try(function() return skill:call("isCustomSkillEnable", id) end)
  if en ~= true then
    local ok3 = pcall(function() skill:call("setCustomSkillLevelUp", id) end)
    steps[#steps + 1] = "setCustomSkillLevelUp ok=" .. tostring(ok3) .. " now=" .. cur()
    local ok4 = pcall(call_ov, skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, id, lvl)
    steps[#steps + 1] = "setCustomSkillEnable#2 ok=" .. tostring(ok4) .. " now=" .. cur()
  end
  local after = snap()
  local changed = {}
  for k, v in pairs(after) do
    if k ~= id and before[k] ~= v then changed[#changed + 1] = tostring(k) .. ":" .. tostring(before[k]) .. "->" .. tostring(v) end
  end
  table.sort(changed)
  steps[#steps + 1] = "other skills changed: " .. (#changed > 0 and table.concat(changed, " ") or "none")
  for _, s in ipairs(steps) do log.info(TAG .. "wskill_try_fix: " .. s) end
  return table.concat(steps, " | ")
end

---------------------------------------------------------------- v1.89 add a missing EnabledCustomSkills entry (writes, with read-backs)
-- args: target, skill id, level. The v0.88 dump showed SmokeGiants (120) has NO entry in
-- EnabledCustomSkills while every other skill does, and all setters were no-ops for it.
-- Hypothesis: the setters only update an existing entry. So: if an entry exists, set its
-- Level field; if not, create one (CustomSkillID=id, Level=lvl) and List.Add it, then
-- call setCustomSkillEnable once more. Reports every step + read-backs.
COMMANDS.wskill_add_entry = function(a)
  local c = get_target(a[1])
  local id, lvl = int(a[2]), int(a[3])
  local skill = c.skill
  if type(skill) ~= "userdata" then error("SkillContext not found") end
  local function cur()
    local en = try(function() return skill:call("isCustomSkillEnable", id) end)
    local lv = try(function() return skill:call("getCustomSkillLevel", id) end)
    return tostring(en) .. "/" .. tostring(lv)
  end
  local steps = {}
  steps[#steps + 1] = "start enable/level=" .. cur()
  local list = try(function() return skill:get_field("EnabledCustomSkills") end)
  if type(list) ~= "userdata" then error("EnabledCustomSkills not found") end
  local function list_count()
    local els = coll_elems(list)
    if #els > 0 then return #els end
    local cnt = try(function() return list:call("get_Count") end)
    return cnt or -1
  end
  steps[#steps + 1] = "list count before=" .. tostring(list_count())
  local els = coll_elems(list)
  if #els == 0 then
    local cnt = try(function() return list:call("get_Count") end) or 0
    for i = 0, cnt - 1 do
      local e = try(function() return list:call("get_Item", i) end)
      if e ~= nil then els[#els + 1] = e end
    end
  end
  local found = nil
  for _, e in ipairs(els) do
    if type(e) == "userdata" then
      local cid = try(function() return e:get_field("CustomSkillID") end)
      if cid == id then found = e break end
    end
  end
  if found ~= nil then
    steps[#steps + 1] = "entry already exists, setting its Level field to " .. tostring(lvl)
    local ok_set = pcall(function() found:set_field("Level", lvl) end)
    steps[#steps + 1] = "set_field Level ok=" .. tostring(ok_set) .. " now=" .. cur()
    local ok_en = pcall(call_ov, skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, id, lvl)
    steps[#steps + 1] = "setCustomSkillEnable ok=" .. tostring(ok_en) .. " now=" .. cur()
  else
    steps[#steps + 1] = "no entry for id " .. tostring(id) .. ", creating one"
    local td = sdk.find_type_definition("app.HumanSkillContext.EnabledCustomSkill")
    steps[#steps + 1] = "type found=" .. tostring(td ~= nil)
    local newobj = nil
    local create_ok = pcall(function()
      if td and td.create_instance then newobj = td:create_instance() end
    end)
    steps[#steps + 1] = "create_instance ok=" .. tostring(create_ok) .. " obj=" .. tostring(type(newobj))
    if type(newobj) ~= "userdata" then
      local ok2 = pcall(function()
        if sdk.create_instance then newobj = sdk.create_instance("app.HumanSkillContext.EnabledCustomSkill") end
      end)
      steps[#steps + 1] = "sdk.create_instance fallback ok=" .. tostring(ok2) .. " obj=" .. tostring(type(newobj))
    end
    if type(newobj) ~= "userdata" then error("could not create EnabledCustomSkill instance") end
    local ok_id = pcall(function() newobj:set_field("CustomSkillID", id) end)
    local ok_lv = pcall(function() newobj:set_field("Level", lvl) end)
    local ok_vn = pcall(function() newobj:set_field("IsViewedNew", false) end)
    steps[#steps + 1] = "set fields ID ok=" .. tostring(ok_id) .. " Level ok=" .. tostring(ok_lv) .. " Viewed ok=" .. tostring(ok_vn)
    local rid = try(function() return newobj:get_field("CustomSkillID") end)
    local rlv = try(function() return newobj:get_field("Level") end)
    steps[#steps + 1] = "new obj reads ID=" .. tostring(rid) .. " Level=" .. tostring(rlv)
    local ok_add = pcall(function() list:call("Add", newobj) end)
    steps[#steps + 1] = "List.Add ok=" .. tostring(ok_add) .. " count now=" .. tostring(list_count()) .. " getters now=" .. cur()
    local ok_en = pcall(call_ov, skill, "setCustomSkillEnable", "HumanCustomSkillID", 2, id, lvl)
    steps[#steps + 1] = "setCustomSkillEnable after Add ok=" .. tostring(ok_en) .. " now=" .. cur()
  end
  for _, s in ipairs(steps) do log.info(TAG .. "wskill_add_entry: " .. s) end
  return table.concat(steps, " | ")
end

---------------------------------------------------------------- v1.1 core skills
COMMANDS.get_nstate = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local out = {}
  for _, ent in ipairs(enum_list("app.HumanNormalSkillID")) do
    if ent.value ~= 0 then
      local j = job_of(ent.name)
      if j == job or j == nil then
        local en = try(function() return c.skill:call("isNormalSkillEnable", ent.value) end)
        out[#out + 1] = fmt_int(ent.value) .. "," .. tostring(en) .. "," .. (j == nil and "other" or "voc")
      end
    end
  end
  return table.concat(out, ";")
end

COMMANDS.enable_nskill = function(a)
  local c = get_target(a[1])
  call_ov(c.skill, "setNormalSkillEnable", "HumanNormalSkillID", 1, int(a[2]))
  return "ok"
end

COMMANDS.enable_nskills = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local incl_other = (a[3] == "all")
  local set, total, verified, failed = 0, 0, 0, {}
  for _, ent in ipairs(enum_list("app.HumanNormalSkillID")) do
    local j = job_of(ent.name)
    if ent.value ~= 0 and (j == job or (incl_other and j == nil)) then
      total = total + 1
      if pcall(call_ov, c.skill, "setNormalSkillEnable", "HumanNormalSkillID", 1, ent.value) then set = set + 1 end
      local en = try(function() return c.skill:call("isNormalSkillEnable", ent.value) end)
      if en == true then verified = verified + 1 else failed[#failed + 1] = ent.name end
    end
  end
  local r = set .. "/" .. total .. " set, " .. verified .. " read back enabled"
  if #failed > 0 then r = r .. "; NOT enabled: " .. table.concat(failed, " ") end
  return r
end

------------------------------------------------ v1.89.80 unlearn core skills
-- Enabled core skills live in SkillContext.EnableNormalSkills (a List).
-- Clearing that list is what the community "Reset normal skill" mod does;
-- removing a single id from it also works. Both routes are tried per id, and
-- every affected id is verified with isNormalSkillEnable before reporting.
do
  local function n_list(c)
    return try(function() return c.skill:get_field("EnableNormalSkills") end)
  end

  local function n_enabled(c, id)
    return try(function() return c.skill:call("isNormalSkillEnable", id) end)
  end

  local function n_item_id(v)
    local n = tonumber(v)
    if n then return n end
    if type(v) == "userdata" then
      n = tonumber(try(function() return v:get_field("value__") end))
      if n then return n end
      n = tonumber(tostring(v):match("(%d+)"))
      if n then return n end
    end
    return nil
  end

  local function n_remove(list, id)
    local count = tonumber(try(function() return list:call("get_Count") end))
    if count then
      for i = 0, count - 1 do
        local v = try(function() return list:call("get_Item", i) end)
        if n_item_id(v) == id then
          if pcall(function() list:call("RemoveAt", i) end) then
            return true, "RemoveAt(" .. i .. ")"
          end
          break
        end
      end
    end
    if pcall(function() list:call("Remove", id) end) then
      return true, "Remove(id)"
    end
    return false, "no removal method worked"
  end

  local function n_clear(list)
    if pcall(function() list:call("Clear") end) then return true end
    if pcall(function() list:call("Clear()") end) then return true end
    return false
  end

  local function n_add(c, list, id)
    -- setNormalSkillEnable is the path the enable commands use; List.Add is
    -- the fallback if that overload is not present on this build.
    if pcall(call_ov, c.skill, "setNormalSkillEnable", "HumanNormalSkillID", 1, id) then
      return true
    end
    return pcall(function() list:call("Add", id) end)
  end

  local function n_unlearn(c, remove)
    local list = n_list(c)
    if not list then error("SkillContext.EnableNormalSkills not found") end
    local steps, removed = {}, 0
    for _, id in ipairs(remove) do
      local ok, how = n_remove(list, id)
      if ok then
        removed = removed + 1
        steps[#steps + 1] = tostring(id) .. " " .. how
      end
    end

    local function still_enabled()
      local out = {}
      for _, id in ipairs(remove) do
        if n_enabled(c, id) == true then out[#out + 1] = id end
      end
      return out
    end

    local still = still_enabled()
    local lost = {}
    if #still > 0 then
      -- Fallback: rebuild the list from the state the game reports.
      local keep = {}
      for _, ent in ipairs(enum_list("app.HumanNormalSkillID")) do
        if ent.value ~= 0 and n_enabled(c, ent.value) == true then
          local wanted = false
          for _, id in ipairs(remove) do
            if id == ent.value then wanted = true break end
          end
          if not wanted then keep[#keep + 1] = ent.value end
        end
      end
      if not n_clear(list) then
        error("could not clear EnableNormalSkills (still enabled: "
              .. table.concat(still, ",") .. ")")
      end
      for _, id in ipairs(keep) do
        n_add(c, list, id)
        if n_enabled(c, id) ~= true then lost[#lost + 1] = id end
      end
      steps[#steps + 1] = "rebuilt list, kept " .. tostring(#keep)
      still = still_enabled()
    end

    local verified = 0
    for _, id in ipairs(remove) do
      if n_enabled(c, id) == false then verified = verified + 1 end
    end
    local r = verified .. "/" .. #remove .. " unlearned"
    if #steps > 0 then r = r .. " (" .. table.concat(steps, ", ") .. ")" end
    if #still > 0 then
      r = r .. "; STILL ENABLED: " .. table.concat(still, ",")
    end
    if #lost > 0 then
      r = r .. "; WARNING: re-enable failed for " .. table.concat(lost, ",")
    end
    log.info(TAG .. "unlearn: " .. r)
    return r
  end

  COMMANDS.disable_nskill = function(a)
    local c = get_target(a[1])
    local id = int(a[2])
    if n_enabled(c, id) == false then return "already unlearned" end
    return n_unlearn(c, { id })
  end

  COMMANDS.disable_nskills = function(a)
    local c = get_target(a[1])
    local job = int(a[2])
    local incl_other = (a[3] == "all")
    local remove = {}
    for _, ent in ipairs(enum_list("app.HumanNormalSkillID")) do
      local j = job_of(ent.name)
      if ent.value ~= 0 and (j == job or (incl_other and j == nil))
          and n_enabled(c, ent.value) == true then
        remove[#remove + 1] = ent.value
      end
    end
    if #remove == 0 then return "nothing to unlearn - no core skill is enabled" end
    return n_unlearn(c, remove)
  end
end

---------------------------------------------------------------- v1.1 augments
COMMANDS.get_augments = function(a)
  local c = get_target(a[1])
  if not c.ability then error("AbilityContext not found") end
  local job = int(a[2])
  local t = {}
  for slot = 0, 5 do
    t[#t + 1] = fmt_int(try(function() return c.ability:call("getAbility", job, slot) end) or 0)
  end
  return table.concat(t, ",")
end

COMMANDS.set_augment = function(a)
  local c = get_target(a[1])
  if not c.ability then error("AbilityContext not found") end
  c.ability:call("setAbility", int(a[2]), int(a[4]), int(a[3]))   -- target, job, slot, id
  return "ok"
end

COMMANDS.unlock_augments = function(a)
  local c = get_target(a[1])
  if not c.ability then error("AbilityContext not found") end
  local job = int(a[2])
  local incl_other = (a[3] == "all")
  local n, total = 0, 0
  for _, ent in ipairs(enum_list("app.HumanAbilityID")) do
    local j = job_of(ent.name)
    if ent.value ~= 0 and (j == job or (incl_other and j == nil)) then
      total = total + 1
      if pcall(call_ov, c.ability, "setAbilityEnable", "HumanAbilityID", 1, ent.value) then n = n + 1 end
    end
  end
  return n .. "/" .. total
end

-- v1.14.1: every app.HumanAbilityID entry (augments), including ones without a JobNN_ prefix that the lists used to hide
COMMANDS.augment_dump = function(a)
  local c = get_target(a[1])
  if not c.ability then error("AbilityContext not found") end
  local job = int(a[2])
  local lines = {}
  lines[#lines + 1] = "target = " .. tostring(a[1]) .. "   vocation = " .. tostring(job)
  local cur = {}
  for slot = 0, 5 do cur[#cur + 1] = fmt_int(try(function() return c.ability:call("getAbility", job, slot) end) or 0) end
  lines[#lines + 1] = "equipped augment ids (slots 1-6): " .. table.concat(cur, ",")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "id\tname\tjob\tenabled"
  for _, ent in ipairs(enum_list("app.HumanAbilityID")) do
    local en = try(function() return c.ability:call("isAbilityEnable", ent.value) end)
    lines[#lines + 1] = string.format("%d\t%s\t%s\t%s", ent.value, ent.name, tostring(job_of(ent.name) or "none"), tostring(en))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "AbilityContext methods mentioning ability / enable:"
  local t, seen = c.ability:get_type_definition(), {}
  while t do
    for _, m in ipairs(t:get_methods() or {}) do
      local k = m:get_name() .. "(" .. #(m:get_param_types() or {}) .. ")"
      if not seen[k] then seen[k] = true lines[#lines + 1] = "   M " .. k end
    end
    t = try(function() return t:get_parent_type() end)
  end
  if not wr(DIR .. "augdump.txt", table.concat(lines, "\n")) then error("could not write augdump.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.1 level / exp / favorability / equipped badge
COMMANDS.get_info = function(a)
  local c = get_target(a[1])
  local job = c.job and try(function() return c.job:call("get_Job") end)
  local lvl = c.status and try(function() return c.status:call("get_Level") end)
  return tostring(job or "?") .. "," .. tostring(lvl or "?")
end

COMMANDS.set_level = function(a)
  local c = get_target(a[1])
  local lvl = int(a[2])
  -- Sanity guard: DD2's normal cap is 200; negative or absurd values can
  -- leave the save in a state the game cannot load.
  if lvl < 1 or lvl > 200 then error("level out of range (1-200)") end
  if not c.status then error("StatusContext not found") end
  c.status:call("set_Level", lvl)
  return "ok"
end

COMMANDS.add_job_exp = function(a)
  local c = get_target(a[1])
  local amount = int(a[2])
  if amount < 0 or amount > 100000000 then
    error("EXP out of range (0-100000000)")
  end
  if not c.job then error("JobContext not found") end
  call_ov(c.job, "addJobExp", nil, 1, amount)
  return "ok"
end

COMMANDS.get_fav = function()
  local c = get_target("pawn")
  if not c.mdata then error("MainPawnDataContext not found") end
  return tostring(c.mdata:call("get_FavorabilityRating"))
end

COMMANDS.set_fav = function(a)
  local v = tonumber(a[1])
  if not v then error("bad arguments") end
  if v < 0 or v > 1000 then error("favorability out of range (0-1000)") end
  local c = get_target("pawn")
  if not c.mdata then error("MainPawnDataContext not found") end
  c.mdata:call("setFavorabilityRating", v + 0.0)
  return "ok"
end

COMMANDS.badge_equip = function(a)
  local n = int(a[1])
  if n < 1 or n > 50 then error("bad arguments") end
  local c = pawn_ctx()
  if not c.pdata then error("PawnDataContext not found") end
  c.pdata:call("setBadge", toint(2 ^ (n - 1)))
  return "ok"
end

---------------------------------------------------------------- v1.1 stats (base values) + search
local FRIENDLY = {
  BasicAttack = "Strength (base)", BasicDefence = "Defense (base)",
  BasicMagicAttack = "Magick (base)", BasicMagicDefence = "Magick Defense (base)",
  Blow = "Knockdown Power (base)", _Exp = "Experience",
  RemainingAmount = "Stamina (current)", ReducedMaxValue = "Stamina (max)",
  ReducedMaxHp = "Health (max)",
}

local function core_groups(c)
  local H = c.human
  local chara = follow(H, { "<Chara>k__BackingField" })
  local function g(title, obj) return { title = title, obj = type(obj) == "userdata" and obj or nil } end
  return {
    g("Combat stats", follow(chara, { "<DamageCalculator>k__BackingField", "Status" })),
    g("Experience", follow(chara, { "<Context>k__BackingField", "HumanStatusContext" })),
    g("Stamina", follow(H, { "<RecoverInteractCtrl>k__BackingField", "StaminaContext" })),
    g("Health", follow(chara, { "<NavigationAI>k__BackingField", "<AIBlackBoard>k__BackingField",
      "<TalkController>k__BackingField", "<OwnerHitController>k__BackingField" })),
  }
end

local function numeric_fields(obj)
  local out, seen = {}, {}
  local td = obj:get_type_definition()
  while td do
    for _, f in ipairs(td:get_fields() or {}) do
      if not f:is_static() then
        local n = f:get_name()
        if not seen[n] then
          seen[n] = true
          local v = try(function() return obj:get_field(n) end)
          if type(v) == "number" then out[#out + 1] = n end
        end
      end
    end
    td = try(function() return td:get_parent_type() end)
  end
  table.sort(out, function(x, y) return x:lower() < y:lower() end)
  return out
end

local LOCKS = {}   -- key -> { obj=, e={kind=,name=}, v= }

local function stat_read(obj, e)
  if e.kind == "f" then return try(function() return obj:get_field(e.name) end) end
  return try(function() return obj:call("get_" .. e.name) end)
end

local function stat_write(obj, e, v)
  if e.kind == "f" then obj:set_field(e.name, v) else obj:call("set_" .. e.name, v) end
end

local function typed_value(cur, text)
  local n = tonumber(text)
  if not n then error("bad value") end
  if math.type(cur) == "float" then return n + 0.0 end
  return math.floor(n)
end

local function set_lock(key, obj, e, v, on)
  if on then LOCKS[key] = { obj = obj, e = e, v = v } else LOCKS[key] = nil end
end

COMMANDS.get_core = function(a)
  local c = get_target(a[1])
  local lines = {}
  for gi, grp in ipairs(core_groups(c)) do
    if grp.obj then
      for _, n in ipairs(numeric_fields(grp.obj)) do
        local v = try(function() return grp.obj:get_field(n) end)
        if type(v) == "number" then
          local raw = n:gsub("^<(.+)>k__BackingField$", "%1")
          local label = FRIENDLY[raw] and string.format("%s [%s]", FRIENDLY[raw], raw) or raw
          lines[#lines + 1] = string.format("%d\t%s\t%s\t%s\t%s", gi, grp.title, n, clean(label), tostring(v))
        end
      end
    end
  end
  if not wr(DIR .. "core.txt", table.concat(lines, "\n")) then error("could not write core.txt") end
  return tostring(#lines)
end

-- args: target, group, field, value, lock(0/1)
COMMANDS.set_core = function(a)
  local c = get_target(a[1])
  local gi = int(a[2])
  local grp = core_groups(c)[gi]
  if not grp or not grp.obj then error("group not found") end
  local cur = grp.obj:get_field(a[3])
  if type(cur) ~= "number" then error("no numeric field " .. tostring(a[3])) end
  local nv = typed_value(cur, a[4])
  grp.obj:set_field(a[3], nv)
  set_lock(a[1] .. ":core" .. gi .. ":" .. a[3], grp.obj, { kind = "f", name = a[3] }, nv, a[5] == "1")
  return "ok"
end

COMMANDS.clear_locks = function()
  local n = 0
  for k in pairs(LOCKS) do LOCKS[k] = nil n = n + 1 end
  return tostring(n)
end

-- stat search over every context of the character (same idea as the REFramework editor)
local scache = {}

local NUMT = {
  ["System.Int32"] = true, ["System.UInt32"] = true, ["System.Int64"] = true,
  ["System.UInt64"] = true, ["System.Single"] = true, ["System.Double"] = true,
  ["System.Int16"] = true, ["System.UInt16"] = true, ["System.Byte"] = true,
}

local function stat_sources(c)
  local addr = try(function() return c.human:get_address() end)
  local sc = scache[c.kind]
  if sc and sc.addr == addr then return sc.src end
  for k in pairs(LOCKS) do if k:sub(1, #c.kind + 1) == c.kind .. ":" then LOCKS[k] = nil end end
  local src, seen = {}, {}
  local function add(label, o)
    if type(o) ~= "userdata" then return end
    local ad = try(function() return o:get_address() end)
    if ad and seen[ad] then return end
    if ad then seen[ad] = true end
    src[#src + 1] = { label = label, obj = o }
  end
  add("Human", c.human)
  add("StatusContext", c.status)
  add("JobContext", c.job)
  add("AbilityContext", c.ability)
  add("PawnDataContext", c.pdata)
  add("MainPawnDataContext", c.mdata)
  for _, n in ipairs({ "get_Chara", "get_Character", "get_CachedCharacter" }) do
    add(n:sub(5), try(function() return c.src:call(n) end))
  end
  local holder = try(function() return c.human:call("get_Context") end)
  local dict = holder and (try(function() return holder:get_field("Contexts") end)
      or try(function() return holder:call("get_Contexts") end))
  local entries = dict and try(function() return dict:get_field("_entries"):get_elements() end)
  for _, e in ipairs(entries or {}) do
    local val = try(function() return e:get_field("value") end)
    if type(val) == "userdata" then
      local cur = try(function() return val:get_field("<CurrentContext>k__BackingField") end)
          or try(function() return val:call("get_CurrentContext") end)
      if type(cur) == "userdata" then add((tname(cur):gsub("^app%.", "")), cur) end
    end
  end
  scache[c.kind] = { addr = addr, src = src }
  return src
end

local function stat_entries(s)
  if s.entries then return s.entries end
  local list, seen = {}, {}
  local td = s.obj:get_type_definition()
  local methods, mseen = {}, {}
  while td do
    for _, f in ipairs(td:get_fields() or {}) do
      if not f:is_static() then
        local n = f:get_name()
        if not seen["f" .. n] then
          seen["f" .. n] = true
          local v = try(function() return s.obj:get_field(n) end)
          if type(v) == "number" then list[#list + 1] = { kind = "f", name = n } end
        end
      end
    end
    for _, m in ipairs(td:get_methods() or {}) do
      local k = m:get_name() .. #(m:get_param_types() or {})
      if not mseen[k] then mseen[k] = true methods[#methods + 1] = m end
    end
    td = try(function() return td:get_parent_type() end)
  end
  local setters = {}
  for _, m in ipairs(methods) do
    local n = m:get_name()
    if n:sub(1, 4) == "set_" and #(m:get_param_types() or {}) == 1 then setters[n:sub(5)] = true end
  end
  for _, m in ipairs(methods) do
    local n = m:get_name()
    if n:sub(1, 4) == "get_" and #(m:get_param_types() or {}) == 0 and setters[n:sub(5)] then
      local rt = try(function() return m:get_return_type():get_full_name() end)
      if rt and NUMT[rt] and not seen["f" .. n:sub(5)] then list[#list + 1] = { kind = "p", name = n:sub(5) } end
    end
  end
  table.sort(list, function(x, y) return x.name:lower() < y.name:lower() end)
  s.entries = list
  return list
end

local function stat_match(s, e, filter)
  local v = stat_read(s.obj, e)
  if filter:sub(1, 1) == "=" then
    local want = tonumber(filter:sub(2))
    return (want ~= nil and type(v) == "number" and math.abs(v - want) < 0.01), v
  end
  local lname = (s.label .. "." .. e.name):lower()
  for tok in filter:lower():gmatch("[^,%s]+") do
    if lname:find(tok, 1, true) then return true, v end
  end
  return false, v
end

-- args: target, filter, max rows
COMMANDS.stat_search = function(a)
  local c = get_target(a[1])
  local filter = (a[2] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if filter == "" then error("enter a filter") end
  local maxrows = math.min(int(a[3] or 100), 400)
  local lines, shown = {}, 0
  for si, s in ipairs(stat_sources(c)) do
    for _, e in ipairs(stat_entries(s)) do
      if shown >= maxrows then break end
      local ok, v = stat_match(s, e, filter)
      if ok and type(v) == "number" then
        shown = shown + 1
        lines[#lines + 1] = string.format("%d\t%s\t%s\t%s\t%s", si, clean(s.label), e.kind, clean(e.name), tostring(v))
      end
    end
  end
  if not wr(DIR .. "stats.txt", table.concat(lines, "\n")) then error("could not write stats.txt") end
  return tostring(shown)
end

-- args: target, source index, kind (f/p), name, value, lock(0/1)
COMMANDS.stat_set = function(a)
  local c = get_target(a[1])
  local s = stat_sources(c)[int(a[2])]
  if not s then error("source not found - search again") end
  local e = { kind = a[3] == "p" and "p" or "f", name = a[4] }
  local cur = stat_read(s.obj, e)
  if type(cur) ~= "number" then error("field not readable") end
  local nv = typed_value(cur, a[5])
  stat_write(s.obj, e, nv)
  set_lock(a[1] .. ":s" .. a[2] .. ":" .. a[4], s.obj, e, nv, a[6] == "1")
  return "ok"
end

re.on_frame(function()
  for _, l in pairs(LOCKS) do
    local cur = stat_read(l.obj, l.e)
    if type(cur) == "number" and cur ~= l.v then pcall(stat_write, l.obj, l.e, l.v) end
  end
end)

---------------------------------------------------------------- v1.6 equipment-ability probe
-- Special skills on weapons (Shearing Wind, Fanged Rupture, ...) are "equipment abilities". This lists every function on the
-- character's contexts / managers that deals with EquipmentAbilityID, and calls the read-only ones for EVERY ability id.
-- Run it WITH the item equipped: the ids that answer true are the ones the game currently treats as active.
COMMANDS.eqability_probe = function(a)
  local c = get_target(a[1])
  local ids = enum_list("app.EquipmentAbilityID")
  local sources, seenaddr = {}, {}
  local function addsrc(label, obj)
    if type(obj) ~= "userdata" then return end
    local ad = try(function() return obj:get_address() end)
    if ad and seenaddr[ad] then return end
    if ad then seenaddr[ad] = true end
    sources[#sources + 1] = { label = label, obj = obj }
  end
  addsrc("SkillContext", c.skill)
  for _, s2 in ipairs(stat_sources(c)) do addsrc(s2.label, s2.obj) end
  for _, n in ipairs({ "app.ItemManager", "app.CharacterManager", "app.PawnManager" }) do
    addsrc((n:gsub("^app%.", "")), sdk.get_managed_singleton(n))
  end
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  L("SOURCE\tKIND\tDETAIL")
  L("(" .. #ids .. " EquipmentAbilityID values, " .. #sources .. " sources)")
  for _, s2 in ipairs(sources) do
    local td = try(function() return s2.obj:get_type_definition() end)
    local seenm = {}
    while td do
      for _, m in ipairs(td:get_methods() or {}) do
        local n = m:get_name()
        local ln = n:lower()
        local pts = m:get_param_types() or {}
        local ps, uses = {}, false
        for _, p in ipairs(pts) do
          local pn = try(function() return p:get_full_name() end) or "?"
          ps[#ps + 1] = pn
          if pn:find("EquipmentAbilityID", 1, true) then uses = true end
        end
        local key = n .. "/" .. #pts
        if (uses or ln:find("equipability", 1, true) or ln:find("equipmentability", 1, true)) and not seenm[key] then
          seenm[key] = true
          local rt = try(function() return m:get_return_type():get_full_name() end) or "?"
          L(s2.label .. "\tMETHOD\t" .. n .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt)
          if #pts == 1 and uses and probe_name_ok(ln) then
            local trues = {}
            for _, e in ipairs(ids) do
              local ok, v = pcall(function() return m:call(s2.obj, e.value) end)
              if ok and (v == true or (type(v) == "number" and v ~= 0)) then
                trues[#trues + 1] = e.name .. "=" .. tostring(v)
              end
            end
            local shown = {}
            for i = 1, math.min(#trues, 80) do shown[i] = trues[i] end
            L(s2.label .. "\tTRUE-FOR\t" .. n .. " (" .. #trues .. " ids): " .. table.concat(shown, " ")
              .. (#trues > 80 and " ..." or ""))
          end
        end
      end
      td = try(function() return td:get_parent_type() end)
    end
  end
  for _, l in ipairs(lines) do log.info(TAG .. "eqability: " .. l) end
  if not wr(DIR .. "eqability.txt", table.concat(lines, "\n")) then error("could not write eqability.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.7 equipment-ability probe, part 2
-- Which abilities does the game consider ACTIVE on this character (calcEquipmentAbilityFactor), what does the
-- character's equipped-ability list for the chosen vocation contain, and what does the ability data table look like.
local function dump_obj(L, obj, label, depth, maxn)
  if type(obj) ~= "userdata" then L(label .. " = " .. tostring(obj)) return end
  local td = try(function() return obj:get_type_definition() end)
  L(label .. " : " .. (td and td:get_full_name() or "?"))
  if depth <= 0 or not td then return end
  local t, seen = td, {}
  while t do
    for _, f in ipairs(t:get_fields() or {}) do
      if not f:is_static() then
        local n = f:get_name()
        if not seen[n] then
          seen[n] = true
          local v = try(function() return obj:get_field(n) end)
          if type(v) == "userdata" then
            local els = coll_elems(v)
            if #els > 0 then
              L(label .. "." .. n .. " = collection n=" .. #els)
              for i = 1, math.min(#els, maxn) do
                dump_obj(L, els[i], label .. "." .. n .. "[" .. i .. "]", depth - 1, maxn)
              end
            else
              dump_obj(L, v, label .. "." .. n, depth - 1, maxn)
            end
          else
            L(label .. "." .. n .. " = " .. tostring(v))
          end
        end
      end
    end
    t = try(function() return t:get_parent_type() end)
  end
end

COMMANDS.eqability_probe2 = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local ids = enum_list("app.EquipmentAbilityID")
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local chara = follow(c.human, { "<Chara>k__BackingField" })
  local cid
  for _, o in ipairs({ c.src, chara }) do
    for _, h in ipairs({ "get_CharaID", "get_CharaId", "getCharaID" }) do
      if cid == nil and type(o) == "userdata" then cid = try(function() return o:call(h) end) end
    end
  end
  L("character id = " .. tostring(cid) .. "   vocation = " .. job)
  local itm = sdk.get_managed_singleton("app.ItemManager")
  if cid ~= nil and itm then
    L("== ACTIVE abilities (calcEquipmentAbilityFactor ~= 0) ==")
    local n = 0
    for _, e in ipairs(ids) do
      local v = try(function() return itm:call("calcEquipmentAbilityFactor", cid, e.value) end)
      if type(v) == "number" and v ~= 0 then
        n = n + 1
        L(string.format("ACTIVE  %s (id %s) factor %s", e.name, fmt_int(e.value), tostring(v)))
      end
    end
    L("(" .. n .. " active)")
  else
    L("could not read the character id / ItemManager")
  end
  L("== AbilityContext.getEquipAbilityList(" .. job .. ") ==")
  if c.ability then
    local r = try(function() return c.ability:call("getEquipAbilityList", job) end)
    if r ~= nil then dump_obj(L, r, "equipList", 3, 12) else L("returned nothing") end
  end
  L("== ALL EquipmentAbilityID values (id = name) ==")
  for _, e in ipairs(ids) do L(string.format("%s = %s", fmt_int(e.value), e.name)) end
  for _, l in ipairs(lines) do log.info(TAG .. "eqability2: " .. l) end
  if not wr(DIR .. "eqability2.txt", table.concat(lines, "\n")) then error("could not write eqability2.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.1 item editor (equipment skills, appraisal, enhancement, stats)
local IT = { owners = {}, rows = {}, owner_idx = 1 }

local function im() return sdk.get_managed_singleton("app.ItemManager") end

local function player_charid()
  local cm = sdk.get_managed_singleton("app.CharacterManager")
  if not cm then return nil end
  for _, g in ipairs({ "get_ManualPlayer", "getManualPlayer", "get_ManualPlayerNoCheck" }) do
    local p = try(function() return cm:call(g) end)
    if p then
      for _, h in ipairs({ "get_CharaID", "get_CharaId", "getCharaID" }) do
        local id = try(function() return p:call(h) end)
        if type(id) == "number" then return id end
      end
    end
  end
  return nil
end

local function cur_key()
  local o = IT.owners[IT.owner_idx]
  return o and o.key
end

local function find_character(key)
  local cands = {}
  local cm = sdk.get_managed_singleton("app.CharacterManager")
  if cm then
    local p = try(function() return cm:call("get_ManualPlayer") end)
    if p then cands[#cands + 1] = p end
  end
  local pm = sdk.get_managed_singleton("app.PawnManager")
  if pm then
    local p = try(function() return pm:call("get_MainPawn") end)
    if p then
      local ch = try(function() return p:call("get_Chara") end) or try(function() return p:call("get_Character") end) or p
      cands[#cands + 1] = ch
    end
  end
  for _, ch in ipairs(cands) do
    for _, h in ipairs({ "get_CharaID", "get_CharaId" }) do
      local id = try(function() return ch:call(h) end)
      if id == key then return ch end
    end
  end
  return nil
end

local function slots_of(ab)
  local t = {}
  if ab then for i = 1, 4 do t[i] = tostring(try(function() return ab:get_field("Slot" .. i) end)) end end
  return table.concat(t, ",")
end

local function get_ability(master) return try(function() return master:call("get_Ability") end) end

local function describe(master)
  local item = try(function() return master:call("get_ItemData") end)
  local name = item and try(function() return item:call("get_Name") end) or "?"
  local isequip = item and try(function() return item:call("get_IsEquip") end)
  local equipped = try(function() return master:call("get_IsEquipped") end)
  local ab = get_ability(master)
  local slots = {}
  for i = 1, 4 do slots[i] = ab and try(function() return ab:get_field("Slot" .. i) end) or 0 end
  return { master = master, name = clean(name), isequip = isequip and true or false,
           equipped = equipped and true or false, slots = slots }
end

local function row_of(i)
  local r = IT.rows[int(i)]
  if not r then error("item row not found - reload the item list") end
  return r
end

local function write_ability(master, mutate)
  local ab = get_ability(master)
  if not ab then error("could not read ability") end
  mutate(ab)
  master:call("set_Ability", ab)
  return slots_of(get_ability(master))
end

local function equipped_copy(master, key)
  local m = im()
  if not m then return nil end
  local ro = try(function() return m:call("getEquipData", key) end)
  if not ro then return nil end
  local ed = try(function() return ro:get_field("Data") end)
  if not ed then return nil end
  local sid = try(function() return master:call("get_StorageId") end)
  local equips = try(function() return ed:get_field("Equips") end)
  if not equips then return nil end
  for i, el in ipairs(elems_of(equips)) do
    local es = try(function() return el:get_field("_StorageId") end)
    if es ~= nil and es == sid then return ed, el, i - 1 end
  end
  return ed, nil, nil
end

local function full_apply(master)
  local key = cur_key()
  local m = im()
  if not m then error("ItemManager not available") end
  local report = {}
  local ab = get_ability(master)
  local param = try(function() return master:call("get_Param") end)
  local ed, el = equipped_copy(master, key)
  if el and ab then
    pcall(function() el:set_field("_Ability", ab) end)
    local back = try(function() return el:get_field("_Ability") end)
    if slots_of(back) ~= slots_of(ab) then
      pcall(function()
        for s = 1, 4 do
          back:set_field("Slot" .. s, try(function() return ab:get_field("Slot" .. s) end) or 0)
        end
      end)
      back = try(function() return el:get_field("_Ability") end)
    end
    report[#report + 1] = "equipCopy=" .. (slots_of(back) == slots_of(ab) and "OK" or "MISMATCH")
  else
    report[#report + 1] = "equipCopy: none"
  end
  if param and ab then
    report[#report + 1] = "updateEquipAbility:" .. tostring(pcall(function() m:call("updateEquipAbility", param, ab) end))
    report[#report + 1] = "acquire:" .. tostring(pcall(function() m:call("acquireEquipmentAbility", ab) end))
  end
  if ed then report[#report + 1] = "calc:" .. tostring(pcall(function() ed:call("calc") end)) end
  local ch = find_character(key)
  if ch then
    report[#report + 1] = "applyEquipData:" .. tostring(pcall(function() m:call("applyEquipDataForCharacter", ch) end))
  else
    report[#report + 1] = "character not found (only you / main pawn supported)"
  end
  return table.concat(report, " | ")
end

local function recalc(master)
  local key = cur_key()
  local m = im()
  if not m then error("ItemManager not available") end
  local rep = {}
  local ed, el = equipped_copy(master, key)
  local param = try(function() return master:call("get_Param") end)
  if el then
    local enh = try(function() return master:call("get_Enhance") end)
    if enh then rep[#rep + 1] = "syncEnh:" .. tostring(pcall(function() el:set_field("_Enhance", enh) end)) end
  end
  if ed and param then rep[#rep + 1] = "updateEnhanceEquip:" .. tostring(pcall(function() ed:call("updateEnhanceEquip", param) end)) end
  if ed then rep[#rep + 1] = "calc:" .. tostring(pcall(function() ed:call("calc") end)) end
  local ch = find_character(key)
  if ch then rep[#rep + 1] = "apply:" .. tostring(pcall(function() m:call("applyEquipDataForCharacter", ch) end)) end
  return "recalc: " .. table.concat(rep, " | ")
end

-- owners: "idx,key,count,isplayer;..."
COMMANDS.item_owners = function()
  local m = im()
  if not m then error("ItemManager not ready (load a save first)") end
  local sd = try(function() return m:get_field("StorageDict") end)
  local pid = player_charid()
  local owners = {}
  dict_iter(sd, function(k, list)
    local items = try(function() return list:get_field("_items") end)
    local size = try(function() return list:get_field("_size") end) or 0
    if items then
      local els = elems_of(items)
      local ms = {}
      for i = 1, math.min(size, #els) do ms[#ms + 1] = els[i] end
      owners[#owners + 1] = { key = k, masters = ms, is_player = (pid ~= nil and k == pid) }
    end
  end)
  table.sort(owners, function(x, y)
    if x.is_player ~= y.is_player then return x.is_player and true or false end
    return #x.masters > #y.masters
  end)
  IT.owners, IT.owner_idx, IT.rows = owners, 1, {}
  local out = {}
  for i, o in ipairs(owners) do
    out[#out + 1] = string.format("%d,%s,%d,%d", i, clean(o.key), #o.masters, o.is_player and 1 or 0)
  end
  return table.concat(out, ";")
end

-- args: owner idx, only equipment(0/1), only equipped(0/1) -> writes itemrows.txt
local reapply_item_names
COMMANDS.item_rows = function(a)
  local oi, only_equip, only_equipped = int(a[1]), a[2] == "1", a[3] == "1"
  local o = IT.owners[oi]
  if not o then error("owner not found - reload the inventory first") end
  IT.owner_idx = oi
  reapply_item_names(o.masters)
  local rows = {}
  for _, m in ipairs(o.masters) do
    local d = describe(m)
    if (not only_equip or d.isequip) and (not only_equipped or d.equipped) then rows[#rows + 1] = d end
  end
  table.sort(rows, function(x, y) return x.name < y.name end)
  IT.rows = rows
  local lines = {}
  for i, d in ipairs(rows) do
    lines[#lines + 1] = string.format("%d\t%s\t%d\t%s", i, d.name, d.equipped and 1 or 0,
      table.concat({ fmt_int(d.slots[1]), fmt_int(d.slots[2]), fmt_int(d.slots[3]), fmt_int(d.slots[4]) }, ","))
  end
  if not wr(DIR .. "itemrows.txt", table.concat(lines, "\n")) then error("could not write itemrows.txt") end
  return tostring(#rows)
end

-- "s1,s2,s3,s4,isAppraised,phys,magic,blow,weight,equipped"
COMMANDS.item_get = function(a)
  local r = row_of(a[1])
  local ab = get_ability(r.master)
  if not ab then error("could not read ability") end
  local function f(n) return tostring(try(function() return ab:get_field(n) end) or 0) end
  local appr = try(function() return ab:get_field("IsAppraised") end)
  local equipped = try(function() return r.master:call("get_IsEquipped") end)
  return table.concat({ f("Slot1"), f("Slot2"), f("Slot3"), f("Slot4"), appr and "1" or "0",
    f("PhysicalParameter"), f("MagicParameter"), f("BlowParameter"), f("WeightParameter"),
    equipped and "1" or "0" }, ",")
end

COMMANDS.item_set_slot = function(a)
  local r = row_of(a[1])
  local slot, id = int(a[2]), int(a[3])
  if slot < 1 or slot > 4 then error("bad slot") end
  local now = write_ability(r.master, function(ab) ab:set_field("Slot" .. slot, id) end)
  return "slots now: " .. now
end

COMMANDS.item_clear = function(a)
  local r = row_of(a[1])
  local now = write_ability(r.master, function(ab) for s = 1, 4 do ab:set_field("Slot" .. s, 0) end end)
  return "slots now: " .. now
end

COMMANDS.item_apply = function(a)
  return full_apply(row_of(a[1]).master)
end

-- args: row, physical, magic, blow, weight, isAppraised(0/1)
COMMANDS.item_set_appraisal = function(a)
  local r = row_of(a[1])
  local vals = { PhysicalParameter = int(a[2]), MagicParameter = int(a[3]), BlowParameter = int(a[4]), WeightParameter = int(a[5]) }
  write_ability(r.master, function(ab)
    for n, v in pairs(vals) do ab:set_field(n, v) end
    ab:set_field("IsAppraised", a[6] == "1")
  end)
  return full_apply(r.master)
end

-- ---------------------------------------------------------------- element (blue-triangle enhancement)
local ELEM_BITS = { "FireElement", "IceElement", "ThunderElement", "LightElement" }
local ELEM_LABELS = { FireElement = "Fire", IceElement = "Ice", ThunderElement = "Lightning", LightElement = "Holy" }
local ELEM_FROM_LABEL = { Fire = "FireElement", Ice = "IceElement", Lightning = "ThunderElement", Holy = "LightElement" }
local BONUS_ORDER = { "Slot1", "Slot2", "Slot3", "Slot4", "PhysicalParam", "MagicParam", "BlowParam",
  "SlashDefence", "StrikeDefence", "FireElement", "IceElement", "ThunderElement", "LightElement" }

local bonus_bits_cache = nil
local function bonus_bits()
  if bonus_bits_cache then return bonus_bits_cache end
  local t = {}
  for _, e in ipairs(enum_list("app.EquipmentAbilityBonus")) do t[e.name] = e.value end
  bonus_bits_cache = t
  return t
end

local function bonus_mask()
  local m, bits = 0, bonus_bits()
  for _, n in ipairs(BONUS_ORDER) do m = m | (bits[n] or 0) end
  return m
end

-- current enhancement bit name: "None", one BONUS_ORDER name, or "several"
local function bonus_cur_name(bonus)
  local bits = bonus_bits()
  local cur = (bonus or 0) & bonus_mask()
  if cur == 0 then return "None" end
  for _, n in ipairs(BONUS_ORDER) do if cur == (bits[n] or 0) then return n end end
  return "several"
end

-- element labels this item may carry (game rules); nil if the query fails
local function valid_element_names(master)
  local item_id = try(function() return master:call("get_ItemId") end)
  local ab = get_ability(master)
  if type(item_id) ~= "number" or not ab then return nil end
  local td = sdk.find_type_definition("app.EquipmentAbilityUtil")
  local m = td and find_method(td, "getValidBonusIgnoreGrade", { "app.ItemIDEnum", "app.ItemDefine.EquipmentAbilityParam" })
  local set = m and try(function() return m:call(nil, item_id, ab) end)
  if not set then return nil end
  local bits, out = bonus_bits(), {}
  for _, n in ipairs(ELEM_BITS) do
    local b = bits[n]
    if b and try(function() return set:call("Contains", b) end) == true then out[#out + 1] = ELEM_LABELS[n] end
  end
  return out
end

-- element the game itself computes for this item (verification read)
local function game_element(master)
  local param = try(function() return master:call("get_Param") end)
  local enh = param and try(function() return param:call("makeEnhancedParam") end)
  local v = enh and try(function() return enh:call("get_Element") end)
  if type(v) ~= "number" then return "?" end
  local n = enum_by_val("app.AttackUserData.ElementType")[v] or ("#" .. tostring(v))
  if n == "Thunder" then return "Lightning" end
  if n == "Light" then return "Holy" end
  return n
end

-- "curBitName|allowedCsv|gameElement|isWeapon" ; allowedCsv "?" if the rule query failed
COMMANDS.item_get_element = function(a)
  local r = row_of(a[1])
  local ab = get_ability(r.master)
  if not ab then error("could not read ability") end
  local bonus = try(function() return ab:get_field("Bonus") end) or 0
  local allowed = valid_element_names(r.master)
  local item = try(function() return r.master:call("get_ItemData") end)
  local dtype = item and try(function() return item:get_field("<DataType>k__BackingField") end)
  return table.concat({ bonus_cur_name(bonus),
    allowed and table.concat(allowed, ",") or "?",
    game_element(r.master), dtype == 2 and "1" or "0" }, "|")
end

-- args: row, element (None/Fire/Ice/Lightning/Holy). Replaces any other
-- enhancement bit (only one works) and marks the item appraised so the
-- element actually shows in game. Refuses elements the game's rules
-- disallow for this item.
COMMANDS.item_set_element = function(a)
  local r = row_of(a[1])
  local want = a[2] or "None"
  local bit = 0
  if want ~= "None" then
    local name = ELEM_FROM_LABEL[want]
    if not name then error("bad element: " .. tostring(want)) end
    bit = bonus_bits()[name] or error("element bit not found: " .. name)
    local allowed = valid_element_names(r.master)
    if allowed then
      local ok = false
      for _, x in ipairs(allowed) do if x == want then ok = true end end
      if not ok then error("this item cannot have " .. want .. " (game rules)") end
    end
  end
  write_ability(r.master, function(ab)
    local bonus = try(function() return ab:get_field("Bonus") end) or 0
    ab:set_field("Bonus", (bonus & ~bonus_mask()) | bit)
    ab:set_field("IsAppraised", true)
  end)
  return full_apply(r.master)
end

-- args: row. Dumps every field that could hold the element % to elemprobe.txt:
-- all fields of EquipmentAbilityParam, all fields of makeEnhancedParam(),
-- element-named fields of WeaponParam and StorageData.
COMMANDS.item_element_probe = function(a)
  local r = row_of(a[1])
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  local function dump_fields(tag, obj, only_elem)
    add("== " .. tag .. " ==")
    if not obj then add("(none)") return end
    local td = try(function() return obj:get_type_definition() end)
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
      local n = try(function() return f:get_name() end)
      if n and (not only_elem or n:find("lement")) then
        local v = try(function() return obj:get_field(n) end)
        add(n .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
      end
    end
  end
  dump_fields("EquipmentAbilityParam (ability)", get_ability(r.master), false)
  local param = try(function() return r.master:call("get_Param") end)
  local enh = param and try(function() return param:call("makeEnhancedParam") end)
  dump_fields("makeEnhancedParam (EquipParam)", enh, false)
  local item = try(function() return r.master:call("get_ItemData") end)
  local wp = item and try(function() return item:call("get_WeaponParam") end)
  dump_fields("WeaponParam (element fields)", wp, true)
  dump_fields("StorageData (element fields)", param, true)
  add("== StorageData._TempElement (inner fields) ==")
  local temp = param and try(function() return param:get_field("_TempElement") end)
  if temp then
    local td = try(function() return temp:get_type_definition() end)
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
      local n = try(function() return f:get_name() end)
      if n then
        local v = try(function() return temp:get_field(n) end)
        add(n .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
      end
    end
  else add("(none)") end
  add("== Enhance (get_Enhance) ==")
  local enh2 = try(function() return r.master:call("get_Enhance") end)
  if enh2 then
    local td = try(function() return enh2:get_type_definition() end)
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
      local n = try(function() return f:get_name() end)
      if n then
        local v = try(function() return enh2:get_field(n) end)
        add(n .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
      end
    end
  else add("(none)") end
  add("== StorageData (ALL fields) ==")
  if param then
    local td = try(function() return param:get_type_definition() end)
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
      local n = try(function() return f:get_name() end)
      if n then
        local v = try(function() return param:get_field(n) end)
        add(n .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
      end
    end
  end
  add("== EquipParam array entries (all fields) ==")
  if enh then
    for _, an in ipairs({ "ElementType", "StoreType" }) do
      local arr = try(function() return enh:get_field(an) end)
      local els = arr and elems_of(arr)
      add(an .. " n=" .. tostring(els and #els or "?"))
      if els then
        for i, e in ipairs(els) do
          local td = try(function() return e:get_type_definition() end)
          local tn = td and try(function() return td:get_full_name() end)
          add("  [" .. i .. "] type=" .. tostring(tn))
          for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
            local n = try(function() return f:get_name() end)
            if n then
              local v = try(function() return e:get_field(n) end)
              add("    " .. n .. " = " .. tostring(v))
            end
          end
        end
      end
    end
  end
  if not wr(DIR .. "elemprobe.txt", table.concat(lines, "\n")) then error("could not write elemprobe.txt") end
  return "wrote elemprobe.txt (" .. #lines .. " lines)"
end

-- element restriction unlock (Kairos "remove element restriction"): the game
-- decides which elements a weapon may carry in
-- EquipmentAbilityUtil.gatherWeaponValidBonus(set, weaponParam). Hooking it
-- and adding all four element bits to the set makes every weapon accept any
-- element, for this session (hooks clear on game restart; disallowed
-- elements then show as None again). One-way: hooks cannot be removed.
local elem_unlock = { hooked = false }
local function install_elem_unlock()
  if elem_unlock.hooked then return "element restrictions already removed" end
  local td = sdk.find_type_definition("app.EquipmentAbilityUtil")
  local m = td and try(function()
    return td:get_method("gatherWeaponValidBonus(System.Collections.Generic.HashSet`1<app.EquipmentAbilityBonus>, app.ItemWeaponParam)")
  end)
  if not m then error("gatherWeaponValidBonus not found") end
  local ok = pcall(sdk.hook, m,
    function(args)
      local st = thread.get_hook_storage()
      st.elem_set = try(function() return sdk.to_managed_object(args[2]) end)
    end,
    function(retval)
      local st = thread.get_hook_storage()
      local set = st.elem_set
      st.elem_set = nil
      if set then
        local bits = bonus_bits()
        for _, n in ipairs(ELEM_BITS) do
          local b = bits[n]
          if b then pcall(function() set:call("Add", b) end) end
        end
      end
      return retval
    end)
  if not ok then error("element unlock hook failed") end
  elem_unlock.hooked = true
  return "element restrictions removed for this session - every weapon can now take any element"
end

COMMANDS.item_element_unlock = function(a)
  return install_elem_unlock()
end

-- auto-install at load: forced elements must validate every session, and
-- hooks do not survive a game restart. pcall: if the method is missing the
-- game still loads fine and the button remains as a fallback.
pcall(install_elem_unlock)

-- element % overrides: the displayed % is EquipParam._ElementStore, which
-- makeEnhancedParam hardcodes (no stored field feeds it), so override it in
-- a post-hook. Keyed by chara:storage:item so it targets one item.
-- Persisted to elemstore.txt so overrides survive restarts.
local ELEM_DIAG = { installed = false, install_status = "not attempted", pre_calls = 0, matched = 0, last_key = nil, this_idx = nil, sret_idx = nil, post_sets = 0, last_args = nil }
local WES_DIAG = { calls = 0, applied = 0 }
local ELEM_ACTIVE_PTR = nil
local ELEM_ACTIVE_PCT = nil
local ELEM_STORE = {}
local function elem_store_key(sd)
  local c = try(function() return sd:get_field("_CharaId") end)
  local s = try(function() return sd:get_field("_StorageId") end)
  local i = try(function() return sd:get_field("_ItemId") end)
  if c == nil or s == nil or i == nil then return nil end
  return tostring(c) .. ":" .. tostring(s) .. ":" .. tostring(i)
end
local function elem_store_load()
  local text = rd(DIR .. "elemstore.txt")
  if not text then return end
  for k, v in text:gmatch("([^=%s]+)=(%d+)") do ELEM_STORE[k] = tonumber(v) end
end
local ITEM_NAMES = {}
local ITEM_NAMES_APPLIED = {}
local function item_names_load()
  local text = rd(DIR .. "itemnames.txt")
  if not text then return end
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local id, nm = line:match("^(%d+)=(.*)$")
    if id and nm ~= "" then ITEM_NAMES[tonumber(id)] = nm end
  end
end
local function item_names_save()
  local lines = {}
  for id, nm in pairs(ITEM_NAMES) do lines[#lines + 1] = tostring(id) .. "=" .. nm end
  wr(DIR .. "itemnames.txt", table.concat(lines, "\n"))
end
item_names_load()
local NAME_MAP = {}
local NAME_DIAG = { installed = false, status = "not installed", calls = 0, matched = 0, id_field = nil, seen_id = nil, seen_ptr = nil, type_name = nil }
local NAME_ID_FIELD = nil
local function itemdata_item_id(item)
  if NAME_ID_FIELD then
    return try(function() return item:get_field(NAME_ID_FIELD) end)
  end
  for _, fn in ipairs({ "_ItemId", "ItemId", "_Id", "Id", "_ItemID", "ItemID" }) do
    local v = try(function() return item:get_field(fn) end)
    if type(v) == "number" then NAME_ID_FIELD = fn return v end
  end
  return nil
end
local function install_name_hook_from(td)
  if NAME_DIAG.installed or not td then return false end
  local m, cur = nil, td
  while cur and not m do
    m = find_method(cur, "get_Name", {})
    if not m then cur = try(function() return cur:get_parent_type() end) end
  end
  if not m then return false end
  local ok = pcall(sdk.hook, m,
    function(args)
      local st = thread.get_hook_storage()
      st.name_obj = try(function() return sdk.to_managed_object(args[2]) end)
    end,
    function(retval)
      local st = thread.get_hook_storage()
      local obj = st.name_obj
      st.name_obj = nil
      NAME_DIAG.calls = NAME_DIAG.calls + 1
      local custom = nil
      if obj then
        local id = itemdata_item_id(obj)
        NAME_DIAG.id_field = NAME_ID_FIELD
        NAME_DIAG.seen_id = id
        custom = id and ITEM_NAMES[id]
        if not custom then
          local ptr = try(function() return sdk.to_int64(obj) end)
          NAME_DIAG.seen_ptr = ptr
          custom = ptr and NAME_MAP[ptr]
        end
      end
      if custom then
        NAME_DIAG.matched = NAME_DIAG.matched + 1
        return sdk.create_managed_string(custom)
      end
      return retval
    end)
  if ok then
    NAME_DIAG.installed = true
    NAME_DIAG.status = "installed"
    NAME_DIAG.type_name = try(function() return td:get_full_name() end)
    log.info(TAG .. "name hook installed on " .. tostring(NAME_DIAG.type_name))
    return true
  end
  return false
end
local function install_name_hook()
  for _, tn in ipairs({ "app.ItemDataParam", "app.ItemDefine.ItemDataParam" }) do
    local td = sdk.find_type_definition(tn)
    if td and install_name_hook_from(td) then return end
  end
  if not NAME_DIAG.installed then NAME_DIAG.status = "get_Name not found" end
end
pcall(install_name_hook)
reapply_item_names = function(masters)
  if not NAME_DIAG.installed and #masters > 0 then
    local it0 = try(function() return masters[1]:call("get_ItemData") end)
    if it0 then
      local td0 = try(function() return it0:get_type_definition() end)
      install_name_hook_from(td0)
    end
  end
  for _, m in ipairs(masters) do
    local param = try(function() return m:call("get_Param") end)
    local id = param and try(function() return param:get_field("_ItemId") end)
    local nm = id and ITEM_NAMES[id]
    if nm and not ITEM_NAMES_APPLIED[id] then
      local item = try(function() return m:call("get_ItemData") end)
      if item then
        local ptr = try(function() return sdk.to_int64(item) end)
        if ptr then NAME_MAP[ptr] = nm end
        ITEM_NAMES_APPLIED[id] = true
      end
    end
  end
end

local function elem_store_save()
  local lines = {}
  for k, v in pairs(ELEM_STORE) do lines[#lines + 1] = k .. "=" .. tostring(v) end
  wr(DIR .. "elemstore.txt", table.concat(lines, "\n"))
end
local function install_elem_store_hook()
  local td = sdk.find_type_definition("app.ItemDefine.StorageData")
  local m = td and find_method(td, "makeEnhancedParam", {})
  if not m then ELEM_DIAG.install_status = "no method" log.info(TAG .. "elemstore: makeEnhancedParam not found") return end
  -- makeEnhancedParam returns a large struct, so the game passes a hidden
  -- return-buffer pointer that shifts `this` from args[2] to args[3].
  -- Scan args[2..3] once for the StorageData (has _StorageId) and the
  -- return buffer (has _ElementStore), then cache the indices.
  local function find_indices(args)
    if ELEM_DIAG.this_idx and ELEM_DIAG.sret_idx then return ELEM_DIAG.this_idx, ELEM_DIAG.sret_idx end
    local ti, si = nil, nil
    for i = 2, 3 do
      local a = args[i]
      if a ~= nil then
        local obj = try(function() return sdk.to_managed_object(a) end)
        if obj then
          if type(try(function() return obj:get_field("_StorageId") end)) == "number" then ti = i end
          if type(try(function() return obj:get_field("_ElementStore") end)) == "number" then si = i end
        end
      end
      if ti and si then break end
    end
    if ti then ELEM_DIAG.this_idx = ti end
    if si then ELEM_DIAG.sret_idx = si end
    return ti, si
  end
  local ok = pcall(sdk.hook, m,
    function(args)
      local st = thread.get_hook_storage()
      st.elem_pct = nil
      st.elem_buf = nil
      do
        local parts = {}
        for i = 1, 4 do
          local a = args[i]
          local raw = a ~= nil and tostring(try(function() return sdk.to_int64(a) end)) or "nil"
          local tn = "nil"
          if a ~= nil then
            local obj = try(function() return sdk.to_managed_object(a) end)
            if obj then tn = tostring(try(function()
              local td = obj:get_type_definition()
              return td and td:get_full_name()
            end)) end
          end
          parts[#parts + 1] = i .. ":" .. raw .. ":" .. tn
        end
        ELEM_DIAG.last_args = table.concat(parts, " ; ")
      end
      local ti, si = find_indices(args)
      local sd = ti and try(function() return sdk.to_managed_object(args[ti]) end)
      local key = sd and elem_store_key(sd)
      ELEM_DIAG.pre_calls = ELEM_DIAG.pre_calls + 1
      ELEM_DIAG.last_key = key or "(nil)"
      if key and ELEM_STORE[key] then
        ELEM_DIAG.matched = ELEM_DIAG.matched + 1
        st.elem_pct = ELEM_STORE[key]
        if si then st.elem_buf = try(function() return sdk.to_managed_object(args[si]) end) end
      end
    end,
    function(retval)
      local st = thread.get_hook_storage()
      local pct = st.elem_pct
      local buf = st.elem_buf
      st.elem_pct = nil
      st.elem_buf = nil
      if pct ~= nil then
        local done = false
        if buf then done = pcall(function() buf:set_field("_ElementStore", pct) end) end
        if not done then
          local ep = try(function() return sdk.to_managed_object(retval) end)
          if ep then done = pcall(function() ep:set_field("_ElementStore", pct) end) end
        end
        if done then ELEM_DIAG.post_sets = ELEM_DIAG.post_sets + 1 end
      end
      return retval
    end)
  if not ok then ELEM_DIAG.install_status = "hook failed" log.info(TAG .. "elemstore: hook install failed") end
  if ok then ELEM_DIAG.installed = true ELEM_DIAG.install_status = "ok" end
end

elem_store_load()
pcall(install_elem_store_hook)

local CALC_DIAG = { calls = 0, sets = 0 }
local GE_DIAG = { calls = 0 }
local function install_calc_hook()
  local td = sdk.find_type_definition("app.EquipData")
  local m = td and find_method(td, "calc", {})
  if not m then log.info(TAG .. "calc hook: method not found") return end
  local ok = pcall(sdk.hook, m,
    function(args)
      local st = thread.get_hook_storage()
      st.calc_ed = try(function() return sdk.to_managed_object(args[2]) end)
    end,
    function(retval)
      local st = thread.get_hook_storage()
      local ed = st.calc_ed
      st.calc_ed = nil
      CALC_DIAG.calls = CALC_DIAG.calls + 1
      if ed then
        local equips = try(function() return ed:get_field("Equips") end)
        local els = equips and elems_of(equips)
        if els then
          for _, el in ipairs(els) do
            local key = elem_store_key(el)
            local over = key and ELEM_STORE[key]
            if over then
              local eqp = try(function() return ed:get_field("_EqParam") end)
              if eqp and pcall(function() eqp:set_field("_ElementStore", over) end) then
                CALC_DIAG.sets = CALC_DIAG.sets + 1
              end
              break
            end
          end
        end
      end
      return retval
    end)
  if ok then log.info(TAG .. "calc hook installed") end
end
pcall(install_calc_hook)
local function install_ge_hook()
  local td = sdk.find_type_definition("app.EquipParam")
  local m = td and find_method(td, "get_ElementStore", {})
  if not m then return end
  pcall(sdk.hook, m, nil, function(retval)
    GE_DIAG.calls = GE_DIAG.calls + 1
    return retval
  end)
end
pcall(install_ge_hook)
local function install_wes_hook()
  local td = sdk.find_type_definition("app.ItemWeaponParam")
  local m = td and find_method(td, "get_ElementStore", {})
  if not m then log.info(TAG .. "wes hook: method not found") return end
  local ok = pcall(sdk.hook, m,
    function(args)
      local st = thread.get_hook_storage()
      st.wes_this = try(function() return sdk.to_int64(args[2]) end)
    end,
    function(retval)
      local st = thread.get_hook_storage()
      local this_ptr = st.wes_this
      st.wes_this = nil
      WES_DIAG.calls = WES_DIAG.calls + 1
      if this_ptr ~= nil and ELEM_ACTIVE_PTR ~= nil and this_ptr == ELEM_ACTIVE_PTR
          and ELEM_ACTIVE_PCT ~= nil then
        WES_DIAG.applied = WES_DIAG.applied + 1
        return ELEM_ACTIVE_PCT
      end
      return retval
    end)
  if ok then log.info(TAG .. "wes hook installed") end
end
pcall(install_wes_hook)

-- "computed|override" ; override "" if none
COMMANDS.item_get_elem_store = function(a)
  local r = row_of(a[1])
  local param = try(function() return r.master:call("get_Param") end)
  local enh = param and try(function() return param:call("makeEnhancedParam") end)
  local computed = enh and try(function() return enh:get_field("_ElementStore") end) or 0
  local key = param and elem_store_key(param)
  local over = key and ELEM_STORE[key]
  return tostring(computed) .. "|" .. (over ~= nil and tostring(over) or "")
end

-- args: row, pct ("clear" to remove override, or a number)
COMMANDS.item_type_probe = function(a)
  local r = row_of(a[1])
  local item = try(function() return r.master:call("get_ItemData") end)
  if not item then error("could not read item data") end
  local td = try(function() return item:get_type_definition() end)
  if not td then error("no type definition") end
  local tname = try(function() return td:get_full_name() end) or "?"
  local ms = try(function() return td:get_methods() end) or {}
  local out = { "type|" .. tname, "methods|" .. tostring(#ms) }
  for _, m in ipairs(ms) do
    local mn = try(function() return m:get_name() end) or ""
    if mn:lower():find("name") then
      local pt = try(function() return m:get_param_types() end)
      out[#out + 1] = mn .. "(" .. (pt and tostring(#pt) or "?") .. ")"
    end
  end
  return table.concat(out, " // ")
end
COMMANDS.item_name_diag = function(a)
  local mapn, namesn = 0, 0
  for _ in pairs(NAME_MAP) do mapn = mapn + 1 end
  for _ in pairs(ITEM_NAMES) do namesn = namesn + 1 end
  return string.format("installed|%s|status|%s|type|%s|calls|%d|matched|%d|id_field|%s|seen_id|%s|seen_ptr|%s|map|%d|names|%d",
    tostring(NAME_DIAG.installed), tostring(NAME_DIAG.status), tostring(NAME_DIAG.type_name), NAME_DIAG.calls, NAME_DIAG.matched,
    tostring(NAME_DIAG.id_field), tostring(NAME_DIAG.seen_id), tostring(NAME_DIAG.seen_ptr), mapn, namesn)
end
COMMANDS.item_get_name = function(a)
  local r = row_of(a[1])
  local item = try(function() return r.master:call("get_ItemData") end)
  local cur = item and try(function() return item:call("get_Name") end) or "?"
  local param = try(function() return r.master:call("get_Param") end)
  local id = param and try(function() return param:get_field("_ItemId") end)
  local custom = id and ITEM_NAMES[id] or nil
  return clean(cur) .. "|" .. (custom or "")
end
COMMANDS.item_set_name = function(a)
  local r = row_of(a[1])
  local name = a[2] or ""
  if name:find("|", 1, true) then
    error("item names cannot contain '|'")
  end
  local item = try(function() return r.master:call("get_ItemData") end)
  if not item then error("could not read item data") end
  local param = try(function() return r.master:call("get_Param") end)
  local id = param and try(function() return param:get_field("_ItemId") end)
  if not id then error("could not identify item") end
  if name == "clear" or name == "" then
    ITEM_NAMES[id] = nil
    ITEM_NAMES_APPLIED[id] = nil
    do
      local ptr = try(function() return sdk.to_int64(item) end)
      if ptr then NAME_MAP[ptr] = nil end
    end
    item_names_save()
    return "custom name cleared (restart the game to restore the original name)"
  end
  name = clean_name(name)
  if name == "" then error("name is empty") end
  do
    local ptr = try(function() return sdk.to_int64(item) end)
    if ptr then NAME_MAP[ptr] = name end
  end
  ITEM_NAMES[id] = name
  ITEM_NAMES_APPLIED[id] = true
  item_names_save()
  return 'Item renamed to "' .. name .. '" (renames all items of this type)'
end
COMMANDS.item_set_elem_store = function(a)
  local r = row_of(a[1])
  local param = try(function() return r.master:call("get_Param") end)
  if not param then error("could not read storage data") end
  local key = elem_store_key(param)
  if not key then error("could not identify item") end
  local v = a[2]
  if v == "clear" or v == "" then
    ELEM_STORE[key] = nil
  else
    local pct = int(v)
    if pct < 0 then error("element % cannot be negative") end
    ELEM_STORE[key] = pct
  end
  elem_store_save()
  do
    local item = try(function() return r.master:call("get_ItemData") end)
    local wp = item and try(function() return item:call("get_WeaponParam") end)
    if wp and ELEM_STORE[key] ~= nil then
      ELEM_ACTIVE_PTR = try(function() return sdk.to_int64(wp) end)
      ELEM_ACTIVE_PCT = ELEM_STORE[key]
    else
      ELEM_ACTIVE_PTR = nil
      ELEM_ACTIVE_PCT = nil
    end
  end
  return full_apply(r.master)
end

-- "installed|status|preCalls|matched|lastKey|itemKey|override|computed|eqStorageId"
-- Snapshot of hook counters is taken BEFORE this command's own
-- makeEnhancedParam call, so lastKey shows what the GAME computed on.
-- args: row. Dumps EquipData fields + Equips elements, flagging any object
-- holding _ElementStore (a cached EquipParam), then calc() + re-check.
COMMANDS.item_equipdata_probe = function(a)
  local r = row_of(a[1])
  local key = cur_key()
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  local m = im()
  if not m then error("ItemManager not available") end
  local ro = try(function() return m:call("getEquipData", key) end)
  if not ro then error("getEquipData returned nil") end
  local ed = try(function() return ro:get_field("Data") end)
  if not ed then error("ro.Data nil") end
  add("== EquipData type: " .. tostring(try(function()
    local td = ed:get_type_definition() return td and td:get_full_name() end)) .. " ==")
  local function dump_obj(tag, obj, depth)
    local td = try(function() return obj:get_type_definition() end)
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
      local n = try(function() return f:get_name() end)
      if n then
        local v = try(function() return obj:get_field(n) end)
        local extra = ""
        if type(v) == "userdata" then
          local es = try(function() return v:get_field("_ElementStore") end)
          if es ~= nil then extra = "  <-- HAS _ElementStore=" .. tostring(es) end
          local vtd = try(function()
            local t2 = v:get_type_definition() return t2 and t2:get_full_name() end)
          if vtd then extra = extra .. " [" .. tostring(vtd) .. "]" end
        end
        add(string.rep("  ", depth) .. n .. " = " .. tostring(v) .. " (" .. type(v) .. ")" .. extra)
      end
    end
  end
  add("-- EquipData fields --")
  dump_obj("ed", ed, 0)
  add("-- Equips elements --")
  local equips = try(function() return ed:get_field("Equips") end)
  local els = equips and elems_of(equips)
  add("Equips n=" .. tostring(els and #els or "?"))
  if els then
    for i, el in ipairs(els) do
      local sid = try(function() return el:get_field("_StorageId") end)
      add("Equips[" .. (i - 1) .. "] _StorageId=" .. tostring(sid))
      dump_obj("el", el, 1)
    end
  end
  add("-- ArisenWeapons elements --")
  local aw = try(function() return ed:get_field("ArisenWeapons") end)
  local awels = aw and elems_of(aw)
  add("ArisenWeapons n=" .. tostring(awels and #awels or "?"))
  if awels then
    for i, el in ipairs(awels) do
      add("ArisenWeapons[" .. (i - 1) .. "]")
      dump_obj("aw", el, 1)
    end
  end
  add("-- after calc() --")
  local pre_before, mat_before = ELEM_DIAG.pre_calls, ELEM_DIAG.matched
  local ok_calc = pcall(function() ed:call("calc") end)
  add("calc ok=" .. tostring(ok_calc))
  add("hook calls during calc=" .. tostring(ELEM_DIAG.pre_calls - pre_before)
    .. " matched=" .. tostring(ELEM_DIAG.matched - mat_before))
  local td2 = try(function() return ed:get_type_definition() end)
  for _, f in ipairs(td2 and try(function() return td2:get_fields() end) or {}) do
    local n = try(function() return f:get_name() end)
    if n then
      local v = try(function() return ed:get_field(n) end)
      if type(v) == "userdata" then
        local es = try(function() return v:get_field("_ElementStore") end)
        if es ~= nil then add("  " .. n .. " _ElementStore=" .. tostring(es)) end
      end
    end
  end
  if not wr(DIR .. "equipdata.txt", table.concat(lines, "\n")) then error("could not write equipdata.txt") end
  return "wrote equipdata.txt (" .. #lines .. " lines)"
end

-- args: none. Lists methods on item types matching Param/Element/Calc/Enhance.
COMMANDS.item_methods_probe = function(a)
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  for _, tname in ipairs({ "app.ItemDefine.StorageData", "app.EquipData",
      "app.ItemDefine.EquipmentAbilityParam", "app.ItemWeaponParam",
      "app.ItemArmorParam", "app.EquipParam", "app.ItemManager" }) do
    add("== " .. tname .. " ==")
    local td = sdk.find_type_definition(tname)
    if not td then add("(type not found)") else
      for _, m in ipairs(try(function() return td:get_methods() end) or {}) do
        local n = try(function() return m:get_name() end) or ""
        if n:find("Param") or n:find("Element") or n:find("Calc") or n:find("calc")
            or n:find("Enhance") or n:find("enhance") then
          local rt = try(function()
            local t = m:get_return_type() return t and t:get_full_name() end)
          local pc = try(function() return m:get_num_params() end)
          add("  " .. n .. " -> " .. tostring(rt) .. " params=" .. tostring(pc))
        end
      end
    end
  end
  if not wr(DIR .. "methods.txt", table.concat(lines, "\n")) then error("could not write methods.txt") end
  return "wrote methods.txt (" .. #lines .. " lines)"
end

-- args: row. Dumps ALL fields of the item's _ItemData (ItemWeaponParam /
-- ItemArmorParam) and of ItemManager's ItemParameters, to find the field
-- holding the displayed element % (50).
COMMANDS.item_weaponparam_probe = function(a)
  local r = row_of(a[1])
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  local item = try(function() return r.master:call("get_ItemData") end)
  if not item then error("could not read item data") end
  add("== _ItemData (get_ItemData) ==")
  local td = try(function() return item:get_type_definition() end)
  add("type=" .. tostring(td and try(function() return td:get_full_name() end)))
  for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
    local n = try(function() return f:get_name() end)
    if n then
      local v = try(function() return item:get_field(n) end)
      add(n .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
    end
  end
  local wp = try(function() return item:call("get_WeaponParam") end)
  if wp then
    add("== WeaponParam (get_WeaponParam) ==")
    local td2 = try(function() return wp:get_type_definition() end)
    add("type=" .. tostring(td2 and try(function() return td2:get_full_name() end)))
    for _, f in ipairs(td2 and try(function() return td2:get_fields() end) or {}) do
      local n = try(function() return f:get_name() end)
      if n then
        local v = try(function() return wp:get_field(n) end)
        add(n .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
      end
    end
  else add("== WeaponParam: (none - not a weapon) ==") end
  local m = im()
  if m then
    local ip = try(function() return m:call("getItemParameters") end)
    if ip then
      add("== ItemManager.ItemParameters ==")
      local td3 = try(function() return ip:get_type_definition() end)
      add("type=" .. tostring(td3 and try(function() return td3:get_full_name() end)))
      for _, f in ipairs(td3 and try(function() return td3:get_fields() end) or {}) do
        local n = try(function() return f:get_name() end)
        if n and (n:find("lement") or n:find("Element")) then
          local v = try(function() return ip:get_field(n) end)
          add(n .. " = " .. tostring(v) .. " (" .. type(v) .. ")")
        end
      end
    end
  end
  if not wr(DIR .. "weaponparam.txt", table.concat(lines, "\n")) then error("could not write weaponparam.txt") end
  return "wrote weaponparam.txt (" .. #lines .. " lines)"
end

COMMANDS.item_elem_diag = function(a)
  local r = row_of(a[1])
  local snap_pre, snap_matched, snap_last, snap_args = ELEM_DIAG.pre_calls, ELEM_DIAG.matched, ELEM_DIAG.last_key, ELEM_DIAG.last_args
  local param = try(function() return r.master:call("get_Param") end)
  local key = param and elem_store_key(param)
  local over = key and ELEM_STORE[key]
  local enh = param and try(function() return param:call("makeEnhancedParam") end)
  local computed = enh and try(function() return enh:get_field("_ElementStore") end)
  local ed, el = equipped_copy(r.master, cur_key())
  local eq_sid = el and try(function() return el:get_field("_StorageId") end)
  local out = table.concat({
    ELEM_DIAG.installed and "1" or "0", ELEM_DIAG.install_status,
    tostring(snap_pre), tostring(snap_matched), tostring(snap_last),
    tostring(key), over ~= nil and tostring(over) or "",
    tostring(computed), tostring(eq_sid),
    tostring(ELEM_DIAG.this_idx), tostring(ELEM_DIAG.sret_idx),
    tostring(ELEM_DIAG.post_sets), tostring(snap_args),
    tostring(CALC_DIAG.calls), tostring(CALC_DIAG.sets),
    tostring(GE_DIAG.calls),
    tostring(WES_DIAG.calls), tostring(WES_DIAG.applied) }, "|")
  ELEM_DIAG.pre_calls, ELEM_DIAG.matched, ELEM_DIAG.post_sets = 0, 0, 0
  ELEM_DIAG.last_key, ELEM_DIAG.last_args = nil, nil
  CALC_DIAG.calls, CALC_DIAG.sets, GE_DIAG.calls = 0, 0, 0
  WES_DIAG.calls, WES_DIAG.applied = 0, 0
  return out
end

local function item_params(master)
  local item = try(function() return master:call("get_ItemData") end)
  if not item then error("item data not found") end
  local wp = try(function() return item:call("get_WeaponParam") end)
  local ap = try(function() return item:call("get_ArmorParam") end)
  local p = wp or ap
  if not p then error("this item has no weapon/armor stats") end
  return item, p, wp ~= nil
end

local enh_cap_cache = {}
local function enhance_cap(is_weapon)
  local k = is_weapon and "w" or "a"
  if enh_cap_cache[k] then return enh_cap_cache[k] end
  local cap = 0
  local m = im()
  local d = m and try(function() return m:get_field(is_weapon and "_WeaponEnhanceDict" or "_ArmorEnhanceDict") end)
  dict_iter(d, function(_, arr)
    local n = #elems_of(arr)
    if n > cap then cap = n end
  end)
  if cap == 0 then cap = 10 end
  enh_cap_cache[k] = cap
  return cap
end

-- "level,cap,type0,type1,type2,isWeapon"
COMMANDS.item_get_enh = function(a)
  local r = row_of(a[1])
  local _, _, is_weapon = item_params(r.master)
  local enh = try(function() return r.master:call("get_Enhance") end)
  if not enh then error("no enhance data") end
  local function f(n) return tostring(try(function() return enh:get_field(n) end) or 0) end
  return table.concat({ f("_Num"), tostring(enhance_cap(is_weapon)), f("_Type0"), f("_Type1"), f("_Type2"),
    is_weapon and "1" or "0" }, ",")
end

-- args: row, level, type0, type1, type2
COMMANDS.item_set_enh = function(a)
  local r = row_of(a[1])
  local enh = try(function() return r.master:call("get_Enhance") end)
  if not enh then error("no enhance data") end
  enh:set_field("_Num", int(a[2]))
  for t = 0, 2 do enh:set_field("_Type" .. t, int(a[3 + t])) end
  r.master:call("set_Enhance", enh)
  return recalc(r.master)
end

local W_FIELDS = {
  { "_PhysicalAttack", "Physical Attack" }, { "_MagicAttack", "Magic Attack" },
  { "_SlashRate", "Slash Rate" }, { "_StrikeRate", "Strike Rate" }, { "_StrikeStore", "Strike Store" },
  { "_Blow", "Blow" }, { "_Shake", "Shake" }, { "_ElementStore", "Element Store" },
  { "_StaminaReduce", "Stamina Reduce" }, { "_ShakeGuard", "Shake Guard" }, { "_BlowGuard", "Blow Guard" },
  { "_PoisonStore", "Poison Store" }, { "_SleepStore", "Sleep Store" }, { "_SilentStore", "Silence Store" },
  { "_StoneStore", "Stone Store" }, { "_WaterStore", "Water Store" }, { "_OilStore", "Oil Store" },
}
local A_FIELDS = {
  { "_PhysicalDefence", "Defense" }, { "_MagicDefence", "Magick Defense" },
  { "_SlashDefenceRate", "Slash Res" }, { "_StrikeDefenceRate", "Strike Res" },
  { "_ShakeResistRate", "Shake (Knockdown) Res" }, { "_BlowResistRate", "Blow Res" },
  { "_FireDefence", "Fire Defense" }, { "_FireResist", "Fire Resist" },
  { "_IceDefence", "Ice Defense" }, { "_IceResist", "Ice Resist" },
  { "_ThunderDefence", "Thunder Defense" }, { "_ThunderResist", "Thunder Resist" },
  { "_LightDefence", "Light Defense" }, { "_DarkDefence", "Dark Defense" },
  { "_PoisonResist", "Poison Resist" }, { "_SleepResist", "Sleep Resist" }, { "_SilentResist", "Silence Resist" },
  { "_StoneResist", "Stone Resist" }, { "_WaterResist", "Water Resist" }, { "_OilResist", "Oil Resist" },
  { "_FaintResist", "Faint Resist" }, { "_ColdResist", "Cold Resist" },
}
local TOTAL_FIELDS = {
  { "_PhysicalAttack", "Attack" }, { "_MagicAttack", "Magick Attack" }, { "_Shake", "Shake" }, { "_Blow", "Blow" },
  { "_PhysicalDefence", "Defense" }, { "_MagicDefence", "Magick Defense" },
  { "_ShakeResistRate", "Knockdown Res" }, { "_ColdResist", "Cold Resist" }, { "_Weight", "Weight (raw)" },
}

-- writes itemstats.txt ("field\tlabel\tvalue"); returns "W,n" or "A,n"
COMMANDS.item_get_stats = function(a)
  local r = row_of(a[1])
  local item, p, is_weapon = item_params(r.master)
  local lines = {}
  for _, f in ipairs(is_weapon and W_FIELDS or A_FIELDS) do
    local v = try(function() return p:get_field(f[1]) end)
    if type(v) == "number" then lines[#lines + 1] = f[1] .. "\t" .. f[2] .. "\t" .. tostring(v) end
  end
  local w = try(function() return item:get_field("_Weight") end)
  if type(w) == "number" then lines[#lines + 1] = "_Weight\tWeight (raw)\t" .. tostring(w) end
  if not wr(DIR .. "itemstats.txt", table.concat(lines, "\n")) then error("could not write itemstats.txt") end
  return (is_weapon and "W," or "A,") .. #lines
end

-- args: row, field, value  (edits the SHARED item data in memory; resets when the game restarts)
COMMANDS.item_set_stat = function(a)
  local r = row_of(a[1])
  local item, p, is_weapon = item_params(r.master)
  local field, v = a[2], int(a[3])
  local allowed = (field == "_Weight")
  for _, f in ipairs(is_weapon and W_FIELDS or A_FIELDS) do if f[1] == field then allowed = true end end
  if not allowed then error("field not allowed: " .. tostring(field)) end
  if field == "_Weight" then item:set_field(field, v) else p:set_field(field, v) end
  return recalc(r.master)
end

---------------------------------------------------------------- v1.11 helpers (moved up: used by the v1.16 item stat dump)
local function tdn(t) return try(function() return t:get_full_name() end) end

local function msig(m)
  local ps = {}
  for _, p in ipairs(m:get_param_types() or {}) do ps[#ps + 1] = tdn(p) or "?" end
  local rt = try(function() return m:get_return_type():get_full_name() end) or "?"
  return m:get_name() .. "(" .. table.concat(ps, ", ") .. ") -> " .. rt
end

local function flat_fields(L, obj, label)
  if type(obj) ~= "userdata" then L(label .. " = " .. tostring(obj)) return end
  local td = try(function() return obj:get_type_definition() end)
  L(label .. " : " .. (td and tdn(td) or "?"))
  local seen = {}
  while td do
    for _, f in ipairs(td:get_fields() or {}) do
      if not f:is_static() then
        local n = f:get_name()
        if not seen[n] then
          seen[n] = true
          local v = try(function() return obj:get_field(n) end)
          if type(v) == "userdata" then
            local ft = try(function() return f:get_type():get_full_name() end) or "?"
            L("   " .. n .. " : " .. ft)
          else
            L("   " .. n .. " = " .. tostring(v))
          end
        end
      end
    end
    td = try(function() return td:get_parent_type() end)
  end
end

COMMANDS.item_recalc = function(a)
  return recalc(row_of(a[1]).master)
end

---------------------------------------------------------------- v1.16: dump EVERY field of one item (hunt hidden stats
-- like cast speed / stamina regen on rings). args: row -> writes itemstatdump.txt
COMMANDS.item_stat_dump = function(a)
  local r = row_of(a[1])
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  L("##### item stat dump : " .. tostring(r.name) .. " #####")
  local item = try(function() return r.master:call("get_ItemData") end)
  if not item then error("item data not found") end
  L("")
  flat_fields(L, r.master, "InventoryEntry(master)")
  L("")
  flat_fields(L, item, "ItemData")
  L("")
  local wp = try(function() return item:call("get_WeaponParam") end)
  local ap = try(function() return item:call("get_ArmorParam") end)
  if wp then flat_fields(L, wp, "WeaponParam") else L("WeaponParam = (none)") end
  L("")
  if ap then flat_fields(L, ap, "ArmorParam") else L("ArmorParam = (none)") end
  L("")
  local ab = get_ability(r.master)
  if ab then flat_fields(L, ab, "Ability") else L("Ability = (none)") end
  L("")
  L("##### fields whose names suggest cast / speed / stamina / regen / charge / cost #####")
  local PATS = { "cast", "charg", "speed", "stamina", "regen", "recover", "cost",
                 "consum", "chant", "rapid", "quick", "haste", "cool", "gauge" }
  local seen_hit = {}
  local function sweep(obj, label)
    if type(obj) ~= "userdata" then return end
    local td = try(function() return obj:get_type_definition() end)
    while td do
      for _, f in ipairs(td:get_fields() or {}) do
        if not f:is_static() then
          local n = f:get_name()
          local l = n:lower()
          for _, p in ipairs(PATS) do
            if l:find(p, 1, true) and not seen_hit[label .. n] then
              seen_hit[label .. n] = true
              local v = try(function() return obj:get_field(n) end)
              L(string.format("HIT  %s.%s = %s", label, n,
                              type(v) == "userdata" and "<object>" or tostring(v)))
              break
            end
          end
        end
      end
      td = try(function() return td:get_parent_type() end)
    end
  end
  sweep(item, "ItemData")
  sweep(wp, "WeaponParam")
  sweep(ap, "ArmorParam")
  sweep(r.master, "Entry")
  sweep(ab, "Ability")
  for _, l in ipairs(lines) do log.info(TAG .. "statdump: " .. l) end
  if not wr(DIR .. "itemstatdump.txt", table.concat(lines, "\n")) then
    error("could not write itemstatdump.txt")
  end
  return tostring(#lines) .. " lines"
end

---------------------------------------------------------------- v1.17: read/write the _Special effect fields of an item
-- (rings etc. carry their unique effects here, e.g. cast speed / stamina regen
--  as effect ID + parameters). args: row -> "special,v1,v2,v3"
COMMANDS.item_get_special = function(a)
  local r = row_of(a[1])
  local item = try(function() return r.master:call("get_ItemData") end)
  if not item then error("item data not found") end
  local function f(n) return tostring(try(function() return item:get_field(n) end) or 0) end
  return table.concat({ f("_Special"), f("_SpecialValue"), f("_SpecialValue2"), f("_SpecialValue3") }, ",")
end

-- args: row, special, v1, v2, v3  (writes the SHARED item data; resets on restart)
COMMANDS.item_set_special = function(a)
  local r = row_of(a[1])
  local item = try(function() return r.master:call("get_ItemData") end)
  if not item then error("item data not found") end
  local fields = { "_Special", "_SpecialValue", "_SpecialValue2", "_SpecialValue3" }
  for i = 1, 4 do
    local ok = try(function() item:set_field(fields[i], int(a[1 + i])) return true end)
    if not ok then error("could not write " .. fields[i] .. " (not present on this item type?)") end
  end
  return recalc(r.master)
end

---------------------------------------------------------------- v1.18: probe for the special-effect NAME lookup
-- Lists every method/field of the item data (and its Ability), calls all
-- no-arg getters, highlights anything with "special" in the name.
-- args: row -> writes specialprobe.txt
COMMANDS.item_special_probe = function(a)
  local r = row_of(a[1])
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  L("##### special probe : " .. tostring(r.name) .. " #####")
  local item = try(function() return r.master:call("get_ItemData") end)
  if not item then error("item data not found") end
  local function probe_obj(obj, tag)
    local tdef = try(function() return obj:get_type_definition() end)
    if not tdef then L(tag .. ": no type definition") return end
    L("")
    L("## " .. tag .. " : " .. tostring(try(function() return tdef:get_full_name() end) or "?") .. " ##")
    local methods = try(function() return tdef:get_methods() end) or {}
    L("-- methods (" .. #methods .. ") --")
    local getters = {}
    for _, m in ipairs(methods) do
      local mn = try(function() return m:get_name() end) or "?"
      local pt = try(function() return m:get_param_types() end) or {}
      local mark = ""
      if mn:lower():find("special") then mark = "   <== SPECIAL?" end
      L("  " .. mn .. " (params=" .. #pt .. ")" .. mark)
      if #pt == 0 and mn:sub(1, 3) == "get" then getters[#getters + 1] = mn end
    end
    L("-- getter results --")
    for _, mn in ipairs(getters) do
      local v = try(function() return obj:call(mn) end)
      local disp
      if v == nil then disp = "(nil/error)"
      else
        local ok, st = pcall(tostring, v)
        disp = ok and tostring(st):sub(1, 400) or "(unprintable)"
      end
      L("  " .. mn .. " -> " .. disp)
    end
    local fields = try(function() return tdef:get_fields() end) or {}
    L("-- fields (" .. #fields .. ") --")
    for _, f in ipairs(fields) do
      local fn = try(function() return f:get_name() end) or "?"
      local mark = ""
      if fn:lower():find("special") then mark = "   <== SPECIAL?" end
      L("  " .. fn .. mark)
    end
  end
  probe_obj(item, "ItemData")
  local ab = try(function() return item:call("get_Ability") end)
  if ab then probe_obj(ab, "Ability") else L("Ability: (none)") end
  -- v1.22.0: hunt the effect NAME. The item data has no text getters, so try the
  -- inventory entry (master) for explanation/description, and guess type names.
  local mtd = try(function() return r.master:get_type_definition() end)
  if mtd then
    L("")
    L("## master : " .. tostring(try(function() return mtd:get_full_name() end) or "?") .. " ##")
    local mmethods = try(function() return mtd:get_methods() end) or {}
    for _, m in ipairs(mmethods) do
      local mn = try(function() return m:get_name() end) or "?"
      local pt = try(function() return m:get_param_types() end) or {}
      if #pt == 0 then
        local low = mn:lower()
        if low:find("explain") or low:find("expos") or low:find("detail") or low:find("flavor") then
          local v = try(function() return r.master:call(mn) end)
          local disp = "(nil/error)"
          if v ~= nil then
            local ok, st = pcall(tostring, v)
            disp = ok and tostring(st):sub(1, 600) or "(unprintable)"
          end
          L("  " .. mn .. " -> " .. disp)
        end
      end
    end
  end
  L("")
  L("## candidate special type definitions ##")
  local candidates = {
    "app.ItemDefine.SpecialType", "app.ItemDefine.SpecialKind",
    "app.EquipSpecialParam", "app.ItemSpecialParam",
    "app.ItemDefine.EquipSpecialType", "app.ArmorSpecialParam",
  }
  for _, cn in ipairs(candidates) do
    local ctd = try(function() return sdk.find_type_definition(cn) end)
    if ctd then
      L("  " .. cn .. "  EXISTS")
      for _, f in ipairs(try(function() return ctd:get_fields() end) or {}) do
        L("    field: " .. tostring(try(function() return f:get_name() end) or "?"))
      end
    else
      L("  " .. cn .. "  (not found)")
    end
  end
  if not wr(DIR .. "specialprobe.txt", table.concat(lines, "\n")) then
    error("could not write specialprobe.txt")
  end
  return tostring(#lines) .. " lines"
end

---------------------------------------------------------------- v1.19: sweep every loaded row for _Special ~= 0
-- args: none (uses IT.rows; load the inventory in the Item Editor tab first)
-- writes specialsweep.txt : "name | special=ID v1=A v2=B v3=C"
COMMANDS.item_special_sweep = function(a)
  if #IT.rows == 0 then error("inventory not loaded - open the Item Editor tab and load it first") end
  local lines = {}
  lines[#lines + 1] = "##### special sweep : items with _Special ~= 0 #####"
  for _, r in ipairs(IT.rows) do
    local item = try(function() return r.master:call("get_ItemData") end)
    if item then
      local sp = try(function() return item:get_field("_Special") end) or 0
      if sp ~= 0 then
        local v1 = try(function() return item:get_field("_SpecialValue") end) or 0
        local v2 = try(function() return item:get_field("_SpecialValue2") end) or 0
        local v3 = try(function() return item:get_field("_SpecialValue3") end) or 0
        lines[#lines + 1] = tostring(r.name) .. " | special=" .. tostring(sp)
          .. " v1=" .. tostring(v1) .. " v2=" .. tostring(v2) .. " v3=" .. tostring(v3)
      end
    end
  end
  if not wr(DIR .. "specialsweep.txt", table.concat(lines, string.char(10))) then
    error("could not write specialsweep.txt")
  end
  return tostring(#lines - 1) .. " items"
end

---------------------------------------------------------------- v1.22: set vocation anywhere (player or pawn)
-- Adapted from SetVocationAnywhere (Dutchysaur): request the job change anywhere,
-- unlock the job if needed, best-effort unequip of vocation-locked armor.
-- args: kind ("player"/"pawn"), jobnum (1-10)
COMMANDS.set_vocation = function(a)
  local kind = a[1]
  local jobnum = int(a[2])
  if jobnum < 1 or jobnum > 10 then error("bad job number (1-10)") end
  if kind == "pawn" and jobnum > 6 then error("pawns can only use vocations 1-6") end
  local t = get_target(kind)
  local human = t.human
  local jc = t.job
  if jc then
    local q = try(function() return jc:call("isJobQualified", jobnum) end)
    if not q then try(function() jc:call("setJobQualified", jobnum) end) end
  end
  local changer = try(function() return human:call("get_JobChanger") end)
  if not changer then error("JobChanger not found") end
  local ok = try(function() changer:call("requestChangeJob", jobnum) return true end)
  if not ok then error("requestChangeJob failed") end
  try(function()
    local mgr = im()
    local charaid = t.src:call("get_CharaID")
    local storage = mgr:call("getStorageList", charaid, nil)
    local n = storage:call("get_Count")
    for i = 0, n - 1 do
      local sd = storage:call("get_Item", i)
      local master = mgr:call("getStorageMasterData(app.ItemDefine.StorageData)", sd)
      if master:call("get_IsEquipped") == true then
        local itemid = sd:get_field("_ItemId")
        local param = mgr:call("getItemData(System.Int32)", itemid)
        if param:get_field("_Category") == 3 then
          mgr:call("removeEquip(app.ItemDefine.StorageData, app.Character, System.Boolean, System.Boolean)",
            master:call("get_Param"), t.src, false, true)
        end
      end
    end
    mgr:call("applyEquipChange")
  end)
  return "vocation set to " .. jobnum
end

-- args: kind ("player"/"pawn")
COMMANDS.unlock_all_vocations = function(a)
  local t = get_target(a[1])
  local jc = t.job
  if not jc then error("JobContext not found") end
  local maxjob = a[1] == "pawn" and 6 or 10
  local n = 0
  for i = 1, maxjob do
    local q = try(function() return jc:call("isJobQualified", i) end)
    if not q then
      if try(function() jc:call("setJobQualified", i) return true end) then n = n + 1 end
    end
  end
  return "unlocked " .. n .. " vocation(s)"
end

-- "Attack 123 | Defense 45 ..." as the game computes it for the equipped item's owner
COMMANDS.item_totals = function(a)
  local r = row_of(a[1])
  local ed = equipped_copy(r.master, cur_key())
  local eq = ed and try(function() return ed:get_field("_EqParam") end)
  if not eq then return "(not equipped / no totals)" end
  local parts = {}
  for _, f in ipairs(TOTAL_FIELDS) do
    parts[#parts + 1] = f[2] .. " " .. tostring(try(function() return eq:get_field(f[1]) end))
  end
  return table.concat(parts, "  |  ")
end

---------------------------------------------------------------- v1.2 duplicate items
-- Duplicates an item you own by asking the game to give you the same item ID again (the game's own
-- getItem / forceGetItemToWarehouse). For equipment it can also copy skills / appraisal / enhancement
-- onto the new copies (best effort). Has its own state, so it does not disturb the Item Editor tab.
local DUP = { owners = {}, rows = {} }

local function dup_read_owners()
  local m = im()
  if not m then error("ItemManager not ready (load a save first)") end
  local sd = try(function() return m:get_field("StorageDict") end)
  local pid = player_charid()
  local owners = {}
  dict_iter(sd, function(k, list)
    local items = try(function() return list:get_field("_items") end)
    local size = try(function() return list:get_field("_size") end) or 0
    if items then
      local els = elems_of(items)
      local ms = {}
      for i = 1, math.min(size, #els) do
        if els[i] ~= nil then ms[#ms + 1] = els[i] end
      end
      owners[#owners + 1] = { key = k, masters = ms, is_player = (pid ~= nil and k == pid) }
    end
  end)
  table.sort(owners, function(x, y)
    if x.is_player ~= y.is_player then return x.is_player and true or false end
    return #x.masters > #y.masters
  end)
  return owners
end

-- address of the shared item-data object -> item id (taken from the game's own item table)
local function dup_idmap()
  local map = {}
  local m = im()
  local dict = m and try(function() return m:get_field("_ItemDataDict") end)
  dict_iter(dict, function(k, v)
    if type(k) == "number" and type(v) == "userdata" then
      local ad = try(function() return v:get_address() end)
      if ad then map[ad] = k end
    end
  end)
  return map
end

local function dup_item_id(master, map)
  local item = try(function() return master:call("get_ItemData") end)
  if type(item) == "userdata" then
    local ad = try(function() return item:get_address() end)
    if ad and map[ad] then return map[ad], item end
  end
  for _, n in ipairs({ "get_ItemId", "get_ItemID", "get_Id", "get_ID" }) do
    local v = try(function() return master:call(n) end)
    if type(v) == "number" then return v, item end
    if type(item) == "userdata" then
      v = try(function() return item:call(n) end)
      if type(v) == "number" then return v, item end
    end
  end
  if type(item) == "userdata" then
    for _, n in ipairs({ "_ItemId", "_ItemID", "_Id", "ItemId", "_ID" }) do
      local v = try(function() return item:get_field(n) end)
      if type(v) == "number" then return v, item end
    end
  end
  return nil, item
end

local function dup_count(master, id)
  for _, n in ipairs({ "get_Num", "get_Count", "get_StackNum", "get_HaveNum", "get_ItemNum" }) do
    local v = try(function() return master:call(n) end)
    if type(v) == "number" then return v end
  end
  for _, n in ipairs({ "_Num", "_Count", "Num", "Count", "_StackNum" }) do
    local v = try(function() return master:get_field(n) end)
    if type(v) == "number" then return v end
  end
  local m = im()
  if m and id then
    for _, n in ipairs({ "getHaveNum", "getItemNum", "getNum", "getHaveItemNum" }) do
      local v = try(function() return m:call(n, id) end)
      if type(v) == "number" then return v end
    end
  end
  return nil
end

local function dup_sid(master)
  local s = try(function() return master:call("get_StorageId") end)
  if s == nil then return nil end
  return tostring(s)
end

-- same format as item_owners: "idx,key,count,isplayer;..."
COMMANDS.dup_owners = function()
  DUP.owners, DUP.rows = dup_read_owners(), {}
  local out = {}
  for i, o in ipairs(DUP.owners) do
    out[#out + 1] = string.format("%d,%s,%d,%d", i, clean(o.key), #o.masters, o.is_player and 1 or 0)
  end
  return table.concat(out, ";")
end

-- args: owner idx, only equipment(0/1) -> writes duprows.txt "row\tname\tid\tcount\tisequip\tequipped"
COMMANDS.dup_rows = function(a)
  local o = DUP.owners[int(a[1])]
  if not o then error("owner not found - reload the inventory first") end
  local only_equip = a[2] == "1"
  local map = dup_idmap()
  local rows = {}
  for _, m in ipairs(o.masters) do
    local id, item = dup_item_id(m, map)
    local isequip = item and try(function() return item:call("get_IsEquip") end) and true or false
    if not only_equip or isequip then
      local name = item and try(function() return item:call("get_Name") end) or "?"
      rows[#rows + 1] = {
        master = m, id = id, isequip = isequip, name = clean(name),
        count = id and dup_count(m, id) or nil,
        equipped = try(function() return m:call("get_IsEquipped") end) and true or false,
      }
    end
  end
  table.sort(rows, function(x, y) return x.name < y.name end)
  DUP.rows = rows
  local lines = {}
  for i, r in ipairs(rows) do
    lines[#lines + 1] = string.format("%d\t%s\t%s\t%s\t%d\t%d", i, r.name, r.id and fmt_int(r.id) or "-1",
      r.count and fmt_int(r.count) or "?", r.isequip and 1 or 0, r.equipped and 1 or 0)
  end
  if not wr(DIR .. "duprows.txt", table.concat(lines, "\n")) then error("could not write duprows.txt") end
  return tostring(#rows)
end

-- args: row, copies (0 = same amount as you own now), to_storage(0/1), copy_props(0/1)
COMMANDS.dup_do = function(a)
  local r = DUP.rows[int(a[1])]
  if not r then error("item row not found - reload the list") end
  local copies, to_storage, props = int(a[2]), a[3] == "1", a[4] == "1"
  if not r.id then error("could not determine this item's ID - press Probe and send me the log") end
  if copies == 0 then
    if not r.count then error("stack size unreadable for this item - type a number of copies instead") end
    copies = math.floor(r.count)
  end
  if copies < 1 or copies > 9999 then error("copies must be between 1 and 9999") end
  if r.isequip and copies > 50 then error("equipment: at most 50 copies at once") end

  local track = r.isequip and props
  local before, nbefore = {}, 0
  if track then
    for _, o in ipairs(dup_read_owners()) do
      for _, mm in ipairs(o.masters) do
        local sid = dup_sid(mm)
        if sid then before[sid] = true nbefore = nbefore + 1 end
      end
    end
  end

  local what = give_item(r.id, copies, to_storage)
  local msg = string.format("%s: %d x %s (id %s)", what, copies, r.name, fmt_int(r.id))
  if not track then return msg end
  if nbefore == 0 then return msg .. " - could not track the new copies, properties not copied" end

  local src_ab = try(function() return r.master:call("get_Ability") end)
  local src_enh = try(function() return r.master:call("get_Enhance") end)
  local map = dup_idmap()
  local n_new, n_ok = 0, 0
  for _, o in ipairs(dup_read_owners()) do
    for _, mm in ipairs(o.masters) do
      local sid = dup_sid(mm)
      if sid and not before[sid] then
        local id2 = dup_item_id(mm, map)
        if id2 == r.id then
          n_new = n_new + 1
          local ok1 = src_ab ~= nil and pcall(function() mm:call("set_Ability", src_ab) end)
          local ok2 = src_enh ~= nil and pcall(function() mm:call("set_Enhance", src_enh) end)
          if ok1 or ok2 then n_ok = n_ok + 1 end
        end
      end
    end
  end
  return string.format("%s | new copies found: %d, skills/enhancement copied to: %d", msg, n_new, n_ok)
end

-- logs the fields / methods of the selected inventory entry (to find stack-size / id accessors)
COMMANDS.dup_probe = function(a)
  local r = DUP.rows[int(a[1])]
  if not r then error("item row not found - reload the list") end
  local found = {}
  local function scan(obj, label)
    if type(obj) ~= "userdata" then return end
    local td = try(function() return obj:get_type_definition() end)
    while td do
      log.info(TAG .. "probe " .. label .. " type " .. tostring(td:get_full_name()))
      for _, f in ipairs(td:get_fields() or {}) do
        local n = f:get_name()
        local ln = n:lower()
        if ln:find("num", 1, true) or ln:find("count", 1, true) or ln:find("stack", 1, true) or ln:find("id", 1, true) then
          local v = try(function() return obj:get_field(n) end)
          log.info(TAG .. "probe " .. label .. " field " .. n .. " = " .. tostring(v))
          found[#found + 1] = label .. "." .. n
        end
      end
      for _, m in ipairs(td:get_methods() or {}) do
        local n = m:get_name()
        local ln = n:lower()
        if #(m:get_param_types() or {}) == 0 and n:sub(1, 4) == "get_"
            and (ln:find("num", 1, true) or ln:find("count", 1, true) or ln:find("stack", 1, true) or ln:find("id", 1, true)) then
          local v = try(function() return obj:call(n) end)
          log.info(TAG .. "probe " .. label .. " method " .. n .. " = " .. tostring(v))
          found[#found + 1] = label .. "." .. n
        end
      end
      td = try(function() return td:get_parent_type() end)
    end
  end
  scan(r.master, "master")
  scan(try(function() return r.master:call("get_ItemData") end), "itemdata")
  return string.format("id=%s count=%s - %d candidate members written to the REFramework log",
    tostring(r.id), tostring(r.count), #found)
end

---------------------------------------------------------------- v1.9 upgraded weapon skills (JobNN_ExSkillK) on the equipped weapon
-- The upgraded weapon skills (Shearing Wind, Fanged Rupture, ...) are the equipment abilities JobNN_ExSkill1..5 that sit in an
-- item's 4 special-skill slots. This writes the chosen ones into the slots of the target's EQUIPPED weapon(s) and re-applies.
local EXS_UNDO = {}

local function exs_target_owner(c)
  local chara = follow(c.human, { "<Chara>k__BackingField" })
  local cid
  for _, o in ipairs({ c.src, chara }) do
    for _, h in ipairs({ "get_CharaID", "get_CharaId", "getCharaID" }) do
      if cid == nil and type(o) == "userdata" then cid = try(function() return o:call(h) end) end
    end
  end
  if cid == nil then error("character id not found") end
  COMMANDS.item_owners()
  for i, o in ipairs(IT.owners) do
    if tostring(o.key) == tostring(cid) then IT.owner_idx = i return IT.owners[i] end
  end
  error("inventory of this character not found")
end

local function exs_equipped_weapons(owner)
  local out = {}
  for _, m in ipairs(owner.masters) do
    local d = describe(m)
    if d.isequip and d.equipped then
      local item = try(function() return m:call("get_ItemData") end)
      local wp = item and try(function() return item:call("get_WeaponParam") end)
      if wp then out[#out + 1] = { master = m, name = d.name } end
    end
  end
  return out
end

-- args: target, job (1-9), "k,k,..." (which ExSkill numbers 1-5, max 4)
COMMANDS.exskill_equip = function(a)
  local c = get_target(a[1])
  local job = int(a[2])
  local picks = {}
  for k in tostring(a[3] or ""):gmatch("%d+") do picks[#picks + 1] = tonumber(k) end
  if #picks == 0 then error("pick at least one ExSkill") end
  if #picks > 4 then error("an item has only 4 skill slots - pick at most 4") end
  local byname = {}
  for _, e in ipairs(enum_list("app.EquipmentAbilityID")) do byname[e.name] = e.value end
  local ids = {}
  for _, k in ipairs(picks) do
    local v = byname[string.format("Job%02d_ExSkill%d", job, k)]
    if not v then error(string.format("no ability Job%02d_ExSkill%d in this game version", job, k)) end
    ids[#ids + 1] = v
  end
  local owner = exs_target_owner(c)
  local weapons = exs_equipped_weapons(owner)
  if #weapons == 0 then error("no equipped weapon found for this character") end
  EXS_UNDO = {}
  local report = {}
  for _, w in ipairs(weapons) do
    local ab = get_ability(w.master)
    local old = {}
    for i = 1, 4 do old[i] = ab and try(function() return ab:get_field("Slot" .. i) end) or 0 end
    EXS_UNDO[#EXS_UNDO + 1] = { master = w.master, slots = old, name = w.name }
    write_ability(w.master, function(x) for i, id in ipairs(ids) do x:set_field("Slot" .. i, id) end end)
    report[#report + 1] = w.name .. ": " .. full_apply(w.master)
  end
  return string.format("%d weapon(s): slots 1-%d = ExSkill %s | %s", #weapons, #ids, table.concat(picks, ","), table.concat(report, " || "))
end

COMMANDS.exskill_undo = function(a)
  if #EXS_UNDO == 0 then error("nothing to undo") end
  local c = get_target(a[1])
  exs_target_owner(c)   -- refreshes IT.owners / owner_idx so full_apply knows the owner
  local report = {}
  for _, u in ipairs(EXS_UNDO) do
    write_ability(u.master, function(x) for i = 1, 4 do x:set_field("Slot" .. i, u.slots[i] or 0) end end)
    report[#report + 1] = u.name .. ": " .. full_apply(u.master)
  end
  EXS_UNDO = {}
  return "restored | " .. table.concat(report, " || ")
end

---------------------------------------------------------------- v1.10 item type -> skills that really occur on that type
-- The game does not let every special skill sit on every item type. We learn the rule from the game's own items:
-- every item in every inventory / storage is read, its type ("class") is found, and the skills seen in its 4 slots are recorded.
local EQMAP = nil
local EQ_VIA = "?"

local function item_slot(master)
  local item = try(function() return master:call("get_ItemData") end)
  local srcs = { master, item }
  if type(item) == "userdata" then
    srcs[#srcs + 1] = try(function() return item:call("get_WeaponParam") end)
    srcs[#srcs + 1] = try(function() return item:call("get_ArmorParam") end)
  end
  for oi, o in ipairs(srcs) do
    if type(o) == "userdata" then
      local td = try(function() return o:get_type_definition() end)
      while td do
        for _, m in ipairs(td:get_methods() or {}) do
          local n = m:get_name()
          if n:sub(1, 4) == "get_" and #(m:get_param_types() or {}) == 0 then
            local rt = try(function() return m:get_return_type():get_full_name() end) or ""
            if rt:find("SlotEnum", 1, true) or rt:find("EquipSlot", 1, true) then
              local v = try(function() return o:call(n) end)
              if type(v) == "number" then
                EQ_VIA = "source#" .. oi .. " " .. tostring(td:get_full_name()) .. "." .. n .. " -> " .. rt
                return v
              end
            end
          end
        end
        td = try(function() return td:get_parent_type() end)
      end
    end
  end
  return nil
end

local EQ_CATNAMES = nil
local function item_class(master)
  local item = try(function() return master:call("get_ItemData") end)
  local wp = item and try(function() return item:call("get_WeaponParam") end)
  local ap = item and try(function() return item:call("get_ArmorParam") end)
  local cat = item and try(function() return item:get_field("_EquipCategory") end)
  local job = item and try(function() return item:get_field("_Job") end)
  if wp then
    local n
    if type(job) == "number" then
      for j = 0, 12 do if math.floor(job) == (1 << j) then n = j end end
    end
    if n then return "Weapon:job" .. n, "Weapon", n, string.format("Weapon (Job%02d)", n) end
    return "Weapon:mask" .. tostring(job), "Weapon", nil, "Weapon (job mask " .. tostring(job) .. ")"
  end
  if ap then
    if not EQ_CATNAMES then
      EQ_CATNAMES = {}
      for _, e in ipairs(enum_list("app.ItemEquipCategory")) do EQ_CATNAMES[e.value] = e.name end
    end
    return "Armor:cat" .. tostring(cat), "Armor", cat, "Armor / " .. (EQ_CATNAMES[cat] or tostring(cat))
  end
  return "Other:-", "Other", nil, "Other"
end

local function eq_labels()
  local t = {}
  for _, e in ipairs(enum_list("app.EquipData.SlotEnum")) do t[e.value] = e.name end
  return t
end

local function eqmap_build()
  local owners = dup_read_owners()
  local labels = eq_labels()
  local abn = {}
  for _, e in ipairs(enum_list("app.EquipmentAbilityID")) do abn[e.value] = e.name end
  local map, ncls, ex, lab = {}, {}, {}, {}
  local total = 0
  for _, o in ipairs(owners) do
    for _, m in ipairs(o.masters) do
      local item = try(function() return m:call("get_ItemData") end)
      local isequip = item and try(function() return item:call("get_IsEquip") end)
      if isequip then
        total = total + 1
        local key, base, slot, label = item_class(m)
        lab[key] = label
        ncls[key] = (ncls[key] or 0) + 1
        local ab = get_ability(m)
        local nm = try(function() return item:call("get_Name") end) or "?"
        if ab then
          for i = 1, 4 do
            local id = try(function() return ab:get_field("Slot" .. i) end)
            if type(id) == "number" and id ~= 0 then
              map[key] = map[key] or {}
              map[key][id] = (map[key][id] or 0) + 1
              ex[key] = ex[key] or {}
              ex[key][id] = ex[key][id] or clean(nm)
            end
          end
        end
      end
    end
  end
  EQMAP = { map = map, ncls = ncls, lab = lab }
  -- readable report (+ a few things about ItemManager for debugging)
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  L("item type = weapon job (from _Job) or armor _EquipCategory")
  L(total .. " equipment items scanned")
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  for k in pairs(ncls) do if not map[k] then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do
    L("")
    L(string.format("== %s  (%s)  %d items", k, lab[k] or "?", ncls[k] or 0))
    local ids = {}
    for id in pairs(map[k] or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      L(string.format("   %3d %-55s x%d  e.g. %s", id, abn[id] or "?", map[k][id], ex[k][id] or ""))
    end
  end
  L("")
  L("== ItemManager fields that look like ability tables ==")
  local mgr = sdk.get_managed_singleton("app.ItemManager")
  local td = mgr and mgr:get_type_definition()
  local shown = 0
  while td and shown < 80 do
    for _, f in ipairs(td:get_fields() or {}) do
      if not f:is_static() then
        local n = f:get_name()
        local ft = try(function() return f:get_type():get_full_name() end) or "?"
        local ln = (n .. ft):lower()
        if ln:find("abil", 1, true) or ln:find("lot", 1, true) or ln:find("restrict", 1, true) then
          local v = try(function() return mgr:get_field(n) end)
          local cnt = (type(v) == "userdata") and #coll_elems(v) or 0
          L(string.format("   %s : %s%s", n, ft, cnt > 0 and (" (n=" .. cnt .. ")") or ""))
          shown = shown + 1
        end
      end
    end
    td = try(function() return td:get_parent_type() end)
  end
  for _, l in ipairs(lines) do log.info(TAG .. "eqmap: " .. l) end
  if not wr(DIR .. "eqmap.txt", table.concat(lines, "\n")) then error("could not write eqmap.txt") end
  return total, #keys
end

COMMANDS.eqmap_build = function()
  local total, k = eqmap_build()
  return string.format("%d items, %d item types", total, k)
end

-- arg: item row (+ "1" to rescan). Returns "key|label|id,id,...|items of this type"
COMMANDS.eqmap_valid = function(a)
  local r = row_of(a[1])
  if not EQMAP or a[2] == "1" then eqmap_build() end
  local key, base, slot = item_class(r.master)
  local set = {}
  for id in pairs(EQMAP.map[key] or {}) do set[id] = true end
  -- hard rule (matches the game data): JobNN_ExSkillK only on weapons of vocation NN
  for _, e in ipairs(enum_list("app.EquipmentAbilityID")) do
    local j = e.name:match("^Job(%d%d)_ExSkill%d$")
    if j then
      if base == "Weapon" and slot == tonumber(j) then set[e.value] = true else set[e.value] = nil end
    end
  end
  local ids = {}
  for id in pairs(set) do ids[#ids + 1] = id end
  table.sort(ids)
  return string.format("%s|%s|%s|%d", key, EQMAP.lab[key] or "?", table.concat(ids, ","), EQMAP.ncls[key] or 0)
end

---------------------------------------------------------------- v1.11 dump: where does the game keep "which skill fits which item type"?

COMMANDS.abil_dump = function()
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local PAT = { "abil", "lot", "slot", "extens", "apprais", "categor", "restrict", "allow", "selectable", "equiptype", "part" }
  local function hit(name)
    local l = name:lower()
    for _, p in ipairs(PAT) do if l:find(p, 1, true) then return true end end
    return false
  end

  L("##### 1. ItemManager members (fields and methods) whose name suggests ability / slot / lot / category #####")
  local itd = sdk.find_type_definition("app.ItemManager")
  local t = itd
  local seenm = {}
  while t do
    for _, f in ipairs(t:get_fields() or {}) do
      local n = f:get_name()
      if hit(n) and not seenm["f" .. n] then
        seenm["f" .. n] = true
        L("FIELD  " .. n .. " : " .. (try(function() return f:get_type():get_full_name() end) or "?") .. (f:is_static() and "  [static]" or ""))
      end
    end
    for _, m in ipairs(t:get_methods() or {}) do
      local k = msig(m)
      if hit(m:get_name()) and not seenm[k] then
        seenm[k] = true
        L("METHOD " .. k)
      end
    end
    t = try(function() return t:get_parent_type() end)
  end

  L("")
  L("##### 2. Type graph around equipment abilities #####")
  local roots = { "app.ItemManager", "app.EquipmentAbilityData", "app.ItemDefine.EquipmentAbilityParam",
    "app.ItemDefine.StorageData", "app.EquipData", "app.ItemDefine" }
  local visited, order = {}, {}
  local queue = {}
  for _, r in ipairs(roots) do
    local td = sdk.find_type_definition(r)
    if td then queue[#queue + 1] = { td = td, d = 0 } end
  end
  local function relevant(n)
    local l = n:lower()
    return n:sub(1, 4) == "app." and (l:find("abil", 1, true) or l:find("equip", 1, true) or l:find("lot", 1, true)
      or l:find("categ", 1, true) or l:find("slot", 1, true) or l:find("itemdefine", 1, true))
  end
  local qi = 1
  while qi <= #queue and #order < 500 do
    local node = queue[qi]
    qi = qi + 1
    local n = tdn(node.td)
    if n and not visited[n] then
      visited[n] = node.td
      order[#order + 1] = n
      if node.d < 3 then
        local refs = {}
        for _, f in ipairs(node.td:get_fields() or {}) do refs[#refs + 1] = try(function() return f:get_type() end) end
        for _, m in ipairs(node.td:get_methods() or {}) do
          refs[#refs + 1] = try(function() return m:get_return_type() end)
          for _, p in ipairs(m:get_param_types() or {}) do refs[#refs + 1] = p end
        end
        for _, rt in ipairs(refs) do
          local rn = rt and tdn(rt)
          if rn and relevant(rn) and not visited[rn] then queue[#queue + 1] = { td = rt, d = node.d + 1 } end
        end
      end
    end
  end
  table.sort(order)
  L(#order .. " related types found:")
  for _, n in ipairs(order) do L("   " .. n) end

  L("")
  L("##### 3. Members of every related type with 'Abil' in its name #####")
  local ntypes = 0
  for _, n in ipairs(order) do
    if n:lower():find("abil", 1, true) and ntypes < 40 then
      ntypes = ntypes + 1
      local td = visited[n]
      L("--- " .. n)
      local c = 0
      for _, f in ipairs(td:get_fields() or {}) do
        if c < 60 then
          c = c + 1
          L("   F " .. f:get_name() .. " : " .. (try(function() return f:get_type():get_full_name() end) or "?") .. (f:is_static() and " [static]" or ""))
        end
      end
      local mc = 0
      for _, m in ipairs(td:get_methods() or {}) do
        if mc < 60 then mc = mc + 1 L("   M " .. msig(m)) end
      end
    end
  end

  L("")
  L("##### 4. Raw data of sample items (ItemData + Weapon/Armor param) #####")
  local owners = dup_read_owners()
  local w, ar, seen_names = 0, 0, {}
  for _, o in ipairs(owners) do
    for _, m in ipairs(o.masters) do
      local item = try(function() return m:call("get_ItemData") end)
      if type(item) == "userdata" and (w < 2 or ar < 6) then
        local nm = try(function() return item:call("get_Name") end) or "?"
        local wp = try(function() return item:call("get_WeaponParam") end)
        local ap = try(function() return item:call("get_ArmorParam") end)
        if not seen_names[nm] and ((wp and w < 2) or (ap and ar < 6)) then
          seen_names[nm] = true
          if wp then w = w + 1 else ar = ar + 1 end
          L("")
          L(">>> " .. tostring(nm))
          flat_fields(L, item, "ItemData")
          if wp then flat_fields(L, wp, "WeaponParam") end
          if ap then flat_fields(L, ap, "ArmorParam") end
          flat_fields(L, m, "InventoryEntry")
        end
      end
    end
  end

  L("")
  L("##### 5. Enums #####")
  for _, en in ipairs({ "app.EquipData.SlotEnum" }) do
    for _, e in ipairs(enum_list(en)) do L(string.format("%s  %s = %s", en, e.name, fmt_int(e.value))) end
  end
  for _, l in ipairs(lines) do log.info(TAG .. "abildump: " .. l) end
  if not wr(DIR .. "abildump.txt", table.concat(lines, "\n")) then error("could not write abildump.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.12 dump 2: appraisal data (where abilities are rolled per item category)
COMMANDS.abil_dump2 = function()
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local itm = sdk.get_managed_singleton("app.ItemManager")
  L("##### A. ItemManager appraisal / ability-flag objects #####")
  for _, n in ipairs({ "AppraisalItemInfo", "AppraisalItemDropWeight", "GetEquipmentAbilityIdFlag" }) do
    local v = itm and try(function() return itm:get_field(n) end)
    L("")
    if v then dump_obj(L, v, n, 3, 4) else L(n .. " not readable") end
  end

  L("")
  L("##### B. members of the related types #####")
  local roots = { "app.AppraisalItemInfoManager", "app.AppraisalItemDropWeightManager", "app.FlagController",
    "app.ItemDefine.EquipmentAbilityParam", "app.ItemDefine.StorageData", "app.ItemEquipParam", "app.EquipParam",
    "app.EquipSpecial", "app.GUIAppraisalDefine.AppraisalItemLevel", "app.AppraiseItemRimCostSettingData" }
  local visited, order, queue = {}, {}, {}
  for _, r in ipairs(roots) do
    local td = sdk.find_type_definition(r)
    if td then queue[#queue + 1] = { td = td, d = 0 } end
  end
  local function relevant(n)
    local l = n:lower()
    return n:sub(1, 4) == "app." and (l:find("apprais", 1, true) or l:find("abil", 1, true) or l:find("dropweight", 1, true))
  end
  local qi = 1
  while qi <= #queue and #order < 80 do
    local node = queue[qi]
    qi = qi + 1
    local n = tdn(node.td)
    if n and not visited[n] then
      visited[n] = node.td
      order[#order + 1] = n
      if node.d < 2 then
        local refs = {}
        for _, f in ipairs(node.td:get_fields() or {}) do refs[#refs + 1] = try(function() return f:get_type() end) end
        for _, m in ipairs(node.td:get_methods() or {}) do
          refs[#refs + 1] = try(function() return m:get_return_type() end)
          for _, p in ipairs(m:get_param_types() or {}) do refs[#refs + 1] = p end
        end
        for _, rt in ipairs(refs) do
          local rn = rt and tdn(rt)
          if rn and relevant(rn) and not visited[rn] then queue[#queue + 1] = { td = rt, d = node.d + 1 } end
        end
      end
    end
  end
  for _, n in ipairs(order) do
    local td = visited[n]
    L("--- " .. n)
    local c = 0
    for _, f in ipairs(td:get_fields() or {}) do
      if c < 80 then c = c + 1 L("   F " .. f:get_name() .. " : " .. (try(function() return f:get_type():get_full_name() end) or "?") .. (f:is_static() and " [static]" or "")) end
    end
    local mc = 0
    for _, m in ipairs(td:get_methods() or {}) do
      if mc < 80 then mc = mc + 1 L("   M " .. msig(m)) end
    end
  end

  L("")
  L("##### C. enums #####")
  for _, en in ipairs({ "app.ItemEquipCategory", "app.Character.JobEnum", "app.GuiDefine.EquipmentGrade" }) do
    for _, e in ipairs(enum_list(en)) do L(string.format("%s  %s = %s", en, e.name, fmt_int(e.value))) end
  end
  for _, l in ipairs(lines) do log.info(TAG .. "abildump2: " .. l) end
  if not wr(DIR .. "abildump2.txt", table.concat(lines, "\n")) then error("could not write abildump2.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.13 dump 3: EquipmentAbilityData + live validity probe
COMMANDS.abil_dump3 = function()
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local itm = sdk.get_managed_singleton("app.ItemManager")

  local function relevant(n)
    local l = n:lower()
    return n:sub(1, 4) == "app." and (l:find("abil", 1, true) or l:find("equipmentability", 1, true))
  end

  -- A. type graph from the ability master data
  L("##### A. EquipmentAbilityData type graph (all fields and methods, nothing capped except 300 members/type) #####")
  local roots = { "app.EquipmentAbilityData", "app.ItemDefine.EquipmentAbilityParam", "app.EquipmentAbilityBonus" }
  local visited, order, queue = {}, {}, {}
  for _, r in ipairs(roots) do
    local td = sdk.find_type_definition(r)
    if td then queue[#queue + 1] = { td = td, d = 0 } else L("type not found: " .. r) end
  end
  local qi = 1
  while qi <= #queue and #order < 150 do
    local node = queue[qi]
    qi = qi + 1
    local n = tdn(node.td)
    if n and not visited[n] then
      visited[n] = node.td
      order[#order + 1] = n
      if node.d < 4 then
        local refs = {}
        for _, f in ipairs(node.td:get_fields() or {}) do refs[#refs + 1] = try(function() return f:get_type() end) end
        for _, m in ipairs(node.td:get_methods() or {}) do
          refs[#refs + 1] = try(function() return m:get_return_type() end)
          for _, p in ipairs(m:get_param_types() or {}) do refs[#refs + 1] = p end
        end
        for _, rt in ipairs(refs) do
          local rn = rt and tdn(rt)
          if rn and relevant(rn) and not visited[rn] then queue[#queue + 1] = { td = rt, d = node.d + 1 } end
        end
      end
    end
  end
  L(#order .. " types: " .. table.concat(order, ", "))
  for _, n in ipairs(order) do
    local td = visited[n]
    local par = try(function() return td:get_parent_type():get_full_name() end) or "?"
    L("")
    L("--- " .. n .. "   (parent " .. par .. ")")
    local c = 0
    for _, f in ipairs(td:get_fields() or {}) do
      if c < 300 then c = c + 1 L("   F " .. f:get_name() .. " : " .. (try(function() return f:get_type():get_full_name() end) or "?") .. (f:is_static() and " [static]" or "")) end
    end
    c = 0
    for _, m in ipairs(td:get_methods() or {}) do
      if c < 300 then c = c + 1 L("   M " .. msig(m) .. (try(function() return m:is_static() end) and " [static]" or "")) end
    end
  end

  -- B. every ItemManager method that mentions abilities / categories / jobs
  L("")
  L("##### B. ItemManager methods mentioning ability / category / job types #####")
  local keys = { "EquipmentAbilityID", "EquipmentAbilityParam", "EquipmentAbilityData", "ItemEquipCategory", "JobEnum", "EquipmentAbilityBonus" }
  local t, seenm = sdk.find_type_definition("app.ItemManager"), {}
  while t do
    for _, m in ipairs(t:get_methods() or {}) do
      local k = msig(m)
      if not seenm[k] then
        seenm[k] = true
        for _, key in ipairs(keys) do
          if k:find(key, 1, true) then L("   " .. k) break end
        end
      end
    end
    t = try(function() return t:get_parent_type() end)
  end

  -- C. live instances
  L("")
  L("##### C. live objects of ability types (ItemManager fields, guessed singletons, static getters) #####")
  local insts = {}
  local function add_inst(label, obj)
    if type(obj) ~= "userdata" then return end
    local td = try(function() return obj:get_type_definition() end)
    if not td then return end
    insts[#insts + 1] = { label = label, obj = obj, td = td }
    L("")
    dump_obj(L, obj, label, 3, 6)
  end
  local ft = sdk.find_type_definition("app.ItemManager")
  local seenf = {}
  while ft and itm do
    for _, f in ipairs(ft:get_fields() or {}) do
      local n = f:get_name()
      local tn = (try(function() return f:get_type():get_full_name() end) or "")
      if not seenf[n] and not f:is_static() and relevant(tn) then
        seenf[n] = true
        add_inst("ItemManager." .. n, try(function() return itm:get_field(n) end))
      end
    end
    ft = try(function() return ft:get_parent_type() end)
  end
  for _, sn in ipairs({ "app.EquipmentAbilityManager", "app.EquipmentAbilityDataManager", "app.AbilityManager",
    "app.ItemDataManager", "app.DataManager", "app.ItemDefine" }) do
    local o = try(function() return sdk.get_managed_singleton(sn) end)
    if o then
      L("")
      L("singleton found: " .. sn)
      local sd = try(function() return o:get_type_definition() end)
      for _, f in ipairs(sd and sd:get_fields() or {}) do
        local tn = (try(function() return f:get_type():get_full_name() end) or "")
        if relevant(tn) and not f:is_static() then add_inst(sn .. "." .. f:get_name(), try(function() return o:get_field(f:get_name()) end)) end
      end
    end
  end
  for _, n in ipairs(order) do
    local td = visited[n]
    for _, m in ipairs(td:get_methods() or {}) do
      local nm = m:get_name()
      if try(function() return m:is_static() end) and #(m:get_param_types() or {}) == 0 and nm:sub(1, 4) == "get_" then
        local rt = try(function() return m:get_return_type():get_full_name() end) or ""
        if relevant(rt) then add_inst(n .. "::" .. nm .. "()", try(function() return m:call(nil) end)) end
      end
    end
  end
  if #insts == 0 then L("no live ability objects found by these routes") end

  -- D. probe: pure-looking predicate methods swept over ability id x category/job
  L("")
  L("##### D. predicate probe: is/can/check/has/enable methods returning Boolean, params limited to ability id / category / job / int #####")
  local OKP = { ["app.EquipmentAbilityID"] = "abil", ["app.ItemEquipCategory"] = "cat", ["app.Character.JobEnum"] = "job", ["System.Int32"] = "int", ["System.Byte"] = "int" }
  local calls = 0
  local function probe(label, obj, td)
    local t2, seen = td, {}
    while t2 do
      for _, m in ipairs(t2:get_methods() or {}) do
        local nm = m:get_name()
        local ln = nm:lower()
        local rt = try(function() return m:get_return_type():get_full_name() end)
        local pts = m:get_param_types() or {}
        local key = msig(m)
        if not seen[key] and rt == "System.Boolean" and (ln:find("^is") or ln:find("^can") or ln:find("^check") or ln:find("^has") or ln:find("^enable"))
          and #pts >= 1 and #pts <= 2 then
          local kinds, good = {}, true
          for i, p in ipairs(pts) do
            kinds[i] = OKP[tdn(p) or ""]
            if not kinds[i] then good = false end
          end
          local hasAbil = false
          for _, k in ipairs(kinds) do if k == "abil" then hasAbil = true end end
          seen[key] = true
          if good and hasAbil and calls < 6000 then
            L("")
            L("probe " .. label .. " :: " .. key)
            local static = try(function() return m:is_static() end)
            local self = (not static) and obj or nil
            if (not static) and not obj then L("   (needs instance, none available)")
            elseif #pts == 1 then
              local on = {}
              for a = 0, 78 do
                calls = calls + 1
                local ok, r = pcall(function() return m:call(self, a) end)
                if ok and (r == true or r == 1) then on[#on + 1] = tostring(a) end
              end
              L("   true for ability ids: " .. table.concat(on, ","))
            else
              local aIdx = (kinds[1] == "abil") and 1 or 2
              local oIdx = 3 - aIdx
              for a = 1, 78 do
                local on = {}
                for o = 0, 10 do
                  calls = calls + 1
                  local ok, r
                  if aIdx == 1 then ok, r = pcall(function() return m:call(self, a, o) end)
                  else ok, r = pcall(function() return m:call(self, o, a) end) end
                  if ok and (r == true or r == 1) then on[#on + 1] = tostring(o) end
                end
                L(string.format("   ability %d (%s) %s=%s", a, "", kinds[oIdx], table.concat(on, ",")))
              end
            end
          end
        end
      end
      t2 = try(function() return t2:get_parent_type() end)
    end
  end
  local probed = {}
  for _, i in ipairs(insts) do probed[#probed + 1] = { label = i.label, obj = i.obj, td = i.td } end
  probed[#probed + 1] = { label = "ItemManager", obj = itm, td = sdk.find_type_definition("app.ItemManager") }
  for _, n in ipairs(order) do probed[#probed + 1] = { label = n .. " (static only)", obj = nil, td = visited[n] } end
  for _, p in ipairs(probed) do if p.td then probe(p.label, p.obj, p.td) end end
  L("")
  L("probe calls made: " .. calls)

  L("")
  L("##### E. ability id names (from app.EquipmentAbilityID) #####")
  for _, e in ipairs(enum_list("app.EquipmentAbilityID")) do L(string.format("%d %s", e.value, e.name)) end

  for _, l in ipairs(lines) do log.info(TAG .. "abildump3: " .. l) end
  if not wr(DIR .. "abildump3.txt", table.concat(lines, "\n")) then error("could not write abildump3.txt") end
  return tostring(#lines)
end

-- v1.13.1: everything the game has about core (normal) skills for the target, to find what Enable ALL misses
COMMANDS.core_dump = function(a)
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local c = get_target(a[1])
  local job = int(a[2])
  L("target = " .. tostring(a[1]) .. "   vocation = " .. tostring(job))
  L("")
  L("##### 1. every app.HumanNormalSkillID entry and its state for this target #####")
  for _, ent in ipairs(enum_list("app.HumanNormalSkillID")) do
    local en = try(function() return c.skill:call("isNormalSkillEnable", ent.value) end)
    L(string.format("%d\t%s\tjob=%s\tenabled=%s", ent.value, ent.name, tostring(job_of(ent.name)), tostring(en)))
  end
  L("")
  L("##### 2. SkillContext methods and fields mentioning normal / enable / learn / lock #####")
  local td, seen = c.skill:get_type_definition(), {}
  L("type " .. (tdn(td) or "?"))
  local t = td
  while t do
    for _, m in ipairs(t:get_methods() or {}) do
      local k = msig(m)
      local l = k:lower()
      if not seen[k] and (l:find("normal", 1, true) or l:find("enable", 1, true) or l:find("learn", 1, true) or l:find("lock", 1, true) or l:find("acquire", 1, true)) then
        seen[k] = true
        L("   M " .. k)
      end
    end
    for _, f in ipairs(t:get_fields() or {}) do
      L("   F " .. f:get_name() .. " : " .. (try(function() return f:get_type():get_full_name() end) or "?"))
    end
    t = try(function() return t:get_parent_type() end)
  end
  L("")
  L("##### 3. SkillContext object contents #####")
  dump_obj(L, c.skill, "SkillContext", 2, 8)
  L("")
  L("##### 4. JobContext methods mentioning level / rank / normal #####")
  if c.job then
    local jt, js = c.job:get_type_definition(), {}
    while jt do
      for _, m in ipairs(jt:get_methods() or {}) do
        local k = msig(m)
        local l = k:lower()
        if not js[k] and (l:find("level", 1, true) or l:find("rank", 1, true) or l:find("normal", 1, true) or l:find("skill", 1, true)) then
          js[k] = true
          L("   M " .. k)
        end
      end
      jt = try(function() return jt:get_parent_type() end)
    end
    L("")
    dump_obj(L, c.job, "JobContext", 2, 8)
  else
    L("no JobContext")
  end
  for _, l in ipairs(lines) do log.info(TAG .. "coredump: " .. l) end
  if not wr(DIR .. "coredump.txt", table.concat(lines, "\n")) then error("could not write coredump.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.14 jump height / air time / no fall damage
-- Jump height and air time come from the "Super Jump Updated" mod: JumpParam.MaxRootHeight and a scale on
-- HumanJumpRootAdjuster.ElapsedFrame. No fall damage patches every numeric field under the player's Action param whose
-- path contains "fall" (damage rate/factor -> 0, start height/distance -> very large) and restores the originals when switched off.
local JUMP = { height = nil, orig_height = nil, air = 1.0, nofall = false, active = false, human = nil, fall_orig = {}, cache = nil }

local function jump_ctx()
  local c = get_target("player")
  local pr = try(function() return c.human:call("get_Param") end)
  local act = pr and try(function() return pr:call("get_Action") end)
  if not act then error("player Action param not found") end
  local jp = try(function() return act:get_field("JumpParam") end) or try(function() return act.JumpParam end)
  if not jp then error("JumpParam not found") end
  return c, act, jp
end

local function jp_read(jp)
  local v = try(function() return jp:get_field("MaxRootHeight") end)
  if type(v) ~= "number" then v = try(function() return jp.MaxRootHeight end) end
  return v
end

local function jp_write(jp, v)
  if not pcall(function() jp:set_field("MaxRootHeight", v + 0.0) end) then jp.MaxRootHeight = v + 0.0 end
end

local function fall_scan(root, words)
  local out, seen, count = {}, {}, 0
  local function matches(lp)
    for _, w in ipairs(words) do if lp:find(w, 1, true) then return true end end
    return false
  end
  local function walk(obj, path, depth)
    local t = try(function() return obj:get_type_definition() end)
    while t do
      for _, f in ipairs(t:get_fields() or {}) do
        if count < 800 and not f:is_static() then
          local n = f:get_name()
          local key = path .. "." .. n
          if not seen[key] then
            seen[key] = true
            count = count + 1
            local tn = try(function() return f:get_type():get_full_name() end) or ""
            local v = try(function() return obj:get_field(n) end)
            if type(v) == "number" then
              if matches(key:lower()) then out[#out + 1] = { obj = obj, name = n, path = key, val = v, tn = tn } end
            elseif type(v) == "userdata" and depth < 3 and tn:sub(1, 4) == "app." and not tn:find("[]", 1, true) and not tn:find("`", 1, true) then
              walk(v, key, depth + 1)
            end
          end
        end
      end
      t = try(function() return t:get_parent_type() end)
    end
  end
  walk(root, "Action", 0)
  return out
end

local function fall_plan(e)
  local l = e.name:lower()
  local isint = math.type(e.val) == "integer"
  if l:find("height", 1, true) or l:find("distance", 1, true) or l:find("threshold", 1, true) or l:find("border", 1, true)
    or l:find("limit", 1, true) or l:find("start", 1, true) then
    if not isint then return 100000.0 end
    if e.tn:find("Int32", 1, true) then return 1000000 end
    if e.tn:find("Int16", 1, true) and not e.tn:find("UInt16", 1, true) then return 30000 end
    return nil
  end
  if l:find("damage", 1, true) or l:find("rate", 1, true) or l:find("ratio", 1, true) or l:find("factor", 1, true)
    or l:find("percent", 1, true) or l:find("hp", 1, true) then
    return isint and 0 or 0.0
  end
  return nil
end

local function fall_apply(act)
  local addr = try(function() return act:get_address() end)
  if not (JUMP.cache and JUMP.cache.addr == addr) then
    JUMP.cache = { addr = addr, list = fall_scan(act, { "fall" }) }
  end
  local names, n = {}, 0
  for _, e in ipairs(JUMP.cache.list) do
    local ent = JUMP.fall_orig[e.path]
    if JUMP.nofall then
      local nv = fall_plan(e)
      if nv ~= nil then
        if not ent then ent = { orig = e.val } JUMP.fall_orig[e.path] = ent end
        ent.obj, ent.name = e.obj, e.name
        if pcall(function() e.obj:set_field(e.name, nv) end) then n = n + 1 names[#names + 1] = e.path end
      end
    elseif ent then
      pcall(function() e.obj:set_field(e.name, ent.orig) end)
      n = n + 1
    end
  end
  if not JUMP.nofall then JUMP.fall_orig = {} end
  return n, names
end

local function jump_apply()
  local c, act, jp = jump_ctx()
  if JUMP.orig_height == nil then JUMP.orig_height = jp_read(jp) end
  JUMP.human = c.human
  if JUMP.height then jp_write(jp, JUMP.height) end
  local n, names = fall_apply(act)
  return n, names
end

local jat = sdk.find_type_definition("app.HumanJumpRootAdjuster")
if jat then
  pcall(function()
    sdk.hook(jat:get_method("update"), function(args)
      if JUMP.air ~= 1.0 and JUMP.human then
        pcall(function()
          local this = sdk.to_managed_object(args[2])
          if this and this.Human == JUMP.human then this.ElapsedFrame = this.ElapsedFrame * JUMP.air end
        end)
      end
    end, nil)
  end)
end

local jump_last = 0
re.on_frame(function()
  if not JUMP.active then return end
  local now = os.clock()
  if now - jump_last < 1.0 then return end
  jump_last = now
  pcall(jump_apply)
end)

-- args: height ("" = leave), air time scale, no fall damage 0/1
COMMANDS.jump_set = function(a)
  local h = tonumber(a[1] or "")
  if h then JUMP.height = h end
  JUMP.air = tonumber(a[2] or "") or JUMP.air
  JUMP.nofall = (a[3] == "1")
  JUMP.active = true
  local n, names = jump_apply()
  local msg = string.format("height=%s air=%s", tostring(JUMP.height), tostring(JUMP.air))
  if JUMP.nofall then
    msg = msg .. string.format("; no fall damage: %d field(s) patched", n)
    if n == 0 then msg = msg .. " (none found - use DUMP jump/fall data and send it)" else msg = msg .. " [" .. table.concat(names, ", ") .. "]" end
  else
    msg = msg .. "; no fall damage off"
  end
  return msg
end

COMMANDS.jump_get = function()
  local c, act, jp = jump_ctx()
  local cur = jp_read(jp)
  if JUMP.orig_height == nil then JUMP.orig_height = cur end
  return string.format("%s,%s,%s,%s", tostring(JUMP.orig_height), tostring(cur), tostring(JUMP.air), JUMP.nofall and "1" or "0")
end

COMMANDS.jump_reset = function()
  local c, act, jp = jump_ctx()
  if JUMP.orig_height ~= nil then jp_write(jp, JUMP.orig_height) end
  JUMP.height, JUMP.air, JUMP.nofall, JUMP.active = nil, 1.0, false, false
  fall_apply(act)
  return "reset to game values (" .. tostring(JUMP.orig_height) .. ")"
end

---------------------------------------------------------------- v1.31 movement speed
-- Movement x% via HumanMoveSpeedCalculator hook; ladder via FullBodyLayer speed.
local MOVE = { rate = 100, pawns = true, ladder = 100,
               addrs = {}, layer = nil, refresh_at = 0, hooked = false }

local function move_refresh()
  local set = {}
  local cm = sdk.get_managed_singleton("app.CharacterManager")
  local pl = cm and try(function() return cm:call("get_ManualPlayer") end)
  if pl then local a = try(function() return pl:get_address() end) if a then set[a] = true end end
  if MOVE.pawns then
    local pm = sdk.get_managed_singleton("app.PawnManager")
    local list = pm and try(function() return pm:call("getAllPartyPawn") end)
    for _, pw in ipairs(coll_elems(list)) do
      local ch = try(function() return pw:call("get_CachedCharacter") end)
      if ch then local a = try(function() return ch:get_address() end) if a then set[a] = true end end
    end
  end
  MOVE.addrs = set
end

-- install once at load; the pre-hook is a single comparison while rate == 100
do
  local mst = sdk.find_type_definition("app.HumanMoveSpeedCalculator")
  local m = mst and try(function()
    return mst:get_method("calcMoveFrameSpeedImpl(app.HumanSpeedParameter.ActionTypeEnum)")
  end)
  if m then
    pcall(function()
      sdk.hook(m,
        function(args)
          local st = thread.get_hook_storage()
          st.mv = nil
          local rate = MOVE.rate
          if rate == 100 then return end
          local at = sdk.to_int64(args[3]) & 0xFFFFFFFF
          if not (at == 0 or at == 1 or (at >= 6 and at <= 16)) then return end
          local calc = sdk.to_managed_object(args[2])
          local chara = calc and try(function() return calc:get_field("Chara") end)
          local addr = chara and try(function() return chara:get_address() end)
          if addr and MOVE.addrs[addr] then st.mv = rate end
        end,
        function(retval)
          local st = thread.get_hook_storage()
          local rate = st.mv
          st.mv = nil
          if not rate then return retval end
          return sdk.float_to_ptr(sdk.to_float(retval) * rate / 100)
        end)
      MOVE.hooked = true
    end)
  end
  if not MOVE.hooked then log.info(TAG .. "movespeed: hook not installed (method not found)") end
end

re.on_frame(function()
  local active = MOVE.rate ~= 100 or MOVE.ladder ~= 100
  if active then
    local now = os.clock()
    if now - MOVE.refresh_at > 5 then
      MOVE.refresh_at = now
      pcall(move_refresh)
    end
  end
  local want = nil
  if MOVE.ladder ~= 100 then
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local pl = cm and try(function() return cm:call("get_ManualPlayer") end)
    local node = pl and try(function()
      local mgr = pl:get_field("<ActionManager>k__BackingField")
      local fsm = mgr and mgr:get_field("Fsm")
      local s = fsm and fsm:call("getCurrentNodeName(System.UInt32)", 0)
      return type(s) == "string" and s or nil
    end)
    if node and node:sub(1, 22) == "Locomotion.ClimbLadder" then
      want = MOVE.ladder / 100
    end
  end
  if want then
    if not MOVE.layer then
      local cm = sdk.get_managed_singleton("app.CharacterManager")
      local pl = cm and try(function() return cm:call("get_ManualPlayer") end)
      MOVE.layer = pl and try(function() return pl:get_field("FullBodyLayer") end)
    end
    if MOVE.layer then pcall(function() MOVE.layer:call("set_Speed(System.Single)", want) end) end
  elseif MOVE.layer then
    pcall(function() MOVE.layer:call("set_Speed(System.Single)", 1.0) end)
    MOVE.layer = nil
  end
end)

-- args: rate percent (100 = off), pawns 0/1, ladder percent (100 = off)
COMMANDS.movespeed_set = function(a)
  MOVE.rate = math.max(100, math.min(300, tonumber(a[1]) or 100))
  MOVE.pawns = (a[2] ~= "0")
  MOVE.ladder = math.max(100, math.min(300, tonumber(a[3]) or 100))
  pcall(move_refresh)
  MOVE.refresh_at = os.clock()
  return string.format("movement %d%% (pawns %s), ladder %d%%",
    MOVE.rate, MOVE.pawns and "on" or "off", MOVE.ladder)
end

COMMANDS.movespeed_get = function()
  return string.format("%d|%d|%d|%s",
    MOVE.rate, MOVE.pawns and 1 or 0, MOVE.ladder, MOVE.hooked and "hooked" or "nohook")
end

COMMANDS.jump_probe = function()
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local c, act, jp = jump_ctx()
  L("##### JumpParam #####")
  dump_obj(L, jp, "JumpParam", 2, 6)
  L("")
  L("##### numeric fields under the Action param whose path contains fall / land / drop (P = would be patched by No fall damage) #####")
  for _, e in ipairs(fall_scan(act, { "fall", "land", "drop" })) do
    local plan = e.path:lower():find("fall", 1, true) and fall_plan(e) or nil
    L(string.format("%s %s = %s  (%s)%s", plan ~= nil and "P" or "-", e.path, tostring(e.val), e.tn, plan ~= nil and ("  -> " .. tostring(plan)) or ""))
  end
  L("")
  L("##### Action param type: field names and types (top level) #####")
  local t = try(function() return act:get_type_definition() end)
  while t do
    for _, f in ipairs(t:get_fields() or {}) do
      L("   F " .. f:get_name() .. " : " .. (try(function() return f:get_type():get_full_name() end) or "?"))
    end
    t = try(function() return t:get_parent_type() end)
  end
  L("")
  L("##### Human methods mentioning fall / land #####")
  local ht, seen = c.human:get_type_definition(), {}
  while ht do
    for _, m in ipairs(ht:get_methods() or {}) do
      local k = msig(m)
      local l = k:lower()
      if not seen[k] and (l:find("fall", 1, true) or l:find("land", 1, true)) then seen[k] = true L("   M " .. k) end
    end
    ht = try(function() return ht:get_parent_type() end)
  end
  for _, l in ipairs(lines) do log.info(TAG .. "jumpprobe: " .. l) end
  if not wr(DIR .. "jumpprobe.txt", table.concat(lines, "\n")) then error("could not write jumpprobe.txt") end
  return tostring(#lines)
end

---------------------------------------------------------------- v1.23: faster enemy respawn
-- Adapted from FasterRespawn.lua. Hooks are installed at load but stay
-- inert (they only record the game's defaults) until respawn_set activates
-- the override. Rest at a camp/inn once to trigger the reload.
-- The override is OFF until respawn_set turns it on: merely installing
-- this script must never change gameplay. While inactive both hooks only
-- capture the game's own defaults and return them untouched.
local RESPAWN = { boss = 1, normal = 1, active = false, is_boss = false,
                  boss_def = nil, normal_def = nil, day_def = nil }
do
  local td = try(function() return sdk.find_type_definition("app.GenerateDefaultParameter") end)
  local m = td and try(function() return td:get_method("getDeadCharaRepopTime") end)
  if m then
    sdk.hook(m,
      function(args)
        local v = try(function() return sdk.to_int64(args[3]) end)
        RESPAWN.is_boss = (v and v > 0) and true or false
      end,
      function(retval)
        -- capture the game's original default once, then override
        local orig = try(function() return sdk.to_int64(retval) end)
        if orig ~= nil then
          if RESPAWN.is_boss and RESPAWN.boss_def == nil then
            RESPAWN.boss_def = orig
            log.info(TAG .. "respawn: captured boss default " .. tostring(orig) .. "h")
          elseif not RESPAWN.is_boss and RESPAWN.normal_def == nil then
            RESPAWN.normal_def = orig
            log.info(TAG .. "respawn: captured normal default " .. tostring(orig) .. "h")
          end
        end
        if not RESPAWN.active then return retval end
        return sdk.to_ptr(RESPAWN.is_boss and RESPAWN.boss or RESPAWN.normal)
      end)
    log.info(TAG .. "respawn hook: getDeadCharaRepopTime")
  else
    log.info(TAG .. "respawn hook: getDeadCharaRepopTime NOT FOUND")
  end
  local gm = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local rm = gm and try(function() return gm:get_method("get_RepopDay") end)
  if rm then
    sdk.hook(rm, function(args) end, function(retval)
      if RESPAWN.day_def == nil then
        RESPAWN.day_def = try(function() return sdk.to_int64(retval) end)
        log.info(TAG .. "respawn: captured repop-day default " .. tostring(RESPAWN.day_def))
      end
      if not RESPAWN.active then return retval end
      return sdk.to_ptr(0)
    end)
    log.info(TAG .. "respawn hook: get_RepopDay (override gated on respawn_set)")
  else
    log.info(TAG .. "respawn hook: get_RepopDay NOT FOUND")
  end
end

-- args: boss hours, normal hours
COMMANDS.respawn_set = function(a)
  local b = tonumber(a[1]); local n = tonumber(a[2])
  if b then RESPAWN.boss = math.max(0, math.floor(b)) end
  if n then RESPAWN.normal = math.max(0, math.floor(n)) end
  RESPAWN.active = true
  return string.format("respawn override ON: boss %dh, normal %dh (rest at a camp/inn once to trigger)",
    RESPAWN.boss, RESPAWN.normal)
end

COMMANDS.respawn_get = function()
  return string.format("%d,%d,%d", RESPAWN.boss, RESPAWN.normal,
    RESPAWN.active and 1 or 0)
end

local function _defstr(v) return v == nil and "?" or tostring(v) end

-- "?" for any default the game has not reported yet (kill/rest first)
COMMANDS.respawn_defaults = function()
  return string.format("%s,%s,%s",
    _defstr(RESPAWN.boss_def), _defstr(RESPAWN.normal_def), _defstr(RESPAWN.day_def))
end

COMMANDS.respawn_reset = function()
  RESPAWN.active = false
  if RESPAWN.boss_def ~= nil then RESPAWN.boss = RESPAWN.boss_def end
  if RESPAWN.normal_def ~= nil then RESPAWN.normal = RESPAWN.normal_def end
  return string.format("%d,%d", RESPAWN.boss, RESPAWN.normal)
end

-- Fast-forward ~3 days so corpses decompose and repop hooks trigger.
-- Discovers the real TimeManager API at runtime and reports what it did.
COMMANDS.respawn_clear = function(a)
  local lines = {}
  local function L(x) lines[#lines + 1] = x end
  local tm = try(function() return sdk.get_managed_singleton("app.TimeManager") end)
  if not tm then error("TimeManager unavailable") end
  local day0 = try(function() return tm:get_InGameDay() end)
  L("day before: " .. tostring(day0))

  local done = false
  -- 1. engine time-skip via direct field write. The clock is plain data
  -- (TimeManager._TimeData.<InGameDay>k__BackingField); no method
  -- preconditions to violate. Write + read-back verify.
  local tsm = try(function() return sdk.get_managed_singleton("app.TimeSkipManager") end)
  if tsm then
    local ok, msg = pcall(function()
      local tm2 = try(function() return sdk.get_managed_singleton("app.TimeManager") end)
      if not tm2 then error("no TimeManager") end
      local day0 = tm2:get_InGameDay()
      if not day0 then error("no day") end
      local tdata = tm2:get_field("_TimeData")
      if not tdata then error("no _TimeData") end
      local fname = "<InGameDay>k__BackingField"
      local target = day0 + 3
      local function try_write(obj)
        if not obj then return false end
        local wok = pcall(function() obj:set_field(fname, target) end)
        if not wok then
          local fdef = try(function()
            return obj:get_type_definition():get_field(fname) end)
          if fdef then wok = pcall(function() fdef:set_data(obj, target) end) end
        end
        local rb = try(function() return obj:get_field(fname) end)
        return wok and rb == target
      end
      local ok1 = try_write(tdata)
      local tlook = tm2:get_field("_TimeDataLook")
      local ok2 = try_write(tlook)
      -- _DetectionCacheDay lives on TimeManager itself (different field name)
      local dcok = pcall(function() tm2:set_field("_DetectionCacheDay", target) end)
      local dcrb = try(function() return tm2:get_field("_DetectionCacheDay") end)
      if ok1 then
        return "OK day " .. tostring(day0) .. " -> " .. tostring(target) ..
          " (timedata=" .. tostring(ok1) ..
          " look=" .. tostring(ok2) ..
          " cache=" .. tostring(dcok and dcrb == target) .. ")"
      else
        error("write did not stick")
      end
    end)
    if ok then
      L("engine time-skip: " .. tostring(msg) .. " (field write, no teleport)")
      L("check the in-game clock - corpses should clear as time catches up")
      done = true
    else
      L("engine time-skip failed: " .. tostring(msg):sub(1, 120))
    end
  else
    L("TimeSkipManager not found")
  end

  -- 2. fallback: old TimeManager guessing
  if not done then
    local td = try(function() return sdk.find_type_definition("app.TimeManager") end)
    local attempts = {
      { "skipTime", { 72.0 } }, { "SkipTime", { 72.0 } },
      { "advanceTime", { 72.0 } }, { "addTime", { 72.0 } },
    }
    for _, at in ipairs(attempts) do
      local name, args = at[1], at[2]
      local ok = pcall(function()
        local m = td and td:get_method(name)
        if not m then error("no method") end
        tm:call(name, table.unpack(args))
      end)
      if ok then L("called " .. name .. "(72)"); done = true; break end
    end
  end

  local day1 = try(function() return tm:get_InGameDay() end)
  L("day after (immediate read): " .. tostring(day1))
  if not done then
    L("no working time-skip found - rest at a camp/inn to advance time instead")
  end
  return table.concat(lines, " | ")
end

---------------------------------------------------------------- v1.89.5: summon-boss probe
-- Research pass for a future "summon boss near the player" feature.
-- Dumps the spawn-relevant surface (character catalog, CharacterManager,
-- GenerateManager, pawn/enemy managers, loaded characters) to
-- summon_probe.txt and returns a one-line summary. Read-only: it never
-- calls any generate/create method, it only lists names.
-- Shared summon state, declared before the probes: probe step 5
-- stages a container here for summon_verify to re-read.
local SUMMON = { ctrl = nil, name = nil, chara = nil, uniq = nil, queued = false, cont = nil }

COMMANDS.summon_probe = function()
  local out = {}
  local function L(x) out[#out + 1] = x end
  local KEYS = { "generat", "spawn", "create", "request", "summon",
                 "chara", "regist", "repop", "appear", "call" }
  local function keyhit(name)
    local l = name:lower()
    for _, k in ipairs(KEYS) do if l:find(k, 1, true) then return true end end
    return false
  end
  local function dump_methods(td, label)
    if not td then L(label .. ": TYPE NOT FOUND") return end
    local ms = try(function() return td:get_methods() end) or {}
    local n = 0
    for _, m in ipairs(ms) do
      local mn = try(function() return m:get_name() end) or ""
      if keyhit(mn) then
        local pts = try(function() return m:get_param_types() end) or {}
        local ps = {}
        for _, t in ipairs(pts) do
          ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
        end
        local rt = try(function() return m:get_return_type() end)
        L("  method " .. mn .. "(" .. table.concat(ps, ", ") .. ") -> " ..
          tostring(rt and try(function() return rt:get_full_name() end) or "?"))
        n = n + 1
        if n >= 120 then L("  ... (method list capped)") break end
      end
    end
    L("  (" .. n .. " spawn-ish methods of " .. #ms .. " total)")
  end
  local function dump_fields(td, label, inst)
    if not td then return end
    local fs = try(function() return td:get_fields() end) or {}
    local shown = 0
    for _, f in ipairs(fs) do
      local fn = try(function() return f:get_name() end) or ""
      if keyhit(fn) or inst then
        local ft = try(function() return f:get_type() end)
        local line = "  field " .. fn .. " : " ..
          tostring(ft and try(function() return ft:get_full_name() end) or "?")
        if inst then
          local v = try(function() return f:get_data(inst) end)
          if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            line = line .. " = " .. tostring(v)
          elseif v ~= nil then
            local vt = try(function() return v:get_type_definition() end)
            line = line .. " = <" ..
              tostring(vt and try(function() return vt:get_full_name() end) or type(v)) .. ">"
          end
        end
        L(line)
        shown = shown + 1
        if shown >= 80 then L("  ... (field list capped)") break end
      end
    end
  end

  L("== summon_probe (bridge 1.89.67) ==")

  -- 1. character catalog: the ID enum, if one exists
  for _, tname in ipairs({ "app.CharacterID", "app.CharaID",
                           "app.CharacterId", "app.CharaId" }) do
    local td = try(function() return sdk.find_type_definition(tname) end)
    if td then
      L("== catalog type " .. tname .. " ==")
      local fs = try(function() return td:get_fields() end) or {}
      local n = 0
      for _, f in ipairs(fs) do
        local fn = try(function() return f:get_name() end) or ""
        local v = try(function() return f:get_data(nil) end)
        L("  " .. fn .. " = " .. tostring(v))
        n = n + 1
        if n >= 400 then L("  ... (catalog capped at 400)") break end
      end
      L("  (" .. n .. " entries)")
    end
  end

  -- 2. the managers that could create a character
  for _, tname in ipairs({ "app.CharacterManager", "app.GenerateManager",
                           "app.GenerateDefaultParameter", "app.EnemyManager",
                           "app.PawnManager" }) do
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== " .. tname .. " ==")
    dump_methods(td, tname)
    local inst = td and try(function() return sdk.get_managed_singleton(tname) end)
    dump_fields(td, tname, inst)
    if not inst then L("  (no singleton instance)") end
  end

  -- 3. who is loaded right now (shows how enemies register as characters)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local player = cm and try(function() return cm:call("get_ManualPlayer") end)
  if player then
    local go = try(function() return player:call("get_GameObject") end)
    local tr = go and try(function() return go:call("get_Transform") end)
    local pos = tr and try(function() return tr:call("get_Position") end)
    L("== player position: " .. tostring(pos and
      (tostring(pos.x) .. ", " .. tostring(pos.y) .. ", " .. tostring(pos.z)) or "?") .. " ==")
  else
    L("== player not found (not loaded into the game?) ==")
  end

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe.txt", text) then error("could not write summon_probe.txt") end
  return "summon_probe.txt written: " .. #out .. " lines"
end

do
---------------------------------------------------------------- v1.89.5: summon probe step 2
-- Step 1 found the pipeline shape: GenerateManager can build a character
-- container (getPoolGenerateInfoContainerForCharacter) and generate from
-- it (requestGenerate). What step 1 did not show: the enum VALUES those
-- calls take (GeneratorCategory, LayerTypeEnum, InitSetTypeEnum,
-- GenerateOprionFlags), the container type's own shape, and the full
-- CharacterID catalog (it capped at 400). This dumps exactly those.
-- Read-only again: lists names/values, calls nothing.
COMMANDS.summon_probe2 = function()
  local out = {}
  local function L(x) out[#out + 1] = x end

  local function dump_enum(tname)
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== enum " .. tname .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local fs = try(function() return td:get_fields() end) or {}
    local n = 0
    for _, f in ipairs(fs) do
      local fn = try(function() return f:get_name() end) or ""
      if fn ~= "value__" then
        local v = try(function() return f:get_data(nil) end)
        L("  " .. fn .. " = " .. tostring(v))
        n = n + 1
      end
    end
    L("  (" .. n .. " members)")
  end

  local function dump_type_full(tname, cap)
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== type " .. tname .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local ms = try(function() return td:get_methods() end) or {}
    local n = 0
    for _, m in ipairs(ms) do
      local mn = try(function() return m:get_name() end) or ""
      local pts = try(function() return m:get_param_types() end) or {}
      local ps = {}
      for _, t in ipairs(pts) do
        ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
      end
      local rt = try(function() return m:get_return_type() end)
      L("  method " .. mn .. "(" .. table.concat(ps, ", ") .. ") -> " ..
        tostring(rt and try(function() return rt:get_full_name() end) or "?"))
      n = n + 1
      if n >= cap then L("  ... (method list capped)") break end
    end
    local fs = try(function() return td:get_fields() end) or {}
    local shown = 0
    for _, f in ipairs(fs) do
      local fn = try(function() return f:get_name() end) or ""
      local ft = try(function() return f:get_type() end)
      L("  field " .. fn .. " : " ..
        tostring(ft and try(function() return ft:get_full_name() end) or "?"))
      shown = shown + 1
      if shown >= cap then L("  ... (field list capped)") break end
    end
    L("  (" .. n .. " methods, " .. shown .. " fields)")
  end

  L("== summon_probe2 (bridge 1.89.67) ==")

  for _, tname in ipairs({ "app.GeneratorCategory", "app.LayerTypeEnum",
                           "app.GenerateDefine.InitSetTypeEnum",
                           "app.GenerateManager.GenerateOprionFlags",
                           "app.GenerateManager.GenerateOptionFlags",
                           "app.RequestTypeEnum" }) do
    dump_enum(tname)
  end

  dump_type_full("app.GenerateInfo.GenerateInfoContainer", 200)
  dump_type_full("app.GenerateInfo.CommonInfoData", 200)
  dump_type_full("app.GenerateController", 120)

  for _, tname in ipairs({ "app.GenerateManager", "app.CharacterManager",
                           "app.EnemyManager", "app.PawnManager" }) do
    local inst = try(function() return sdk.get_managed_singleton(tname) end)
    L("singleton " .. tname .. ": " .. (inst and "PRESENT" or "absent"))
  end

  local td = try(function() return sdk.find_type_definition("app.CharacterID") end)
  L("== catalog app.CharacterID (full) ==")
  if td then
    local fs = try(function() return td:get_fields() end) or {}
    local n = 0
    for _, f in ipairs(fs) do
      local fn = try(function() return f:get_name() end) or ""
      local v = try(function() return f:get_data(nil) end)
      L("  " .. fn .. " = " .. tostring(v))
      n = n + 1
    end
    L("  (" .. n .. " entries)")
  else
    L("  TYPE NOT FOUND")
  end

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe2.txt", text) then error("could not write summon_probe2.txt") end
  return "summon_probe2.txt written: " .. #out .. " lines"
end

end
do
---------------------------------------------------------------- v1.89.8: summon probe step 3
-- requestGenerate(container, ...) returns nil without an exception
-- for factory-built and hand-built containers alike, so the real
-- entry point may be elsewhere in GenerateManager: step 1's keyword
-- filter saw 120 of its 356 methods. This dumps the FULL method list
-- plus the shapes of the table/selector route types. Read-only.
COMMANDS.summon_probe3 = function()
  local out = {}
  local function L(x) out[#out + 1] = x end
  local function sig(m)
    local pts = try(function() return m:get_param_types() end) or {}
    local ps = {}
    for _, t in ipairs(pts) do
      ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
    end
    local rt = try(function() return m:get_return_type() end)
    return "(" .. table.concat(ps, ", ") .. ") -> " ..
      tostring(rt and try(function() return rt:get_full_name() end) or "?")
  end
  local function dump_all_methods(tname)
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== ALL methods of " .. tname .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local ms = try(function() return td:get_methods() end) or {}
    for _, m in ipairs(ms) do
      L("  " .. tostring(try(function() return m:get_name() end) or "?") .. sig(m))
    end
    L("  (" .. #ms .. " methods)")
  end
  local function dump_type_full(tname, cap)
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== type " .. tname .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local ms = try(function() return td:get_methods() end) or {}
    local n = 0
    for _, m in ipairs(ms) do
      L("  method " .. tostring(try(function() return m:get_name() end) or "?") .. sig(m))
      n = n + 1
      if n >= cap then L("  ... (method list capped)") break end
    end
    local fs = try(function() return td:get_fields() end) or {}
    local shown = 0
    for _, f in ipairs(fs) do
      local fn = try(function() return f:get_name() end) or ""
      local ft = try(function() return f:get_type() end)
      L("  field " .. fn .. " : " ..
        tostring(ft and try(function() return ft:get_full_name() end) or "?"))
      shown = shown + 1
      if shown >= cap then L("  ... (field list capped)") break end
    end
    L("  (" .. n .. " methods, " .. shown .. " fields)")
  end

  L("== summon_probe3 (bridge 1.89.67) ==")
  dump_all_methods("app.GenerateManager")
  for _, tname in ipairs({ "app.GenerateSelector", "app.GenerateTableData",
                           "app.GenerateTableListData", "app.AutoSetGenerateTableData",
                           "app.GenerateSetting.GenerateSettingContainer",
                           "app.UniqueID", "app.GeneratorID", "app.RequestID",
                           "app.GenerateTable" }) do
    dump_type_full(tname, 250)
  end
  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe3.txt", text) then error("could not write summon_probe3.txt") end
  return "summon_probe3.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.11: summon probe step 4
-- Five rounds in, every door refuses the same way (nil / code -1)
-- while the manager's own checks pass, and the verify retries killed
-- the async-prefab theory (same -1 seconds later). Stop guessing
-- what a valid request looks like and DIFF against a real one: dump
-- our factory container and a real world enemy's container (built
-- back from its save-data request) through the same reflective
-- dumper, fire the force call at the REAL container as a control,
-- and dump the catalog/default-parameter types that might fill the
-- gap. (Building our container registers it, exactly like a summon
-- attempt; nothing here spawns from our container.)
COMMANDS.summon_probe4 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function typename(o)
    local td = try(function() return o:get_type_definition() end)
    return td and tostring(try(function() return td:get_full_name() end)) or "?"
  end
  local function dump_obj(label, o, depth)
    if not o then L(label .. " = nil") return end
    L(label .. " : " .. typename(o))
    if depth >= 2 then return end
    local td = try(function() return o:get_type_definition() end)
    if not td then return end
    local ms = try(function() return td:get_methods() end) or {}
    local shown = 0
    for _, m in ipairs(ms) do
      local mn = try(function() return m:get_name() end) or ""
      if mn:sub(1, 4) == "get_" then
        local pts = try(function() return m:get_param_types() end) or {}
        if #pts == 0 then
          local v = try(function() return o:call(mn) end)
          if v == nil then
            L("  " .. mn .. " = nil")
          elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            L("  " .. mn .. " = " .. tostring(v))
          else
            L("  " .. mn .. " = <" .. typename(v) .. "> " .. tostring(v))
            if depth == 0 and mn:find("Info") then
              dump_obj("  [" .. mn .. "]", v, depth + 1)
            end
          end
          shown = shown + 1
          if shown >= 120 then L("  ... (getters capped)") break end
        end
      end
    end
  end
  local function dump_enum(tname)
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== enum " .. tname .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local fs = try(function() return td:get_fields() end) or {}
    for _, f in ipairs(fs) do
      if try(function() return f:is_static() end) then
        L("  " .. tostring(try(function() return f:get_name() end) or "?") ..
          " = " .. tostring(try(function() return f:get_data(nil) end)))
      end
    end
  end
  local function dump_type(tname)
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== type " .. tname .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local ms = try(function() return td:get_methods() end) or {}
    local n = 0
    for _, m in ipairs(ms) do
      local pts = try(function() return m:get_param_types() end) or {}
      local ps = {}
      for _, t in ipairs(pts) do
        ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
      end
      local rt = try(function() return m:get_return_type() end)
      L("  method " .. tostring(try(function() return m:get_name() end) or "?") ..
        "(" .. table.concat(ps, ", ") .. ") -> " ..
        tostring(rt and try(function() return rt:get_full_name() end) or "?"))
      n = n + 1
      if n >= 200 then L("  ... (methods capped)") break end
    end
    local fs = try(function() return td:get_fields() end) or {}
    local shown = 0
    for _, f in ipairs(fs) do
      local ft = try(function() return f:get_type() end)
      L("  field " .. tostring(try(function() return f:get_name() end) or "?") ..
        " : " .. tostring(ft and try(function() return ft:get_full_name() end) or "?"))
      shown = shown + 1
      if shown >= 80 then L("  ... (fields capped)") break end
    end
  end

  L("== summon_probe4 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not gm or not cm then
    L("GenerateManager or CharacterManager missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe4.txt", table.concat(out, "\n")) then error("could not write summon_probe4.txt") end
    return "summon_probe4: managers missing"
  end
  dump_enum("app.LoadAreaEnum")

  -- Resolve ch255000 and the player transform exactly like summon_boss.
  local chara = nil
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfs = ctd and try(function() return ctd:get_fields() end) or {}
  for _, f in ipairs(cfs) do
    if try(function() return f:is_static() end) and
       try(function() return f:get_name() end) == "ch255000" then
      chara = try(function() return f:get_data(nil) end)
    end
  end
  L("ch255000 resolved: " .. tostring(chara))
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  local scale = try(function() return Vector3f.new(1, 1, 1) end)
  local genID = try(function() return gm:call("getPoolGeneratorID") end)
  local uniqID = chara and try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
  local cont = nil
  if chara and ppos and quat and scale and genID and uniqID then
    cont = try(function()
      return gm:call("getPoolGenerateInfoContainerForCharacter",
        genID, uniqID, ppos, quat, scale, 3, 0, chara, 1)
    end)
  end
  dump_obj("OUR container (ch255000, factory)", cont, 0)
  L("defaults: scaleForMonster=" ..
    tostring(try(function() return gm:call("getDefaultScaleForMonster", chara, false) end)) ..
    " initSetting present=" ..
    tostring(try(function() return gm:call("getInitSetting", chara, 1) end) ~= nil) ..
    " appearPriority(100)=" ..
    tostring(try(function() return gm:call("getDefaultAppearPriority", 100, 3, chara) end)))

  -- A real world enemy's request, converted back into a container.
  local reqs = try(function() return gm:call("getEnemyRequests", 3, false, false) end)
    or try(function() return gm:call("getEnemyRequests", 3, true, true) end)
  local cnt = reqs and try(function() return reqs:call("get_Count") end)
  L("enemy requests count = " .. tostring(cnt))
  if reqs and cnt and cnt > 0 then
    local first = try(function() return reqs:call("get_Item", 0) end)
    dump_obj("REAL request save data [0]", first, 0)
    local rc = first and try(function() return gm:call("convRequestSaveDataToContainer", first) end)
    dump_obj("REAL container (converted)", rc, 0)
    if rc then
      local code = try(function()
        return gm:call("forceRequestCreateInstance", rc, function() end, function() end)
      end)
      L("forceRequestCreateInstance(REAL container) = " .. tostring(code))
    end
  end

  local cc = try(function() return gm:call("get_CatalogCtrl") end)
  dump_obj("CatalogCtrl instance", cc, 0)
  dump_type("app.GenerateCatalogController")
  dump_type("app.GenerateDefaultParameter")
  dump_type("via.PrefabController")
  dump_type("app.PrefabController")

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe4.txt", text) then error("could not write summon_probe4.txt") end
  return "summon_probe4.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.12: summon probe step 5
-- Probe 4's findings: getEnemyRequests returned ZERO (it lists saved
-- repop requests, not live enemies - so no real-container diff from
-- that route), our factory container is fully populated, and the
-- missing piece is likely the PREFAB: GenerateCatalogController
-- holds an enemy catalog (CharacterID -> PrefabController) that only
-- contains what the loaded areas registered. force/safe returning -1
-- fits "character not in the enemy catalog / prefab not ready".
-- This probe asks the catalog directly, per code: is there a prefab
-- controller, is it ready, does our container read as ready - and it
-- fires the force call at the first catalog-ready code as a control.
-- It also pulls one live reserve controller (the ~195 the manager
-- reported) and dumps it for the container diff probe 4 wanted.
COMMANDS.summon_probe5 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function typename(o)
    local td = try(function() return o:get_type_definition() end)
    return td and tostring(try(function() return td:get_full_name() end)) or "?"
  end
  local function dump_obj(label, o, depth)
    if not o then L(label .. " = nil") return end
    L(label .. " : " .. typename(o))
    if depth >= 2 then return end
    local td = try(function() return o:get_type_definition() end)
    if not td then return end
    local ms = try(function() return td:get_methods() end) or {}
    local shown = 0
    for _, m in ipairs(ms) do
      local mn = try(function() return m:get_name() end) or ""
      if mn:sub(1, 4) == "get_" then
        local pts = try(function() return m:get_param_types() end) or {}
        if #pts == 0 then
          local v = try(function() return o:call(mn) end)
          if v == nil then
            L("  " .. mn .. " = nil")
          elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            L("  " .. mn .. " = " .. tostring(v))
          else
            L("  " .. mn .. " = <" .. typename(v) .. "> " .. tostring(v))
            if depth == 0 and (mn:find("Info") or mn:find("Container")) then
              dump_obj("  [" .. mn .. "]", v, depth + 1)
            end
          end
          shown = shown + 1
          if shown >= 120 then L("  ... (getters capped)") break end
        end
      end
    end
  end
  local function new_pc()
    local td = try(function() return sdk.find_type_definition("app.PrefabController") end)
    if not td then return nil end
    local o = try(function() return td:create_instance() end)
    if o then try(function() o:call(".ctor") end) end
    return o
  end

  L("== summon_probe5 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not gm or not cm then
    L("GenerateManager or CharacterManager missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe5.txt", table.concat(out, "\n")) then error("could not write summon_probe5.txt") end
    return "summon_probe5: managers missing"
  end
  local cc = try(function() return gm:call("get_CatalogCtrl") end)
  L("CatalogCtrl: " .. tostring(cc))
  if not cc then
    if not wr(DIR .. "summon_probe5.txt", table.concat(out, "\n")) then error("could not write summon_probe5.txt") end
    return "summon_probe5: no catalog controller"
  end

  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  local scale = try(function() return Vector3f.new(1, 1, 1) end)

  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfs = ctd and try(function() return ctd:get_fields() end) or {}
  local function resolve(code)
    for _, f in ipairs(cfs) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == code then
        return try(function() return f:get_data(nil) end)
      end
    end
    return nil
  end

  local codes = { "ch255000", "ch252000", "ch258002", "ch230004", "ch240000" }
  local control_done = false
  for _, code in ipairs(codes) do
    local chara = resolve(code)
    L("-- " .. code .. " resolved: " .. tostring(chara))
    if chara then
      local pc = new_pc()
      local found = pc and try(function()
        return cc:call("getCharacterPrefabController", 3, chara, pc)
      end)
      if found then
        L("   catalog: FOUND ready=" ..
          tostring(try(function() return pc:call("get_Ready") end)) ..
          " refCount=" .. tostring(try(function() return pc:call("get_RefCount") end)) ..
          " hasRef=" .. tostring(try(function() return pc:call("get_HasReference") end)) ..
          " path=" .. tostring(try(function() return pc:call("get_ResourcePath") end)))
      else
        L("   catalog: NOT FOUND (no prefab controller for this code here)")
      end
      local genID = try(function() return gm:call("getPoolGeneratorID") end)
      local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
      local cont = nil
      if ppos and quat and scale and genID and uniqID then
        cont = try(function()
          return gm:call("getPoolGenerateInfoContainerForCharacter",
            genID, uniqID, ppos, quat, scale, 3, 0, chara, 1)
        end)
      end
      if cont then
        L("   container isReadyPrefab=" ..
          tostring(try(function() return cc:call("isReadyPrefab", cont) end)) ..
          " isHasReferencePrefab=" ..
          tostring(try(function() return cc:call("isHasReferencePrefab", cont) end)))
        local ci = try(function() return cont:call("get_CommonInfo") end)
        local sb = ci and try(function() return cc:call("requestStandbyPrefab", ci) end)
        L("   catalog requestStandbyPrefab(CommonInfo) = " .. tostring(sb) ..
          " ; isReadyPrefab now=" ..
          tostring(try(function() return cc:call("isReadyPrefab", cont) end)))
        if code == "ch255000" then
          SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq = cont, code, chara, uniqID
          SUMMON.ctrl = nil
          L("   (ch255000 container staged - Verify re-reads catalog readiness)")
        end
        if found and not control_done and
           try(function() return pc:call("get_Ready") end) == true then
          local code2 = try(function()
            return gm:call("forceRequestCreateInstance", cont, function() end, function() end)
          end)
          L("   CONTROL force on catalog-ready " .. code .. " = " .. tostring(code2))
          control_done = true
        end
      else
        L("   container build failed")
      end
    end
  end
  L("control force attempted: " .. tostring(control_done))

  -- One live reserve controller, for the container diff.
  local res = try(function() return gm:call("getReserveRequests", 3, false, false) end)
    or try(function() return gm:call("getReserveRequests", 3, true, true) end)
  L("reserve dictionary: " .. tostring(res))
  if res then
    local lst = try(function() return res:call("get_Item", 0) end)
    L("reserve list for layer Normal(0): " .. tostring(lst))
    if lst then
      local n = try(function() return lst:call("get_Count") end)
      L("reserve controllers (Normal): " .. tostring(n))
      if n and n > 0 then
        local c0 = try(function() return lst:call("get_Item", 0) end)
        dump_obj("RESERVE controller [0]", c0, 0)
      end
    end
  end

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe5.txt", text) then error("could not write summon_probe5.txt") end
  return "summon_probe5.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.13: summon probe step 6
-- Probe 5 fallout: getCharacterPrefabController filled nothing for
-- any code (its PrefabController parameter is likely an out/ref the
-- Lua bridge cannot service), yet isReadyPrefab reads TRUE for a
-- standby-warmed container - so prefabs are reachable, just not
-- through that signature. This probe dumps the enemy catalog's own
-- type (via the _EnemyCatalog field's type definition) to find a
-- callable accessor, tries its indexer for ch255000, and dumps
-- app.GenerateController in full (the reserve route's setup()
-- signature matters for round 6). Read-only.
COMMANDS.summon_probe6 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function sig(m)
    local pts = try(function() return m:get_param_types() end) or {}
    local ps = {}
    for _, t in ipairs(pts) do
      ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
    end
    local rt = try(function() return m:get_return_type() end)
    return "(" .. table.concat(ps, ", ") .. ") -> " ..
      tostring(rt and try(function() return rt:get_full_name() end) or "?")
  end
  local function dump_type_td(td, label)
    L("== type " .. label .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local ms = try(function() return td:get_methods() end) or {}
    for _, m in ipairs(ms) do
      L("  method " .. tostring(try(function() return m:get_name() end) or "?") .. sig(m))
    end
    local fs = try(function() return td:get_fields() end) or {}
    for _, f in ipairs(fs) do
      local ft = try(function() return f:get_type() end)
      L("  field " .. tostring(try(function() return f:get_name() end) or "?") ..
        " : " .. tostring(ft and try(function() return ft:get_full_name() end) or "?"))
    end
    L("  (" .. #ms .. " methods, " .. #fs .. " fields)")
  end
  local function dump_type(tname)
    dump_type_td(try(function() return sdk.find_type_definition(tname) end), tname)
  end

  L("== summon_probe6 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  if not cc then
    L("no catalog controller - not loaded into the world?")
    if not wr(DIR .. "summon_probe6.txt", table.concat(out, "\n")) then error("could not write summon_probe6.txt") end
    return "summon_probe6: no catalog controller"
  end
  local ec = try(function() return cc:get_field("_EnemyCatalog") end)
  L("_EnemyCatalog field value: " .. tostring(ec))
  if ec then
    local etd = try(function() return ec:get_type_definition() end)
    dump_type_td(etd, "_EnemyCatalog (runtime type)")
    -- Resolve ch255000 and try the catalog's indexer-style accessors.
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local cfs = ctd and try(function() return ctd:get_fields() end) or {}
    local chara = nil
    for _, f in ipairs(cfs) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000" then
        chara = try(function() return f:get_data(nil) end)
      end
    end
    L("ch255000 resolved: " .. tostring(chara))
    if chara then
      for _, mname in ipairs({ "get_Item", "getValue", "get", "find" }) do
        local v = try(function() return ec:call(mname, chara) end)
        L("  catalog " .. mname .. "(ch255000) = " .. tostring(v))
        if v then
          L("    -> ready=" ..
            tostring(try(function() return v:call("get_Ready") end)) ..
            " refCount=" .. tostring(try(function() return v:call("get_RefCount") end)) ..
            " path=" .. tostring(try(function() return v:call("get_ResourcePath") end)))
        end
      end
    end
  end
  dump_type("app.GenerateController")

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe6.txt", text) then error("could not write summon_probe6.txt") end
  return "summon_probe6.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.14: summon probe step 7
-- Round 6's manual reserve route (setup + registGenerateController)
-- queued our controller - then CRASHED the game. The distributor
-- expects manager-side bookkeeping our manual registration skipped.
-- New lead: a GeneratorID carries a TableID (Guid) + ExtraID, and a
-- pooled ID's TableID is probably empty - which would explain why
-- every door refuses a table-less request while all other checks
-- pass. This probe reads our IDs, dumps the enemy catalog's type
-- (carried over from step 6), and scans the global generate tables
-- for one whose set data contains ch255000. Read-only.
COMMANDS.summon_probe7 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function typename(o)
    local td = try(function() return o:get_type_definition() end)
    return td and tostring(try(function() return td:get_full_name() end)) or "?"
  end
  local function dump_obj(label, o, depth)
    if not o then L(label .. " = nil") return end
    L(label .. " : " .. typename(o))
    if depth >= 2 then return end
    local td = try(function() return o:get_type_definition() end)
    if not td then return end
    local ms = try(function() return td:get_methods() end) or {}
    local shown = 0
    for _, m in ipairs(ms) do
      local mn = try(function() return m:get_name() end) or ""
      if mn:sub(1, 4) == "get_" then
        local pts = try(function() return m:get_param_types() end) or {}
        if #pts == 0 then
          local v = try(function() return o:call(mn) end)
          if v == nil then
            L("  " .. mn .. " = nil")
          elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            L("  " .. mn .. " = " .. tostring(v))
          else
            L("  " .. mn .. " = <" .. typename(v) .. "> " .. tostring(v))
            if depth == 0 and (mn:find("Info") or mn:find("Container")) then
              dump_obj("  [" .. mn .. "]", v, depth + 1)
            end
          end
          shown = shown + 1
          if shown >= 120 then L("  ... (getters capped)") break end
        end
      end
    end
  end
  local function sig(m)
    local pts = try(function() return m:get_param_types() end) or {}
    local ps = {}
    for _, t in ipairs(pts) do
      ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
    end
    local rt = try(function() return m:get_return_type() end)
    return "(" .. table.concat(ps, ", ") .. ") -> " ..
      tostring(rt and try(function() return rt:get_full_name() end) or "?")
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end
  local TARGET = 1523627639

  L("== summon_probe7 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  if not gm then
    L("no GenerateManager - not loaded into the world?")
    if not wr(DIR .. "summon_probe7.txt", table.concat(out, "\n")) then error("could not write summon_probe7.txt") end
    return "summon_probe7: no GenerateManager"
  end

  -- Our pooled GeneratorID, dissected.
  local genID = try(function() return gm:call("getPoolGeneratorID") end)
  L("pooled GeneratorID: tableID=" ..
    tostring(genID and try(function() return genID:call("get_TableID") end)) ..
    " extraID=" .. tostring(genID and try(function() return genID:call("get_ExtraID") end)) ..
    " isEmpty=" .. tostring(genID and try(function() return genID:call("isEmpty") end)) ..
    " str=" .. tostring(genID))

  -- Enemy catalog internals (from step 6).
  local cc = try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  L("_EnemyCatalog: " .. tostring(ec))
  if ec then
    local etd = try(function() return ec:get_type_definition() end)
    if etd then
      local ms = try(function() return etd:get_methods() end) or {}
      for _, m in ipairs(ms) do
        L("  catalog method " ..
          tostring(try(function() return m:get_name() end) or "?") .. sig(m))
      end
    end
  end

  -- Scan the global generate tables for ch255000.
  local lists = try(function() return gm:call("get_GlobalTableListDatas") end)
  local nlists = arr_len(lists)
  L("global table list datas: " .. tostring(nlists))
  local scanned, hits = 0, 0
  local first_dumped = false
  if lists and nlists then
    for li = 0, nlists - 1 do
      local ld = arr_get(lists, li)
      local tabs = ld and try(function() return ld:call("get_NormalTableList") end)
      local ntabs = arr_len(tabs)
      if tabs and ntabs then
        for ti = 0, ntabs - 1 do
          if scanned >= 600 then break end
          local td2 = arr_get(tabs, ti)
          local tbl = td2 and try(function() return td2:call("get_Table") end)
          if tbl then
            scanned = scanned + 1
            if not first_dumped then
              first_dumped = true
              dump_obj("FIRST table", tbl, 0)
              local ei = try(function() return tbl:call("get_EnemyInfo") end)
              dump_obj("FIRST table EnemyInfo", ei, 0)
              local inits0 = try(function() return tbl:call("get_InitSetDatas") end)
              local n0 = arr_len(inits0)
              L("FIRST table InitSetDatas: " .. tostring(n0))
              if inits0 and n0 and n0 > 0 then
                dump_obj("FIRST InitSetData[0]", arr_get(inits0, 0), 0)
              end
            end
            local inits = try(function() return tbl:call("get_InitSetDatas") end)
            local nin = arr_len(inits)
            if inits and nin then
              for ii = 0, nin - 1 do
                local isd = arr_get(inits, ii)
                if isd then
                  local itd = try(function() return isd:get_type_definition() end)
                  local ims = itd and try(function() return itd:get_methods() end) or {}
                  for _, m in ipairs(ims) do
                    local mn = try(function() return m:get_name() end) or ""
                    if mn:sub(1, 4) == "get_" then
                      local pts = try(function() return m:get_param_types() end) or {}
                      if #pts == 0 then
                        local v = try(function() return isd:call(mn) end)
                        if v == TARGET or tostring(v) == tostring(TARGET) then
                          hits = hits + 1
                          L("TABLE HIT: listGuid=" ..
                            tostring(try(function() return ld:call("get_Guid") end)) ..
                            " tableID=" ..
                            tostring(try(function() return td2:call("get_TableID") end)) ..
                            " via " .. mn)
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  L("tables scanned: " .. scanned .. ", hits for ch255000: " .. hits)

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe7.txt", text) then error("could not write summon_probe7.txt") end
  return "summon_probe7.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.15: summon probe step 8
-- Probe 7's catalog dump gave DictionaryCatalog real, callable
-- accessors: ContainsKey, getCount, getKeys, getValues. This dumps
-- the enemy catalog census - how many prefabs are registered at this
-- location, whether ch255000 is among them, and the full key list
-- (the definitive roster of what can spawn here). Read-only.
COMMANDS.summon_probe8 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end
  local TARGET = 1523627639

  L("== summon_probe8 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not ec then
    L("no enemy catalog - not loaded into the world?")
    if not wr(DIR .. "summon_probe8.txt", table.concat(out, "\n")) then error("could not write summon_probe8.txt") end
    return "summon_probe8: no enemy catalog"
  end
  L("player catalog count = " ..
    tostring(try(function() return cc:call("getPlayerCatalogCount") end)))
  L("enemy catalog count = " ..
    tostring(try(function() return ec:call("getCount") end)))
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfs = ctd and try(function() return ctd:get_fields() end) or {}
  local chara = nil
  for _, f in ipairs(cfs) do
    if try(function() return f:is_static() end) and
       try(function() return f:get_name() end) == "ch255000" then
      chara = try(function() return f:get_data(nil) end)
    end
  end
  L("ContainsKey(ch255000) = " ..
    tostring(chara and try(function() return ec:call("ContainsKey", chara) end)))
  local keys = try(function() return ec:call("getKeys") end)
  local n = arr_len(keys)
  L("enemy catalog keys: " .. tostring(n))
  local present = false
  if keys and n then
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      if k == TARGET or tostring(k):find(tostring(TARGET), 1, true) then
        present = true
        L("  key[" .. i .. "] = " .. tostring(k) .. "  <-- ch255000")
      else
        L("  key[" .. i .. "] = " .. tostring(k))
      end
    end
  end
  L("ch255000 in enemy catalog here: " .. tostring(present))

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe8.txt", text) then error("could not write summon_probe8.txt") end
  return "summon_probe8.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.17: summon probe step 9
-- Round 8 falsified standby-warming for catalog-ABSENT prefabs:
-- isReadyPrefab never flipped across minutes of standby re-requests
-- for ch255000 (ContainsKey=false at this location). New question:
-- is ch255000 the exception or the rule? This maps catalog presence
-- for ALL 22 dropdown codes here, samples registered prefabs'
-- resource paths (pattern intel), and fires the force call at the
-- first present-and-ready code as a control - if that lands, the
-- pipeline works wherever the game has the prefab registered.
COMMANDS.summon_probe9 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  L("== summon_probe9 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe9.txt", table.concat(out, "\n")) then error("could not write summon_probe9.txt") end
    return "summon_probe9: managers missing"
  end
  L("enemy catalog count = " ..
    tostring(try(function() return ec:call("getCount") end)))

  -- Sample registered prefab paths.
  local vals = try(function() return ec:call("getValues") end)
  local nv = arr_len(vals)
  L("catalog values: " .. tostring(nv))
  if vals and nv then
    for i = 0, math.min(nv, 8) - 1 do
      local pc = arr_get(vals, i)
      L("  prefab[" .. i .. "] ready=" ..
        tostring(pc and try(function() return pc:call("get_Ready") end)) ..
        " path=" .. tostring(pc and try(function() return pc:call("get_ResourcePath") end)))
    end
  end

  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfs = ctd and try(function() return ctd:get_fields() end) or {}
  local function resolve(code)
    for _, f in ipairs(cfs) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == code then
        return try(function() return f:get_data(nil) end)
      end
    end
    return nil
  end
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  local scale = try(function() return Vector3f.new(1, 1, 1) end)

  local codes = { "ch240000", "ch250000", "ch251000", "ch252000",
                  "ch253000", "ch254000", "ch255000", "ch256000",
                  "ch256001", "ch257000", "ch257001", "ch257003",
                  "ch258000", "ch258001", "ch258002", "ch259000",
                  "ch260000", "ch260001", "ch261000", "ch261001",
                  "ch230004", "ch231000" }
  local present_count = 0
  local control_done = false
  for _, code in ipairs(codes) do
    local chara = resolve(code)
    local present = chara and try(function() return ec:call("ContainsKey", chara) end)
    if present then present_count = present_count + 1 end
    L(code .. ": catalog present=" .. tostring(present))
    if present and not control_done and ppos and quat and scale then
      local shell = try(function() return gm:call("getPoolGeneratorID") end)
      local genID = shell and try(function() return shell:call("makeNewGeneratorID") end)
      local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
      local cont = nil
      if genID and uniqID then
        cont = try(function()
          return gm:call("getPoolGenerateInfoContainerForCharacter",
            genID, uniqID, ppos, quat, scale, 3, 0, chara, 1)
        end)
      end
      if cont then
        pcall(function() gm:call("requestStandbyPrefab", cont) end)
        local ready = try(function() return cc:call("isReadyPrefab", cont) end)
        L("   control container ready=" .. tostring(ready))
        SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq = cont, code, chara, uniqID
        SUMMON.ctrl = nil
        if ready == true then
          local fc = try(function()
            return gm:call("forceRequestCreateInstance", cont, function() end, function() end)
          end)
          L("   CONTROL force on present+ready " .. code .. " = " .. tostring(fc))
          control_done = true
        else
          L("   (staged - Verify will re-read readiness and fire when ready)")
          control_done = true
        end
      end
    end
  end
  L("dropdown codes present in catalog here: " .. present_count .. " / " .. #codes)
  L("control attempted: " .. tostring(control_done))

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe9.txt", text) then error("could not write summon_probe9.txt") end
  return "summon_probe9.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.18: summon probe step 10
-- Probe 9: NONE of the 22 boss-tier dropdown codes is in this
-- location's enemy catalog (0/22) - the catalog holds the common
-- field families the loaded contents use (samples all read
-- AppSystem/ch/ch220/Prefab/ch220000_00.pfb, ready=true). Every
-- summon test so far aimed at an absent prefab. Control time: run
-- the full pipeline at a code that is PRESENT (ch220000 family) -
-- if it spawns, the pipeline is proven and boss codes are purely
-- catalog-gated. Also recon for the self-register route: dump
-- via.Prefab and resource-manager type candidates to find a load
-- API for paths like the sampled pattern.
COMMANDS.summon_probe10 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function sig(m)
    local pts = try(function() return m:get_param_types() end) or {}
    local ps = {}
    for _, t in ipairs(pts) do
      ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
    end
    local rt = try(function() return m:get_return_type() end)
    return "(" .. table.concat(ps, ", ") .. ") -> " ..
      tostring(rt and try(function() return rt:get_full_name() end) or "?")
  end
  local function dump_type(tname, cap)
    local td = try(function() return sdk.find_type_definition(tname) end)
    L("== type " .. tname .. " ==")
    if not td then L("  TYPE NOT FOUND") return end
    local ms = try(function() return td:get_methods() end) or {}
    local n = 0
    for _, m in ipairs(ms) do
      L("  method " .. tostring(try(function() return m:get_name() end) or "?") .. sig(m))
      n = n + 1
      if n >= cap then L("  ... (methods capped)") break end
    end
    local fs = try(function() return td:get_fields() end) or {}
    local shown = 0
    for _, f in ipairs(fs) do
      local ft = try(function() return f:get_type() end)
      L("  field " .. tostring(try(function() return f:get_name() end) or "?") ..
        " : " .. tostring(ft and try(function() return ft:get_full_name() end) or "?"))
      shown = shown + 1
      if shown >= 60 then L("  ... (fields capped)") break end
    end
  end

  L("== summon_probe10 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe10.txt", table.concat(out, "\n")) then error("could not write summon_probe10.txt") end
    return "summon_probe10: managers missing"
  end

  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfs = ctd and try(function() return ctd:get_fields() end) or {}
  local function resolve(code)
    for _, f in ipairs(cfs) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == code then
        return try(function() return f:get_data(nil) end)
      end
    end
    return nil
  end
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  local scale = try(function() return Vector3f.new(1, 1, 1) end)

  local control_done = false
  for _, code in ipairs({ "ch220000", "ch221000", "ch222000" }) do
    local chara = resolve(code)
    local present = chara and try(function() return ec:call("ContainsKey", chara) end)
    L(code .. ": catalog present=" .. tostring(present))
    if present and not control_done and ppos and quat and scale then
      local shell = try(function() return gm:call("getPoolGeneratorID") end)
      local genID = shell and try(function() return shell:call("makeNewGeneratorID") end)
      local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
      local cont = nil
      if genID and uniqID then
        cont = try(function()
          return gm:call("getPoolGenerateInfoContainerForCharacter",
            genID, uniqID, ppos, quat, scale, 3, 0, chara, 1)
        end)
      end
      if cont then
        pcall(function() gm:call("requestStandbyPrefab", cont) end)
        local ready = try(function() return cc:call("isReadyPrefab", cont) end)
        L("   control container ready=" .. tostring(ready))
        SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq = cont, code, chara, uniqID
        SUMMON.ctrl = nil
        if ready == true then
          local fc = try(function()
            return gm:call("forceRequestCreateInstance", cont, function() end, function() end)
          end)
          L("   CONTROL force on present+ready " .. code .. " = " .. tostring(fc))
          if not (type(fc) == "number" and fc >= 0) then
            local sc = try(function()
              return gm:call("safeRequestCreateInstance", cont, function() end, function() end)
            end)
            L("   CONTROL safe on present+ready " .. code .. " = " .. tostring(sc))
            local gc = try(function()
              return gm:call("requestGenerate", cont, 8 + 35184372088832, false, false,
                function() end, function() end)
            end)
            L("   CONTROL requestGenerate on present+ready " .. code .. " = " ..
              tostring(gc) .. (gc and " (controller!)" or ""))
            if gc then SUMMON.ctrl = gc end
          end
        else
          L("   (staged - Verify re-reads readiness and fires when ready)")
        end
        control_done = true
      end
    end
  end
  L("control attempted: " .. tostring(control_done))

  dump_type("via.Prefab", 120)
  dump_type("via.ResourceManager", 120)

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe10.txt", text) then error("could not write summon_probe10.txt") end
  return "summon_probe10.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.19: summon probe step 11
-- Probe 10 shock: even ch220000 reads catalog present=FALSE while
-- the catalog demonstrably holds ch220000_00's prefab (probe 9 path
-- samples). New theory: the catalog keys are the VARIANT codes
-- (ch220000_00) - the CharacterID enum's 1707 fields are mostly
-- variant-suffixed, and every presence test so far used bare base
-- codes. This probe reads the keys' own names (ToString), tests
-- ContainsKey on variant codes, fires the control on the first
-- confirmed key, and recons the register route (PrefabController
-- fields for the wrapped via.Prefab; ResourceManager load methods).
COMMANDS.summon_probe11 = function()
  local out = {}
  local function L(x)
    if #out < 1600 then out[#out + 1] = x end
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  L("== summon_probe11 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe11.txt", table.concat(out, "\n")) then error("could not write summon_probe11.txt") end
    return "summon_probe11: managers missing"
  end

  -- 1) Key census: what do the catalog keys call themselves?
  local keys = try(function() return ec:call("getKeys") end)
  local nk = arr_len(keys)
  L("catalog keys: " .. tostring(nk))
  if keys and nk then
    for i = 0, math.min(nk, 40) - 1 do
      local k = arr_get(keys, i)
      L("  key[" .. i .. "] tostring=" ..
        tostring(k and try(function() return k:call("ToString") end)))
    end
  end

  -- 2) Variant-code presence tests.
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfs = ctd and try(function() return ctd:get_fields() end) or {}
  local byname = {}
  for _, f in ipairs(cfs) do
    if try(function() return f:is_static() end) then
      local nm = try(function() return f:get_name() end)
      if nm then byname[nm] = try(function() return f:get_data(nil) end) end
    end
  end
  local function present(code)
    local v = byname[code]
    if v == nil then return "no-enum-field" end
    return tostring(try(function() return ec:call("ContainsKey", v) end))
  end
  for _, code in ipairs({ "ch220000_00", "ch220000", "ch255000_00", "ch255000",
                          "ch258000_00", "ch258002", "ch240000_00", "ch240000" }) do
    L(code .. ": enum=" .. tostring(byname[code] ~= nil) ..
      " catalog present=" .. present(code))
  end

  -- 3) Control: first confirmed-present variant gets the full ladder.
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  local scale = try(function() return Vector3f.new(1, 1, 1) end)
  local control_done = false
  for _, code in ipairs({ "ch220000_00", "ch220000", "ch221000_00" }) do
    local chara = byname[code]
    local ispres = chara and try(function() return ec:call("ContainsKey", chara) end)
    if ispres and not control_done and ppos and quat and scale then
      local shell = try(function() return gm:call("getPoolGeneratorID") end)
      local genID = shell and try(function() return shell:call("makeNewGeneratorID") end)
      local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
      local cont = nil
      if genID and uniqID then
        cont = try(function()
          return gm:call("getPoolGenerateInfoContainerForCharacter",
            genID, uniqID, ppos, quat, scale, 3, 0, chara, 1)
        end)
      end
      if cont then
        pcall(function() gm:call("requestStandbyPrefab", cont) end)
        local ready = try(function() return cc:call("isReadyPrefab", cont) end)
        L("CONTROL " .. code .. ": container ready=" .. tostring(ready))
        SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq = cont, code, chara, uniqID
        SUMMON.ctrl = nil
        if ready == true then
          local fc = try(function()
            return gm:call("forceRequestCreateInstance", cont, function() end, function() end)
          end)
          L("  CONTROL force = " .. tostring(fc))
          if not (type(fc) == "number" and fc >= 0) then
            local sc = try(function()
              return gm:call("safeRequestCreateInstance", cont, function() end, function() end)
            end)
            L("  CONTROL safe = " .. tostring(sc))
            local gc = try(function()
              return gm:call("requestGenerate", cont, 8 + 35184372088832, false, false,
                function() end, function() end)
            end)
            L("  CONTROL requestGenerate = " .. tostring(gc) ..
              (gc and " (controller!)" or ""))
            if gc then SUMMON.ctrl = gc end
          end
        else
          L("  (staged - Verify re-reads readiness and fires when ready)")
        end
        control_done = true
      end
    end
  end
  L("control attempted: " .. tostring(control_done))

  -- 4) PrefabController fields: where does the via.Prefab live?
  local pcd = try(function() return sdk.find_type_definition("app.PrefabController") end)
  L("== app.PrefabController fields ==")
  if pcd then
    for _, f in ipairs(try(function() return pcd:get_fields() end) or {}) do
      local ft = try(function() return f:get_type() end)
      L("  field " .. tostring(try(function() return f:get_name() end) or "?") ..
        " : " .. tostring(ft and try(function() return ft:get_full_name() end) or "?"))
    end
  else L("  TYPE NOT FOUND") end

  -- 5) ResourceManager: load-flavored methods only.
  local rmd = try(function() return sdk.find_type_definition("via.ResourceManager") end)
  L("== via.ResourceManager load-ish methods ==")
  if rmd then
    local function sig(m)
      local pts = try(function() return m:get_param_types() end) or {}
      local ps = {}
      for _, t in ipairs(pts) do
        ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
      end
      local rt = try(function() return m:get_return_type() end)
      return "(" .. table.concat(ps, ", ") .. ") -> " ..
        tostring(rt and try(function() return rt:get_full_name() end) or "?")
    end
    for _, m in ipairs(try(function() return rmd:get_methods() end) or {}) do
      local nm = tostring(try(function() return m:get_name() end) or "")
      local low = nm:lower()
      if low:find("load") or low:find("create") or low:find("find") or
         low:find("request") or low:find("resource") then
        L("  method " .. nm .. sig(m))
      end
    end
  else L("  TYPE NOT FOUND") end

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe11.txt", text) then error("could not write summon_probe11.txt") end
  return "summon_probe11.txt written: " .. #out .. " lines"
end



end
do
---------------------------------------------------------------- v1.89.22: summon probe step 13
-- Step 12 bundled two untested operations (a manager-internals
-- census and the never-fired requestCreateInstance door) and the
-- game crashed; from here: ONE new door per probe. This one is the
-- via.Prefab direct instantiate - the standard REFramework spawn
-- primitive, no GenerateManager enrollment involved: find
-- ch255000_00's PrefabController by resource path (read-only, the
-- probe-9 pattern), take its wrapped prefab (field _Item), and if
-- it reports Ready, instantiate it at the summon spot. A raw
-- instance is a scene object - it writes nothing to save data.
COMMANDS.summon_probe13 = function()
  local out = {}
  local function L(x)
    if #out < 200 then out[#out + 1] = x end
  end
  L("== summon_probe13 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe13.txt", table.concat(out, "\n")) then error("could not write summon_probe13.txt") end
    return "summon_probe13: managers missing"
  end

  -- Find the PrefabController whose resource path names ch255000.
  local target_pc, target_path = nil, nil
  local vals = try(function() return ec:call("getValues") end)
  local nv = vals and (try(function() return vals:call("get_Count") end)
    or try(function() return vals:call("get_Length") end))
  L("catalog values: " .. tostring(nv))
  if vals and nv then
    for i = 0, nv - 1 do
      local pc = try(function() return vals:call("get_Item", i) end)
        or try(function() return vals:call("GetValue", i) end)
      local rp = pc and try(function() return pc:call("get_ResourcePath") end)
      if rp and tostring(rp):find("ch255000") then
        target_pc, target_path = pc, tostring(rp)
        break
      end
    end
  end
  L("prefab controller: " .. tostring(target_pc) .. " path=" .. tostring(target_path))
  if not target_pc then
    L("no ch255000 controller in this catalog - boss not registered here")
    if not wr(DIR .. "summon_probe13.txt", table.concat(out, "\n")) then error("could not write summon_probe13.txt") end
    return "summon_probe13: ch255000 not in catalog here"
  end
  L("controller ready=" ..
    tostring(try(function() return target_pc:call("get_Ready") end)) ..
    " hasRef=" ..
    tostring(try(function() return target_pc:call("get_HasReference") end)))

  local prefab = try(function() return target_pc:get_field("_Item") end)
  L("prefab (_Item): " .. tostring(prefab))
  if not prefab then
    if not wr(DIR .. "summon_probe13.txt", table.concat(out, "\n")) then error("could not write summon_probe13.txt") end
    return "summon_probe13: no prefab in controller"
  end
  local pready = try(function() return prefab:call("get_Ready") end)
  L("prefab ready=" .. tostring(pready) ..
    " valid=" .. tostring(try(function() return prefab:call("get_Valid") end)) ..
    " exist=" .. tostring(try(function() return prefab:call("get_Exist") end)) ..
    " standby=" .. tostring(try(function() return prefab:call("get_Standby") end)))

  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local pos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  if not pos or not quat then
    L("player transform unavailable")
    if not wr(DIR .. "summon_probe13.txt", table.concat(out, "\n")) then error("could not write summon_probe13.txt") end
    return "summon_probe13: no player transform"
  end
  local fx, fz = 0.7071, 0.7071
  local front = try(function() return cm:call("get_CameraFront") end)
  if front and type(front.x) == "number" and type(front.z) == "number" then
    local len = math.sqrt(front.x * front.x + front.z * front.z)
    if len > 0.01 then fx, fz = front.x / len, front.z / len end
  end
  local spos = try(function() return Vector3f.new(pos.x + fx * 5.0, pos.y, pos.z + fz * 5.0) end)
  L("spawn pos: " .. tostring(spos and spos.x) .. ", " ..
    tostring(spos and spos.y) .. ", " .. tostring(spos and spos.z))

  if pready == true and spos then
    local go = try(function() return prefab:call("instantiate", spos, quat) end)
    L("instantiate(pos, quat) -> " .. tostring(go))
    if go then
      L("INSTANTIATED - look at the spawn spot")
    else
      L("instantiate returned nil (no exception captured)")
    end
  elseif spos then
    L("prefab not ready - setting standby and NOT instantiating this run")
    pcall(function() prefab:call("set_Standby", true) end)
    L("standby set; run probe step 13 again in a few seconds")
  end

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe13.txt", text) then error("could not write summon_probe13.txt") end
  return "summon_probe13.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.23: summon probe step 14
-- READ-ONLY. The summon code in 1.89.22 is byte-identical to
-- 1.89.20 (diffed against the CT v1.25 bundle), yet summon now
-- crashes - so the variable is catalog state, not code. Step 13
-- also found its path-matched controller was the ch255000_01 file
-- with an INVALID prefab (valid=false). This probe maps the ch255
-- (and ch240) family properly: catalog keys and values enumerated
-- in step, each key's controller + wrapped prefab state, plus a
-- factory container's readiness read. No standby calls, no
-- instantiate, no generate calls - reads only.
COMMANDS.summon_probe14 = function()
  local out = {}
  local function L(x)
    if #out < 300 then out[#out + 1] = x end
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  L("== summon_probe14 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe14.txt", table.concat(out, "\n")) then error("could not write summon_probe14.txt") end
    return "summon_probe14: managers missing"
  end

  local keys = try(function() return ec:call("getKeys") end)
  local vals = try(function() return ec:call("getValues") end)
  local nk = arr_len(keys)
  local nv = arr_len(vals)
  L("catalog keys=" .. tostring(nk) .. " values=" .. tostring(nv))
  if keys and vals and nk and nv then
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm and (tostring(nm):find("ch255") or tostring(nm):find("ch240")) then
        local pc = arr_get(vals, i)
        local item = pc and try(function() return pc:get_field("_Item") end)
        L(nm .. ": ctrl path=" ..
          tostring(pc and try(function() return pc:call("get_ResourcePath") end)) ..
          " ready=" .. tostring(pc and try(function() return pc:call("get_Ready") end)) ..
          " hasRef=" .. tostring(pc and try(function() return pc:call("get_HasReference") end)) ..
          " | prefab path=" ..
          tostring(item and try(function() return item:call("get_Path") end)) ..
          " ready=" .. tostring(item and try(function() return item:call("get_Ready") end)) ..
          " valid=" .. tostring(item and try(function() return item:call("get_Valid") end)))
      end
    end
  end

  -- Container-side readiness for ch255000_00, no standby anywhere.
  local chara = try(function() return enum_value("app.CharacterID", "ch255000_00") end)
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  local scale = try(function() return Vector3f.new(1, 1, 1) end)
  if chara and ppos and quat and scale then
    local shell = try(function() return gm:call("getPoolGeneratorID") end)
    local genID = shell and try(function() return shell:call("makeNewGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID then
      cont = try(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, ppos, quat, scale, 3, 0, chara, 1)
      end)
    end
    L("fresh container (no standby): isReadyPrefab=" ..
      tostring(cont and try(function() return cc:call("isReadyPrefab", cont) end)) ..
      " isHasReferencePrefab=" ..
      tostring(cont and try(function() return cc:call("isHasReferencePrefab", cont) end)))
  else
    L("container build skipped (missing pieces)")
  end

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe14.txt", text) then error("could not write summon_probe14.txt") end
  return "summon_probe14.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.25: summon probe step 15
-- Probe 14's map: keys and values ARE aligned, and EVERY ch255
-- controller here wraps an INVALID prefab (valid=false) - catalog
-- presence is not resource presence. That explains acceptance
-- without instances: force issues a request against a prefab that
-- cannot instantiate in this area. Two questions in one session:
-- (1) does standby flip the wrapped prefab's validity? (2) the
-- factory container carries LoadArea=Local(2) with a loaded-
-- contents check; LoadAreaEnum has LoadedAreaIgnoreContentsLoad-
-- Check(6) - if a setter exists, does a container set to 6 get
-- its request fulfilled? One force maximum, fire-once rules.
COMMANDS.summon_probe15 = function()
  local out = {}
  local function L(x)
    if #out < 400 then out[#out + 1] = x end
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  L("== summon_probe15 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe15.txt", table.concat(out, "\n")) then error("could not write summon_probe15.txt") end
    return "summon_probe15: managers missing"
  end

  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_state(pc)
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item,
      item and try(function() return item:call("get_Valid") end),
      item and try(function() return item:call("get_Ready") end)
  end

  local pc = find_ctrl("ch255000_00")
  local item, valid0, ready0 = prefab_state(pc)
  L("ch255000_00 controller=" .. tostring(pc) ..
    " prefab valid=" .. tostring(valid0) .. " ready=" .. tostring(ready0))

  local chara = try(function() return enum_value("app.CharacterID", "ch255000_00") end)
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  local scale = try(function() return Vector3f.new(1, 1, 1) end)
  if not (chara and ppos and quat and scale) then
    L("missing pieces: chara=" .. tostring(chara) .. " pos=" .. tostring(ppos) ..
      " quat=" .. tostring(quat) .. " scale=" .. tostring(scale))
    if not wr(DIR .. "summon_probe15.txt", table.concat(out, "\n")) then error("could not write summon_probe15.txt") end
    return "summon_probe15: missing pieces (see file)"
  end
  local fx, fz = 0.7071, 0.7071
  local front = try(function() return cm:call("get_CameraFront") end)
  if front and type(front.x) == "number" and type(front.z) == "number" then
    local len = math.sqrt(front.x * front.x + front.z * front.z)
    if len > 0.01 then fx, fz = front.x / len, front.z / len end
  end
  local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)

  local function build_cont()
    local shell = try(function() return gm:call("getPoolGeneratorID") end)
    local genID = shell and try(function() return shell:call("makeNewGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    if genID and uniqID and spos then
      return try(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, spos, quat, scale, 3, 0, chara, 1)
      end), uniqID
    end
    return nil, nil
  end

  local cont, uniqID = build_cont()
  L("container isReadyPrefab BEFORE standby = " ..
    tostring(cont and try(function() return cc:call("isReadyPrefab", cont) end)))

  -- Where does LoadArea live? Scan the container + sub-info types.
  local function scan_loadarea(obj, label)
    if not obj then return nil, nil end
    local td = try(function() return obj:get_type_definition() end)
    local setter = nil
    for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
      local nm = tostring(try(function() return m:get_name() end) or "")
      if nm:lower():find("loadarea") then
        L("  " .. label .. " method " .. nm)
        if nm:lower():find("set") then setter = nm end
      end
    end
    local cur = try(function() return obj:call("get_LoadArea") end)
    if cur ~= nil then L("  " .. label .. " get_LoadArea = " .. tostring(cur)) end
    if setter then return obj, setter end
    return nil, nil
  end
  local la_obj, la_setter = scan_loadarea(cont, "container")
  if not la_obj and cont then
    for _, gname in ipairs({ "get_CommonInfo", "get_CharaInfo", "get_StatusInfo",
                             "get_BattleNoticeInfo", "get_SetFlagInfo" }) do
      local sub = try(function() return cont:call(gname) end)
      local o, st = scan_loadarea(sub, gname)
      if o then la_obj, la_setter = o, st break end
    end
  end
  L("LoadArea setter: " .. tostring(la_setter) .. " on " .. tostring(la_obj))

  -- Standby (manager + catalog), then re-read both states.
  if cont then
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    local ci = try(function() return cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
  end
  local _, valid1, ready1 = prefab_state(pc)
  L("after standby: prefab valid=" .. tostring(valid1) .. " ready=" .. tostring(ready1) ..
    " | container isReadyPrefab=" ..
    tostring(cont and try(function() return cc:call("isReadyPrefab", cont) end)))

  -- The LoadArea=6 attempt: fresh container, set it, standby, fire once.
  if la_obj and la_setter then
    local cont2, uniq2 = build_cont()
    if cont2 then
      local function refind(obj)
        local td = try(function() return obj:get_type_definition() end)
        for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
          if tostring(try(function() return m:get_name() end) or "") == la_setter then
            return obj
          end
        end
        return nil
      end
      local target = refind(cont2)
      if not target then
        for _, gname in ipairs({ "get_CommonInfo", "get_CharaInfo", "get_StatusInfo",
                                 "get_BattleNoticeInfo", "get_SetFlagInfo" }) do
          local sub = try(function() return cont2:call(gname) end)
          if sub and refind(sub) then target = sub break end
        end
      end
      if target then
        local okset = pcall(function() target:call(la_setter, 6) end)
        L("set_LoadArea(6) on fresh container: " .. tostring(okset))
        pcall(function() gm:call("requestStandbyPrefab", cont2) end)
        local rdy = try(function() return cc:call("isReadyPrefab", cont2) end)
        local _, v2, _ = prefab_state(pc)
        L("LoadArea=6 container ready=" .. tostring(rdy) ..
          " prefab valid=" .. tostring(v2))
        SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
          cont2, "ch255000_00", chara, uniq2
        SUMMON.ctrl = nil
        SUMMON.fired = false
        if rdy == true then
          local fc = try(function()
            return gm:call("forceRequestCreateInstance", cont2, function() end, function() end)
          end)
          L("force on LoadArea=6 container = " .. tostring(fc))
          if type(fc) == "number" and fc >= 0 then SUMMON.fired = true end
          L("(staged - Verify polls the instance; it will not fire again)")
        end
      else
        L("could not re-find the LoadArea setter on the fresh container")
      end
    end
  else
    L("no LoadArea setter found - the bypass cannot be attempted this way")
    if cont then
      SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
        cont, "ch255000_00", chara, uniqID
      SUMMON.ctrl = nil
      SUMMON.fired = false
    end
  end

  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe15.txt", text) then error("could not write summon_probe15.txt") end
  return "summon_probe15.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.26: summon probe step 16
-- Two facts converged: (1) standby DOES load the prefab - the
-- 1.89.25 summon log reads valid=false at build, valid=true at
-- verify - yet the accepted force request still produced nothing.
-- (2) Every summon since round 7 used a MINTED GeneratorID, whose
-- diag reads containsGenerateRegister=false; round 4's POOLED-ID
-- container read TRUE. requestGenerate (the controller door) has
-- returned nil for every minted ID. This probe is a state machine
-- - press it repeatedly: run 1 builds ONE container on the pooled
-- GeneratorID (+ LoadArea=6 if a setter exists) and starts the
-- standby load; later runs re-read validity and, once valid=true,
-- fire requestGenerate first, force behind it, exactly once.
-- (Resolution uses a local field map: probes sit above enum_value
-- in this file, so that helper is out of their scope - the
-- probes 14/15 chara=nil bug.)
COMMANDS.summon_probe16 = function()
  local out = {}
  local function L(x)
    if #out < 400 then out[#out + 1] = x end
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  L("== summon_probe16 (bridge 1.89.67) ==")
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    if not wr(DIR .. "summon_probe16.txt", table.concat(out, "\n")) then error("could not write summon_probe16.txt") end
    return "summon_probe16: managers missing"
  end

  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid(pc)
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end),
           item and try(function() return item:call("get_Ready") end)
  end
  local pc = find_ctrl("ch255000_00")
  local pv, pr = prefab_valid(pc)
  L("prefab: valid=" .. tostring(pv) .. " ready=" .. tostring(pr))

  local P = SUMMON.pool
  if P and P.done then
    L("pool summon already fired - use Verify / Summon log from here")
    if not wr(DIR .. "summon_probe16.txt", table.concat(out, "\n")) then error("could not write summon_probe16.txt") end
    return "summon_probe16: already fired (see file)"
  end

  if not P then
    -- Build the one pooled-ID container.
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    local ppos = ptr and try(function() return ptr:call("get_Position") end)
    local quat = ptr and try(function() return ptr:call("get_Rotation") end)
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and ppos and quat and scale) then
      L("missing pieces at build: chara=" .. tostring(chara) ..
        " pos=" .. tostring(ppos) .. " quat=" .. tostring(quat))
      if not wr(DIR .. "summon_probe16.txt", table.concat(out, "\n")) then error("could not write summon_probe16.txt") end
      return "summon_probe16: missing pieces (see file)"
    end
    local fx, fz = 0.7071, 0.7071
    local front = try(function() return cm:call("get_CameraFront") end)
    if front and type(front.x) == "number" and type(front.z) == "number" then
      local len = math.sqrt(front.x * front.x + front.z * front.z)
      if len > 0.01 then fx, fz = front.x / len, front.z / len end
    end
    local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID and spos then
      cont = try(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, spos, quat, scale, 3, 0, chara, 1)
      end)
    end
    if not cont then
      L("pooled container build failed")
      if not wr(DIR .. "summon_probe16.txt", table.concat(out, "\n")) then error("could not write summon_probe16.txt") end
      return "summon_probe16: container build failed"
    end
    L("pooled-ID container built (NOT minted)")
    L("diag containsGenerateRegister=" ..
      tostring(try(function() return gm:call("checkContainsGenerateRegister", cont) end)) ..
      " checkRegenerate=" ..
      tostring(try(function() return gm:call("checkRegenerate", cont) end)))
    -- LoadArea hunt (from step 15, which never got to run it).
    local function scan_loadarea(obj)
      if not obj then return nil, nil end
      local td = try(function() return obj:get_type_definition() end)
      for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
        local nm = tostring(try(function() return m:get_name() end) or "")
        if nm:lower():find("loadarea") and nm:lower():find("set") then
          return obj, nm
        end
      end
      return nil, nil
    end
    local la_obj, la_setter = scan_loadarea(cont)
    if not la_obj then
      for _, gname in ipairs({ "get_CommonInfo", "get_CharaInfo", "get_StatusInfo",
                               "get_BattleNoticeInfo", "get_SetFlagInfo" }) do
        local sub = try(function() return cont:call(gname) end)
        local o, st = scan_loadarea(sub)
        if o then la_obj, la_setter = o, st break end
      end
    end
    if la_obj and la_setter then
      local okset = pcall(function() la_obj:call(la_setter, 6) end)
      L("LoadArea set to 6 via " .. la_setter .. ": " .. tostring(okset))
    else
      L("no LoadArea setter found on container/sub-infos")
    end
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    local ci = try(function() return cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    SUMMON.pool = { cont = cont, uniq = uniqID, chara = chara, done = false }
    L("standby started - press probe step 16 again in a few seconds")
    if not wr(DIR .. "summon_probe16.txt", table.concat(out, "\n")) then error("could not write summon_probe16.txt") end
    return "summon_probe16: standby started (see file)"
  end

  -- Loading stage: re-check validity, fire once when valid.
  if pv ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    local ci = try(function() return P.cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    L("prefab still loading (valid=" .. tostring(pv) ..
      ") - standby re-requested; press probe step 16 again")
    if not wr(DIR .. "summon_probe16.txt", table.concat(out, "\n")) then error("could not write summon_probe16.txt") end
    return "summon_probe16: still loading (see file)"
  end

  L("prefab VALID - firing on the pooled-ID container")
  local cb = function() end
  local ctrl = try(function()
    return gm:call("requestGenerate", P.cont, 8 + 35184372088832, false, false, cb, cb)
  end)
  L("requestGenerate = " .. tostring(ctrl) .. (ctrl and " (CONTROLLER!)" or ""))
  local fc = nil
  if not ctrl then
    fc = try(function()
      return gm:call("forceRequestCreateInstance", P.cont, cb, cb)
    end)
    L("force = " .. tostring(fc))
  end
  P.done = true
  SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
    P.cont, "ch255000_00", P.chara, P.uniq
  SUMMON.ctrl = ctrl
  SUMMON.fired = (ctrl ~= nil) or (type(fc) == "number" and fc >= 0)
  L("post-fire: queued=" ..
    tostring(try(function() return gm:call("containsRequest", 3, P.uniq) end)) ..
    " instantiateReq=" ..
    tostring(try(function() return gm:call("hasInstantiateRequest", 3, P.uniq) end)) ..
    " genInfo=" ..
    (try(function() return gm:call("getGeneratedInstanceInfo", 3, P.uniq) end) and "present" or "none") ..
    " instance=" ..
    tostring(pm and try(function() return pm:call("getInstanceChara", 3, P.chara) end)))
  if ctrl then
    L("controller: IsGenerated=" ..
      tostring(try(function() return ctrl:call("get_IsGenerated") end)) ..
      " RequestState=" ..
      tostring(try(function() return ctrl:call("get_RequestState") end)))
  end
  L("WATCH THE SPAWN SPOT - then Verify polls the instance")
  local text = table.concat(out, "\n")
  if not wr(DIR .. "summon_probe16.txt", text) then error("could not write summon_probe16.txt") end
  return "summon_probe16.txt written: " .. #out .. " lines"
end


end
do
---------------------------------------------------------------- v1.89.27: summon probe step 17
-- Step 16 FIRED: requestGenerate returned a controller and the
-- request queued - but nothing materialized, and the follow-up
-- trail was lost when a ch240000 summon overwrote SUMMON and the
-- summon log. Step 17 keeps step 16's recipe (pooled GeneratorID,
-- LoadArea=6, standby-until-valid, requestGenerate first) and adds
-- what was missing: an accumulated history inside the probe file
-- itself (immune to summon_log resets) and a polling stage - every
-- press after the fire appends the controller's state, range flags
-- and the instance check, so the file shows whether the queued
-- controller advances, stalls, or dies.
COMMANDS.summon_probe17 = function()
  local P = SUMMON.pool17
  if not P then
    P = { hist = {} }
    SUMMON.pool17 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 900 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe17.txt", text) then error("could not write summon_probe17.txt") end
    return "summon_probe17: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid()
    local pc = find_ctrl("ch255000_00")
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end),
           item and try(function() return item:call("get_Ready") end)
  end
  local function poll(tag)
    local ctrl = P.ctrl
    L(tag .. ": ctrl generated=" ..
      tostring(ctrl and try(function() return ctrl:call("get_IsGenerated") end)) ..
      " state=" ..
      tostring(ctrl and try(function() return ctrl:call("get_RequestState") end)) ..
      " queued=" ..
      tostring(try(function() return gm:call("containsRequest", 3, P.uniq) end)) ..
      " genInfo=" ..
      (try(function() return gm:call("getGeneratedInstanceInfo", 3, P.uniq) end) and "present" or "none") ..
      " instance=" ..
      tostring(pm and try(function() return pm:call("getInstanceChara", 3, P.chara) end)))
    if ctrl then
      L("  range: fixPos=" ..
        tostring(try(function() return ctrl:call("get_IsFixGeneratePosition") end)) ..
        " inRange=" ..
        tostring(try(function() return ctrl:call("get_IsInGenerateRangeForReserveDistributorUnit") end)) ..
        " pos=" ..
        tostring(try(function() local p = ctrl:call("get_Position") return p and (tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)) end)))
    end
  end

  if P.done then
    poll("poll")
    return flush("poll appended")
  end

  if not P.cont then
    L("== summon_probe17 (bridge 1.89.67) == build")
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    local ppos = ptr and try(function() return ptr:call("get_Position") end)
    local quat = ptr and try(function() return ptr:call("get_Rotation") end)
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and ppos and quat and scale) then
      L("missing pieces at build")
      return flush("missing pieces")
    end
    local fx, fz = 0.7071, 0.7071
    local front = try(function() return cm:call("get_CameraFront") end)
    if front and type(front.x) == "number" and type(front.z) == "number" then
      local len = math.sqrt(front.x * front.x + front.z * front.z)
      if len > 0.01 then fx, fz = front.x / len, front.z / len end
    end
    local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID and spos then
      cont = try(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, spos, quat, scale, 3, 0, chara, 1)
      end)
    end
    if not cont then
      L("pooled container build failed")
      return flush("build failed")
    end
    local function scan_loadarea(obj)
      if not obj then return nil, nil end
      local td = try(function() return obj:get_type_definition() end)
      for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
        local nm = tostring(try(function() return m:get_name() end) or "")
        if nm:lower():find("loadarea") and nm:lower():find("set") then
          return obj, nm
        end
      end
      return nil, nil
    end
    local la_obj, la_setter = scan_loadarea(cont)
    if not la_obj then
      for _, gname in ipairs({ "get_CommonInfo", "get_CharaInfo", "get_StatusInfo",
                               "get_BattleNoticeInfo", "get_SetFlagInfo" }) do
        local sub = try(function() return cont:call(gname) end)
        local o, st = scan_loadarea(sub)
        if o then la_obj, la_setter = o, st break end
      end
    end
    if la_obj and la_setter then
      pcall(function() la_obj:call(la_setter, 6) end)
      L("LoadArea=6 set via " .. la_setter)
    else
      L("no LoadArea setter found")
    end
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    local ci = try(function() return cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont, P.uniq, P.chara = cont, uniqID, chara
    local pv, pr = prefab_valid()
    L("container built (pooled ID); prefab valid=" .. tostring(pv) ..
      " ready=" .. tostring(pr) .. " - standby started")
    return flush("standby started")
  end

  local pv, pr = prefab_valid()
  if pv ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    local ci = try(function() return P.cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    L("loading: prefab valid=" .. tostring(pv) .. " ready=" .. tostring(pr) ..
      " - standby re-requested")
    return flush("still loading")
  end

  L("prefab VALID - firing requestGenerate on pooled container")
  local cb = function() end
  local ctrl = try(function()
    return gm:call("requestGenerate", P.cont, 8 + 35184372088832, false, false, cb, cb)
  end)
  L("requestGenerate = " .. tostring(ctrl) .. (ctrl and " (CONTROLLER)" or ""))
  if not ctrl then
    local fc = try(function()
      return gm:call("forceRequestCreateInstance", P.cont, cb, cb)
    end)
    L("force fallback = " .. tostring(fc))
  end
  P.ctrl = ctrl
  P.done = true
  SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
    P.cont, "ch255000_00", P.chara, P.uniq
  SUMMON.ctrl = ctrl
  SUMMON.fired = true
  poll("post-fire")
  L("keep pressing probe step 17 - each press appends a poll line")
  return flush("fired")
end


end
do
---------------------------------------------------------------- v1.89.28: summon probe step 18
-- Step 17's queued controller NEVER advances: state=0 frozen,
-- queued=true, and the distributor range flag reads FALSE with a
-- garbage controller position (16646938897890.0,0,0) - the
-- distributor never claims it, and a later poll press crashed the
-- game (queued generate objects are perishable; do not poll them).
-- Route G (GenerateManager) is therefore parked. Route I was never
-- actually attempted on the CORRECT prefab: step 13 grabbed the
-- first path match (an invalid _01). This probe uses the aligned
-- catalog lookup for ch255000_00's own controller, drives its
-- prefab to valid via the proven container standby, then calls
-- via.Prefab.instantiate(pos, quat) exactly once - the standard
-- REFramework spawn primitive, no distributor, no queue, nothing
-- polled afterwards.
COMMANDS.summon_probe18 = function()
  local P = SUMMON.pool18
  if not P then
    P = { hist = {} }
    SUMMON.pool18 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 400 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe18.txt", text) then error("could not write summon_probe18.txt") end
    return "summon_probe18: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local pc = find_ctrl("ch255000_00")
  local item = pc and try(function() return pc:get_field("_Item") end)
  local pvalid = item and try(function() return item:call("get_Valid") end)
  local pready = item and try(function() return item:call("get_Ready") end)

  if P.done then
    L("already instantiated this session - see above; not repeating")
    return flush("already done")
  end

  if not P.cont then
    L("== summon_probe18 (bridge 1.89.67) == build (standby vehicle)")
    L("aligned controller path=" ..
      tostring(pc and try(function() return pc:call("get_ResourcePath") end)) ..
      " prefab valid=" .. tostring(pvalid) .. " ready=" .. tostring(pready))
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    local ppos = ptr and try(function() return ptr:call("get_Position") end)
    local quat = ptr and try(function() return ptr:call("get_Rotation") end)
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and ppos and quat and scale) then
      L("missing pieces at build")
      return flush("missing pieces")
    end
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID then
      cont = try(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, ppos, quat, scale, 3, 0, chara, 1)
      end)
    end
    if not cont then
      L("standby-vehicle container build failed")
      return flush("build failed")
    end
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    local ci = try(function() return cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont = cont
    L("standby started - press probe step 18 again in a few seconds")
    return flush("standby started")
  end

  if pvalid ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    local ci = try(function() return P.cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    L("loading: prefab valid=" .. tostring(pvalid) ..
      " ready=" .. tostring(pready) .. " - standby re-requested")
    return flush("still loading")
  end

  -- Prefab is valid: instantiate it at the summon spot, once.
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  if not (ppos and quat) then
    L("player transform unavailable at fire time")
    return flush("no transform")
  end
  local fx, fz = 0.7071, 0.7071
  local front = try(function() return cm:call("get_CameraFront") end)
  if front and type(front.x) == "number" and type(front.z) == "number" then
    local len = math.sqrt(front.x * front.x + front.z * front.z)
    if len > 0.01 then fx, fz = front.x / len, front.z / len end
  end
  local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
  L("prefab VALID - instantiating at " ..
    tostring(spos and spos.x) .. ", " .. tostring(spos and spos.y) ..
    ", " .. tostring(spos and spos.z))
  local go = item and spos and try(function() return item:call("instantiate", spos, quat) end)
  L("instantiate(pos, quat) -> " .. tostring(go))
  if go then
    L("gameobject name = " ..
      tostring(try(function() return go:call("get_Name") end)))
    L("INSTANTIATED - look at the spawn spot NOW")
  else
    L("instantiate returned nil (guarded, no exception captured)")
  end
  P.done = true
  return flush("fired")
end


end
do
---------------------------------------------------------------- v1.89.29: summon probe step 19
-- Route I verdict: instantiate(pos, quat) on a valid prefab
-- returned nil - dead end (the async requestToInstantiate is the
-- only sibling, untested). Back to Route G with the one concrete
-- defect steps 16/17 exposed: the queued controller's position
-- was garbage and it sat out of the distributor's range forever.
-- The factory takes a position, but CommonInfo carries SEPARATE
-- Initial/Context positions that were never set explicitly. This
-- probe sets them (plus the initial angle and the container's
-- transform), reads them back, then - once the prefab is valid -
-- fires requestGenerate once and snapshots the controller's
-- position/range IN THE SAME CALL. No cross-press polling: queued
-- controllers are perishable. If the snapshot position is still
-- garbage, restart the game promptly to clear the queued request.
COMMANDS.summon_probe19 = function()
  local P = SUMMON.pool19
  if not P then
    P = { hist = {} }
    SUMMON.pool19 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 400 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe19.txt", text) then error("could not write summon_probe19.txt") end
    return "summon_probe19: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end
  local function v3(v)
    if not v then return "nil" end
    return tostring(v.x) .. "," .. tostring(v.y) .. "," .. tostring(v.z)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid()
    local pc = find_ctrl("ch255000_00")
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end)
  end

  if P.done then
    L("already fired this session - not repeating (see snapshot above)")
    return flush("already done")
  end

  if not P.cont then
    L("== summon_probe19 (bridge 1.89.67) == build + position fix")
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    local ppos = ptr and try(function() return ptr:call("get_Position") end)
    local quat = ptr and try(function() return ptr:call("get_Rotation") end)
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and ppos and quat and scale) then
      L("missing pieces at build")
      return flush("missing pieces")
    end
    local fx, fz = 0.7071, 0.7071
    local front = try(function() return cm:call("get_CameraFront") end)
    if front and type(front.x) == "number" and type(front.z) == "number" then
      local len = math.sqrt(front.x * front.x + front.z * front.z)
      if len > 0.01 then fx, fz = front.x / len, front.z / len end
    end
    local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
    L("spawn pos = " .. v3(spos))
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID and spos then
      cont = try(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, spos, quat, scale, 3, 0, chara, 1)
      end)
    end
    if not cont then
      L("container build failed")
      return flush("build failed")
    end
    local ci = try(function() return cont:call("get_CommonInfo") end)
    L("CommonInfo before fix: initial=" ..
      v3(ci and try(function() return ci:call("get_InitialPosition") end)) ..
      " context=" ..
      v3(ci and try(function() return ci:call("get_ContextPosition") end)))
    local ok1, e1 = pcall(function() ci:call("setInitialPosition", spos) end)
    local ok2, e2 = pcall(function() ci:call("setContextPosition", spos) end)
    local ok3, e3 = pcall(function() ci:call("setInitialAngle", quat) end)
    L("setInitialPosition=" .. tostring(ok1) .. " setContextPosition=" ..
      tostring(ok2) .. " setInitialAngle=" .. tostring(ok3))
    if not (ok1 and ok2 and ok3) then
      L("  errors: " .. tostring(e1) .. " | " .. tostring(e2) .. " | " .. tostring(e3))
    end
    local ok4, e4 = pcall(function() cont:call("setTransform", spos, quat) end)
    if not ok4 then
      local ok5, e5 = pcall(function() cont:call("setTransform", spos) end)
      L("setTransform(pos,quat) failed (" .. tostring(e4) ..
        "); setTransform(pos)=" .. tostring(ok5) ..
        (ok5 and "" or (" (" .. tostring(e5) .. ")")))
    else
      L("setTransform(pos, quat)=true")
    end
    L("CommonInfo after fix: initial=" ..
      v3(ci and try(function() return ci:call("get_InitialPosition") end)) ..
      " context=" ..
      v3(ci and try(function() return ci:call("get_ContextPosition") end)))
    -- LoadArea=6 (the step 16/17 recipe).
    local td = try(function() return cont:get_type_definition() end)
    local setter = nil
    for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
      local nm = tostring(try(function() return m:get_name() end) or "")
      if nm:lower():find("loadarea") and nm:lower():find("set") then setter = nm break end
    end
    if setter then
      pcall(function() cont:call(setter, 6) end)
      L("LoadArea=6 via " .. setter)
    else
      L("no LoadArea setter on container this time")
    end
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont, P.uniq, P.chara = cont, uniqID, chara
    L("standby started - press probe step 19 again in a few seconds")
    return flush("standby started")
  end

  if prefab_valid() ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    local ci = try(function() return P.cont:call("get_CommonInfo") end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    L("loading: prefab not valid yet - standby re-requested")
    return flush("still loading")
  end

  L("prefab VALID - firing requestGenerate once (position-fixed container)")
  local cb = function() end
  local okG, ctrl = pcall(function()
    return gm:call("requestGenerate", P.cont, 8 + 35184372088832, false, false, cb, cb)
  end)
  L("requestGenerate ok=" .. tostring(okG) .. " -> " .. tostring(ctrl) ..
    (okG and "" or (" err=" .. tostring(ctrl))))
  if okG and ctrl then
    L("SNAPSHOT ctrl: generated=" ..
      tostring(try(function() return ctrl:call("get_IsGenerated") end)) ..
      " state=" ..
      tostring(try(function() return ctrl:call("get_RequestState") end)) ..
      " pos=" ..
      v3(try(function() return ctrl:call("get_Position") end)) ..
      " inRange=" ..
      tostring(try(function() return ctrl:call("get_IsInGenerateRangeForReserveDistributorUnit") end)) ..
      " fixPos=" ..
      tostring(try(function() return ctrl:call("get_IsFixGeneratePosition") end)))
    SUMMON.ctrl = ctrl
  else
    local fc = try(function()
      return gm:call("forceRequestCreateInstance", P.cont, cb, cb)
    end)
    L("force fallback = " .. tostring(fc))
  end
  SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
    P.cont, "ch255000_00", P.chara, P.uniq
  SUMMON.fired = true
  P.done = true
  L("fired. If the snapshot pos reads like the spawn pos and inRange=true,")
  L("watch the spot; ONE Verify in ~15s reads the outcome. If pos is")
  L("garbage again, restart the game promptly to clear the queue.")
  return flush("fired")
end


end
do
---------------------------------------------------------------- v1.89.30: summon probe step 20
-- The reference Enemy Spawner mod (Nexus 940, handed over by the
-- user) spawns through a door this project never assembled
-- correctly: gm:requestCreateInstance with the FULL overload -
-- (PrefabController, GenerateInfoContainer, Int32, InstanceInfo,
-- Action, Action). Its recipe, reimplemented here from the API
-- facts: the container comes from a fresh app.InstanceInfo (not
-- the GenerateManager factory); CommonInfo gets set_ObjectID
-- (pointer to gm:getIdWrapper(charID)) and setContextPosition /
-- setContextAngle (CONTEXT, not Initial); the request ID comes
-- from a fresh app.RequestID:makeNewRequestID(); the prefab gate
-- is get_Ready() after prefab-level set_Standby(true); the
-- InstanceInfo is the enrollment the instance registers into.
COMMANDS.summon_probe20 = function()
  local P = SUMMON.pool20
  if not P then
    P = { hist = {} }
    SUMMON.pool20 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 400 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe20.txt", text) then error("could not write summon_probe20.txt") end
    return "summon_probe20: " .. tag
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not gm or not cm then
    L("managers missing - not loaded into the world?")
    return flush("managers missing")
  end

  if P.done then
    local go = P.inst and try(function() return P.inst:call("get_Instance") end)
    local ch = P.inst and try(function() return P.inst:call("get_Chara") end)
    L("post-spawn read: instance GameObject=" .. tostring(go) ..
      " Chara=" .. tostring(ch))
    return flush("post-spawn read")
  end

  if not P.inst then
    L("== summon_probe20 (bridge 1.89.67) == setup")
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    if not chara then
      L("ch255000_00 not resolvable")
      return flush("no chara")
    end
    P.chara = chara
    -- PrefabController via the merged catalog (RefCounter chain).
    local cc = try(function() return gm:call("get_CatalogCtrl") end)
    local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
    local merged = ec and try(function() return ec:get_field("<MergedCatalog>k__BackingField") end)
    local rc = merged and try(function() return merged:call("get_Item", chara) end)
    local pfbCtrl = rc and try(function() return rc:call("get_Item") end)
    L("merged catalog chain: rc=" .. tostring(rc) .. " prefabCtrl=" .. tostring(pfbCtrl))
    if not pfbCtrl then
      L("no prefab controller for ch255000_00 in merged catalog")
      return flush("no prefab controller")
    end
    P.pfbCtrl = pfbCtrl
    local prefab = try(function() return pfbCtrl:call("get_Item") end)
    P.prefab = prefab
    L("prefab path=" ..
      tostring(prefab and try(function() return prefab:call("get_Path") end)) ..
      " ready=" ..
      tostring(prefab and try(function() return prefab:call("get_Ready") end)))
    -- Fresh InstanceInfo + its container.
    local inst = try(function() return sdk.create_instance("app.InstanceInfo"):add_ref() end)
    local cont = inst and try(function() return inst:call("get_Container") end)
    L("InstanceInfo=" .. tostring(inst) .. " container=" .. tostring(cont))
    if not inst or not cont then
      L("InstanceInfo/container creation failed")
      return flush("no instanceinfo")
    end
    P.inst, P.cont = inst, cont
    -- Request ID from a fresh app.RequestID.
    local robj = try(function() return sdk.create_instance("app.RequestID"):add_ref() end)
    local rid = robj and try(function() return robj:call("makeNewRequestID") end)
    P.rid = rid
    L("requestID object=" .. tostring(robj) .. " makeNewRequestID=" .. tostring(rid))
    -- Generator ID wrapper for the ObjectID.
    local wrap = try(function() return gm:call("getIdWrapper", chara) end)
    L("getIdWrapper=" .. tostring(wrap))
    -- Player transform / spawn spot.
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    local ppos = ptr and try(function() return ptr:call("get_Position") end)
    local quat = ptr and try(function() return ptr:call("get_Rotation") end)
    if not (ppos and quat) then
      L("player transform unavailable")
      return flush("no transform")
    end
    local fx, fz = 0.7071, 0.7071
    local front = try(function() return cm:call("get_CameraFront") end)
    if front and type(front.x) == "number" and type(front.z) == "number" then
      local len = math.sqrt(front.x * front.x + front.z * front.z)
      if len > 0.01 then fx, fz = front.x / len, front.z / len end
    end
    local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
    -- Init (the mod's SpawnInstance.init, our own wiring):
    local ci = try(function() return cont:call("get_CommonInfo") end)
    local okS, eS = pcall(function() prefab:call("set_Standby", true) end)
    L("prefab set_Standby(true): " .. tostring(okS) .. (okS and "" or (" " .. tostring(eS))))
    if wrap then
      local okO, eO = pcall(function() ci:call("set_ObjectID", sdk.to_ptr(wrap)) end)
      L("CommonInfo set_ObjectID(to_ptr(wrapper)): " .. tostring(okO) ..
        (okO and "" or (" " .. tostring(eO))))
    else
      local oid = ci and try(function() return ci:get_field("_ObjectID") end)
      local okF, eF = pcall(function() oid:set_field("_SelectedCharacterID", chara) end)
      L("fallback _ObjectID._SelectedCharacterID set: " .. tostring(okF) ..
        (okF and "" or (" " .. tostring(eF))))
    end
    local okP, eP = pcall(function() ci:call("setContextPosition", spos) end)
    local okA, eA = pcall(function() ci:call("setContextAngle", quat) end)
    L("setContextPosition=" .. tostring(okP) .. " setContextAngle=" .. tostring(okA))
    if not (okP and okA) then
      L("  errors: " .. tostring(eP) .. " | " .. tostring(eA))
    end
    L("setup complete - press probe step 20 again (spawn fires when prefab ready)")
    return flush("setup complete")
  end

  -- Spawn stage: gate on the prefab's Ready, then the full call.
  local ready = P.prefab and try(function() return P.prefab:call("get_Ready") end)
  if ready ~= true then
    pcall(function() P.prefab:call("set_Standby", true) end)
    L("waiting: prefab ready=" .. tostring(ready) .. " - standby re-set")
    return flush("waiting for prefab")
  end
  L("prefab READY - calling requestCreateInstance (full overload)")
  local ok, err = pcall(function()
    return gm:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
      P.pfbCtrl, P.cont, P.rid, P.inst, nil, nil)
  end)
  L("requestCreateInstance: ok=" .. tostring(ok) ..
    (ok and "" or (" err=" .. tostring(err))))
  P.done = true
  local go = try(function() return P.inst:call("get_Instance") end)
  L("t=0 instance GameObject=" .. tostring(go) ..
    " (async - later presses re-read it)")
  L("WATCH THE SPAWN SPOT")
  return flush("spawn requested")
end


end
do
---------------------------------------------------------------- v1.89.31: summon probe step 21
-- Step 20 executed the reference recipe cleanly - every joint
-- ok, requestCreateInstance returned ok - yet nothing
-- materialized. One marshaling suspect stands out in its log:
-- makeNewRequestID() returned a MANAGED OBJECT, while the
-- overload's third parameter is System.Int32. If the object was
-- coerced to garbage (or 0), the request carries an ID the
-- completion path never matches and the instance is silently
-- dropped. This probe dumps app.RequestID (declared return type
-- of makeNewRequestID + every field of the returned object),
-- extracts the numeric ID, and retries the identical spawn with
-- that number as parameter 3.
COMMANDS.summon_probe21 = function()
  local P = SUMMON.pool21
  if not P then
    P = { hist = {} }
    SUMMON.pool21 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 400 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe21.txt", text) then error("could not write summon_probe21.txt") end
    return "summon_probe21: " .. tag
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not gm or not cm then
    L("managers missing - not loaded into the world?")
    return flush("managers missing")
  end

  if P.done then
    local go = P.inst and try(function() return P.inst:call("get_Instance") end)
    local ch = P.inst and try(function() return P.inst:call("get_Chara") end)
    L("post-spawn read: instance GameObject=" .. tostring(go) ..
      " Chara=" .. tostring(ch))
    return flush("post-spawn read")
  end

  if not P.inst then
    L("== summon_probe21 (bridge 1.89.67) == setup + RequestID dump")
    -- RequestID forensics first.
    local rtd = try(function() return sdk.find_type_definition("app.RequestID") end)
    local mm = rtd and try(function() return rtd:get_method("makeNewRequestID") end)
    local rt = mm and try(function() return mm:get_return_type() end)
    L("makeNewRequestID declared return type: " ..
      tostring(rt and try(function() return rt:get_name() end)))
    local robj = try(function() return sdk.create_instance("app.RequestID"):add_ref() end)
    local rid = robj and try(function() return robj:call("makeNewRequestID") end)
    L("requestID object=" .. tostring(robj) .. " makeNewRequestID -> " .. tostring(rid))
    local function dump_fields(obj, label)
      local td = obj and try(function() return obj:get_type_definition() end)
      local fields = td and try(function() return td:get_fields() end)
      if not fields then
        L(label .. ": no type definition")
        return nil
      end
      local found = nil
      for _, f in ipairs(fields) do
        local nm = try(function() return f:get_name() end)
        if nm then
          local v = try(function() return obj:get_field(nm) end)
          L("  " .. label .. "." .. nm .. " = " .. tostring(v) ..
            " (" .. type(v) .. ")")
          if type(v) == "number" and not found then found = v end
        end
      end
      return found
    end
    local numid = dump_fields(rid, "returned")
    if not numid then numid = dump_fields(robj, "requestObj") end
    P.numid = numid
    L("extracted numeric request ID: " .. tostring(numid))
    -- Character + prefab controller (merged catalog chain).
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    if not chara then
      L("ch255000_00 not resolvable")
      return flush("no chara")
    end
    P.chara = chara
    local cc = try(function() return gm:call("get_CatalogCtrl") end)
    local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
    local merged = ec and try(function() return ec:get_field("<MergedCatalog>k__BackingField") end)
    local rc = merged and try(function() return merged:call("get_Item", chara) end)
    local pfbCtrl = rc and try(function() return rc:call("get_Item") end)
    if not pfbCtrl then
      L("no prefab controller for ch255000_00 in merged catalog")
      return flush("no prefab controller")
    end
    P.pfbCtrl = pfbCtrl
    local prefab = try(function() return pfbCtrl:call("get_Item") end)
    P.prefab = prefab
    L("prefab path=" ..
      tostring(prefab and try(function() return prefab:call("get_Path") end)) ..
      " ready=" ..
      tostring(prefab and try(function() return prefab:call("get_Ready") end)))
    local inst = try(function() return sdk.create_instance("app.InstanceInfo"):add_ref() end)
    local cont = inst and try(function() return inst:call("get_Container") end)
    if not inst or not cont then
      L("InstanceInfo/container creation failed")
      return flush("no instanceinfo")
    end
    P.inst, P.cont = inst, cont
    local wrap = try(function() return gm:call("getIdWrapper", chara) end)
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    local ppos = ptr and try(function() return ptr:call("get_Position") end)
    local quat = ptr and try(function() return ptr:call("get_Rotation") end)
    if not (ppos and quat) then
      L("player transform unavailable")
      return flush("no transform")
    end
    local fx, fz = 0.7071, 0.7071
    local front = try(function() return cm:call("get_CameraFront") end)
    if front and type(front.x) == "number" and type(front.z) == "number" then
      local len = math.sqrt(front.x * front.x + front.z * front.z)
      if len > 0.01 then fx, fz = front.x / len, front.z / len end
    end
    local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
    local ci = try(function() return cont:call("get_CommonInfo") end)
    pcall(function() prefab:call("set_Standby", true) end)
    if wrap then
      pcall(function() ci:call("set_ObjectID", sdk.to_ptr(wrap)) end)
    end
    pcall(function() ci:call("setContextPosition", spos) end)
    pcall(function() ci:call("setContextAngle", quat) end)
    L("setup complete (wrapper=" .. tostring(wrap) ..
      ") - press probe step 21 again to fire with the numeric ID")
    return flush("setup complete")
  end

  local ready = P.prefab and try(function() return P.prefab:call("get_Ready") end)
  if ready ~= true then
    pcall(function() P.prefab:call("set_Standby", true) end)
    L("waiting: prefab ready=" .. tostring(ready) .. " - standby re-set")
    return flush("waiting for prefab")
  end
  if P.numid == nil then
    L("no numeric ID could be extracted - cannot fire the Int32 variant")
    P.done = true
    return flush("no numeric id")
  end
  L("prefab READY - firing requestCreateInstance with numeric ID " ..
    tostring(P.numid))
  local ok, err = pcall(function()
    return gm:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
      P.pfbCtrl, P.cont, P.numid, P.inst, nil, nil)
  end)
  L("requestCreateInstance(int): ok=" .. tostring(ok) ..
    (ok and "" or (" err=" .. tostring(err))))
  P.done = true
  L("WATCH THE SPAWN SPOT - later presses re-read the instance")
  return flush("spawn requested (int id)")
end


end
do
---------------------------------------------------------------- v1.89.32: summon probe step 22
-- Step 21's forensics killed the numeric-ID theory:
-- makeNewRequestID's declared return type IS app.RequestID, a
-- composite { _GenID, _UniqID } with no numeric field anywhere.
-- So the mod's "System.Int32" signature string cannot be the
-- overload that actually serves its call on this game build -
-- either an app.RequestID overload exists and REFramework
-- resolves by arguments, or TU4 changed the table. This probe
-- censuses EVERY requestCreateInstance overload on
-- app.GenerateManager with full parameter types, then fires the
-- one whose third parameter is app.RequestID, passing the
-- RequestID object itself.
COMMANDS.summon_probe22 = function()
  local P = SUMMON.pool22
  if not P then
    P = { hist = {} }
    SUMMON.pool22 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 500 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe22.txt", text) then error("could not write summon_probe22.txt") end
    return "summon_probe22: " .. tag
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not gm or not cm then
    L("managers missing - not loaded into the world?")
    return flush("managers missing")
  end

  if P.done then
    local go = P.inst and try(function() return P.inst:call("get_Instance") end)
    local ch = P.inst and try(function() return P.inst:call("get_Chara") end)
    L("post-spawn read: instance GameObject=" .. tostring(go) ..
      " Chara=" .. tostring(ch))
    return flush("post-spawn read")
  end

  if not P.inst then
    L("== summon_probe22 (bridge 1.89.67) == overload census + setup")
    local gtd = try(function() return gm:get_type_definition() end)
    local methods = gtd and try(function() return gtd:get_methods() end)
    local chosen = nil
    local count = 0
    for _, m in ipairs(methods or {}) do
      local nm = try(function() return m:get_name() end)
      if nm == "requestCreateInstance" then
        count = count + 1
        local params = try(function() return m:get_params() end)
        local types = {}
        for _, prm in ipairs(params or {}) do
          local pt = try(function() return prm:get_type() end)
          types[#types + 1] =
            tostring(pt and try(function() return pt:get_name() end))
        end
        local sig = "requestCreateInstance(" .. table.concat(types, ", ") .. ")"
        L("overload #" .. count .. ": " .. sig)
        if types[3] and types[3]:find("RequestID") then chosen = sig end
      end
    end
    L("overloads found: " .. count .. " | RequestID-param overload: " ..
      tostring(chosen))
    P.sig = chosen -- nil means: fall back to plain-name resolution
    -- Character + prefab controller (merged catalog chain).
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    if not chara then
      L("ch255000_00 not resolvable")
      return flush("no chara")
    end
    P.chara = chara
    local cc = try(function() return gm:call("get_CatalogCtrl") end)
    local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
    local merged = ec and try(function() return ec:get_field("<MergedCatalog>k__BackingField") end)
    local rc = merged and try(function() return merged:call("get_Item", chara) end)
    local pfbCtrl = rc and try(function() return rc:call("get_Item") end)
    if not pfbCtrl then
      L("no prefab controller for ch255000_00 in merged catalog")
      return flush("no prefab controller")
    end
    P.pfbCtrl = pfbCtrl
    local prefab = try(function() return pfbCtrl:call("get_Item") end)
    P.prefab = prefab
    local inst = try(function() return sdk.create_instance("app.InstanceInfo"):add_ref() end)
    local cont = inst and try(function() return inst:call("get_Container") end)
    if not inst or not cont then
      L("InstanceInfo/container creation failed")
      return flush("no instanceinfo")
    end
    P.inst, P.cont = inst, cont
    local robj = try(function() return sdk.create_instance("app.RequestID"):add_ref() end)
    local rid = robj and try(function() return robj:call("makeNewRequestID") end)
    P.rid = rid
    L("requestID (object) = " .. tostring(rid))
    local wrap = try(function() return gm:call("getIdWrapper", chara) end)
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    local ppos = ptr and try(function() return ptr:call("get_Position") end)
    local quat = ptr and try(function() return ptr:call("get_Rotation") end)
    if not (ppos and quat) then
      L("player transform unavailable")
      return flush("no transform")
    end
    local fx, fz = 0.7071, 0.7071
    local front = try(function() return cm:call("get_CameraFront") end)
    if front and type(front.x) == "number" and type(front.z) == "number" then
      local len = math.sqrt(front.x * front.x + front.z * front.z)
      if len > 0.01 then fx, fz = front.x / len, front.z / len end
    end
    local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
    local ci = try(function() return cont:call("get_CommonInfo") end)
    pcall(function() prefab:call("set_Standby", true) end)
    if wrap then
      pcall(function() ci:call("set_ObjectID", sdk.to_ptr(wrap)) end)
    end
    pcall(function() ci:call("setContextPosition", spos) end)
    pcall(function() ci:call("setContextAngle", quat) end)
    L("setup complete - press probe step 22 again to fire")
    return flush("setup complete")
  end

  local ready = P.prefab and try(function() return P.prefab:call("get_Ready") end)
  if ready ~= true then
    pcall(function() P.prefab:call("set_Standby", true) end)
    L("waiting: prefab ready=" .. tostring(ready) .. " - standby re-set")
    return flush("waiting for prefab")
  end
  if P.sig then
    L("prefab READY - firing dumped overload: " .. P.sig)
    local ok, err = pcall(function()
      return gm:call(P.sig, P.pfbCtrl, P.cont, P.rid, P.inst, nil, nil)
    end)
    L("requestCreateInstance(RequestID overload): ok=" .. tostring(ok) ..
      (ok and "" or (" err=" .. tostring(err))))
  else
    L("prefab READY - no RequestID overload in census; plain-name call")
    local ok, err = pcall(function()
      return gm:call("requestCreateInstance",
        P.pfbCtrl, P.cont, P.rid, P.inst, nil, nil)
    end)
    L("requestCreateInstance(plain name): ok=" .. tostring(ok) ..
      (ok and "" or (" err=" .. tostring(err))))
  end
  P.done = true
  L("WATCH THE SPAWN SPOT - later presses re-read the instance")
  return flush("spawn requested")
end


end
do
---------------------------------------------------------------- v1.89.33: summon probe step 23
-- Step 22's data: two requestCreateInstance overloads exist;
-- the plain-name call THREW at invoke and the game FROZE. The
-- reference mod never calls this from a command context - its
-- pump runs inside re.on_application_entry("UpdateBehavior"),
-- the game's behavior-update phase. Step 23 changes ONLY the
-- execution context: the command stages the full spawn bundle,
-- and a one-time UpdateBehavior hook (the mod's own hook) does
-- the ready check and the fire - with the mod's verbatim
-- signature string - then reads the instance back ~2s later.
local function summon23_hook()
  if SUMMON.hook23 then return end
  SUMMON.hook23 = true
  re.on_application_entry("UpdateBehavior", function()
    local P = SUMMON.pool23
    if not P or not P.armed then return end
    if P.fired then
      if not P.read then
        P.ticks = (P.ticks or 0) + 1
        if P.ticks >= 180 then
          P.read = true
          local go = try(function() return P.inst:call("get_Instance") end)
          local ch = try(function() return P.inst:call("get_Chara") end)
          P.hist[#P.hist + 1] = "[hook] +~3s instance GameObject=" ..
            tostring(go) .. " Chara=" .. tostring(ch)
        end
      end
      return
    end
    local ready = P.prefab and
      try(function() return P.prefab:call("get_Ready") end)
    if ready ~= true then
      pcall(function() P.prefab:call("set_Standby", true) end)
      return
    end
    P.fired = true
    P.hist[#P.hist + 1] = "[hook] prefab READY in UpdateBehavior - firing"
    local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
    local ok, err = pcall(function()
      return gm:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
        P.pfbCtrl, P.cont, P.rid, P.inst, nil, nil)
    end)
    P.hist[#P.hist + 1] = "[hook] requestCreateInstance: ok=" .. tostring(ok) ..
      (ok and "" or (" err=" .. tostring(err)))
    P.ticks = 0
  end)
end

COMMANDS.summon_probe23 = function()
  local P = SUMMON.pool23
  if not P then
    P = { hist = {} }
    SUMMON.pool23 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 500 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe23.txt", text) then error("could not write summon_probe23.txt") end
    return "summon_probe23: " .. tag
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not gm or not cm then
    L("managers missing - not loaded into the world?")
    return flush("managers missing")
  end

  if P.fired then
    local go = P.inst and try(function() return P.inst:call("get_Instance") end)
    local ch = P.inst and try(function() return P.inst:call("get_Chara") end)
    L("post-spawn read: instance GameObject=" .. tostring(go) ..
      " Chara=" .. tostring(ch))
    return flush("post-spawn read")
  end
  if P.armed then
    L("still armed - the UpdateBehavior hook fires when the prefab is ready")
    return flush("armed, waiting")
  end

  L("== summon_probe23 (bridge 1.89.67) == stage + arm UpdateBehavior hook")
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local chara = nil
  for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
    if try(function() return f:is_static() end) and
       try(function() return f:get_name() end) == "ch255000_00" then
      chara = try(function() return f:get_data(nil) end)
      break
    end
  end
  if not chara then
    L("ch255000_00 not resolvable")
    return flush("no chara")
  end
  P.chara = chara
  local cc = try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  local merged = ec and try(function() return ec:get_field("<MergedCatalog>k__BackingField") end)
  local rc = merged and try(function() return merged:call("get_Item", chara) end)
  local pfbCtrl = rc and try(function() return rc:call("get_Item") end)
  if not pfbCtrl then
    L("no prefab controller for ch255000_00 in merged catalog")
    return flush("no prefab controller")
  end
  P.pfbCtrl = pfbCtrl
  local prefab = try(function() return pfbCtrl:call("get_Item") end)
  P.prefab = prefab
  local inst = try(function() return sdk.create_instance("app.InstanceInfo"):add_ref() end)
  local cont = inst and try(function() return inst:call("get_Container") end)
  if not inst or not cont then
    L("InstanceInfo/container creation failed")
    return flush("no instanceinfo")
  end
  P.inst, P.cont = inst, cont
  local robj = try(function() return sdk.create_instance("app.RequestID"):add_ref() end)
  local rid = robj and try(function() return robj:call("makeNewRequestID") end)
  P.rid = rid
  local wrap = try(function() return gm:call("getIdWrapper", chara) end)
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local pgo = player and try(function() return player:call("get_GameObject") end)
  local ptr = pgo and try(function() return pgo:call("get_Transform") end)
  local ppos = ptr and try(function() return ptr:call("get_Position") end)
  local quat = ptr and try(function() return ptr:call("get_Rotation") end)
  if not (ppos and quat) then
    L("player transform unavailable")
    return flush("no transform")
  end
  local fx, fz = 0.7071, 0.7071
  local front = try(function() return cm:call("get_CameraFront") end)
  if front and type(front.x) == "number" and type(front.z) == "number" then
    local len = math.sqrt(front.x * front.x + front.z * front.z)
    if len > 0.01 then fx, fz = front.x / len, front.z / len end
  end
  local spos = try(function() return Vector3f.new(ppos.x + fx * 5.0, ppos.y, ppos.z + fz * 5.0) end)
  local ci = try(function() return cont:call("get_CommonInfo") end)
  pcall(function() prefab:call("set_Standby", true) end)
  if wrap then
    pcall(function() ci:call("set_ObjectID", sdk.to_ptr(wrap)) end)
  end
  pcall(function() ci:call("setContextPosition", spos) end)
  pcall(function() ci:call("setContextAngle", quat) end)
  summon23_hook()
  P.armed = true
  L("staged and ARMED - the hook fires inside UpdateBehavior when ready.")
  L("No more presses needed: wait ~10s, watch the spot, then press once")
  L("more to collect the hook's log lines (marked [hook]).")
  return flush("armed")
end


end
do
---------------------------------------------------------------- v1.89.34: summon probe step 24
-- Step 23 fired inside UpdateBehavior: ok=true, instance still
-- nil. The mod's hooks are logging/replacement-only, its charID
-- values are the same enum userdata, so the recipe inputs match
-- - except the POSITION. The mod sets ContextPosition from
-- Character:get_LastGroundPosition() - a via.Position (universal,
-- world-offset aware) - and the angle from the player's
-- PosRotContext. Our probes passed a via.vec3 built from the
-- transform. DD2 keeps a floating origin (WorldOffsetSystem
-- exists to convert vec3 -> universal Position); a local vec3
-- read as universal coordinates lands nowhere near the player.
-- Step 24 = step 23's hook design + the mod's exact pos/rot
-- sources, with the context position read back and logged.
local function summon24_hook()
  if SUMMON.hook24 then return end
  SUMMON.hook24 = true
  re.on_application_entry("UpdateBehavior", function()
    local P = SUMMON.pool24
    if not P or not P.armed then return end
    if P.fired then
      if not P.read then
        P.ticks = (P.ticks or 0) + 1
        if P.ticks >= 180 then
          P.read = true
          local go = try(function() return P.inst:call("get_Instance") end)
          local ch = try(function() return P.inst:call("get_Chara") end)
          P.hist[#P.hist + 1] = "[hook] +~3s instance GameObject=" ..
            tostring(go) .. " Chara=" .. tostring(ch)
        end
      end
      return
    end
    local ready = P.prefab and
      try(function() return P.prefab:call("get_Ready") end)
    if ready ~= true then
      pcall(function() P.prefab:call("set_Standby", true) end)
      return
    end
    P.fired = true
    P.hist[#P.hist + 1] = "[hook] prefab READY in UpdateBehavior - firing"
    local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
    local ok, err = pcall(function()
      return gm:call("requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)",
        P.pfbCtrl, P.cont, P.rid, P.inst, nil, nil)
    end)
    P.hist[#P.hist + 1] = "[hook] requestCreateInstance: ok=" .. tostring(ok) ..
      (ok and "" or (" err=" .. tostring(err)))
    P.ticks = 0
  end)
end

COMMANDS.summon_probe24 = function()
  local P = SUMMON.pool24
  if not P then
    P = { hist = {} }
    SUMMON.pool24 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 500 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe24.txt", text) then error("could not write summon_probe24.txt") end
    return "summon_probe24: " .. tag
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not gm or not cm then
    L("managers missing - not loaded into the world?")
    return flush("managers missing")
  end

  if P.fired then
    local go = P.inst and try(function() return P.inst:call("get_Instance") end)
    local ch = P.inst and try(function() return P.inst:call("get_Chara") end)
    L("post-spawn read: instance GameObject=" .. tostring(go) ..
      " Chara=" .. tostring(ch))
    return flush("post-spawn read")
  end
  if P.armed then
    L("still armed - the UpdateBehavior hook fires when the prefab is ready")
    return flush("armed, waiting")
  end

  L("== summon_probe24 (bridge 1.89.67) == stage (universal position) + arm hook")
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local chara = nil
  for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
    if try(function() return f:is_static() end) and
       try(function() return f:get_name() end) == "ch255000_00" then
      chara = try(function() return f:get_data(nil) end)
      break
    end
  end
  if not chara then
    L("ch255000_00 not resolvable")
    return flush("no chara")
  end
  P.chara = chara
  local cc = try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  local merged = ec and try(function() return ec:get_field("<MergedCatalog>k__BackingField") end)
  local rc = merged and try(function() return merged:call("get_Item", chara) end)
  local pfbCtrl = rc and try(function() return rc:call("get_Item") end)
  if not pfbCtrl then
    L("no prefab controller for ch255000_00 in merged catalog")
    return flush("no prefab controller")
  end
  P.pfbCtrl = pfbCtrl
  local prefab = try(function() return pfbCtrl:call("get_Item") end)
  P.prefab = prefab
  local inst = try(function() return sdk.create_instance("app.InstanceInfo"):add_ref() end)
  local cont = inst and try(function() return inst:call("get_Container") end)
  if not inst or not cont then
    L("InstanceInfo/container creation failed")
    return flush("no instanceinfo")
  end
  P.inst, P.cont = inst, cont
  local robj = try(function() return sdk.create_instance("app.RequestID"):add_ref() end)
  local rid = robj and try(function() return robj:call("makeNewRequestID") end)
  P.rid = rid
  local wrap = try(function() return gm:call("getIdWrapper", chara) end)
  -- The mod's exact transform sources.
  local player = try(function() return cm:call("get_ManualPlayer") end)
  local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
  local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
  local rot = prc and try(function() return prc:call("get_Rot") end)
  if not rot then
    local pgo = player and try(function() return player:call("get_GameObject") end)
    local ptr = pgo and try(function() return pgo:call("get_Transform") end)
    rot = ptr and try(function() return ptr:call("get_Rotation") end)
  end
  L("LastGroundPosition = " .. tostring(gpos) ..
    " (type " .. type(gpos) .. ")")
  if gpos and type(gpos) == "userdata" then
    L("  gpos fields: x=" .. tostring(try(function() return gpos.x end)) ..
      " y=" .. tostring(try(function() return gpos.y end)) ..
      " z=" .. tostring(try(function() return gpos.z end)))
  end
  if not (gpos and rot) then
    L("ground position / rotation unavailable")
    return flush("no transform")
  end
  local ci = try(function() return cont:call("get_CommonInfo") end)
  pcall(function() prefab:call("set_Standby", true) end)
  if wrap then
    pcall(function() ci:call("set_ObjectID", sdk.to_ptr(wrap)) end)
  end
  local okP, eP = pcall(function() ci:call("setContextPosition", gpos) end)
  local okA, eA = pcall(function() ci:call("setContextAngle", rot) end)
  L("setContextPosition(universal)=" .. tostring(okP) ..
    " setContextAngle(PosRot)=" .. tostring(okA))
  if not (okP and okA) then
    L("  errors: " .. tostring(eP) .. " | " .. tostring(eA))
  end
  local back = ci and try(function() return ci:call("get_ContextPosition") end)
  L("context position read-back = " .. tostring(back))
  summon24_hook()
  P.armed = true
  L("staged and ARMED - hook fires in UpdateBehavior when ready.")
  L("Wait ~10s, watch your feet (spawns AT your ground position),")
  L("then press once more to collect the [hook] lines.")
  return flush("armed")
end


end
do
---------------------------------------------------------------- v1.89.35: summon probe step 25
-- The reference recipe is DEAD on TU4 - the user ran the
-- original Enemy Spawner standalone and it does not work in
-- this game version either. So back to Route G (the game's own
-- generate queue), which DID produce a queued controller in
-- steps 16/17 - with one input wrong the whole time: the
-- factory getPoolGenerateInfoContainerForCharacter takes a
-- via.Position (universal), and every Route G attempt fed it a
-- via.vec3 (local). Step 25 feeds get_LastGroundPosition()
-- directly, sets the context position/angle from the same
-- universal sources, keeps pooled ID + LoadArea=6, waits for
-- the prefab to go valid, fires requestGenerate ONCE, and
-- snapshots the controller IN THE SAME CALL (no cross-press
-- polling - queued controllers are perishable).
COMMANDS.summon_probe25 = function()
  local P = SUMMON.pool25
  if not P then
    P = { hist = {} }
    SUMMON.pool25 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 500 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe25.txt", text) then error("could not write summon_probe25.txt") end
    return "summon_probe25: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid()
    local pc = find_ctrl("ch255000_00")
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end)
  end

  if P.done then
    L("already fired this session - use Verify / watch the spot")
    return flush("already done")
  end

  if not P.cont then
    L("== summon_probe25 (bridge 1.89.67) == build (factory + universal Position)")
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
    local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
    local rot = prc and try(function() return prc:call("get_Rot") end)
    if not rot then
      local pgo = player and try(function() return player:call("get_GameObject") end)
      local ptr = pgo and try(function() return pgo:call("get_Transform") end)
      rot = ptr and try(function() return ptr:call("get_Rotation") end)
    end
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and gpos and rot and scale) then
      L("missing pieces at build (chara/gpos/rot/scale)")
      return flush("missing pieces")
    end
    L("universal ground pos = " .. tostring(gpos))
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID then
      local okF, resF = pcall(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, gpos, rot, scale, 3, 0, chara, 1)
      end)
      L("factory call ok=" .. tostring(okF) ..
        (okF and "" or (" err=" .. tostring(resF))))
      if okF then cont = resF end
    end
    if not cont then
      L("factory container build failed")
      return flush("build failed")
    end
    local ci = try(function() return cont:call("get_CommonInfo") end)
    local okP, eP = pcall(function() ci:call("setContextPosition", gpos) end)
    local okA, eA = pcall(function() ci:call("setContextAngle", rot) end)
    L("setContextPosition(universal)=" .. tostring(okP) ..
      " setContextAngle=" .. tostring(okA) ..
      ((okP and okA) and "" or (" errs: " .. tostring(eP) .. " | " .. tostring(eA))))
    local td = try(function() return cont:get_type_definition() end)
    local setter = nil
    for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
      local nm = tostring(try(function() return m:get_name() end) or "")
      if nm:lower():find("loadarea") and nm:lower():find("set") then setter = nm break end
    end
    if setter then
      pcall(function() cont:call(setter, 6) end)
      L("LoadArea=6 via " .. setter)
    else
      L("no LoadArea setter found on container")
    end
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont, P.uniq, P.chara, P.ci = cont, uniqID, chara, ci
    L("standby started - press probe step 25 again in a few seconds")
    return flush("standby started")
  end

  if prefab_valid() ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    if P.ci then pcall(function() cc:call("requestStandbyPrefab", P.ci) end) end
    L("loading: prefab not valid yet - standby re-requested")
    return flush("still loading")
  end

  L("prefab VALID - firing requestGenerate once (universal-Position container)")
  local cb = function() end
  local okG, ctrl = pcall(function()
    return gm:call("requestGenerate", P.cont, 8 + 35184372088832, false, false, cb, cb)
  end)
  L("requestGenerate ok=" .. tostring(okG) .. " -> " .. tostring(ctrl) ..
    (okG and "" or (" err=" .. tostring(ctrl))))
  if okG and ctrl then
    local pos = try(function() return ctrl:call("get_Position") end)
    L("SNAPSHOT ctrl: generated=" ..
      tostring(try(function() return ctrl:call("get_IsGenerated") end)) ..
      " state=" ..
      tostring(try(function() return ctrl:call("get_RequestState") end)) ..
      " pos=" .. tostring(pos) ..
      " inRange=" ..
      tostring(try(function() return ctrl:call("get_IsInGenerateRangeForReserveDistributorUnit") end)) ..
      " fixPos=" ..
      tostring(try(function() return ctrl:call("get_IsFixGeneratePosition") end)))
    if pos and type(pos) == "userdata" then
      L("  ctrl pos fields: x=" .. tostring(try(function() return pos.x end)) ..
        " y=" .. tostring(try(function() return pos.y end)) ..
        " z=" .. tostring(try(function() return pos.z end)))
    end
    SUMMON.ctrl = ctrl
  else
    local fc = try(function()
      return gm:call("forceRequestCreateInstance", P.cont, cb, cb)
    end)
    L("force fallback = " .. tostring(fc))
  end
  SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
    P.cont, "ch255000_00", P.chara, P.uniq
  SUMMON.fired = true
  P.done = true
  L("fired. Snapshot pos ~= your ground pos + inRange=true means the")
  L("distributor can claim it: watch the spot, ONE Verify in ~15s.")
  L("If pos is garbage again, restart promptly to clear the queue.")
  return flush("fired")
end


end
do
---------------------------------------------------------------- v1.89.36: summon probe step 26
-- Probe 25 SPAWNED the monster (controller position read real
-- universal coordinates once the factory got a via.Position) -
-- but inert: not targetable, no AI, no combat either way. The
-- character generated without its activation setup. Two
-- documented activation levers were not used: InitSetType
-- "Summon" (the enum literally has one for this) and the
-- EnableForceCombat generate flag. Step 26 = step 25's recipe
-- with ONLY those two changed: init set resolved by name
-- (Summon, fallback Auto, fallback Common) and flags
-- OverrideContextPosition + EnableForceCombat +
-- DisableSaveRequestToSaveData.
COMMANDS.summon_probe26 = function()
  local P = SUMMON.pool26
  if not P then
    P = { hist = {} }
    SUMMON.pool26 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 500 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe26.txt", text) then error("could not write summon_probe26.txt") end
    return "summon_probe26: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid()
    local pc = find_ctrl("ch255000_00")
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end)
  end

  if P.done then
    L("already fired this session - use Verify / watch the spot")
    return flush("already done")
  end

  if not P.cont then
    L("== summon_probe26 (bridge 1.89.67) == build (factory + universal Position)")
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
    local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
    local rot = prc and try(function() return prc:call("get_Rot") end)
    if not rot then
      local pgo = player and try(function() return player:call("get_GameObject") end)
      local ptr = pgo and try(function() return pgo:call("get_Transform") end)
      rot = ptr and try(function() return ptr:call("get_Rotation") end)
    end
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and gpos and rot and scale) then
      L("missing pieces at build (chara/gpos/rot/scale)")
      return flush("missing pieces")
    end
    L("universal ground pos = " .. tostring(gpos))
    local itd = try(function() return sdk.find_type_definition("app.GenerateDefine.InitSetTypeEnum") end)
    local initset, initname = 1, "Common(fallback)"
    for _, want in ipairs({ "Summon", "Auto" }) do
      local found = nil
      for _, f in ipairs(itd and try(function() return itd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) and
           try(function() return f:get_name() end) == want then
          found = try(function() return f:get_data(nil) end)
          break
        end
      end
      if found ~= nil then initset, initname = found, want break end
    end
    L("init set: " .. initname .. " = " .. tostring(initset))
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID then
      local okF, resF = pcall(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, gpos, rot, scale, 3, 0, chara, initset)
      end)
      L("factory call ok=" .. tostring(okF) ..
        (okF and "" or (" err=" .. tostring(resF))))
      if okF then cont = resF end
    end
    if not cont then
      L("factory container build failed")
      return flush("build failed")
    end
    local ci = try(function() return cont:call("get_CommonInfo") end)
    local okP, eP = pcall(function() ci:call("setContextPosition", gpos) end)
    local okA, eA = pcall(function() ci:call("setContextAngle", rot) end)
    L("setContextPosition(universal)=" .. tostring(okP) ..
      " setContextAngle=" .. tostring(okA) ..
      ((okP and okA) and "" or (" errs: " .. tostring(eP) .. " | " .. tostring(eA))))
    local td = try(function() return cont:get_type_definition() end)
    local setter = nil
    for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
      local nm = tostring(try(function() return m:get_name() end) or "")
      if nm:lower():find("loadarea") and nm:lower():find("set") then setter = nm break end
    end
    if setter then
      pcall(function() cont:call(setter, 6) end)
      L("LoadArea=6 via " .. setter)
    else
      L("no LoadArea setter found on container")
    end
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont, P.uniq, P.chara, P.ci = cont, uniqID, chara, ci
    L("standby started - press probe step 26 again in a few seconds")
    return flush("standby started")
  end

  if prefab_valid() ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    if P.ci then pcall(function() cc:call("requestStandbyPrefab", P.ci) end) end
    L("loading: prefab not valid yet - standby re-requested")
    return flush("still loading")
  end

  L("prefab VALID - firing requestGenerate once (Summon init + force combat)")
  local cb = function() end
  local okG, ctrl = pcall(function()
    return gm:call("requestGenerate", P.cont, 8 + 131072 + 35184372088832, false, false, cb, cb)
  end)
  L("requestGenerate ok=" .. tostring(okG) .. " -> " .. tostring(ctrl) ..
    (okG and "" or (" err=" .. tostring(ctrl))))
  if okG and ctrl then
    local pos = try(function() return ctrl:call("get_Position") end)
    L("SNAPSHOT ctrl: generated=" ..
      tostring(try(function() return ctrl:call("get_IsGenerated") end)) ..
      " state=" ..
      tostring(try(function() return ctrl:call("get_RequestState") end)) ..
      " pos=" .. tostring(pos) ..
      " inRange=" ..
      tostring(try(function() return ctrl:call("get_IsInGenerateRangeForReserveDistributorUnit") end)) ..
      " fixPos=" ..
      tostring(try(function() return ctrl:call("get_IsFixGeneratePosition") end)))
    if pos and type(pos) == "userdata" then
      L("  ctrl pos fields: x=" .. tostring(try(function() return pos.x end)) ..
        " y=" .. tostring(try(function() return pos.y end)) ..
        " z=" .. tostring(try(function() return pos.z end)))
    end
    SUMMON.ctrl = ctrl
  else
    local fc = try(function()
      return gm:call("forceRequestCreateInstance", P.cont, cb, cb)
    end)
    L("force fallback = " .. tostring(fc))
  end
  SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
    P.cont, "ch255000_00", P.chara, P.uniq
  SUMMON.fired = true
  P.done = true
  L("fired. Snapshot pos ~= your ground pos + inRange=true means the")
  L("distributor can claim it: watch the spot, ONE Verify in ~15s.")
  L("If pos is garbage again, restart promptly to clear the queue.")
  return flush("fired")
end


end
do
---------------------------------------------------------------- v1.89.37: summon probe step 27
-- Step 26 verdict: InitSet=Summon + force combat is WORSE -
-- still untargetable and the game crashes ~10s after the
-- summon (the Summon init path starts a setup that faults
-- without its expected context). NEVER use Summon init again.
-- Step 25's recipe (Common init, base flags) is stable but the
-- monster is inert. Step 27 spawns with step 25's exact recipe,
-- then INSPECTS instead of guessing: it finds the generated
-- character (via the controller once generated, else via the
-- CharacterManager's character list), reads its think / hit /
-- target state, does the same for a NATURAL enemy of any kind
-- for comparison, and - if the summoned one is think-stopped
-- while the natural one is not - clears think-stop on the
-- character and reports (watch whether it wakes up).
COMMANDS.summon_probe27 = function()
  local P = SUMMON.pool27
  if not P then
    P = { hist = {} }
    SUMMON.pool27 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 600 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe27.txt", text) then error("could not write summon_probe27.txt") end
    return "summon_probe27: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid()
    local pc = find_ctrl("ch255000_00")
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end)
  end
  -- Dump think/hit/target-flavored state off a character object.
  local function dump_chara(ch, label)
    if not ch then
      L(label .. ": (none)")
      return
    end
    L(label .. ": charaID=" ..
      tostring(try(function() return ch:call("get_CharaID") end)))
    local td = try(function() return ch:get_type_definition() end)
    local ms = td and try(function() return td:get_methods() end)
    local seen = {}
    for _, m in ipairs(ms or {}) do
      local nm = tostring(try(function() return m:get_name() end) or "")
      local low = nm:lower()
      if not seen[nm] and nm:sub(1, 4) == "get_" and
         (low:find("think") or low:find("hit") or low:find("target") or
          low:find("active") or low:find("setup") or low:find("sleep") or
          low:find("combat") or low:find("alive") or low:find("dead")) then
        seen[nm] = true
        local v = try(function() return ch:call(nm) end)
        if v ~= nil and type(v) ~= "table" then
          L("  " .. nm .. " = " .. tostring(v))
        end
      end
    end
    -- Common field-style state, if present.
    for _, fn in ipairs({ "_IsThinkStop", "IsThinkStop", "_ThinkStop" }) do
      local v = try(function() return ch:get_field(fn) end)
      if v ~= nil then L("  field " .. fn .. " = " .. tostring(v)) end
    end
  end
  local function chara_list()
    -- Find a List-like field on CharacterManager holding characters.
    local td = try(function() return cm:get_type_definition() end)
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
      local fn = try(function() return f:get_name() end)
      local v = fn and try(function() return cm:get_field(fn) end)
      local n = v and arr_len(v)
      if n and n > 0 and n < 500 then
        local first = arr_get(v, 0)
        if first and try(function() return first:call("get_CharaID") end) ~= nil then
          return v, fn
        end
      end
    end
    return nil, nil
  end

  if P.inspected then
    L("already inspected this spawn - see above")
    return flush("already inspected")
  end

  if not P.cont then
    L("== summon_probe27 (bridge 1.89.67) == build (probe 25 recipe, stable)")
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
    local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
    local rot = prc and try(function() return prc:call("get_Rot") end)
    if not rot then
      local pgo = player and try(function() return player:call("get_GameObject") end)
      local ptr = pgo and try(function() return pgo:call("get_Transform") end)
      rot = ptr and try(function() return ptr:call("get_Rotation") end)
    end
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and gpos and rot and scale) then
      L("missing pieces at build")
      return flush("missing pieces")
    end
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID then
      cont = try(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, gpos, rot, scale, 3, 0, chara, 1)
      end)
    end
    if not cont then
      L("factory container build failed")
      return flush("build failed")
    end
    local ci = try(function() return cont:call("get_CommonInfo") end)
    pcall(function() ci:call("setContextPosition", gpos) end)
    pcall(function() ci:call("setContextAngle", rot) end)
    local chi = try(function() return cont:call("get_CharaInfo") end)
    L("container CharaInfo _IsThinkStop = " ..
      tostring(chi and try(function() return chi:get_field("_IsThinkStop") end)))
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont, P.uniq, P.chara = cont, uniqID, chara
    L("standby started - press probe step 27 again in a few seconds")
    return flush("standby started")
  end

  if not P.fired then
    if prefab_valid() ~= true then
      pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
      L("loading: prefab not valid yet - standby re-requested")
      return flush("still loading")
    end
    L("prefab VALID - firing requestGenerate once (Common, base flags)")
    local cb = function() end
    local okG, ctrl = pcall(function()
      return gm:call("requestGenerate", P.cont, 8 + 35184372088832, false, false, cb, cb)
    end)
    L("requestGenerate ok=" .. tostring(okG) .. " -> " .. tostring(ctrl) ..
      (okG and "" or (" err=" .. tostring(ctrl))))
    if okG and ctrl then SUMMON.ctrl = ctrl P.ctrl = ctrl end
    SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
      P.cont, "ch255000_00", P.chara, P.uniq
    SUMMON.fired = true
    P.fired = true
    L("fired - let it appear, then press probe step 27 for the inspection")
    return flush("fired")
  end

  -- Inspection stage.
  L("== inspection ==")
  local gen = P.ctrl and try(function() return P.ctrl:call("get_IsGenerated") end)
  L("controller generated=" .. tostring(gen))
  local mine, natural = nil, nil
  local list, lname = chara_list()
  L("character list field: " .. tostring(lname) ..
    " count=" .. tostring(list and arr_len(list)))
  if list then
    local n = arr_len(list)
    for i = 0, n - 1 do
      local ch = arr_get(list, i)
      local id = ch and try(function() return ch:call("get_CharaID") end)
      local nm = id and try(function() return id:call("ToString") end)
      if nm == "ch255000_00" and not mine then mine = ch end
      if nm and nm ~= "ch255000_00" and nm:sub(1, 2) == "ch"
         and not natural then natural = ch end
      if mine and natural then break end
    end
  end
  dump_chara(mine, "SUMMONED")
  dump_chara(natural, "NATURAL (first other)")
  -- The one guarded fix attempt: think-stop on the summoned character.
  if mine then
    local before = try(function() return mine:get_field("_IsThinkStop") end)
    if before == nil then
      before = try(function() return mine:call("get_IsThinkStop") end)
    end
    L("summoned think-stop reads: " .. tostring(before))
    if before == true then
      local okW = pcall(function() mine:set_field("_IsThinkStop", false) end)
      L("set _IsThinkStop=false on character: " .. tostring(okW) ..
        " - WATCH IT: does it wake up?")
    end
  end
  P.inspected = true
  return flush("inspection complete")
end


end
do
---------------------------------------------------------------- v1.89.38: summon probe step 28
-- STOP FIRING, START WATCHING. The spawn fire is unstable
-- across sessions (step 25 stable-inert, step 26 delayed
-- crash, step 27 crashed at the fire press) - our shortcut
-- skips whatever bookkeeping the natural pipeline does first.
-- Step 28 makes NO spawn calls. It installs passive logging
-- hooks on the GenerateManager's spawn entry points (the
-- reference mod hooks two of these permanently, safely) and
-- records the GAME'S OWN natural-spawn calls: which method,
-- which character, and the container state the game itself
-- builds (ObjectID, think-stop, load area). Walk into a fresh
-- area where enemies generate and the log fills; diffing a
-- natural container against our factory container names the
-- missing piece instead of guessing it.
local function summon28_log(line)
  local O = SUMMON.obs28
  if not O then return end
  O.hist[#O.hist + 1] = line
  if #O.hist > 600 then table.remove(O.hist, 1) end
  wr(DIR .. "summon_probe28.txt", table.concat(O.hist, "\n"))
end

local function summon28_describe(tag, cont)
  if not cont then
    summon28_log(tag .. ": container=nil")
    return
  end
  local ci = try(function() return cont:call("get_CommonInfo") end)
  local chi = try(function() return cont:call("get_CharaInfo") end)
  local oid = ci and try(function() return ci:get_field("_ObjectID") end)
  local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
  summon28_log(tag .. ": chara=" .. tostring(sel) ..
    " thinkStop=" ..
    tostring(chi and try(function() return chi:get_field("_IsThinkStop") end)) ..
    " loadArea=" ..
    tostring(ci and try(function() return ci:call("get_LoadArea") end)))
end

local function summon28_install()
  if SUMMON.obs28 then return end
  SUMMON.obs28 = { hist = {}, n = 0 }
  local td = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  if not td then
    summon28_log("GenerateManager type not found - hooks NOT installed")
    return
  end
  local function hook(name, sig, describe_idx)
    local m = try(function()
      if sig then return td:get_method(sig) end
      return td:get_method(name)
    end)
    if not m then
      summon28_log("hook target missing: " .. name)
      return
    end
    local ok = pcall(function()
      sdk.hook(m, function(args)
        SUMMON.obs28.n = SUMMON.obs28.n + 1
        local cont = describe_idx and
          try(function() return sdk.to_managed_object(args[describe_idx]) end)
        summon28_describe("[call #" .. SUMMON.obs28.n .. "] " .. name, cont)
      end, function(retval)
        return retval
      end)
    end)
    summon28_log("hook installed (" .. name .. "): " .. tostring(ok))
  end
  summon28_log("== summon_probe28 (bridge 1.89.67) == hooks")
  -- requestGenerate(GenerateInfoContainer, flags, bool, bool, cb, cb):
  -- args[3] = container.
  hook("requestGenerate", nil, 3)
  -- requestCreateInstance overload 1 (InstanceInfo): args[4] = container.
  hook("requestCreateInstance",
    "requestCreateInstance(app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, app.InstanceInfo, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)", 4)
  -- requestCreateInstance overload 2 (category): args[5] = container.
  hook("requestCreateInstance",
    "requestCreateInstance(app.GeneratorCategory, app.PrefabController, app.GenerateInfo.GenerateInfoContainer, System.Int32, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>, System.Action`2<app.PrefabInstantiateResults,app.DummyArg>)", 5)
  hook("forceRequestCreateInstance", nil, 3)
end

COMMANDS.summon_probe28 = function()
  summon28_install()
  local O = SUMMON.obs28
  local n = O and O.n or 0
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe28.txt", text) then error("could not write summon_probe28.txt") end
  return "summon_probe28: hooks live, " .. n ..
    " natural spawn call(s) captured so far"
end


end
do
---------------------------------------------------------------- v1.89.39: summon probe step 29
-- Step 28 proved natural spawns DO flow through
-- requestGenerate - thousands of retry calls as the player
-- moves. But it logged only 3 fields per call and flooded.
-- Step 29 dedupes: the FIRST time each natural container is
-- seen, it dumps everything once - the flags and bool params
-- the game passes, plus full field lists of the container's
-- CommonInfo / CharaInfo / StatusInfo / GeneratorID. Diffing
-- one of these against our factory container (which produces
-- inert monsters) names the missing state exactly.
local function summon29_install()
  if SUMMON.obs29 then return end
  local O = { hist = {}, seen = {}, dumped = 0, calls = 0 }
  SUMMON.obs29 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 800 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe29.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe29 (bridge 1.89.67) == natural container deep-dump")
  -- number -> name map for CharacterID values.
  local namemap = {}
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
    if try(function() return f:is_static() end) then
      local v = try(function() return f:get_data(nil) end)
      local n = v and try(function() return sdk.to_int64(v) end)
      if n then namemap[n] = try(function() return f:get_name() end) end
    end
  end
  L("charID name map: " .. tostring(#O.hist) .. " lines so far")
  local function dump_fields(obj, label, maxn)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local td = try(function() return obj:get_type_definition() end)
    local fields = td and try(function() return td:get_fields() end)
    if not fields then
      L("  " .. label .. ": (no fields)")
      return
    end
    local out = {}
    for _, f in ipairs(fields) do
      if #out >= (maxn or 40) then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          out[#out + 1] = fn .. "=" .. tostring(v)
        elseif tv == "userdata" then
          local iv = try(function() return sdk.to_int64(v) end)
          if iv ~= nil and iv > -100000 and iv < 5000000000 then
            out[#out + 1] = fn .. "=" .. tostring(iv)
          else
            out[#out + 1] = fn .. "=<obj>"
          end
        end
      end
    end
    L("  " .. label .. ": " .. table.concat(out, " "))
  end
  local td = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = td and try(function() return td:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.dumped >= 12 then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local key = tostring(cont)
      if O.seen[key] then return end
      O.seen[key] = true
      O.dumped = O.dumped + 1
      local flags = try(function() return sdk.to_int64(args[4]) end)
      local b1 = try(function() return sdk.to_int64(args[5]) end)
      local b2 = try(function() return sdk.to_int64(args[6]) end)
      L("[container #" .. O.dumped .. "] flags=" .. tostring(flags) ..
        " bool1=" .. tostring(b1) .. " bool2=" .. tostring(b2))
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local chi = try(function() return cont:call("get_CharaInfo") end)
      local sti = try(function() return cont:call("get_StatusInfo") end)
      local oid = ci and try(function() return ci:get_field("_ObjectID") end)
      local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
      local seln = sel and try(function() return sdk.to_int64(sel) end)
      L("  chara: " .. tostring(seln) .. " = " ..
        tostring(seln and namemap[seln]))
      dump_fields(ci, "CommonInfo", 40)
      dump_fields(chi, "CharaInfo", 40)
      dump_fields(sti, "StatusInfo", 30)
      local gid = ci and (try(function() return ci:call("get_GeneratorID") end)
        or try(function() return ci:get_field("_GeneratorID") end))
      dump_fields(gid, "GeneratorID", 12)
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies, then press the probe again")
end

COMMANDS.summon_probe29 = function()
  summon29_install()
  local O = SUMMON.obs29
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe29.txt", text) then error("could not write summon_probe29.txt") end
  return "summon_probe29: " .. tostring(O and O.calls or 0) ..
    " requestGenerate calls seen, " .. tostring(O and O.dumped or 0) ..
    " containers dumped"
end


end
do
---------------------------------------------------------------- v1.89.40: summon probe step 30
-- Step 29's natural-container dumps gave the systematic
-- diff. Natural field monsters: InitSetType = 2 ("Wait") in
-- 11 of 12 dumps, and generate flags dominated by 2^21
-- (2097152) plus small bits - 2097168 (2^21 + 16) is the most
-- common Monster pattern. Our factory containers used
-- Common (1) and flags 8 + 2^35 - neither appears in any
-- natural call. Everything else (category, requestType,
-- GenerateDisableFlag, status ID, rates) already matches.
-- Step 30 = step 25's stable recipe (pooled factory
-- container, universal ground position, context set,
-- standby-to-valid, single fire) with ONLY those two scalars
-- changed to the natural values.
COMMANDS.summon_probe30 = function()
  local P = SUMMON.pool30
  if not P then
    P = { hist = {} }
    SUMMON.pool30 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 500 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe30.txt", text) then error("could not write summon_probe30.txt") end
    return "summon_probe30: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid()
    local pc = find_ctrl("ch255000_00")
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end)
  end

  if P.done then
    L("already fired this session - use Verify / watch the spot")
    return flush("already done")
  end

  if not P.cont then
    L("== summon_probe30 (bridge 1.89.67) == build (natural scalars)")
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
    local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
    local rot = prc and try(function() return prc:call("get_Rot") end)
    if not rot then
      local pgo = player and try(function() return player:call("get_GameObject") end)
      local ptr = pgo and try(function() return pgo:call("get_Transform") end)
      rot = ptr and try(function() return ptr:call("get_Rotation") end)
    end
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and gpos and rot and scale) then
      L("missing pieces at build (chara/gpos/rot/scale)")
      return flush("missing pieces")
    end
    local itd = try(function() return sdk.find_type_definition("app.GenerateDefine.InitSetTypeEnum") end)
    local initset = 2
    for _, f in ipairs(itd and try(function() return itd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "Wait" then
        initset = try(function() return f:get_data(nil) end) or 2
        break
      end
    end
    L("init set: Wait = " .. tostring(initset))
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID then
      local okF, resF = pcall(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, gpos, rot, scale, 3, 0, chara, initset)
      end)
      L("factory call ok=" .. tostring(okF) ..
        (okF and "" or (" err=" .. tostring(resF))))
      if okF then cont = resF end
    end
    if not cont then
      L("factory container build failed")
      return flush("build failed")
    end
    local ci = try(function() return cont:call("get_CommonInfo") end)
    pcall(function() ci:call("setContextPosition", gpos) end)
    pcall(function() ci:call("setContextAngle", rot) end)
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont, P.uniq, P.chara = cont, uniqID, chara
    L("standby started - press probe step 30 again in a few seconds")
    return flush("standby started")
  end

  if prefab_valid() ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    L("loading: prefab not valid yet - standby re-requested")
    return flush("still loading")
  end

  L("prefab VALID - firing requestGenerate once (Wait init, natural flags 2097168)")
  local cb = function() end
  local okG, ctrl = pcall(function()
    return gm:call("requestGenerate", P.cont, 2097168, false, false, cb, cb)
  end)
  L("requestGenerate ok=" .. tostring(okG) .. " -> " .. tostring(ctrl) ..
    (okG and "" or (" err=" .. tostring(ctrl))))
  if okG and ctrl then
    local pos = try(function() return ctrl:call("get_Position") end)
    L("SNAPSHOT ctrl: generated=" ..
      tostring(try(function() return ctrl:call("get_IsGenerated") end)) ..
      " state=" ..
      tostring(try(function() return ctrl:call("get_RequestState") end)) ..
      " pos=" .. tostring(pos))
    SUMMON.ctrl = ctrl
  end
  SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
    P.cont, "ch255000_00", P.chara, P.uniq
  SUMMON.fired = true
  P.done = true
  L("fired - watch it: targetable? does it move/attack? can you hit it?")
  return flush("fired")
end


end
do
---------------------------------------------------------------- v1.89.41: summon probe step 31
-- Steps 29-30 settled the scalars: natural InitSetType and
-- generate flags are now matched, and the summoned Medusa
-- still stands inert - while pawns perceive and name it.
-- The character exists; its activation setup never runs.
-- Remaining suspect: provenance. Natural containers carry a
-- real table-backed GeneratorID (its _TableID is an object)
-- and a _CustomGeneratorID; ours are pooled/minted shells.
-- Step 31 captures up to 3 live natural Monster containers
-- (via the requestGenerate hook) and dumps the provenance
-- graph: _TableID and _CustomGeneratorID subfields, the
-- _RequestID pair, and the container's own fields - plus
-- existence checks for the table API (getTable /
-- requestGenerateTable / getSelector / getTableListNum /
-- getTableMax). Observation only; fires nothing.
local function sp31_install()
  if SUMMON.obs31 then return end
  local O = { hist = {}, stash = {}, calls = 0 }
  SUMMON.obs31 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 900 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe31.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe31 (bridge 1.89.67) == natural container provenance")
  local td = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = td and try(function() return td:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if #O.stash >= 3 then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      for _, c in ipairs(O.stash) do
        if tostring(c) == tostring(cont) then return end
      end
      O.stash[#O.stash + 1] = cont
      L("captured natural Monster container #" .. #O.stash)
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies, then press the probe again")
end

local function sp31_dump()
  local O = SUMMON.obs31
  local L = O.log
  local function dump_fields(obj, label, depth)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local td = try(function() return obj:get_type_definition() end)
    local fields = td and try(function() return td:get_fields() end)
    L("  " .. label .. " [" ..
      tostring(td and try(function() return td:get_full_name() end)) .. "]")
    if not fields then return end
    local n = 0
    for _, f in ipairs(fields) do
      if n >= 36 then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        n = n + 1
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          L("    " .. fn .. " = " .. tostring(v))
        elseif tv == "userdata" then
          L("    " .. fn .. " = <obj> " .. tostring(v))
          if (depth or 0) > 0 and
             (fn:find("TableID") or fn:find("GeneratorID") or
              fn:find("RequestID") or fn:find("ObjectID") or
              fn:find("GenID") or fn:find("UniqID")) then
            dump_fields(v, label .. "." .. fn, (depth or 0) - 1)
          end
        end
      end
    end
  end
  -- Table API existence on the GenerateManager type.
  local td = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local names = { "getTable", "requestGenerateTable", "getSelector",
                  "getTableListNum", "getTableMax", "getRegenerateTableMax",
                  "createGenerateTable", "registGenerateTable" }
  local found = {}
  for _, nm in ipairs(names) do
    if td and try(function() return td:get_method(nm) end) then
      found[#found + 1] = nm
    end
  end
  L("table API present: " .. table.concat(found, ", "))
  L("containers captured: " .. #O.stash ..
    " (requestGenerate calls seen: " .. O.calls .. ")")
  for i, cont in ipairs(O.stash) do
    L("[natural container #" .. i .. "]")
    dump_fields(cont, "container", 0)
    local ci = try(function() return cont:call("get_CommonInfo") end)
    dump_fields(ci, "CommonInfo", 2)
  end
end

COMMANDS.summon_probe31 = function()
  sp31_install()
  local O = SUMMON.obs31
  if O and #O.stash > 0 then sp31_dump() end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe31.txt", text) then error("could not write summon_probe31.txt") end
  return "summon_probe31: " .. tostring(O and O.calls or 0) ..
    " calls seen, " .. tostring(O and #O.stash or 0) .. " containers captured"
end


end
do
---------------------------------------------------------------- v1.89.42: summon probe step 32
-- Step 31 found the table API (getTable and
-- requestGenerateTable exist on GenerateManager) but its
-- dump read "(nil)" for everything: the captured natural
-- containers are POOLED and recycled - by the second press
-- the stashed references point at dead objects. All
-- inspection must happen inside the hook, at capture time
-- (that is how steps 28/29 got their data). Step 32 does
-- exactly that: at first sight of each of the first 3
-- natural Monster containers, it dumps the full provenance
-- graph in-hook - container fields, CommonInfo with
-- recursion into the table/generator/request/object ID
-- sub-objects, CharaInfo and StatusInfo. Observation only.
local function sp32_install()
  if SUMMON.obs32 then return end
  local O = { hist = {}, seen = {}, dumped = 0, calls = 0 }
  SUMMON.obs32 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe32.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe32 (bridge 1.89.67) == in-hook provenance dump")
  local td = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local names = { "getTable", "requestGenerateTable", "getSelector",
                  "getTableListNum", "getTableMax", "getRegenerateTableMax",
                  "createGenerateTable", "registGenerateTable" }
  local found = {}
  for _, nm in ipairs(names) do
    if td and try(function() return td:get_method(nm) end) then
      found[#found + 1] = nm
    end
  end
  L("table API present: " .. table.concat(found, ", "))
  local function dump_fields(obj, label, depth)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local otd = try(function() return obj:get_type_definition() end)
    local fields = otd and try(function() return otd:get_fields() end)
    L("  " .. label .. " [" ..
      tostring(otd and try(function() return otd:get_full_name() end)) .. "]")
    if not fields then return end
    local n = 0
    for _, f in ipairs(fields) do
      if n >= 36 then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        n = n + 1
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          L("    " .. fn .. " = " .. tostring(v))
        elseif tv == "userdata" then
          L("    " .. fn .. " = <obj> " .. tostring(v))
          if (depth or 0) > 0 and
             (fn:find("TableID") or fn:find("GeneratorID") or
              fn:find("RequestID") or fn:find("ObjectID") or
              fn:find("GenID") or fn:find("UniqID")) then
            dump_fields(v, label .. "." .. fn, (depth or 0) - 1)
          end
        end
      end
    end
  end
  local m = td and try(function() return td:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.dumped >= 3 then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local key = tostring(cont)
      if O.seen[key] then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.seen[key] = true
      O.dumped = O.dumped + 1
      L("[natural Monster container #" .. O.dumped .. "]")
      dump_fields(cont, "container", 0)
      dump_fields(ci, "CommonInfo", 2)
      dump_fields(try(function() return cont:call("get_CharaInfo") end),
        "CharaInfo", 0)
      dump_fields(try(function() return cont:call("get_StatusInfo") end),
        "StatusInfo", 0)
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies, then press the probe again")
end

COMMANDS.summon_probe32 = function()
  sp32_install()
  local O = SUMMON.obs32
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe32.txt", text) then error("could not write summon_probe32.txt") end
  return "summon_probe32: " .. tostring(O and O.calls or 0) ..
    " calls seen, " .. tostring(O and O.dumped or 0) .. " containers dumped"
end


end
do
---------------------------------------------------------------- v1.89.43: summon probe step 33
-- Step 32's provenance dumps cleared the ID theory: natural
-- containers' custom GeneratorID wraps an EMPTY Guid - there
-- is no magic table identity to steal. What IS row-specific
-- in natural containers: the InitSetType (207 / 30 / 2 across
-- three monsters of two species), the flags, priorities and
-- scale. The init set is the activation suspect: it plausibly
-- selects the character's own setup routine, and we have
-- only ever fired generic ones (Common, Wait, and the banned
-- Summon). Natural species carry species init sets.
-- Step 33 enumerates every InitSetTypeEnum member named for
-- family 255, picks the family/variant one, and fires step
-- 25's recipe with it (flags back to 8, a value a natural
-- wandering field monster in step 32 used). One variable:
-- the init set.
COMMANDS.summon_probe33 = function()
  local P = SUMMON.pool33
  if not P then
    P = { hist = {} }
    SUMMON.pool33 = P
  end
  local function L(x)
    P.hist[#P.hist + 1] = x
    if #P.hist > 500 then table.remove(P.hist, 1) end
  end
  local function flush(tag)
    local text = table.concat(P.hist, "\n")
    if not wr(DIR .. "summon_probe33.txt", text) then error("could not write summon_probe33.txt") end
    return "summon_probe33: " .. tag
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end

  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
  local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
  if not gm or not cm or not ec then
    L("managers or enemy catalog missing - not loaded into the world?")
    return flush("managers missing")
  end
  local function find_ctrl(want)
    local keys = try(function() return ec:call("getKeys") end)
    local vals = try(function() return ec:call("getValues") end)
    local nk, nv = arr_len(keys), arr_len(vals)
    if not (keys and vals and nk and nv) then return nil end
    local n = math.min(nk, nv)
    for i = 0, n - 1 do
      local k = arr_get(keys, i)
      local nm = k and try(function() return k:call("ToString") end)
      if nm == want then return arr_get(vals, i) end
    end
    return nil
  end
  local function prefab_valid()
    local pc = find_ctrl("ch255000_00")
    local item = pc and try(function() return pc:get_field("_Item") end)
    return item and try(function() return item:call("get_Valid") end)
  end

  if P.done then
    L("already fired this session - use Verify / watch the spot")
    return flush("already done")
  end

  if not P.cont then
    L("== summon_probe33 (bridge 1.89.67) == build (species init set)")
    local itd = try(function() return sdk.find_type_definition("app.GenerateDefine.InitSetTypeEnum") end)
    local cands = {}
    for _, f in ipairs(itd and try(function() return itd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) then
        local nm = try(function() return f:get_name() end)
        if nm and nm:find("255") then
          local v = try(function() return f:get_data(nil) end)
          cands[#cands + 1] = { name = nm, val = v }
          L("  init candidate: " .. nm .. " = " .. tostring(v))
        end
      end
    end
    local initset, initname = nil, nil
    for _, c in ipairs(cands) do
      if c.name == "Ch255" then initset, initname = c.val, c.name break end
    end
    if not initset then
      for _, c in ipairs(cands) do
        if c.name == "Ch255_00" or c.name == "Ch255000" or c.name == "Ch255000_00" then
          initset, initname = c.val, c.name
          break
        end
      end
    end
    if not initset and #cands > 0 then
      initset, initname = cands[1].val, cands[1].name
    end
    if not initset then
      L("no InitSetTypeEnum member names family 255 - cannot fire this probe")
      return flush("no species init found")
    end
    L("init set chosen: " .. initname .. " = " .. tostring(initset))
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local chara = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        chara = try(function() return f:get_data(nil) end)
        break
      end
    end
    local player = try(function() return cm:call("get_ManualPlayer") end)
    local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
    local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
    local rot = prc and try(function() return prc:call("get_Rot") end)
    if not rot then
      local pgo = player and try(function() return player:call("get_GameObject") end)
      local ptr = pgo and try(function() return pgo:call("get_Transform") end)
      rot = ptr and try(function() return ptr:call("get_Rotation") end)
    end
    local scale = try(function() return Vector3f.new(1, 1, 1) end)
    if not (chara and gpos and rot and scale) then
      L("missing pieces at build (chara/gpos/rot/scale)")
      return flush("missing pieces")
    end
    local genID = try(function() return gm:call("getPoolGeneratorID") end)
    local uniqID = try(function() return gm:call("getUniqueIDfromCharacterID", chara) end)
    local cont = nil
    if genID and uniqID then
      local okF, resF = pcall(function()
        return gm:call("getPoolGenerateInfoContainerForCharacter",
          genID, uniqID, gpos, rot, scale, 3, 0, chara, initset)
      end)
      L("factory call ok=" .. tostring(okF) ..
        (okF and "" or (" err=" .. tostring(resF))))
      if okF then cont = resF end
    end
    if not cont then
      L("factory container build failed")
      return flush("build failed")
    end
    local ci = try(function() return cont:call("get_CommonInfo") end)
    pcall(function() ci:call("setContextPosition", gpos) end)
    pcall(function() ci:call("setContextAngle", rot) end)
    pcall(function() gm:call("requestStandbyPrefab", cont) end)
    if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
    P.cont, P.uniq, P.chara = cont, uniqID, chara
    L("standby started - press probe step 33 again in a few seconds")
    return flush("standby started")
  end

  if prefab_valid() ~= true then
    pcall(function() gm:call("requestStandbyPrefab", P.cont) end)
    L("loading: prefab not valid yet - standby re-requested")
    return flush("still loading")
  end

  L("prefab VALID - firing requestGenerate once (species init, flags 8)")
  local cb = function() end
  local okG, ctrl = pcall(function()
    return gm:call("requestGenerate", P.cont, 8, false, false, cb, cb)
  end)
  L("requestGenerate ok=" .. tostring(okG) .. " -> " .. tostring(ctrl) ..
    (okG and "" or (" err=" .. tostring(ctrl))))
  if okG and ctrl then
    L("SNAPSHOT ctrl: generated=" ..
      tostring(try(function() return ctrl:call("get_IsGenerated") end)) ..
      " state=" ..
      tostring(try(function() return ctrl:call("get_RequestState") end)))
    SUMMON.ctrl = ctrl
  end
  SUMMON.cont, SUMMON.name, SUMMON.chara, SUMMON.uniq =
    P.cont, "ch255000_00", P.chara, P.uniq
  SUMMON.fired = true
  P.done = true
  L("fired - watch it: targetable? does it move/attack? can you hit it?")
  return flush("fired")
end


end
do
---------------------------------------------------------------- v1.89.44: summon probe step 34
-- Step 33: the ONLY InitSetTypeEnum member naming family 255
-- is Ch255000_11_SummonAppear (203) - a scenario init - and
-- firing with it crashed the game (banned, like Summon 328).
-- Generic inits do not crash but do not activate; scenario
-- inits expect context that does not exist. The init-set
-- line is closed. What remains is the table route, whose
-- doors step 31/32 confirmed exist on GenerateManager:
-- getTable and requestGenerateTable - and table editing is
-- the one spawn method proven to work on this game version
-- by other mods. Step 34 is read-only recon for it: inside
-- the capture hook, take one natural Monster container's
-- GeneratorID, dump its _TableID value type in full, call
-- getTable with it, and dump the table (InitialSetData plus
-- the first set/row entries) and the GenerateTable type's
-- row-flavored methods. Fires nothing.
local function sp34_install()
  if SUMMON.obs34 then return end
  local O = { hist = {}, done = false, calls = 0 }
  SUMMON.obs34 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe34.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe34 (bridge 1.89.67) == generate-table recon")
  local function dump_fields(obj, label, maxn)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local otd = try(function() return obj:get_type_definition() end)
    local fields = otd and try(function() return otd:get_fields() end)
    L("  " .. label .. " [" ..
      tostring(otd and try(function() return otd:get_full_name() end)) .. "]")
    if not fields then return end
    local n = 0
    for _, f in ipairs(fields) do
      if n >= (maxn or 36) then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        n = n + 1
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          L("    " .. fn .. " = " .. tostring(v))
        else
          L("    " .. fn .. " = <obj> " .. tostring(v))
        end
      end
    end
  end
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      L("[captured natural Monster container - table recon]")
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      dump_fields(tid, "GenID._TableID", 20)
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = nil
      if gm and genID then
        local okT, resT = pcall(function() return gm:call("getTable", genID, 3) end)
        L("getTable(genID, Monster) ok=" .. tostring(okT) ..
          " -> " .. tostring(resT) ..
          (okT and "" or (" err=" .. tostring(resT))))
        if okT then tbl = resT end
      end
      if tbl then
        dump_fields(tbl, "GenerateTable", 40)
        local isd = try(function() return tbl:get_field("_InitialSetData") end)
          or try(function() return tbl:call("get_InitialSetData") end)
        dump_fields(isd, "table.InitialSetData", 16)
        local gttd = try(function() return tbl:get_type_definition() end)
        local ms = gttd and try(function() return gttd:get_methods() end)
        local hits = {}
        for _, mm in ipairs(ms or {}) do
          local mn = try(function() return mm:get_name() end)
          if mn and (mn:find("Row") or mn:find("SetInfo") or
                     mn:find("Initial") or mn:find("Generate")) then
            hits[#hits + 1] = mn
          end
        end
        L("  GenerateTable row methods: " .. table.concat(hits, ", "))
      end
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies, then press the probe again")
end

COMMANDS.summon_probe34 = function()
  sp34_install()
  local O = SUMMON.obs34
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe34.txt", text) then error("could not write summon_probe34.txt") end
  return "summon_probe34: " .. tostring(O and O.calls or 0) ..
    " calls seen, table recon " .. tostring(O and O.done or false)
end


end
do
---------------------------------------------------------------- v1.89.45: summon probe step 35
-- Step 34: a natural container's RequestID GeneratorID DOES
-- carry a real table GUID (System.Guid, non-zero), but
-- getTable(genID, Monster) returned nil - wrong argument
-- form, or tables are keyed differently. Step 35 stops
-- guessing the signature: (A) dump GenerateManager's own
-- fields to find where tables actually live; (B) inside the
-- capture hook, retry getTable with the live TableID Guid
-- itself (alone, with category, and the full GenID alone);
-- (C) if a dictionary/list field on the manager smells like
-- table storage, enumerate its first entries and dump any
-- GenerateTable found (fields + InitialSetData). Read-only.
local function sp35_manager_census(L)
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  if not gm then
    L("GenerateManager singleton missing")
    return
  end
  local td = try(function() return gm:get_type_definition() end)
  local fields = td and try(function() return td:get_fields() end)
  L("[GenerateManager fields]")
  for _, f in ipairs(fields or {}) do
    local fn = try(function() return f:get_name() end)
    if fn and not try(function() return f:is_static() end) then
      local ft = try(function() return f:get_type() end)
      local ftn = ft and try(function() return ft:get_full_name() end)
      local v = try(function() return gm:get_field(fn) end)
      local tv = type(v)
      if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
        L("  " .. fn .. " : " .. tostring(ftn) .. " = " .. tostring(v))
      else
        L("  " .. fn .. " : " .. tostring(ftn) .. " = <obj> " .. tostring(v))
      end
    end
  end
end

local function sp35_install()
  if SUMMON.obs35 then return end
  local O = { hist = {}, done = false, calls = 0 }
  SUMMON.obs35 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe35.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe35 (bridge 1.89.67) == table storage census")
  local function dump_fields(obj, label, maxn)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local otd = try(function() return obj:get_type_definition() end)
    local fields = otd and try(function() return otd:get_fields() end)
    L("  " .. label .. " [" ..
      tostring(otd and try(function() return otd:get_full_name() end)) .. "]")
    if not fields then return end
    local n = 0
    for _, f in ipairs(fields) do
      if n >= (maxn or 36) then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        n = n + 1
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          L("    " .. fn .. " = " .. tostring(v))
        else
          L("    " .. fn .. " = <obj> " .. tostring(v))
        end
      end
    end
  end
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      L("[captured natural Monster container - getTable variants]")
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      if gm and tid then
        local okA, resA = pcall(function() return gm:call("getTable", tid) end)
        L("getTable(tableID) ok=" .. tostring(okA) .. " -> " .. tostring(resA) ..
          (okA and "" or (" err=" .. tostring(resA))))
        local okB, resB = pcall(function() return gm:call("getTable", tid, 3) end)
        L("getTable(tableID, Monster) ok=" .. tostring(okB) .. " -> " .. tostring(resB) ..
          (okB and "" or (" err=" .. tostring(resB))))
        local okC, resC = pcall(function() return gm:call("getTable", genID) end)
        L("getTable(genID) ok=" .. tostring(okC) .. " -> " .. tostring(resC) ..
          (okC and "" or (" err=" .. tostring(resC))))
        local pick = (okA and resA) or (okB and resB) or (okC and resC)
        if pick then
          dump_fields(pick, "table from getTable", 40)
          local isd = try(function() return pick:get_field("_InitialSetData") end)
            or try(function() return pick:call("get_InitialSetData") end)
          dump_fields(isd, "table.InitialSetData", 16)
        end
      end
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies, then press the probe again")
end

COMMANDS.summon_probe35 = function()
  sp35_install()
  local O = SUMMON.obs35
  if O then sp35_manager_census(O.log) end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe35.txt", text) then error("could not write summon_probe35.txt") end
  return "summon_probe35: " .. tostring(O and O.calls or 0) ..
    " calls seen, variants tried " .. tostring(O and O.done or false)
end


end
do
---------------------------------------------------------------- v1.89.46: summon probe step 36
-- Step 35 cracked the lookup: getTable(System.Guid) - the
-- GUID alone - returns the live app.GenerateTable. Its
-- anatomy: _InitSetDatas (an ARRAY of set data), plus
-- _EnemySetInfo / _NpcSetInfo / _GimmickSetInfo /
-- _StrayPawnSetInfo holding the rows. The manager also
-- exposes the whole registry (_TableIDtoTableIndex,
-- _TableNameToTableArray) and the ID/container/controller
-- pools. Step 36 reads one live table's guts in-hook: the
-- first InitialSetData entries, the EnemySetInfo's fields
-- and row-flavored methods, and the first row entries -
-- above all, which field on a row carries the character.
-- Read-only; the row-swap fire comes after this map.
local function sp36_install()
  if SUMMON.obs36 then return end
  local O = { hist = {}, done = false, calls = 0 }
  SUMMON.obs36 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe36.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe36 (bridge 1.89.67) == live table anatomy")
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end
  local function dump_fields(obj, label, maxn)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local otd = try(function() return obj:get_type_definition() end)
    local fields = otd and try(function() return otd:get_fields() end)
    L("  " .. label .. " [" ..
      tostring(otd and try(function() return otd:get_full_name() end)) .. "]")
    if not fields then return end
    local n = 0
    for _, f in ipairs(fields) do
      if n >= (maxn or 36) then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        n = n + 1
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          L("    " .. fn .. " = " .. tostring(v))
        else
          L("    " .. fn .. " = <obj> " .. tostring(v))
        end
      end
    end
  end
  O.dump_fields, O.arr_len, O.arr_get = dump_fields, arr_len, arr_get
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      L("[captured natural Monster container - table anatomy]")
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = gm and tid and
        try(function() return gm:call("getTable", tid) end)
      if not tbl then
        L("getTable(tableID) returned nil this time")
        return
      end
      local isds = try(function() return tbl:get_field("_InitSetDatas") end)
      L("InitSetDatas length: " .. tostring(arr_len(isds)))
      for i = 0, 2 do
        local isd = arr_get(isds, i)
        if isd then dump_fields(isd, "InitSetDatas[" .. i .. "]", 16) end
      end
      local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
      dump_fields(esi, "EnemySetInfo", 30)
      local esitd = esi and try(function() return esi:get_type_definition() end)
      local ms = esitd and try(function() return esitd:get_methods() end)
      local hits = {}
      for _, mm in ipairs(ms or {}) do
        local mn = try(function() return mm:get_name() end)
        if mn and (mn:find("Row") or mn:find("Data") or mn:find("List")) then
          hits[#hits + 1] = mn
        end
      end
      L("  EnemySetInfo data methods: " .. table.concat(hits, ", "))
      -- Whatever collection the set info holds, dump row 0.
      local etd = esitd
      local efields = etd and try(function() return etd:get_fields() end)
      for _, f in ipairs(efields or {}) do
        local fn = try(function() return f:get_name() end)
        if fn and not try(function() return f:is_static() end) then
          local v = try(function() return esi:get_field(fn) end)
          local ln = arr_len(v)
          if ln and ln > 0 then
            L("  collection " .. fn .. " length " .. ln)
            local row = arr_get(v, 0)
            dump_fields(row, "row[0] via " .. fn, 40)
          end
        end
      end
      local gtd = try(function() return tbl:get_type_definition() end)
      local gms = gtd and try(function() return gtd:get_methods() end)
      local ghits = {}
      for _, mm in ipairs(gms or {}) do
        local mn = try(function() return mm:get_name() end)
        if mn and (mn:find("Request") or mn:find("Generate") or
                   mn:find("Regenerate") or mn:find("Reload")) then
          ghits[#ghits + 1] = mn
        end
      end
      L("  GenerateTable generate methods: " .. table.concat(ghits, ", "))
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies, then press the probe again")
end

COMMANDS.summon_probe36 = function()
  sp36_install()
  local O = SUMMON.obs36
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe36.txt", text) then error("could not write summon_probe36.txt") end
  return "summon_probe36: " .. tostring(O and O.calls or 0) ..
    " calls seen, anatomy read " .. tostring(O and O.done or false)
end


end
do
---------------------------------------------------------------- v1.89.47: summon probe step 37
-- Step 36 flaked: getTable(tableID) returned nil for that
-- capture, though step 35's identical call worked. The
-- lookup evidently does not resolve every live container's
-- table (unregistered, NRD, or not-yet-registered tables).
-- Step 37 decouples the anatomy from that race: it scans
-- the manager's own table registry array
-- (<TableNameToTableArray>) directly at command time and
-- dumps the first table that actually has enemy rows -
-- InitSetDatas, EnemySetInfo, row[0], generate methods.
-- The hook stays on as a side-channel, mapping which
-- natural TableID GUIDs getTable resolves and which it
-- does not. Read-only throughout.
local function sp37_registry_scan(L)
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  if not gm then
    L("GenerateManager singleton missing")
    return
  end
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_length") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
  end
  local function dump_fields(obj, label, maxn)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local otd = try(function() return obj:get_type_definition() end)
    local fields = otd and try(function() return otd:get_fields() end)
    L("  " .. label .. " [" ..
      tostring(otd and try(function() return otd:get_full_name() end)) .. "]")
    if not fields then return end
    local n = 0
    for _, f in ipairs(fields) do
      if n >= (maxn or 36) then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        n = n + 1
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          L("    " .. fn .. " = " .. tostring(v))
        else
          L("    " .. fn .. " = <obj> " .. tostring(v))
        end
      end
    end
  end
  local arr = try(function() return gm:get_field("<TableNameToTableArray>k__BackingField") end)
  local n = arr_len(arr)
  L("registry <TableNameToTableArray> length: " .. tostring(n))
  if not (arr and n) then return end
  local dumped = 0
  for i = 0, n - 1 do
    if dumped >= 1 then break end
    local tbl = arr_get(arr, i)
    if tbl then
      local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
      if esi then
        -- Find a collection on the set info with rows.
        local etd = try(function() return esi:get_type_definition() end)
        local efields = etd and try(function() return etd:get_fields() end)
        local rowfield, rowcount = nil, 0
        for _, f in ipairs(efields or {}) do
          local fn = try(function() return f:get_name() end)
          if fn and not try(function() return f:is_static() end) then
            local v = try(function() return esi:get_field(fn) end)
            local ln = arr_len(v)
            if ln and ln > rowcount then
              rowfield, rowcount = fn, ln
            end
          end
        end
        if rowfield then
          dumped = dumped + 1
          L("[registry table #" .. i .. " - has enemy rows]")
          dump_fields(tbl, "GenerateTable", 12)
          local isds = try(function() return tbl:get_field("_InitSetDatas") end)
          L("  InitSetDatas length: " .. tostring(arr_len(isds)))
          for j = 0, 1 do
            local isd = arr_get(isds, j)
            if isd then dump_fields(isd, "InitSetDatas[" .. j .. "]", 16) end
          end
          dump_fields(esi, "EnemySetInfo", 30)
          L("  row collection: " .. rowfield .. " length " .. rowcount)
          local coll = try(function() return esi:get_field(rowfield) end)
          local row = arr_get(coll, 0)
          dump_fields(row, "row[0]", 44)
          local gtd = try(function() return tbl:get_type_definition() end)
          local gms = gtd and try(function() return gtd:get_methods() end)
          local ghits = {}
          for _, mm in ipairs(gms or {}) do
            local mn = try(function() return mm:get_name() end)
            if mn and (mn:find("Request") or mn:find("Generate") or
                       mn:find("Regenerate") or mn:find("Reload")) then
              ghits[#ghits + 1] = mn
            end
          end
          L("  GenerateTable generate methods: " .. table.concat(ghits, ", "))
        end
      end
    end
  end
  if dumped == 0 then L("no registry table with enemy rows found") end
end

local function sp37_install()
  if SUMMON.obs37 then return end
  local O = { hist = {}, seen = {}, tried = 0, calls = 0 }
  SUMMON.obs37 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe37.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe37 (bridge 1.89.67) == registry scan + GUID resolution map")
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.tried >= 6 then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      if not tid then return end
      local key = tostring(try(function() return tid:call("ToString") end))
      if O.seen[key] then return end
      O.seen[key] = true
      O.tried = O.tried + 1
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = gm and try(function() return gm:call("getTable", tid) end)
      L("guid " .. key .. " -> getTable: " .. (tbl and "TABLE" or "nil"))
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok))
end

COMMANDS.summon_probe37 = function()
  sp37_install()
  local O = SUMMON.obs37
  if O then sp37_registry_scan(O.log) end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe37.txt", text) then error("could not write summon_probe37.txt") end
  return "summon_probe37: registry scanned; " ..
    tostring(O and O.tried or 0) .. " natural GUIDs mapped"
end


end
do
---------------------------------------------------------------- v1.89.48: summon probe step 38
-- Step 37's GUID map: 4 of 6 natural table GUIDs resolve
-- through getTable (the other 2 are some other table kind).
-- Its registry-array scan failed separately - the array
-- length could not be read through the usual accessors.
-- Step 38 merges the two: inside the hook, for each
-- distinct natural GUID, if getTable resolves, dump that
-- table's full anatomy immediately (while everything is
-- alive): GenerateTable fields, InitSetDatas entries,
-- EnemySetInfo fields, the first row, and the table's
-- generate/request method names. The array helpers try a
-- broader battery of accessors this time. Read-only.
local function sp38_install()
  if SUMMON.obs38 then return end
  local O = { hist = {}, seen = {}, anatomy = false, calls = 0 }
  SUMMON.obs38 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1400 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe38.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe38 (bridge 1.89.67) == anatomy at a resolving table")
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_length") end)
      or try(function() return a:call("get_Size") end)
      or try(function() return a:call("size") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
      or try(function() return a:call("get_element", i) end)
  end
  local function dump_fields(obj, label, maxn)
    if not obj then
      L("  " .. label .. ": (nil)")
      return
    end
    local otd = try(function() return obj:get_type_definition() end)
    local fields = otd and try(function() return otd:get_fields() end)
    L("  " .. label .. " [" ..
      tostring(otd and try(function() return otd:get_full_name() end)) .. "]")
    if not fields then return end
    local n = 0
    for _, f in ipairs(fields) do
      if n >= (maxn or 36) then break end
      local fn = try(function() return f:get_name() end)
      if fn and not try(function() return f:is_static() end) then
        n = n + 1
        local v = try(function() return obj:get_field(fn) end)
        local tv = type(v)
        if v == nil or tv == "number" or tv == "boolean" or tv == "string" then
          L("    " .. fn .. " = " .. tostring(v))
        else
          L("    " .. fn .. " = <obj> " .. tostring(v))
        end
      end
    end
  end
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.anatomy then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      if not tid then return end
      local key = tostring(try(function() return tid:call("ToString") end))
      if O.seen[key] then return end
      O.seen[key] = true
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = gm and try(function() return gm:call("getTable", tid) end)
      L("guid " .. key .. " -> getTable: " .. (tbl and "TABLE" or "nil"))
      if not tbl then return end
      O.anatomy = true
      L("[anatomy of the resolving table]")
      dump_fields(tbl, "GenerateTable", 12)
      local isds = try(function() return tbl:get_field("_InitSetDatas") end)
      L("  InitSetDatas length: " .. tostring(arr_len(isds)))
      for j = 0, 1 do
        local isd = arr_get(isds, j)
        if isd then dump_fields(isd, "InitSetDatas[" .. j .. "]", 16) end
      end
      local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
      dump_fields(esi, "EnemySetInfo", 30)
      local etd = esi and try(function() return esi:get_type_definition() end)
      local efields = etd and try(function() return etd:get_fields() end)
      for _, f in ipairs(efields or {}) do
        local fn = try(function() return f:get_name() end)
        if fn and not try(function() return f:is_static() end) then
          local v = try(function() return esi:get_field(fn) end)
          local ln = arr_len(v)
          if ln and ln > 0 then
            L("  collection " .. fn .. " length " .. ln)
            dump_fields(arr_get(v, 0), "row[0] via " .. fn, 44)
          end
        end
      end
      local gtd = try(function() return tbl:get_type_definition() end)
      local gms = gtd and try(function() return gtd:get_methods() end)
      local ghits = {}
      for _, mm in ipairs(gms or {}) do
        local mn = try(function() return mm:get_name() end)
        if mn and (mn:find("Request") or mn:find("Generate") or
                   mn:find("Regenerate") or mn:find("Reload") or
                   mn:find("Row") or mn:find("Set")) then
          ghits[#ghits + 1] = mn
        end
      end
      L("  GenerateTable methods: " .. table.concat(ghits, ", "))
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies, then press the probe again")
end

COMMANDS.summon_probe38 = function()
  sp38_install()
  local O = SUMMON.obs38
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe38.txt", text) then error("could not write summon_probe38.txt") end
  return "summon_probe38: " .. tostring(O and O.calls or 0) ..
    " calls seen, anatomy read " .. tostring(O and O.anatomy or false)
end


end
do
---------------------------------------------------------------- v1.89.49: summon probe step 39
-- Step 38 mapped the table: GenerateTable._EnemySetInfo
-- ._BasicRowDatas[] of app.GenerateRowData - _CharaID (int),
-- _Group, _AppearRate, _ManualPos/Angle/Scale, wander flags,
-- and each row owns a prebuilt _Container. Step 39 is the
-- swap itself, in three stages:
--   ARM (hook): a natural Monster container is matched by
--     pointer to the row that owns it in its (resolving)
--     table; the table GUID, row index and original _CharaID
--     are recorded as plain data.
--   SWAP (next press): the table is re-fetched fresh, the
--     row's _CharaID is rewritten to ch255000_00, its
--     _ManualPos and the container's context position are
--     set to the player's ground position, then regeneration
--     is attempted (requestGenerateTable argument battery,
--     first non-throwing form wins; fallback: requestGenerate
--     on the row's own container with flags 8).
--   RESTORE (press after swap): original _CharaID written
--     back and regeneration attempted again.
-- Table data is runtime state (rebuilt from area data), and
-- the original value is logged before any edit.
local function sp39_install()
  if SUMMON.obs39 then return end
  local O = { hist = {}, calls = 0, arm = nil, swapped = false }
  SUMMON.obs39 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 600 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe39.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe39 (bridge 1.89.67) == the row swap")
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_length") end)
      or try(function() return a:call("get_Size") end)
      or try(function() return a:call("size") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
      or try(function() return a:call("get_element", i) end)
  end
  O.arr_len, O.arr_get = arr_len, arr_get
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.arm then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      if not tid then return end
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = gm and try(function() return gm:call("getTable", tid) end)
      if not tbl then return end
      local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
      local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
      local n = arr_len(rows)
      if not n then return end
      for i = 0, n - 1 do
        local row = arr_get(rows, i)
        local rc = row and try(function() return row:get_field("_Container") end)
        if rc and tostring(rc) == tostring(cont) then
          O.arm = {
            tid = tid,
            guid = tostring(try(function() return tid:call("ToString") end)),
            rowIndex = i,
            origChara = try(function() return row:get_field("_CharaID") end),
          }
          L("ARMED: table " .. O.arm.guid .. " row " .. i ..
            " origChara=" .. tostring(O.arm.origChara) ..
            " - press the probe again to SWAP")
          return
        end
      end
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies until ARMED, then press again")
end

local function sp39_regen(L, gm, tbl, tid)
  local forms = {
    { "requestGenerateTable(table)", function() return gm:call("requestGenerateTable", tbl) end },
    { "requestGenerateTable(tableID)", function() return gm:call("requestGenerateTable", tid) end },
    { "requestGenerateTable(tableID, Monster)", function() return gm:call("requestGenerateTable", tid, 3) end },
  }
  for _, f in ipairs(forms) do
    local ok, res = pcall(f[2])
    L("  " .. f[1] .. " ok=" .. tostring(ok) .. " -> " .. tostring(res) ..
      (ok and "" or (" err=" .. tostring(res))))
    if ok then return true end
  end
  return false
end

local function sp39_swap_or_restore()
  local O = SUMMON.obs39
  local L = O.log
  local arm = O.arm
  if not arm then return "not armed yet" end
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local tbl = gm and try(function() return gm:call("getTable", arm.tid) end)
  if not tbl then
    L("table no longer resolves (area changed?) - re-arm by walking")
    O.arm = nil
    return "table gone"
  end
  local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
  local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
  local row = rows and O.arr_get(rows, arm.rowIndex)
  if not row then
    L("row not found at recorded index")
    return "row missing"
  end
  local cur = try(function() return row:get_field("_CharaID") end)
  if not O.swapped then
    if cur ~= arm.origChara then
      L("row chara changed since arming (" .. tostring(cur) ..
        " vs " .. tostring(arm.origChara) .. ") - refusing to swap")
      return "row drifted"
    end
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local boss = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        boss = try(function() return f:get_data(nil) end)
        break
      end
    end
    local bossInt = boss and tonumber(tostring(boss))
    L("boss ch255000_00 int = " .. tostring(bossInt))
    if not bossInt then return "boss id unresolved" end
    local player = cm and try(function() return cm:call("get_ManualPlayer") end)
    local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
    pcall(function() row:set_field("_CharaID", bossInt) end)
    L("row _CharaID now = " ..
      tostring(try(function() return row:get_field("_CharaID") end)))
    if gpos then
      pcall(function() row:set_field("_ManualPos", gpos) end)
      local rc = try(function() return row:get_field("_Container") end)
      local rci = rc and try(function() return rc:call("get_CommonInfo") end)
      if rci then pcall(function() rci:call("setContextPosition", gpos) end) end
      L("row _ManualPos + container context set to your ground position")
      if rc then
        local okF, resF = pcall(function()
          local cb = function() end
          return gm:call("requestGenerate", rc, 8, false, false, cb, cb)
        end)
        L("fallback fire requestGenerate(row container, 8) ok=" ..
          tostring(okF) .. " -> " .. tostring(resF))
      end
    end
    sp39_regen(L, gm, tbl, arm.tid)
    O.swapped = true
    L("SWAPPED - look around: a Medusa should appear at your feet" ..
      " (or at the row's home). Press again to RESTORE the row.")
    return "swapped"
  else
    pcall(function() row:set_field("_CharaID", arm.origChara) end)
    L("row _CharaID restored to " ..
      tostring(try(function() return row:get_field("_CharaID") end)))
    sp39_regen(L, gm, tbl, arm.tid)
    O.swapped = false
    L("RESTORED")
    return "restored"
  end
end

COMMANDS.summon_probe39 = function()
  sp39_install()
  local O = SUMMON.obs39
  local tag = "armed=" .. tostring(O and O.arm ~= nil)
  if O and O.arm then tag = sp39_swap_or_restore() end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe39.txt", text) then error("could not write summon_probe39.txt") end
  return "summon_probe39: " .. tag
end


end
do
---------------------------------------------------------------- v1.89.50: summon probe step 40
-- Step 39's arm never fired in the field and logged nothing
-- about its attempts, so the failing joint was invisible.
-- Likely suspect: the row's _Container is a master copy and
-- the pipeline presents pooled clones to requestGenerate,
-- so pointer equality never holds. Step 40 keeps the same
-- arm/swap/restore stages but (a) logs the first 8 capture
-- attempts in full (GUID, getTable result, every row's
-- container pointer and _ManualPos, the presented
-- container's pointer and _InitialPosition), and (b) arms
-- on a POSITIONAL match when the pointer match fails: a
-- row whose _ManualPos equals the presented container's
-- _InitialPosition (within 0.5m) is that container's row.
local function sp40_install()
  if SUMMON.obs40 then return end
  local O = { hist = {}, calls = 0, arm = nil, swapped = false }
  SUMMON.obs40 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 600 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe40.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe40 (bridge 1.89.67) == the row swap")
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_length") end)
      or try(function() return a:call("get_Size") end)
      or try(function() return a:call("size") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
      or try(function() return a:call("get_element", i) end)
  end
  O.arr_len, O.arr_get = arr_len, arr_get
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.arm then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      if not tid then return end
      local guid = tostring(try(function() return tid:call("ToString") end))
      if O.seenG and O.seenG[guid] then return end
      O.seenG = O.seenG or {}
      O.seenG[guid] = true
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = gm and try(function() return gm:call("getTable", tid) end)
      local ipos = ci and try(function() return ci:get_field("_InitialPosition") end)
      local ix = ipos and try(function() return ipos:get_field("x") end)
      local iy = ipos and try(function() return ipos:get_field("y") end)
      local iz = ipos and try(function() return ipos:get_field("z") end)
      L("[attempt] guid " .. guid .. " getTable=" .. (tbl and "TABLE" or "nil") ..
        " cont=" .. tostring(cont) ..
        " initPos=(" .. tostring(ix) .. "," .. tostring(iy) .. "," ..
        tostring(iz) .. ")")
      if not tbl then return end
      local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
      local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
      local n = arr_len(rows)
      if not n then
        L("  rows unreadable")
        return
      end
      for i = 0, n - 1 do
        local row = arr_get(rows, i)
        local rc = row and try(function() return row:get_field("_Container") end)
        local mp = row and try(function() return row:get_field("_ManualPos") end)
        local mx = mp and try(function() return mp:get_field("x") end)
        local my = mp and try(function() return mp:get_field("y") end)
        local mz = mp and try(function() return mp:get_field("z") end)
        L("  row " .. i .. " container=" .. tostring(rc) ..
          " manualPos=(" .. tostring(mx) .. "," .. tostring(my) .. "," ..
          tostring(mz) .. ") chara=" ..
          tostring(row and try(function() return row:get_field("_CharaID") end)))
        if rc and tostring(rc) == tostring(cont) then
          O.arm = {
            tid = tid, guid = guid, rowIndex = i,
            origChara = try(function() return row:get_field("_CharaID") end),
          }
          L("ARMED by pointer: table " .. guid .. " row " .. i ..
            " origChara=" .. tostring(O.arm.origChara) ..
            " - press the probe again to SWAP")
          return
        end
        if ix and mx and math.abs(ix - mx) < 0.5 and
           math.abs(iy - my) < 0.5 and math.abs(iz - mz) < 0.5 then
          O.arm = {
            tid = tid, guid = guid, rowIndex = i,
            origChara = try(function() return row:get_field("_CharaID") end),
          }
          L("ARMED by position: table " .. guid .. " row " .. i ..
            " origChara=" .. tostring(O.arm.origChara) ..
            " - press the probe again to SWAP")
          return
        end
      end
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - walk into fresh enemies until ARMED, then press again")
end

local function sp40_regen(L, gm, tbl, tid)
  local forms = {
    { "requestGenerateTable(table)", function() return gm:call("requestGenerateTable", tbl) end },
    { "requestGenerateTable(tableID)", function() return gm:call("requestGenerateTable", tid) end },
    { "requestGenerateTable(tableID, Monster)", function() return gm:call("requestGenerateTable", tid, 3) end },
  }
  for _, f in ipairs(forms) do
    local ok, res = pcall(f[2])
    L("  " .. f[1] .. " ok=" .. tostring(ok) .. " -> " .. tostring(res) ..
      (ok and "" or (" err=" .. tostring(res))))
    if ok then return true end
  end
  return false
end

local function sp40_swap_or_restore()
  local O = SUMMON.obs40
  local L = O.log
  local arm = O.arm
  if not arm then return "not armed yet" end
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local tbl = gm and try(function() return gm:call("getTable", arm.tid) end)
  if not tbl then
    L("table no longer resolves (area changed?) - re-arm by walking")
    O.arm = nil
    return "table gone"
  end
  local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
  local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
  local row = rows and O.arr_get(rows, arm.rowIndex)
  if not row then
    L("row not found at recorded index")
    return "row missing"
  end
  local cur = try(function() return row:get_field("_CharaID") end)
  if not O.swapped then
    if cur ~= arm.origChara then
      L("row chara changed since arming (" .. tostring(cur) ..
        " vs " .. tostring(arm.origChara) .. ") - refusing to swap")
      return "row drifted"
    end
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local boss = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        boss = try(function() return f:get_data(nil) end)
        break
      end
    end
    local bossInt = boss and tonumber(tostring(boss))
    L("boss ch255000_00 int = " .. tostring(bossInt))
    if not bossInt then return "boss id unresolved" end
    local player = cm and try(function() return cm:call("get_ManualPlayer") end)
    local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
    pcall(function() row:set_field("_CharaID", bossInt) end)
    L("row _CharaID now = " ..
      tostring(try(function() return row:get_field("_CharaID") end)))
    if gpos then
      pcall(function() row:set_field("_ManualPos", gpos) end)
      local rc = try(function() return row:get_field("_Container") end)
      local rci = rc and try(function() return rc:call("get_CommonInfo") end)
      if rci then pcall(function() rci:call("setContextPosition", gpos) end) end
      L("row _ManualPos + container context set to your ground position")
      if rc then
        local okF, resF = pcall(function()
          local cb = function() end
          return gm:call("requestGenerate", rc, 8, false, false, cb, cb)
        end)
        L("fallback fire requestGenerate(row container, 8) ok=" ..
          tostring(okF) .. " -> " .. tostring(resF))
      end
    end
    sp40_regen(L, gm, tbl, arm.tid)
    O.swapped = true
    L("SWAPPED - look around: a Medusa should appear at your feet" ..
      " (or at the row's home). Press again to RESTORE the row.")
    return "swapped"
  else
    pcall(function() row:set_field("_CharaID", arm.origChara) end)
    L("row _CharaID restored to " ..
      tostring(try(function() return row:get_field("_CharaID") end)))
    sp40_regen(L, gm, tbl, arm.tid)
    O.swapped = false
    L("RESTORED")
    return "restored"
  end
end

COMMANDS.summon_probe40 = function()
  sp40_install()
  local O = SUMMON.obs40
  local tag = "armed=" .. tostring(O and O.arm ~= nil)
  if O and O.arm then tag = sp40_swap_or_restore() end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe40.txt", text) then error("could not write summon_probe40.txt") end
  return "summon_probe40: " .. tag
end


end
do
---------------------------------------------------------------- v1.89.51: summon probe step 41
-- Step 40's swap edited the row and requestGenerateTable
-- accepted - and nothing appeared. The gaps it exposed:
-- (a) the swap happened a press AFTER the group presented,
-- by which time its containers were already cloned and
-- quite possibly already generated; (b) only the row data
-- was edited, while the row's master container keeps its
-- baked character ID; (c) the arm itself was a zero-position
-- fluke. Step 41 removes the gap: the swap executes INSIDE
-- the hook, at the moment a matching group first presents.
-- A table qualifies when it resolves via getTable AND one
-- of its rows carries the presented container's character.
-- On the first qualifying table it: rewrites EVERY row's
-- _CharaID to ch255000_00 (originals logged), stamps each
-- row's master container with a boss ObjectID (the manager's
-- getIdWrapper path, field-set fallback) and the player's
-- ground position, fires requestGenerate once on the first
-- master, then calls requestGenerateTable. One-shot per
-- session. The next press RESTORES rows and master IDs.
local function sp41_install()
  if SUMMON.obs41 then return end
  local O = { hist = {}, calls = 0, done = false, seenG = {}, saved = nil }
  SUMMON.obs41 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 800 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe41.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe41 (bridge 1.89.67) == in-hook whole-table swap")
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_length") end)
      or try(function() return a:call("get_Size") end)
      or try(function() return a:call("size") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
      or try(function() return a:call("get_element", i) end)
  end
  O.arr_len, O.arr_get = arr_len, arr_get
  local function boss_enum()
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        return try(function() return f:get_data(nil) end)
      end
    end
    return nil
  end
  O.boss_enum = boss_enum
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      local oid = ci and try(function() return ci:get_field("_ObjectID") end)
      local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
      local presInt = sel and tonumber(tostring(sel))
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      if not (tid and presInt) then return end
      local guid = tostring(try(function() return tid:call("ToString") end))
      if O.seenG[guid] then return end
      O.seenG[guid] = true
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = gm and try(function() return gm:call("getTable", tid) end)
      L("[attempt] guid " .. guid .. " presented chara=" .. presInt ..
        " getTable=" .. (tbl and "TABLE" or "nil"))
      if not tbl then return end
      local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
      local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
      local n = arr_len(rows)
      if not n then return end
      local match = false
      for i = 0, n - 1 do
        local row = arr_get(rows, i)
        if row and try(function() return row:get_field("_CharaID") end) == presInt then
          match = true
          break
        end
      end
      L("  rows=" .. n .. " presented-chara match=" .. tostring(match))
      if not match then return end
      -- QUALIFIES: execute the swap right here.
      local boss = boss_enum()
      local bossInt = boss and tonumber(tostring(boss))
      if not bossInt then
        L("  boss id unresolved - aborting")
        return
      end
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local origs = {}
      local wrapper = gm and
        try(function() return gm:call("getIdWrapper", boss) end)
      L("  boss wrapper from getIdWrapper: " .. tostring(wrapper))
      for i = 0, n - 1 do
        local row = arr_get(rows, i)
        if row then
          origs[i] = try(function() return row:get_field("_CharaID") end)
          pcall(function() row:set_field("_CharaID", bossInt) end)
          local mc = try(function() return row:get_field("_Container") end)
          local mci = mc and try(function() return mc:call("get_CommonInfo") end)
          if mci then
            local stamped = false
            if wrapper then
              stamped = pcall(function()
                mci:call("set_ObjectID", sdk.to_ptr(wrapper))
              end)
            end
            if not stamped then
              local moi = try(function() return mci:get_field("_ObjectID") end)
              if moi then
                pcall(function() moi:set_field("_SelectedCharacterID", boss) end)
              end
            end
            if gpos then pcall(function() mci:call("setContextPosition", gpos) end) end
          end
          L("  row " .. i .. ": chara " .. tostring(origs[i]) .. " -> " ..
            tostring(try(function() return row:get_field("_CharaID") end)))
        end
      end
      local row0 = arr_get(rows, 0)
      local mc0 = row0 and try(function() return row0:get_field("_Container") end)
      if mc0 then
        local okF, resF = pcall(function()
          local cb = function() end
          return gm:call("requestGenerate", mc0, 8, false, false, cb, cb)
        end)
        L("  fire requestGenerate(master row 0, 8) ok=" .. tostring(okF) ..
          " -> " .. tostring(resF))
      end
      local okR, resR = pcall(function()
        return gm:call("requestGenerateTable", tbl)
      end)
      L("  requestGenerateTable(table) ok=" .. tostring(okR) ..
        " -> " .. tostring(resR))
      O.saved = { tid = tid, guid = guid, origs = origs, n = n }
      O.done = true
      L("SWAPPED in-hook on table " .. guid ..
        " - look for the Medusa at your feet / in this group." ..
        " Press the probe again to RESTORE.")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - LIVE: the first matching enemy group you approach gets swapped")
end

local function sp41_restore()
  local O = SUMMON.obs41
  local L = O.log
  local sv = O.saved
  if not sv then return "nothing to restore" end
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local tbl = gm and try(function() return gm:call("getTable", sv.tid) end)
  if not tbl then
    L("restore: table no longer resolves (area changed - runtime state resets anyway)")
    O.saved = nil
    return "table gone"
  end
  local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
  local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local function enum_by_int(want)
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) then
        local d = try(function() return f:get_data(nil) end)
        if d and tonumber(tostring(d)) == want then return d end
      end
    end
    return nil
  end
  for i = 0, sv.n - 1 do
    local row = rows and O.arr_get(rows, i)
    local orig = sv.origs[i]
    if row and orig then
      pcall(function() row:set_field("_CharaID", orig) end)
      local oe = enum_by_int(orig)
      local mc = try(function() return row:get_field("_Container") end)
      local mci = mc and try(function() return mc:call("get_CommonInfo") end)
      if mci and oe then
        local w = try(function() return gm:call("getIdWrapper", oe) end)
        if w then
          pcall(function() mci:call("set_ObjectID", sdk.to_ptr(w)) end)
        end
      end
      L("  row " .. i .. " restored to " ..
        tostring(try(function() return row:get_field("_CharaID") end)))
    end
  end
  pcall(function() return gm:call("requestGenerateTable", tbl) end)
  O.saved = nil
  L("RESTORED table " .. sv.guid)
  return "restored"
end

COMMANDS.summon_probe41 = function()
  sp41_install()
  local O = SUMMON.obs41
  local tag = "waiting for a matching group"
  if O and O.done then tag = sp41_restore() end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe41.txt", text) then error("could not write summon_probe41.txt") end
  return "summon_probe41: " .. tag
end


end
do
---------------------------------------------------------------- v1.89.52: summon probe step 42
-- Step 41's swap was mechanically perfect - whole-table
-- row rewrite verified, master containers stamped with the
-- real boss wrapper, both regeneration calls accepted -
-- and still nothing appeared. Everything measurable did
-- its job except the world. The remaining explanation:
-- edits to a registered table only take effect when the
-- area RE-REGISTERS it (unload + reload), re-cloning fresh
-- containers from the edited masters. Step 42 is that
-- reload test, kept clean: the in-hook swap edits rows and
-- stamps masters and does NOTHING else (no fires, no regen
-- calls to muddy attribution). The user then leaves until
-- the area unloads (a ferrystone trip guarantees it) and
-- returns: if the group respawns as Medusas, edited masters
-- are what re-registration clones from. Press flow fixed
-- too: after the swap, one press only REPORTS (step 41's
-- copy press silently restored and burned the window);
-- the press after that restores.
local function sp42_install()
  if SUMMON.obs42 then return end
  local O = { hist = {}, calls = 0, done = false, seenG = {}, saved = nil }
  SUMMON.obs42 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 800 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe42.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe42 (bridge 1.89.67) == in-hook whole-table swap")
  local function arr_len(a)
    if not a then return nil end
    return try(function() return a:call("get_Length") end)
      or try(function() return a:call("get_Count") end)
      or try(function() return a:call("get_length") end)
      or try(function() return a:call("get_Size") end)
      or try(function() return a:call("size") end)
  end
  local function arr_get(a, i)
    if not a then return nil end
    return try(function() return a:call("get_Item", i) end)
      or try(function() return a:call("GetValue", i) end)
      or try(function() return a:call("get_element", i) end)
  end
  O.arr_len, O.arr_get = arr_len, arr_get
  local function boss_enum()
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        return try(function() return f:get_data(nil) end)
      end
    end
    return nil
  end
  O.boss_enum = boss_enum
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      local oid = ci and try(function() return ci:get_field("_ObjectID") end)
      local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
      local presInt = sel and tonumber(tostring(sel))
      local rid = ci and try(function() return ci:get_field("_RequestID") end)
      local genID = rid and try(function() return rid:get_field("_GenID") end)
      local tid = genID and try(function() return genID:get_field("_TableID") end)
      if not (tid and presInt) then return end
      local guid = tostring(try(function() return tid:call("ToString") end))
      if O.seenG[guid] then return end
      O.seenG[guid] = true
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local tbl = gm and try(function() return gm:call("getTable", tid) end)
      L("[attempt] guid " .. guid .. " presented chara=" .. presInt ..
        " getTable=" .. (tbl and "TABLE" or "nil"))
      if not tbl then return end
      local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
      local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
      local n = arr_len(rows)
      if not n then return end
      local match = false
      for i = 0, n - 1 do
        local row = arr_get(rows, i)
        if row and try(function() return row:get_field("_CharaID") end) == presInt then
          match = true
          break
        end
      end
      L("  rows=" .. n .. " presented-chara match=" .. tostring(match))
      if not match then return end
      -- QUALIFIES: execute the swap right here.
      local boss = boss_enum()
      local bossInt = boss and tonumber(tostring(boss))
      if not bossInt then
        L("  boss id unresolved - aborting")
        return
      end
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local origs = {}
      local wrapper = gm and
        try(function() return gm:call("getIdWrapper", boss) end)
      L("  boss wrapper from getIdWrapper: " .. tostring(wrapper))
      for i = 0, n - 1 do
        local row = arr_get(rows, i)
        if row then
          origs[i] = try(function() return row:get_field("_CharaID") end)
          pcall(function() row:set_field("_CharaID", bossInt) end)
          local mc = try(function() return row:get_field("_Container") end)
          local mci = mc and try(function() return mc:call("get_CommonInfo") end)
          if mci then
            local stamped = false
            if wrapper then
              stamped = pcall(function()
                mci:call("set_ObjectID", sdk.to_ptr(wrapper))
              end)
            end
            if not stamped then
              local moi = try(function() return mci:get_field("_ObjectID") end)
              if moi then
                pcall(function() moi:set_field("_SelectedCharacterID", boss) end)
              end
            end
            if gpos then pcall(function() mci:call("setContextPosition", gpos) end) end
          end
          L("  row " .. i .. ": chara " .. tostring(origs[i]) .. " -> " ..
            tostring(try(function() return row:get_field("_CharaID") end)))
        end
      end
      O.saved = { tid = tid, guid = guid, origs = origs, n = n }
      O.done = true
      L("SWAPPED in-hook on table " .. guid ..
        " - now LEAVE until the area unloads (ferrystone away and back)," ..
        " return, and look at this group. Press reports, press again restores.")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - LIVE: the first matching enemy group you approach gets swapped")
end

local function sp42_restore()
  local O = SUMMON.obs42
  local L = O.log
  local sv = O.saved
  if not sv then return "nothing to restore" end
  local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
  local tbl = gm and try(function() return gm:call("getTable", sv.tid) end)
  if not tbl then
    L("restore: table no longer resolves (area changed - runtime state resets anyway)")
    O.saved = nil
    return "table gone"
  end
  local esi = try(function() return tbl:get_field("_EnemySetInfo") end)
  local rows = esi and try(function() return esi:get_field("_BasicRowDatas") end)
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local function enum_by_int(want)
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) then
        local d = try(function() return f:get_data(nil) end)
        if d and tonumber(tostring(d)) == want then return d end
      end
    end
    return nil
  end
  for i = 0, sv.n - 1 do
    local row = rows and O.arr_get(rows, i)
    local orig = sv.origs[i]
    if row and orig then
      pcall(function() row:set_field("_CharaID", orig) end)
      local oe = enum_by_int(orig)
      local mc = try(function() return row:get_field("_Container") end)
      local mci = mc and try(function() return mc:call("get_CommonInfo") end)
      if mci and oe then
        local w = try(function() return gm:call("getIdWrapper", oe) end)
        if w then
          pcall(function() mci:call("set_ObjectID", sdk.to_ptr(w)) end)
        end
      end
      L("  row " .. i .. " restored to " ..
        tostring(try(function() return row:get_field("_CharaID") end)))
    end
  end
  O.saved = nil
  L("RESTORED table " .. sv.guid)
  return "restored"
end

COMMANDS.summon_probe42 = function()
  sp42_install()
  local O = SUMMON.obs42
  local tag = "waiting for a matching group"
  if O and O.done then
    if not O.reported then
      O.reported = true
      tag = "swapped on table " .. tostring(O.saved and O.saved.guid) ..
        " - status only, next press restores"
    else
      tag = sp42_restore()
    end
  end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe42.txt", text) then error("could not write summon_probe42.txt") end
  return "summon_probe42: " .. tag
end


end
do
---------------------------------------------------------------- v1.89.53: summon probe step 43
-- Step 42 closed the runtime table route: a verified
-- whole-table swap survived a ferrystone round trip and the
-- group still respawned as originals - re-registration does
-- not read the live table objects we can edit. So: stop
-- editing data the pipeline has already consumed, and stop
-- building containers the pipeline never asked for. Ride
-- the pipeline itself. The requestGenerate hook fires
-- BEFORE the game's own call executes, on the actual clone
-- container the game is about to generate - a container
-- with real registration, a real table identity, and a
-- place in the distributor's queue. Step 43 rewrites THAT
-- container in the pre-hook: its ObjectID becomes the
-- boss (manager getIdWrapper + set_ObjectID, the reference
-- mod's mechanism), its context position becomes the
-- player's ground position, and prefab standby is requested
-- for it - then the game's call proceeds untouched and
-- generates whatever the container now says. One-shot: the
-- first Monster container presented after arming. Nothing
-- is fired externally; no table is edited.
local function sp43_install()
  if SUMMON.obs43 then return end
  local O = { hist = {}, calls = 0, done = false }
  SUMMON.obs43 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 400 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe43.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe43 (bridge 1.89.67) == ride the game's generate call")
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      local oid = ci and try(function() return ci:get_field("_ObjectID") end)
      local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
      L("[riding] presented chara=" .. tostring(sel) ..
        " - rewriting this container to the boss")
      local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
      local boss = nil
      for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) and
           try(function() return f:get_name() end) == "ch255000_00" then
          boss = try(function() return f:get_data(nil) end)
          break
        end
      end
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
      local wrapper = gm and boss and
        try(function() return gm:call("getIdWrapper", boss) end)
      L("  boss wrapper: " .. tostring(wrapper))
      local stamped = false
      if wrapper then
        stamped = pcall(function()
          ci:call("set_ObjectID", sdk.to_ptr(wrapper))
        end)
      end
      if not stamped and oid and boss then
        pcall(function() oid:set_field("_SelectedCharacterID", boss) end)
        L("  fallback: _SelectedCharacterID field set directly")
      end
      local sel2 = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
      L("  ObjectID now reads: " .. tostring(sel2) ..
        " (boss int = 3307750390)")
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
      local rot = prc and try(function() return prc:call("get_Rot") end)
      if gpos then pcall(function() ci:call("setContextPosition", gpos) end) end
      if rot then pcall(function() ci:call("setContextAngle", rot) end) end
      if gpos then pcall(function() ci:call("setInitialPosition", gpos) end) end
      L("  context + initial position set to your ground position")
      pcall(function() gm:call("requestStandbyPrefab", cont) end)
      if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
      L("  standby requested - the game's own call now proceeds." ..
        " Watch this spawn: what appears, and does it fight?")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - LIVE: the next Monster spawn presented gets rewritten")
end

COMMANDS.summon_probe43 = function()
  sp43_install()
  local O = SUMMON.obs43
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe43.txt", text) then error("could not write summon_probe43.txt") end
  return "summon_probe43: " .. tostring(O and O.calls or 0) ..
    " calls seen, rewritten " .. tostring(O and O.done or false)
end


end
do
---------------------------------------------------------------- v1.89.54: summon probe step 44
-- Step 43 rode the game's own call and rewrote the
-- presented container - and the read-back exposed the
-- trap: after set_ObjectID, the object ID still read the
-- ORIGINAL character (and part of that read may have been
-- a stale object - the wrapper local was captured before
-- the setter ran). The original monster spawned. So the
-- character at generate time lives somewhere else: the
-- CommonInfo also has a setCharaID setter (recorded back
-- in the step 1-2 recon, never used as the stamp), and
-- the prefab/controller the clone carries was resolved at
-- clone time. Step 44 rides the call again and does the
-- forensics at presentation time: dump every field of the
-- container and its Common/Chara infos whose value equals
-- the presented character or whose type mentions a
-- prefab/controller, stamp via setCharaID AND set_ObjectID
-- with FRESH read-backs, and if a prefab-controller field
-- exists, swap in the boss's controller from the merged
-- catalog - the exact object the reference spawner used.
local function sp44_install()
  if SUMMON.obs44 then return end
  local O = { hist = {}, calls = 0, done = false }
  SUMMON.obs44 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 600 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe44.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe44 (bridge 1.89.67) == find the identity carrier")
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      local oid0 = ci and try(function() return ci:get_field("_ObjectID") end)
      local sel0 = oid0 and try(function() return oid0:get_field("_SelectedCharacterID") end)
      local presInt = sel0 and tonumber(tostring(sel0))
      L("[riding] presented chara=" .. tostring(sel0))
      local function type_name(o)
        local td = o and try(function() return o:get_type_definition() end)
        return td and try(function() return td:get_full_name() end) or "?"
      end
      local function hunt(obj, label)
        if not obj then return end
        local td = try(function() return obj:get_type_definition() end)
        local fields = td and try(function() return td:get_fields() end) or {}
        for _, f in ipairs(fields) do
          local fname = try(function() return f:get_name() end)
          local ftd = try(function() return f:get_type() end)
          local ftname = ftd and try(function() return ftd:get_full_name() end) or ""
          local interesting = fname and (fname:find("refab") or fname:find("hara") or
            fname:find("ontroller") or ftname:find("Prefab") or
            ftname:find("GenerateId") or ftname:find("Character"))
          if interesting then
            local v = try(function() return obj:get_field(fname) end)
            local vs = tostring(v)
            if presInt and tonumber(vs) == nil and v ~= nil and
               type(v) == "userdata" then
              local inner = try(function() return v:get_field("_SelectedCharacterID") end)
              if inner then vs = vs .. " [inner chara=" .. tostring(inner) .. "]" end
            end
            L("  " .. label .. "." .. tostring(fname) .. " : " .. ftname .. " = " .. vs)
          end
        end
      end
      hunt(cont, "container(" .. type_name(cont) .. ")")
      hunt(ci, "common")
      local chi = try(function() return cont:call("get_CharaInfo") end)
      hunt(chi, "charaInfo")
      local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
      local boss = nil
      for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) and
           try(function() return f:get_name() end) == "ch255000_00" then
          boss = try(function() return f:get_data(nil) end)
          break
        end
      end
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      -- Stamp 1: setCharaID on the CommonInfo.
      local okC = pcall(function() ci:call("setCharaID", boss) end)
      local oidA = try(function() return ci:get_field("_ObjectID") end)
      local selA = oidA and try(function() return oidA:get_field("_SelectedCharacterID") end)
      L("  setCharaID ok=" .. tostring(okC) .. " -> ObjectID now " .. tostring(selA))
      -- Stamp 2: set_ObjectID with the manager wrapper; fresh read-back.
      local wrapper = gm and boss and
        try(function() return gm:call("getIdWrapper", boss) end)
      local okO = false
      if wrapper then
        okO = pcall(function() ci:call("set_ObjectID", sdk.to_ptr(wrapper)) end)
      end
      local oidB = try(function() return ci:get_field("_ObjectID") end)
      local selB = oidB and try(function() return oidB:get_field("_SelectedCharacterID") end)
      L("  set_ObjectID ok=" .. tostring(okO) .. " -> ObjectID now " .. tostring(selB))
      -- Boss prefab controller from the merged catalog.
      local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
      local ec = cc and try(function() return cc:get_field("_EnemyCatalog") end)
      local merged = ec and try(function() return ec:get_field("<MergedCatalog>k__BackingField") end)
      local item = merged and boss and
        try(function() return merged:call("get_Item", boss) end)
      local refc = item and try(function() return item:get_field("<RefCounter>k__BackingField") end)
      local bossCtrl = refc and try(function() return refc:call("get_Item") end)
      L("  boss PrefabController from catalog: " .. tostring(bossCtrl))
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
      local rot = prc and try(function() return prc:call("get_Rot") end)
      if gpos then pcall(function() ci:call("setContextPosition", gpos) end) end
      if rot then pcall(function() ci:call("setContextAngle", rot) end) end
      if gpos then pcall(function() ci:call("setInitialPosition", gpos) end) end
      pcall(function() gm:call("requestStandbyPrefab", cont) end)
      if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
      L("  positions set, standby requested - the game's call proceeds." ..
        " If a prefab/controller field was listed above, tell me its name" ..
        " with what appeared.")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - LIVE: the next Monster spawn presented gets dissected + stamped")
end

COMMANDS.summon_probe44 = function()
  sp44_install()
  local O = SUMMON.obs44
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe44.txt", text) then error("could not write summon_probe44.txt") end
  return "summon_probe44: " .. tostring(O and O.calls or 0) ..
    " calls seen, rewritten " .. tostring(O and O.done or false)
end


end
do
---------------------------------------------------------------- v1.89.55: summon probe step 45
-- BREAKTHROUGH in step 44, with the familiar defect: riding
-- the game's generate call and stamping the presented
-- container through its own setCharaID converted the spawn
-- - a Medusa appeared - but inert: no attacks, cannot be
-- targeted. The same syndrome as the factory route, now
-- proven independent of container provenance: real table
-- clone, real registration, still no combat self. So the
-- missing piece is not where the container comes from; it
-- is something a natural spawn carries or receives that a
-- converted one does not. Step 45 gathers the diff data.
-- At ride time it dumps the container's FULL sub-infos
-- (init type, option flags, every Chara/Status/Special
-- field). On the NEXT press, with the Medusa standing in
-- the world, it censuses the character registries, finds
-- the live Medusa character and one natural enemy, and
-- dumps their think/combat/target-flavored fields side by
-- side - hunting the dormant switch.
local function sp45_install()
  if SUMMON.obs45 then return end
  local O = { hist = {}, calls = 0, done = false }
  SUMMON.obs45 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 900 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe45.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe45 (bridge 1.89.67) == convert, then diff the result")
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local function dump_all(obj, label)
    if not obj then
      L("  " .. label .. ": nil")
      return
    end
    local td = try(function() return obj:get_type_definition() end)
    local fields = td and try(function() return td:get_fields() end) or {}
    local parts = {}
    for _, f in ipairs(fields) do
      local fname = try(function() return f:get_name() end)
      if fname and not fname:find("BackingField") then
        local v = try(function() return obj:get_field(fname) end)
        local vs
        if v == nil then
          vs = "nil"
        elseif type(v) == "userdata" then
          vs = tostring(v)
          local inner = try(function() return v:get_field("_SelectedCharacterID") end)
          if inner then vs = "chara " .. tostring(inner) end
        else
          vs = tostring(v)
        end
        parts[#parts + 1] = fname .. "=" .. vs
      end
    end
    L("  " .. label .. " (" .. #parts .. " fields):")
    L("    " .. table.concat(parts, " | "))
  end
  O.dump_all = dump_all
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      local oid0 = ci and try(function() return ci:get_field("_ObjectID") end)
      local sel0 = oid0 and try(function() return oid0:get_field("_SelectedCharacterID") end)
      L("[riding] presented chara=" .. tostring(sel0))
      dump_all(ci, "common")
      dump_all(try(function() return cont:call("get_CharaInfo") end), "charaInfo")
      dump_all(try(function() return cont:call("get_StatusInfo") end), "statusInfo")
      dump_all(try(function() return cont:call("get_SpecialInfo") end), "specialInfo")
      local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
      local boss = nil
      for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) and
           try(function() return f:get_name() end) == "ch255000_00" then
          boss = try(function() return f:get_data(nil) end)
          break
        end
      end
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local okC = pcall(function() ci:call("setCharaID", boss) end)
      local oidA = try(function() return ci:get_field("_ObjectID") end)
      local selA = oidA and try(function() return oidA:get_field("_SelectedCharacterID") end)
      L("  setCharaID ok=" .. tostring(okC) .. " -> ObjectID now " .. tostring(selA))
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
      local rot = prc and try(function() return prc:call("get_Rot") end)
      if gpos then pcall(function() ci:call("setContextPosition", gpos) end) end
      if rot then pcall(function() ci:call("setContextAngle", rot) end) end
      if gpos then pcall(function() ci:call("setInitialPosition", gpos) end) end
      local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
      pcall(function() gm:call("requestStandbyPrefab", cont) end)
      if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
      L("  converted + positioned + standby - the Medusa should appear." ..
        " Let her stand, then press the probe again for the character diff.")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) ..
    " - LIVE: next Monster spawn is converted; press again after she appears")
end

local function sp45_diff()
  local O = SUMMON.obs45
  local L = O.log
  L("== character census (looking for the live Medusa + a natural) ==")
  local function chara_of(ch)
    local probes = {
      function() return ch:call("get_CharacterID") end,
      function() return ch:get_field("_CharacterID") end,
      function() return ch:get_field("<CharacterID>k__BackingField") end,
      function() return ch:call("get_CharaID") end,
      function() return ch:get_field("_CharaID") end,
    }
    for _, p in ipairs(probes) do
      local v = try(p)
      if v ~= nil then return v end
    end
    return nil
  end
  O.chara_of = chara_of
  local function dump_char(ch, label)
    local td = try(function() return ch:get_type_definition() end)
    local fields = td and try(function() return td:get_fields() end) or {}
    local hits = {}
    for _, f in ipairs(fields) do
      local fname = try(function() return f:get_name() end)
      if fname and (fname:find("Think") or fname:find("think") or
         fname:find("Combat") or fname:find("combat") or
         fname:find("Target") or fname:find("target") or
         fname:find("Hit") or fname:find("Active") or
         fname:find("Enable") or fname:find("Sleep") or
         fname:find("Wake") or fname:find("Generate") or
         fname:find("Register") or fname:find("Dead") or
         fname:find("Alive")) then
        local v = try(function() return ch:get_field(fname) end)
        hits[#hits + 1] = fname .. "=" .. tostring(v)
      end
    end
    L("  " .. label .. " chara=" .. tostring(chara_of(ch)) ..
      " type=" .. tostring(td and try(function() return td:get_full_name() end)))
    L("    " .. (#hits > 0 and table.concat(hits, " | ") or "(no matching fields)"))
  end
  O.dump_char = dump_char
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local function scan_holder(holder, label)
    if not holder then
      L("  " .. label .. ": singleton nil")
      return
    end
    local td = try(function() return holder:get_type_definition() end)
    local fields = td and try(function() return td:get_fields() end) or {}
    for _, f in ipairs(fields) do
      local fname = try(function() return f:get_name() end)
      local ftd = try(function() return f:get_type() end)
      local ftname = ftd and try(function() return ftd:get_full_name() end) or ""
      if fname and (ftname:find("Character") or fname:find("hara") or
         fname:find("nstance") or fname:find("nemy")) then
        local v = try(function() return holder:get_field(fname) end)
        local n = v and (try(function() return v:call("get_Length") end) or
                         try(function() return v:call("get_Count") end))
        L("  " .. label .. "." .. fname .. " : " .. ftname ..
          " = " .. tostring(v) .. (n and (" len=" .. tostring(n)) or ""))
        if v and n and n > 0 and n <= 64 then
          for i = 0, n - 1 do
            local el = try(function() return v:call("get_Item", i) end) or
                       try(function() return v:call("GetValue", i) end)
            if el then
              local cv = chara_of(el)
              if cv ~= nil then
                L("    [" .. i .. "] chara=" .. tostring(cv) .. " obj=" .. tostring(el))
              end
            end
          end
        end
      end
    end
  end
  scan_holder(cm, "CharacterManager")
  scan_holder(em, "EnemyManager")
  -- Direct lookups by category + boss id.
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local boss = nil
  for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
    if try(function() return f:is_static() end) and
       try(function() return f:get_name() end) == "ch255000_00" then
      boss = try(function() return f:get_data(nil) end)
      break
    end
  end
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  for _, holder in ipairs({ cm, pm }) do
    if holder and boss then
      local got = try(function()
        return holder:call("getInstanceChara", 3, boss)
      end)
      L("  getInstanceChara(3, boss) on " ..
        tostring(holder:get_type_definition():get_full_name()) ..
        " -> " .. tostring(got))
      if got then dump_char(got, "MEDUSA") end
    end
  end
  L("== census done - if the Medusa was found, her fields are above;" ..
    " compare with any natural enemy dump ==")
end

COMMANDS.summon_probe45 = function()
  sp45_install()
  local O = SUMMON.obs45
  if O and O.done and not O.diffed then
    O.diffed = true
    sp45_diff()
  end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe45.txt", text) then error("could not write summon_probe45.txt") end
  return "summon_probe45: converted " .. tostring(O and O.done or false) ..
    ", diffed " .. tostring(O and O.diffed or false)
end


end
do
---------------------------------------------------------------- v1.89.56: summon probe step 46
-- Step 45's data: the converted container is healthy on
-- paper (think-stop false, wander on, disable flag 255,
-- status 5) and the Medusa character EXISTS with her full
-- component set - Hit, CombatStateControl, LockOnTarget,
-- even her PetrificationDeadController. She is in the
-- instance registry (PawnManager.getInstanceChara found
-- her). What the census could not answer: is she in the
-- ENEMY registry (EnemyManager._EnemyList, the list
-- targeting and combat actually enumerate), and how does
-- her internal state compare to a natural enemy's? Step 46
-- rides and converts as before; on the next press it walks
-- _EnemyList (identifying each element through its own
-- GenerateInfo, the reliable route), finds her and one
-- natural, and dumps both characters completely - every
-- field, plus the CombatStateControl / Hit /
-- GenerateSetting sub-objects - and censuses her type's
-- activation-flavored methods for the step after.
local function sp46_install()
  if SUMMON.obs46 then return end
  local O = { hist = {}, calls = 0, done = false }
  SUMMON.obs46 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe46.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe46 (bridge 1.89.67) == compare her to a natural")
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
      local boss = nil
      for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) and
           try(function() return f:get_name() end) == "ch255000_00" then
          boss = try(function() return f:get_data(nil) end)
          break
        end
      end
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local okC = pcall(function() ci:call("setCharaID", boss) end)
      local oidA = try(function() return ci:get_field("_ObjectID") end)
      local selA = oidA and try(function() return oidA:get_field("_SelectedCharacterID") end)
      L("[riding] setCharaID ok=" .. tostring(okC) .. " -> ObjectID now " .. tostring(selA))
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
      local rot = prc and try(function() return prc:call("get_Rot") end)
      if gpos then pcall(function() ci:call("setContextPosition", gpos) end) end
      if rot then pcall(function() ci:call("setContextAngle", rot) end) end
      if gpos then pcall(function() ci:call("setInitialPosition", gpos) end) end
      local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
      pcall(function() gm:call("requestStandbyPrefab", cont) end)
      if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
      L("  converted - let her appear, stay near her, then press again.")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) .. " - LIVE")
end

local function sp46_compare()
  local O = SUMMON.obs46
  local L = O.log
  L("== enemy registry comparison ==")
  local function chara_via_geninfo(ch)
    local gi = try(function() return ch:get_field("<GenerateInfo>k__BackingField") end)
      or try(function() return ch:call("get_GenerateInfo") end)
    local ci = gi and try(function() return gi:call("get_CommonInfo") end)
    local oid = ci and try(function() return ci:get_field("_ObjectID") end)
    local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
    return sel and tonumber(tostring(sel)) or nil, gi, ci
  end
  O.chara_via_geninfo = chara_via_geninfo
  local function val_str(v)
    if v == nil then return "nil" end
    if type(v) == "userdata" then
      local td = try(function() return v:get_type_definition() end)
      local tn = td and try(function() return td:get_full_name() end) or "obj"
      return "<" .. tn .. ">"
    end
    return tostring(v)
  end
  O.val_str = val_str
  local function dump_full(ch, label)
    local td = try(function() return ch:get_type_definition() end)
    L("  --- " .. label .. " type=" ..
      tostring(td and try(function() return td:get_full_name() end)))
    local fields = td and try(function() return td:get_fields() end) or {}
    local parts = {}
    for _, f in ipairs(fields) do
      local fname = try(function() return f:get_name() end)
      if fname then
        local v = try(function() return ch:get_field(fname) end)
        parts[#parts + 1] = fname .. "=" .. val_str(v)
      end
    end
    L("    " .. table.concat(parts, " | "))
    for _, sub in ipairs({ "<CombatStateControl>k__BackingField", "<Hit>k__BackingField",
        "<GenerateSetting>k__BackingField", "<LockOnTarget>k__BackingField" }) do
      local so = try(function() return ch:get_field(sub) end)
      if so then
        local std = try(function() return so:get_type_definition() end)
        local sf = std and try(function() return std:get_fields() end) or {}
        local sp = {}
        for _, f in ipairs(sf) do
          local fn = try(function() return f:get_name() end)
          if fn then
            local v = try(function() return so:get_field(fn) end)
            if type(v) ~= "userdata" or v == nil then
              sp[#sp + 1] = fn .. "=" .. val_str(v)
            end
          end
        end
        L("    " .. sub .. " scalars: " .. table.concat(sp, " | "))
      else
        L("    " .. sub .. ": nil")
      end
    end
  end
  O.dump_full = dump_full
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  L("  _EnemyList count=" .. tostring(n))
  local medusa, natural = nil, nil
  if list and n then
    for i = 0, math.min(n, 40) - 1 do
      local el = try(function() return list:call("get_Item", i) end)
      if el then
        local cv = chara_via_geninfo(el)
        local etd = try(function() return el:get_type_definition() end)
        L("    [" .. i .. "] type=" ..
          tostring(etd and try(function() return etd:get_full_name() end)) ..
          " chara=" .. tostring(cv))
        if cv == 3307750390 and not medusa then medusa = el end
        if cv ~= nil and cv ~= 3307750390 and not natural then natural = el end
      end
    end
  end
  L("  Medusa in _EnemyList: " .. tostring(medusa ~= nil))
  if not medusa then
    local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local boss = nil
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == "ch255000_00" then
        boss = try(function() return f:get_data(nil) end)
        break
      end
    end
    medusa = pm and boss and try(function()
      return pm:call("getInstanceChara", 3, boss)
    end)
    L("  Medusa via getInstanceChara fallback: " .. tostring(medusa))
  end
  if medusa then dump_full(medusa, "MEDUSA") end
  if natural then dump_full(natural, "NATURAL") end
  if medusa then
    local td = try(function() return medusa:get_type_definition() end)
    local methods = td and try(function() return td:get_methods() end) or {}
    local hits = {}
    for _, mm in ipairs(methods) do
      local mn = try(function() return mm:get_name() end)
      if mn and (mn:find("Think") or mn:find("Combat") or mn:find("Begin") or
         mn:find("Wake") or mn:find("Active") or mn:find("Regist") or
         mn:find("Start") or mn:find("Enable")) then
        hits[#hits + 1] = mn
      end
    end
    L("  Medusa type activation-flavored methods (" .. #hits .. "): " ..
      table.concat(hits, ", "))
  end
  L("== comparison done ==")
end

COMMANDS.summon_probe46 = function()
  sp46_install()
  local O = SUMMON.obs46
  if O and O.done and not O.compared then
    O.compared = true
    sp46_compare()
  end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe46.txt", text) then error("could not write summon_probe46.txt") end
  return "summon_probe46: converted " .. tostring(O and O.done or false) ..
    ", compared " .. tostring(O and O.compared or false)
end

end
do
---------------------------------------------------------------- v1.89.57: summon probe step 47
-- Step 46, corrected reading: the Medusa IS in the enemy
-- list (element [25], type app.Ch255000 - the step's own
-- chara identifier failed on every element, so its
-- "not in list" line was a false negative). Her character
-- object is complete: boss flags set, hit controller
-- started, post-initialize finished, AI organs present.
-- One original-species value still rides her container:
-- the InitSetType (250 in step 45 - the donor species'
-- opening setup). If the opening setup is what hands a
-- character its brain, a Medusa built with another
-- species' init never gets hers. Step 47 enumerates the
-- InitSetType members naming family 255, stamps the first
-- one that is NOT the banned SummonAppear (203 - crashed
-- in step 33; scenario inits stay banned) alongside
-- setCharaID, and on the next press dumps her AI organs
-- (decision maker, blackboard, hate, sensor) beside a
-- natural enemy's, with both characters' generate-info
-- init values for comparison.
local function sp47_install()
  if SUMMON.obs47 then return end
  local O = { hist = {}, calls = 0, done = false }
  SUMMON.obs47 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe47.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe47 (bridge 1.89.67) == the init experiment + AI diff")
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      local itd = try(function() return sdk.find_type_definition("app.GenerateDefine.InitSetTypeEnum") end)
      local chosen, chosenName = nil, nil
      local seen255 = {}
      for _, f in ipairs(itd and try(function() return itd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) then
          local fn = try(function() return f:get_name() end)
          if fn and fn:find("255") then
            local d = try(function() return f:get_data(nil) end)
            local dv = d and tonumber(tostring(d))
            seen255[#seen255 + 1] = fn .. "=" .. tostring(dv)
            if not fn:find("SummonAppear") and chosen == nil and dv ~= nil then
              chosen, chosenName = dv, fn
            end
          end
        end
      end
      L("[riding] InitSetType members naming 255: " ..
        (#seen255 > 0 and table.concat(seen255, ", ") or "NONE"))
      local origInit = ci and try(function() return ci:get_field("_InitSetType") end)
      L("  container init before: " .. tostring(origInit))
      if chosen ~= nil then
        local okI = pcall(function() ci:call("setInitSetType", chosen) end)
        local nowInit = try(function() return ci:get_field("_InitSetType") end)
        L("  setInitSetType(" .. chosenName .. "=" .. chosen .. ") ok=" ..
          tostring(okI) .. " -> init now " .. tostring(nowInit))
      else
        L("  no non-banned 255 init exists - container init left as-is")
      end
      local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
      local boss = nil
      for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) and
           try(function() return f:get_name() end) == "ch255000_00" then
          boss = try(function() return f:get_data(nil) end)
          break
        end
      end
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local okC = pcall(function() ci:call("setCharaID", boss) end)
      local oidA = try(function() return ci:get_field("_ObjectID") end)
      local selA = oidA and try(function() return oidA:get_field("_SelectedCharacterID") end)
      L("  setCharaID ok=" .. tostring(okC) .. " -> ObjectID now " .. tostring(selA))
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
      local rot = prc and try(function() return prc:call("get_Rot") end)
      if gpos then pcall(function() ci:call("setContextPosition", gpos) end) end
      if rot then pcall(function() ci:call("setContextAngle", rot) end) end
      if gpos then pcall(function() ci:call("setInitialPosition", gpos) end) end
      local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
      pcall(function() gm:call("requestStandbyPrefab", cont) end)
      if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
      L("  converted - watch her closely this time: does she fight?" ..
        " Then press again for the AI diff.")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) .. " - LIVE")
end

local function sp47_compare()
  local O = SUMMON.obs47
  local L = O.log
  L("== AI organ comparison ==")
  local function val_str(v)
    if v == nil then return "nil" end
    if type(v) == "userdata" then
      local td = try(function() return v:get_type_definition() end)
      local tn = td and try(function() return td:get_full_name() end) or "obj"
      return "<" .. tn .. ">"
    end
    return tostring(v)
  end
  local function sub_scalars(ch, field, label)
    local so = try(function() return ch:get_field(field) end)
    if not so then
      L("    " .. label .. ": nil")
      return
    end
    local std = try(function() return so:get_type_definition() end)
    local sf = std and try(function() return std:get_fields() end) or {}
    local sp = {}
    for _, f in ipairs(sf) do
      local fn = try(function() return f:get_name() end)
      if fn then
        local v = try(function() return so:get_field(fn) end)
        if type(v) ~= "userdata" or v == nil then
          sp[#sp + 1] = fn .. "=" .. val_str(v)
        end
      end
    end
    L("    " .. label .. " (" ..
      tostring(std and try(function() return std:get_full_name() end)) .. "): " ..
      table.concat(sp, " | "))
  end
  local function geninfo_line(ch, label)
    local gi = try(function() return ch:get_field("<GenerateInfo>k__BackingField") end)
    local ci = gi and try(function() return gi:call("get_CommonInfo") end)
    if not ci then
      L("    " .. label .. " GenerateInfo: unavailable")
      return
    end
    local oid = try(function() return ci:get_field("_ObjectID") end)
    local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
    L("    " .. label .. " GenerateInfo: chara=" .. tostring(sel) ..
      " init=" .. tostring(try(function() return ci:get_field("_InitSetType") end)) ..
      " option=" .. tostring(try(function() return ci:get_field("_Option") end)) ..
      " loadArea=" .. tostring(try(function() return ci:get_field("_LoadArea") end)))
  end
  local function dump_char(ch, label)
    L("  --- " .. label)
    geninfo_line(ch, label)
    sub_scalars(ch, "<AIDecisionMaker>k__BackingField", label .. " AIDecisionMaker")
    sub_scalars(ch, "<AIBlackBoardController>k__BackingField", label .. " AIBlackBoard")
    sub_scalars(ch, "<HateSystem>k__BackingField", label .. " HateSystem")
    sub_scalars(ch, "<SensorController>k__BackingField", label .. " Sensor")
    sub_scalars(ch, "<CombatStateControl>k__BackingField", label .. " CombatState")
    local td = try(function() return ch:get_type_definition() end)
    local fields = td and try(function() return td:get_fields() end) or {}
    local picks = {}
    for _, f in ipairs(fields) do
      local fn = try(function() return f:get_name() end)
      if fn and (fn:find("AITown") or fn:find("AILocal") or fn:find("IsUpdated") or
         fn:find("IsBoss") or fn:find("AISituation") or fn:find("CombatState") or
         fn:find("Think") or fn:find("GenerateSetting")) then
        local v = try(function() return ch:get_field(fn) end)
        picks[#picks + 1] = fn .. "=" .. val_str(v)
      end
    end
    L("    " .. label .. " picks: " .. table.concat(picks, " | "))
  end
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  L("  _EnemyList count=" .. tostring(n))
  local medusa, natural = nil, nil
  if list and n then
    for i = 0, math.min(n, 40) - 1 do
      local el = try(function() return list:call("get_Item", i) end)
      if el then
        local etd = try(function() return el:get_type_definition() end)
        local tn = etd and try(function() return etd:get_full_name() end)
        if tn == "app.Ch255000" and not medusa then medusa = el end
        if tn ~= "app.Ch255000" and tn ~= nil and not natural then natural = el end
      end
    end
  end
  L("  Medusa element found: " .. tostring(medusa ~= nil) ..
    " | natural element found: " .. tostring(natural ~= nil))
  if medusa then dump_char(medusa, "MEDUSA") end
  if natural then dump_char(natural, "NATURAL") end
  L("== comparison done ==")
end

COMMANDS.summon_probe47 = function()
  sp47_install()
  local O = SUMMON.obs47
  if O and O.done and not O.compared then
    O.compared = true
    sp47_compare()
  end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe47.txt", text) then error("could not write summon_probe47.txt") end
  return "summon_probe47: converted " .. tostring(O and O.done or false) ..
    ", compared " .. tostring(O and O.compared or false)
end
end

do
---------------------------------------------------------------- v1.89.58: summon probe step 48
-- Step 47 reframed everything: the ONLY InitSetType naming
-- family 255 is Ch255000_11_SummonAppear (203) - the
-- Medusa has no ordinary species init at all. She is an
-- event boss; her lair appearance is scripted, and it is
-- entirely possible her brain is switched on by that
-- script, not by the generate pipeline. Every spawn test
-- since step 25 used her. Step 48 changes the test
-- subject: ch250000_00, the Cyclops - a normal field boss
-- found all over the map, whose family should carry an
-- ordinary init. Same ride, same stamps (character +
-- first non-scenario family init if one exists). If a
-- converted Cyclops FIGHTS, the mechanism works and the
-- Medusa was a cursed pick. The comparison stage is also
-- fixed: enemy-list elements are Ch-class objects that do
-- not expose the Character fields probed in step 47 (both
-- sides read nil identically - a probe bug); characters
-- are now reached through getInstanceChara, the route that
-- worked in step 46.
local BOSS_CODE = "ch250000_00"
local BOSS_FAMILY = "250"
local function sp48_install()
  if SUMMON.obs48 then return end
  local O = { hist = {}, calls = 0, done = false }
  SUMMON.obs48 = O
  local function L(x)
    O.hist[#O.hist + 1] = x
    if #O.hist > 1200 then table.remove(O.hist, 1) end
    wr(DIR .. "summon_probe48.txt", table.concat(O.hist, "\n"))
  end
  O.log = L
  L("== summon_probe48 (bridge 1.89.67) == a different boss: " .. BOSS_CODE)
  local function find_enum(code)
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == code then
        return try(function() return f:get_data(nil) end)
      end
    end
    return nil
  end
  O.find_enum = find_enum
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then
    L("requestGenerate method not found - hook NOT installed")
    return
  end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      O.calls = O.calls + 1
      if O.done then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      O.done = true
      local itd = try(function() return sdk.find_type_definition("app.GenerateDefine.InitSetTypeEnum") end)
      local chosen, chosenName = nil, nil
      local seen = {}
      for _, f in ipairs(itd and try(function() return itd:get_fields() end) or {}) do
        if try(function() return f:is_static() end) then
          local fn = try(function() return f:get_name() end)
          if fn and fn:find(BOSS_FAMILY) then
            local d = try(function() return f:get_data(nil) end)
            local dv = d and tonumber(tostring(d))
            seen[#seen + 1] = fn .. "=" .. tostring(dv)
            if not fn:find("Summon") and not fn:find("Event") and
               chosen == nil and dv ~= nil then
              chosen, chosenName = dv, fn
            end
          end
        end
      end
      L("[riding] InitSetType members naming " .. BOSS_FAMILY .. ": " ..
        (#seen > 0 and table.concat(seen, ", ") or "NONE"))
      local origInit = ci and try(function() return ci:get_field("_InitSetType") end)
      L("  container init before: " .. tostring(origInit))
      if chosen ~= nil then
        local okI = pcall(function() ci:call("setInitSetType", chosen) end)
        local nowInit = try(function() return ci:get_field("_InitSetType") end)
        L("  setInitSetType(" .. chosenName .. "=" .. chosen .. ") ok=" ..
          tostring(okI) .. " -> init now " .. tostring(nowInit))
      else
        L("  no ordinary family init - container init left as-is")
      end
      local boss = find_enum(BOSS_CODE)
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local okC = pcall(function() ci:call("setCharaID", boss) end)
      local oidA = try(function() return ci:get_field("_ObjectID") end)
      local selA = oidA and try(function() return oidA:get_field("_SelectedCharacterID") end)
      L("  setCharaID(" .. BOSS_CODE .. ") ok=" .. tostring(okC) ..
        " -> ObjectID now " .. tostring(selA))
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
      local rot = prc and try(function() return prc:call("get_Rot") end)
      if gpos then pcall(function() ci:call("setContextPosition", gpos) end) end
      if rot then pcall(function() ci:call("setContextAngle", rot) end) end
      if gpos then pcall(function() ci:call("setInitialPosition", gpos) end) end
      local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
      pcall(function() gm:call("requestStandbyPrefab", cont) end)
      if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
      L("  converted - a Cyclops should appear at your feet." ..
        " Does he move, attack, react? Can you target him?" ..
        " Then press again for the comparison.")
    end, function(retval)
      return retval
    end)
  end)
  L("hook installed: " .. tostring(ok) .. " - LIVE")
end

local function sp48_compare()
  local O = SUMMON.obs48
  local L = O.log
  L("== comparison via getInstanceChara ==")
  local function val_str(v)
    if v == nil then return "nil" end
    if type(v) == "userdata" then
      local td = try(function() return v:get_type_definition() end)
      local tn = td and try(function() return td:get_full_name() end) or "obj"
      return "<" .. tn .. ">"
    end
    return tostring(v)
  end
  local function sub_scalars(ch, field, label)
    local so = try(function() return ch:get_field(field) end)
    if not so then
      L("    " .. label .. ": nil")
      return
    end
    local std = try(function() return so:get_type_definition() end)
    local sf = std and try(function() return std:get_fields() end) or {}
    local sp = {}
    for _, f in ipairs(sf) do
      local fn = try(function() return f:get_name() end)
      if fn then
        local v = try(function() return so:get_field(fn) end)
        if type(v) ~= "userdata" or v == nil then
          sp[#sp + 1] = fn .. "=" .. val_str(v)
        end
      end
    end
    L("    " .. label .. ": " .. table.concat(sp, " | "))
  end
  local function dump_char(ch, label)
    if not ch then
      L("  --- " .. label .. ": character not found")
      return
    end
    L("  --- " .. label .. " CharacterID=" ..
      tostring(try(function() return ch:get_field("CharacterID") end)) ..
      " IsBoss=" .. tostring(try(function()
        return ch:get_field("<IsBoss>k__BackingField") end)) ..
      " IsPostInitializeFinished=" .. tostring(try(function()
        return ch:get_field("<IsPostInitializeFinished>k__BackingField") end)) ..
      " AITownArea=" .. tostring(try(function()
        return ch:get_field("<AITownArea>k__BackingField") end)) ..
      " AILocalArea=" .. tostring(try(function()
        return ch:get_field("<AILocalArea>k__BackingField") end)) ..
      " DistanceXZSq=" .. tostring(try(function()
        return ch:get_field("<DistanceXZSqFromPlayer>k__BackingField") end)))
    sub_scalars(ch, "<AIDecisionMaker>k__BackingField", label .. " AIDecisionMaker")
    sub_scalars(ch, "<AIBlackBoardController>k__BackingField", label .. " AIBlackBoard")
    sub_scalars(ch, "<HateSystem>k__BackingField", label .. " HateSystem")
    sub_scalars(ch, "<SensorController>k__BackingField", label .. " Sensor")
    sub_scalars(ch, "<CombatStateControl>k__BackingField", label .. " CombatState")
    sub_scalars(ch, "<Hit>k__BackingField", label .. " Hit")
  end
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local bossEnum = O.find_enum(BOSS_CODE)
  local bossChar = pm and bossEnum and try(function()
    return pm:call("getInstanceChara", 3, bossEnum)
  end)
  dump_char(bossChar, "CYCLOPS")
  -- Natural: first enemy-list element of another species,
  -- reached through its own _00 enum.
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  local natChar = nil
  if list and n then
    for i = 0, math.min(n, 40) - 1 do
      local el = try(function() return list:call("get_Item", i) end)
      local etd = el and try(function() return el:get_type_definition() end)
      local tn = etd and try(function() return etd:get_full_name() end)
      if tn and tn ~= "app.Ch250000" then
        local fam = tn:match("app%.(Ch%d+)")
        if fam then
          local code = "ch" .. fam:sub(3) .. "_00"
          local e = O.find_enum(code)
          if e and pm then
            natChar = try(function()
              return pm:call("getInstanceChara", 3, e)
            end)
            if natChar then
              L("  natural picked: " .. tn .. " via " .. code)
              break
            end
          end
        end
      end
    end
  end
  dump_char(natChar, "NATURAL")
  L("== comparison done ==")
end

COMMANDS.summon_probe48 = function()
  sp48_install()
  local O = SUMMON.obs48
  if O and O.done and not O.compared then
    O.compared = true
    sp48_compare()
  end
  local text = O and table.concat(O.hist, "\n") or ""
  if not wr(DIR .. "summon_probe48.txt", text) then error("could not write summon_probe48.txt") end
  return "summon_probe48: converted " .. tostring(O and O.done or false) ..
    ", compared " .. tostring(O and O.compared or false)
end
end

do
---------------------------------------------------------------- v1.89.60: summon probe step 49
-- Reports from the field on the shipped Summon Boss: some
-- converted bosses cannot be damaged. The conversion recipe
-- is species-general, so the gate is likely species data:
-- an invincibility/damage flag the character carries, a
-- damage-collision switch, or an encounter-script gate like
-- the Medusa's brain. Step 49 is read-only: AFTER a boss has
-- been summoned with the normal Summon button, it finds the
-- live boss character (IsBoss) and one natural enemy and
-- dumps their damage-gate state side by side - Hit
-- controller scalars, character damage flags, the generate
-- info the conversion actually used, and combat uptake.
local function sp49_run()
  local hist = {}
  local function L(x)
    hist[#hist + 1] = x
    wr(DIR .. "summon_probe49.txt", table.concat(hist, "\n"))
  end
  L("== summon_probe49 (bridge 1.89.67) == damage-gate diff")
  local function find_enum(code)
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) and
         try(function() return f:get_name() end) == code then
        return try(function() return f:get_data(nil) end)
      end
    end
    return nil
  end
  local function hit_scalars(ch, label)
    local hit = try(function() return ch:get_field("<Hit>k__BackingField") end)
    if not hit then
      L("  " .. label .. " Hit: nil")
      return
    end
    local keys = { "<IsInvincible>k__BackingField", "<IsDamageZero>k__BackingField",
      "<IsUseAttack>k__BackingField", "<IsNoDie>k__BackingField",
      "<IsAttackNoDie>k__BackingField", "<DamageCollisionOff>k__BackingField",
      "<PressCollisionOff>k__BackingField", "<IsStarted>k__BackingField",
      "<ReducedMaxHp>k__BackingField", "<GuardHp>k__BackingField",
      "<HasTacticalAttackNoticeInfo>k__BackingField", "_IsProcDistRegistered",
      "IsRegistColliderTrackOnStart", "<TotalFrameDamage>k__BackingField",
      "SetDamageInfoFrameCount" }
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = k:gsub("<", ""):gsub(">k__BackingField", "") ..
        "=" .. tostring(try(function() return hit:get_field(k) end))
    end
    L("  " .. label .. " Hit: " .. table.concat(parts, " | "))
  end
  local function dump_char(ch, label)
    if not ch then
      L("  --- " .. label .. ": not found")
      return
    end
    local function gf(n)
      return try(function() return ch:get_field(n) end)
    end
    L("  --- " .. label .. " CharacterID=" .. tostring(gf("CharacterID")) ..
      " IsBoss=" .. tostring(gf("<IsBoss>k__BackingField")) ..
      " IsPostInitializeFinished=" ..
      tostring(gf("<IsPostInitializeFinished>k__BackingField")) ..
      " IsNoHitPlayerAttack=" ..
      tostring(gf("<IsNoHitPlayerAttack>k__BackingField")) ..
      " IsImmortality=" .. tostring(gf("<IsImmortality>k__BackingField")) ..
      " IsEnablePawnHitFilter=" ..
      tostring(gf("<IsEnablePawnHitFilter>k__BackingField")))
    local dc = gf("<DamageCalculator>k__BackingField")
    local dctd = dc and try(function() return dc:get_type_definition() end)
    L("    DamageCalculator=" ..
      tostring(dctd and try(function() return dctd:get_full_name() end) or dc))
    local gi = gf("<GenerateInfo>k__BackingField")
    local ci = gi and try(function() return gi:call("get_CommonInfo") end)
    if ci then
      L("    GenerateInfo: init=" ..
        tostring(try(function() return ci:get_field("_InitSetType") end)) ..
        " option=" ..
        tostring(try(function() return ci:get_field("_Option") end)) ..
        " loadArea=" ..
        tostring(try(function() return ci:get_field("_LoadArea") end)))
      local chi = try(function() return gi:call("get_CharaInfo") end)
      if chi then
        L("    CharaInfo: IsForceCombat=" ..
          tostring(try(function() return chi:get_field("_IsForceCombat") end)) ..
          " IsThinkStop=" ..
          tostring(try(function() return chi:get_field("_IsThinkStop") end)) ..
          " GenerateDisableFlag=" ..
          tostring(try(function() return chi:get_field("_GenerateDisableFlag") end)))
      end
    end
    local hate = gf("<HateSystem>k__BackingField")
    if hate then
      L("    HateSystem: IsBossCharacter=" ..
        tostring(try(function() return hate:get_field("_IsBossCharacter") end)) ..
        " HateRequestCount=" ..
        tostring(try(function() return hate:get_field("_HateRequestCount") end)) ..
        " PrevEnemiesCount=" ..
        tostring(try(function() return hate:get_field("_PrevEnemiesCount") end)))
    end
    hit_scalars(ch, label)
  end
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  L("  _EnemyList count=" .. tostring(n))
  local bossChar, natChar = nil, nil
  if list and n and pm then
    for i = 0, math.min(n, 40) - 1 do
      local el = try(function() return list:call("get_Item", i) end)
      local etd = el and try(function() return el:get_type_definition() end)
      local tn = etd and try(function() return etd:get_full_name() end)
      local fam = tn and tn:match("app%.Ch(%d+)")
      if fam then
        local e = find_enum("ch" .. fam .. "_00")
        local ch = e and try(function()
          return pm:call("getInstanceChara", 3, e)
        end)
        if ch then
          local isBoss = try(function()
            return ch:get_field("<IsBoss>k__BackingField")
          end)
          if isBoss == true and not bossChar then
            bossChar = ch
            L("  boss found: " .. tn)
          elseif isBoss ~= true and not natChar then
            natChar = ch
            L("  natural picked: " .. tn)
          end
        end
      end
      if bossChar and natChar then break end
    end
  end
  dump_char(bossChar, "BOSS")
  dump_char(natChar, "NATURAL")
  L("== diff done - send this log plus WHICH boss you summoned ==")
  return hist
end

COMMANDS.summon_probe49 = function()
  local hist = sp49_run()
  return "summon_probe49: " .. (hist[#hist] or "done")
end
end

---------------------------------------------------------------- v1.89.63: summon boss (the ride - productized probe 48, restored verbatim from 1.89.59; the v3 direct factory spawn of 1.89.61 CRASHED in live testing and is banned)
-- The mechanism the 48-step probe campaign proved (and the one
-- that finally produced a FIGHTING boss in-game, 2026-10-23):
-- do not build containers and do not edit tables - RIDE the
-- game's own requestGenerate. A hook fires just before the
-- game generates a real enemy spawn; the presented container
-- (genuinely registered, real table identity, already queued
-- with the distributor) is restamped in place:
--   setInitSetType(the species' own base init, e.g. Ch250 -
--     found by name in InitSetTypeEnum; species-flavored
--     fallback; Common(1) last resort)
--   setCharaID(the picked variant, e.g. ch250000_00)
--   context + initial position = the player's ground
--     position, context angle = the player's rotation
--   prefab standby requested
-- then the game's call proceeds and the pipeline produces a
-- real boss: AI, targeting, hit reception, the works.
-- Known exception: the Medusa (ch255000) has NO base init -
-- her only family init is the scripted SummonAppear, so she
-- is event-locked by design and converts to a statue; other
-- bosses fight. (Her fallback here is Common.)
-- summon_boss|<code> ARMS one conversion per call; the next
-- enemy spawn presented converts. Converted bosses are the
-- donor spawn for save purposes - nothing fabricated enters
-- the save path, and area reloads restore the originals.
local summon_log = {}
local function SL(x)
  summon_log[#summon_log + 1] = x
  wr(DIR .. "summon_log.txt", table.concat(summon_log, "\n"))
end

local function enum_value(tname, fname)
  local td = try(function() return sdk.find_type_definition(tname) end)
  if not td then return nil end
  local fs = try(function() return td:get_fields() end) or {}
  for _, f in ipairs(fs) do
    local fn = try(function() return f:get_name() end)
    if fn == fname then
      return try(function() return f:get_data(nil) end)
    end
  end
  return nil
end

local function summon_ride_install()
  if SUMMON.rideHook then return end
  local gmtd = try(function() return sdk.find_type_definition("app.GenerateManager") end)
  local m = gmtd and try(function() return gmtd:get_method("requestGenerate") end)
  if not m then return end
  local ok = pcall(function()
    sdk.hook(m, function(args)
      local R = SUMMON.ride
      if not R or (R.pending or 0) <= 0 then return end
      local cont = try(function() return sdk.to_managed_object(args[3]) end)
      if not cont then return end
      local ci = try(function() return cont:call("get_CommonInfo") end)
      local cat = ci and try(function() return ci:get_field("_Category") end)
      if cat ~= 3 then return end
      R.pending = R.pending - 1
      if R.init then pcall(function() ci:call("setInitSetType", R.init) end) end
      pcall(function() ci:call("setCharaID", R.chara) end)
      local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
      local player = cm and try(function() return cm:call("get_ManualPlayer") end)
      local gpos = player and try(function() return player:call("get_LastGroundPosition") end)
      local prc = player and try(function() return player:get_field("<PosRotContext>k__BackingField") end)
      local rot = prc and try(function() return prc:call("get_Rot") end)
      if gpos then pcall(function() ci:call("setContextPosition", gpos) end) end
      if rot then pcall(function() ci:call("setContextAngle", rot) end) end
      if gpos then pcall(function() ci:call("setInitialPosition", gpos) end) end
      local gm = try(function() return sdk.get_managed_singleton("app.GenerateManager") end)
      local cc = gm and try(function() return gm:call("get_CatalogCtrl") end)
      pcall(function() gm:call("requestStandbyPrefab", cont) end)
      if ci then pcall(function() cc:call("requestStandbyPrefab", ci) end) end
      SUMMON.converted = (SUMMON.converted or 0) + 1
      SL("converted a spawn into " .. tostring(R.dispname) .. " at your feet")
    end, function(retval)
      return retval
    end)
  end)
  SUMMON.rideHook = ok
end

COMMANDS.summon_boss = function(a)
  local name = (a and a[1]) or ""
  summon_log = {}
  SL("== summon_boss " .. name .. " (bridge 1.89.74) ==")
  if not name:match("^ch%d+[%w_]*$") then
    SL("rejected: not a character catalog name")
    error("'" .. name .. "' is not a character catalog name (e.g. ch250000)")
  end
  -- The pipeline keys on the _00 VARIANT code (probe step 11).
  local dispname = name
  local chara = enum_value("app.CharacterID", name .. "_00")
  if chara ~= nil then
    dispname = name .. "_00"
  else
    chara = enum_value("app.CharacterID", name)
  end
  if chara == nil then SL("catalog lookup failed") error("unknown character id: " .. name) end
  SL("character resolved: " .. dispname .. " = " .. tostring(chara))
  -- Init resolution: the bare family base ("Ch250") first; else
  -- the first family member that is not a scenario/quest init;
  -- else Common(1). The value goes in as a plain number (probe 48).
  local fam = name:sub(3, 5)
  local initVal, initName, fallback, fallbackPose = nil, nil, nil, nil
  local itd = try(function() return sdk.find_type_definition("app.GenerateDefine.InitSetTypeEnum") end)
  for _, f in ipairs(itd and try(function() return itd:get_fields() end) or {}) do
    if try(function() return f:is_static() end) then
      local fn = try(function() return f:get_name() end)
      local d = try(function() return f:get_data(nil) end)
      local dv = d and tonumber(tostring(d))
      if fn == "Ch" .. fam and dv ~= nil then
        initVal, initName = dv, fn
      elseif fn and fn:sub(1, 2 + #fam) == "Ch" .. fam and dv ~= nil and
         not fn:find("Summon") and not fn:find("Event") and
         not fn:find("Quest") then
        -- Pose setups (Sit/Sleep/Wait/...) make a boss that
        -- just sits there (ch261000 picked Ch261000_Sit live);
        -- they are last-resort fallbacks only (v1.89.64).
        if fn:find("Sit") or fn:find("Sleep") or fn:find("Wait") or
           fn:find("Stagnation") or fn:find("Confined") or fn:find("Stay") then
          if not fallbackPose then fallbackPose = { val = dv, name = fn } end
        elseif not fallback then
          fallback = { val = dv, name = fn }
        end
      end
    end
  end
  if not initVal and fallback then initVal, initName = fallback.val, fallback.name end
  if not initVal and fallbackPose then initVal, initName = fallbackPose.val, fallbackPose.name end
  if not initVal then initVal, initName = 1, "Common" end
  SL("init set: " .. initName .. " = " .. tostring(initVal))
  local prev = SUMMON.ride and SUMMON.ride.pending or 0
  SUMMON.ride = { pending = prev + 1, chara = chara, dispname = dispname, init = initVal }
  SUMMON.name, SUMMON.chara = dispname, chara
  summon_ride_install()
  if not SUMMON.rideHook then
    SL("ride hook FAILED to install")
    error("could not install the generate hook - see summon_log.txt")
  end
  SL("armed: " .. dispname .. " - pending conversions: " .. SUMMON.ride.pending)
  return "summon armed: the next enemy spawn becomes " .. dispname ..
    " at your feet - walk toward any enemy group"
end

COMMANDS.summon_verify = function()
  if not SUMMON.name then return "no summon yet this session" end
  local R = SUMMON.ride
  local hookState = SUMMON.rideHook and "installed" or "NOT INSTALLED"
  if R and (R.pending or 0) > 0 then
    return "verify " .. tostring(SUMMON.name) ..
      ": armed pending=" .. tostring(R.pending) ..
      " hook=" .. hookState ..
      " converted=" .. tostring(SUMMON.converted or 0) ..
      " - walk toward an enemy group to trigger the conversion"
  end
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local inst = pm and SUMMON.chara and try(function()
    return pm:call("getInstanceChara", 3, SUMMON.chara)
  end)
  local msg = "verify " .. tostring(SUMMON.name) .. ": instance=" ..
    (inst and "FOUND" or "not found") ..
    " hook=" .. hookState ..
    " converted=" .. tostring(SUMMON.converted or 0)
  SL(msg)
  return msg
end


do
---------------------------------------------------------------- v1.89.71: kill nearby enemies v7
-- v6 REGRESSED: its handle-type check discarded every resolved
-- handle (see sk_handle_for) and v6 killed nothing that
-- resolved. v7 removes the check and widens the category
-- fallback to 0-9. Rogues still resolve under NO category
-- (0-5 proven nil in v6; 6-9 untested) - they are likely not
-- PawnManager characters at all, which is a separate probe
-- if pursued. Despawn fallback kept as last resort, already
-- known to remove nothing visible.
-- v5's verdict (user, live): the Grim Ogre and Dragon he saw
-- killAndSetDieLoop called on DID die (probable - he wasn't
-- certain), while Chimera/Drake and nearby normal monsters did
-- not. The mechanism is proven when a handle resolves; the
-- remaining failure is handle resolution itself. So v6:
--   * category fallback: after all category-3 variants fail,
--     try categories 0,1,2,4,5 (Rogues resolve under none in
--     category 3) - a handle only counts when its own type
--     matches the element's type;
--   * HP filter tightened to word-boundary HP (v5's substring
--     "hp" matched FixedPushPosition and handler objects).
-- Chimera/Drake failures are still undiagnosed from a log (no
-- v5 log with them in range arrived): if their handles WERE
-- found but the death call failed, that is a different fix
-- and the v6 log will show it.
-- v4 failed live (user's summon_kill.txt, 13 enemies): chara=nil
-- for EVERY element, so the ladder never reached a character, a
-- Hit, or an HP field - and its "damage-call ok" lines were false
-- positives (a getter and an event handler, not kills).
-- Probe 52 then proved, read-only, what actually works:
--   * GenerateInfo EXISTS on every element, but get_CommonInfo()
--     returns nil for all of them - the int route (probe 46's
--     chain) is dead for live _EnemyList elements. Never use it
--     again for killing.
--   * The NAME route works: type app.Ch261000 -> CharacterID
--     enum field ch261000_00 (or a same-family variant), and
--     PawnManager.getInstanceChara(3, enum) returns the live
--     character with real IsBoss, real <DistanceXZSqFromPlayer>,
--     and a Hit object. Proven for Ch223003, Ch254000,
--     Ch254001, Ch222005. Ch253010 and Ch230000 returned no
--     handle for the first same-family variant tried - so v5
--     tries EVERY same-family variant, not just the first.
--   * Hit has NO current-HP field (full field list dumped).
--     HP must live on the character itself or its status
--     controller - so the HP hunt searches the handle, the
--     Hit, and Hit.<CachedStatusConditionCtrl>, by name only
--     (hp/health, never max/rate/damage/recover), writes 0
--     with read-back, and reports - it never claims a kill
--     the game hasn't shown.
--   * Damage-named method calls are BANNED (v4's false
--     positives). Only dead/kill/die-named methods on the
--     handle are tried, with no args, inside pcall, and
--     get/is/on-prefixed names are skipped (getters/handlers).
--   * RESULT honesty: the run ends with a re-scan of
--     _EnemyList, and the response says "kill attempt", never
--     "killed" - the user's eyes confirm death.
local sk_hist = {}
local function SK(x)
  sk_hist[#sk_hist + 1] = x
  wr(DIR .. "summon_kill.txt", table.concat(sk_hist, "\n"))
end

local function sk_char_id_fields()
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  return ctd and try(function() return ctd:get_fields() end) or {}
end

-- All CharacterID enum values for one base code ("ch254000"):
-- the _00 variant first, then every other same-family member in
-- catalog order. Returns a list of {value, name}.
local function sk_enums_for(cfields, base)
  local out, rest = {}, {}
  for _, f in ipairs(cfields) do
    if try(function() return f:is_static() end) then
      local nm = try(function() return f:get_name() end)
      if nm then
        if nm == base .. "_00" then
          out[#out + 1] = { try(function() return f:get_data(nil) end), nm }
        elseif nm:sub(1, #base + 1) == base .. "_" then
          rest[#rest + 1] = { try(function() return f:get_data(nil) end), nm }
        end
      end
    end
  end
  for _, r in ipairs(rest) do out[#out + 1] = r end
  return out
end

-- v7: v6's handle-type check was a REGRESSION and is removed.
-- get_type_definition() on a PawnManager handle returns the
-- STATIC type app.Character, not the runtime class - so v6
-- threw away every real handle (Boltscale via ch221004_60,
-- Gore Chimera via ch254001_00, wolves via ch223003_00, harpy
-- via ch222005_00) and killed nothing that resolved, while
-- probe52 in the same moment showed those handles live, the
-- Chimera a boss at distSq 310. Lesson: NEVER gate on
-- get_type_definition for PawnManager handles. The enum IS
-- the identity (a pawn cannot be a Boltscale), and v5 proved
-- resolved handles are the right targets (ogre/dragon died).
-- v7 = v5 acceptance (first non-nil handle wins) + the
-- category fallback widened to 0-9 (Rogues returned nil in
-- every category 0-5 in v6; 6-9 is a cheap getter sweep).
local function sk_handle_for(pm, cfields, base)
  for _, cat in ipairs({ 3, 0, 1, 2, 4, 5, 6, 7, 8, 9 }) do
    for _, e in ipairs(sk_enums_for(cfields, base)) do
      local ch = e[1] and try(function() return pm:call("getInstanceChara", cat, e[1]) end)
      if ch then return ch, e[2], cat end
    end
  end
  return nil
end

-- HP hunt across the given objects ({obj, where} pairs). Only
-- name-identified current-HP fields; writes 0 with read-back.
-- Returns the winning description or nil.
local function sk_hp_hunt(objs)
  for _, entry in ipairs(objs) do
    local o, where = entry.obj, entry.where
    if o then
      local td = try(function() return o:get_type_definition() end)
      for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
        local fn = try(function() return f:get_name() end)
        if fn then
          -- v6: HP as a WORD, not a substring. v5's substring "hp"
          -- matched FixedPushPosition ("pusHPosition"), a boss-HP
          -- -gauge bool and an HP handler object - all saved only
          -- by the number check. The log stays honest now.
          local low = fn:lower()
          local isHp = low == "hp" or low:find("^hp") or low:find("hp$") or
            low:find("_hp_") or low:find("health") or low:find("hitpoint")
          local excluded = low:find("max") or low:find("rate") or
            low:find("damage") or low:find("recover") or low:find("guard")
          if isHp and not excluded then
            local v = try(function() return o:get_field(fn) end)
            SK("    HP candidate (" .. where .. "): " .. fn .. " = " .. tostring(v))
            if type(v) == "number" and v > 0 then
              local okS = pcall(function() o:set_field(fn, 0) end)
              local back = try(function() return o:get_field(fn) end)
              SK("    HP write (" .. where .. "): " .. fn .. " -> 0 (ok=" ..
                 tostring(okS) .. ", reads back " .. tostring(back) .. ")")
              if okS then return "hp-write " .. fn .. " (" .. where .. ")" end
            end
          end
        end
      end
    end
  end
  return nil
end

-- v8 (probe53 answered, 2026-10-24): probe53 on a live boss
-- (ch257003, ReducedMaxHp 240000) proved three things.
-- 1. killAndSetDieLoop is a CONFIRMED no-op on a healthy
-- enemy: IsStartDead stayed false, and the <systemStatus> and
-- <TempStatusFlag> object pointers were IDENTICAL before and
-- after the call. The v7 "ok=true" line means only "didn't
-- throw". Never again treat it as a kill by itself.
-- 2. HP is NOT a field anywhere (character / Hit / status
-- controller field dumps contain no Hp value) - which is why
-- the v5/v6/v7 name hunt found nothing writable. HP lives
-- behind Hit METHODS, dumped by probe53 with signatures:
-- get_Hp() -> Single, get_OldHp(), get_OriginalMaxHp(),
-- get_ReducedMaxHp(), get_IsDie() -> Boolean, and the
-- setters setHpValue(Single, Boolean) and
-- setHp(Single, Boolean, Int32). v8 therefore reads Hp by
-- method, tries each setter in turn with a get_Hp read-back
-- after every attempt, and only when Hp reads 0 does it call
-- killAndSetDieLoop (a die-loop may finally engage once HP
-- is actually 0, where it did nothing at full HP) - then it
-- re-reads get_IsDie / IsStartDead / IsKilledByMethod so the
-- log shows whether the enemy entered a dying state.
-- 3. Damage-entry methods (damageProc / updateDamageHp /
-- updateDamage) all take a DamageInfo object that cannot be
-- fabricated safely from Lua - they stay BANNED, like all
-- damage-named calls since v4's false positives. The HP
-- setters need no DamageInfo, which is why they are tried.
-- The old field hunt + death-call + despawn ladder is kept
-- BELOW the HP ladder as fallback only, and runs only when
-- no HP setter moved Hp to 0.
-- v9 (kill v8 failed live, 2026-10-24): on the summoned Evil
-- Eye (get_Hp 650000, origMax = reducedMax = 650000) ALL FOUR
-- v8 setters returned ok=true and get_Hp read back 650000
-- unchanged, twice (the eye appears twice in _EnemyList, same
-- distSq - one character, two list elements, as with wolves
-- before). ok=true is again only "didn't throw": the setters
-- are silently ignored from outside, so Hp is either computed
-- (from region HPs or from ReducedMaxHp) or needs a damage
-- context. v9 therefore tries, in order, each with a read-back:
-- region HPs (BossHpGaugeNum + getRegionHp / OriginalMax /
-- ReducedMax / isRegionDie, then setRegionOriginalMaxHp(0)
-- per region), setReducedMaxHp(0), recoverHp(-Hp) as a
-- damage-path attempt, and finally the death-state flag
-- itself - Hit.set_IsStartDead(true), which probe53 listed -
-- plus character IsKilledByMethod=true, then one more
-- killAndSetDieLoop, now possibly in a dying context.
-- Success is judged ONLY by a read-back: Hp 0, IsDie true,
-- or IsStartDead true. The v8 setters + field hunt + old
-- death-call + despawn ladder stay as fallback below.
-- v10 (v9 verdict OVERTURNED by the user, twice, 2026-10-24):
-- region-zero DID set Hp 0 + IsDie true on the Evil Eye, and
-- the eye STILL stood in front of him, alive, in the next two
-- runs (already Hp 0 / IsDie true at press time, distances
-- 667 then 1504 - it is moving away, or he is). So IsDie is
-- NOT the character-death flag: it reads like a gauge/region
-- death (region 0 dead, regions 1-9 untouched: 500000, 37500s,
-- 15000s), and the guides' "retreats after its first health
-- section" fits region 0 being one section, not the whole
-- boss. v10 therefore: zero EVERY region (not just region 0),
-- and - the v9 structural bug - ALWAYS run set_IsStartDead
-- and IsKilledByMethod after the region work (v9 skipped them
-- whenever region-zero succeeded, so they were never tried on
-- a Hp-0 enemy at all), then die-loop, with a final state
-- dump. It also logs element/handle pointers per element
-- (are the 2-4 eye list entries one actor or several?) and
-- character <IsImmortality> for in-range targets. Visible
-- death, not any flag, is the only success criterion now.
-- v11 (user verdict, 2026-10-24): "the 2 summons got killed
-- normally the 3rd one does not get kiled by the kill
-- botton." The v10 log names the prime suspect for the
-- 3rd: ch258002's character <IsImmortality> = true, while
-- the wolf in the same run reads false and every Hit gate
-- reads false on both. Immortality is a CHARACTER flag, not
-- a Hit gate, so no earlier ladder ever touched it - and
-- character set_field DOES stick (v10 proved it: the
-- IsKilledByMethod=true set on the first ch258002 element
-- still read true on the second and third elements, same
-- handle). v11 therefore clears IsImmortality first, with a
-- read-back, and re-checks it in the final state. It also
-- logs the pointer proof from v10: many _EnemyList elements
-- share ONE PawnManager handle per species (all ch231000
-- elements -> one handle, all ch258002 elements -> one
-- handle), so element count is not actor count, and the
-- handle is the per-species registered instance. Also
-- noted from v10: setReducedMaxHp(0) reads back 1.0, not 0
-- (clamped by MinRatioReducedMaxHp=1.0 from probe53), and a
-- new far species appeared: ch299400_A_10 (IsBoss=false) -
-- recorded, not named, not in the roster.
-- v12 (v11 failed, user verdict "kill did not work",
-- 2026-10-24): immortality is OUT as the persistent cause -
-- ch258002 read IsImmortality=false this run (it was true
-- in v10, so the flag is transient), and the kill still did
-- not work. The deeper problem is now the target itself:
-- every handle so far was already dead at press time, yet
-- a live actor stood metres away. The PawnManager handle is
-- one registered instance per species (v10 pointers proved
-- it), and it may be stale, not the live actor. v12
-- therefore tries the kill on the _EnemyList ELEMENT itself
-- first - a ChXXXXXX object with its own pointer, its own
-- Hit if it has one, its own gates/regions/death flag -
-- with read-backs, and only then runs the handle ladder as
-- before. If the element's Hp moves but the handle's does
-- not (or vice versa), the log proves they are distinct
-- objects. An element kill is claimed ONLY when its Hp was
-- > 0 before and reads 0 / IsDie flips after - IsDie-true
-- on an already-dead object claims nothing (v9 lesson).
-- This also finally tries Rogues on their own elements,
-- since they never resolve a handle at all.
-- v13 (v12 verdict, 2026-10-24): "that killed the boss
-- but the other summon talos did not die and when the
-- boss got killed i did not gain exp from that." Two
-- separate findings. (1) FIRST VISIBLE KILL: the element
-- ladder killed a boss (ch258002, the long-standing
-- holdout) - operating on the element, not the handle, was
-- the right move. (2) Talos (ch259000) held out under the
-- identical stack, and its element is the ONLY one in the
-- log carrying <EnableDead>k__BackingField = false plus
-- <IsDeadPointA/B>k__BackingField = false - death-gating
-- fields no other element type logged. v13 sets EnableDead
-- true (read-back) before the element die-loop, and logs
-- the DeadPoint fields before/after WITHOUT setting them
-- (their semantics - weak points? death stages? - are not
-- yet known, so they stay read-only this round). (3) EXP:
-- a flag kill bypasses the game's damage/kill-credit
-- pipeline entirely - no attacker is credited, so no EXP
-- is expected from the kill button as built. EXP would
-- need a kill credited through damage (a DamageInfo with
-- the player as attacker), which probe53 already showed
-- cannot be fabricated safely from Lua. That is a separate
-- piece of work, not another flag rung.
-- v14 (v13 verdict "it does not kill talos", 2026-10-24):
-- EnableDead alone is NOT sufficient. Talos's element went
-- 25000 -> 0, IsDie flipped, EnableDead held true, and it
-- still stands. The only Talos-specific difference left in
-- the log is IsDeadPointA/B, still false. v14 sets both
-- true (read-backs) before the die-loop, on elements that
-- HAVE those fields (nil on every other type, so the rung
-- skips cleanly elsewhere). Their exact semantics are
-- still a hypothesis - weak-point/destruction markers or
-- death-stage flags - but they are the last unexplained
-- Talos difference, and setting a named bool on the
-- element with a read-back is the same class as the
-- EnableDead rung that already ran safely. If Talos still
-- stands after this, its death is scripted (not flag
-- driven) and the remaining route is the damage pipeline.
-- CORRECTION to the v12/v13 notes: element Hit is NOT the
-- handle's Hit. The v13 log proves it: ch220001 elements
-- [27][28] read 15000 on the element while the handle
-- reads 0, and Talos's element read 25000 while its handle
-- read 0. Element and handle carry separate Hit state;
-- the element's is the live one.
COMMANDS.summon_kill = function()
  sk_hist = {}
  SK("== summon_kill v14 (bridge 1.89.82) ==")
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  SK("  _EnemyList count=" .. tostring(n))
  if not (pm and list and n) then error("enemy list unavailable - load into the world first") end
  local cfields = sk_char_id_fields()
  local done, skipped = {}, 0
  for i = 0, math.min(n, 40) - 1 do
    local el = try(function() return list:call("get_Item", i) end)
    if el then
      local etd = try(function() return el:get_type_definition() end)
      local tn = etd and try(function() return etd:get_full_name() end) or "?"
      local base = tn:match("app%.(Ch%d+)")
      if base then base = base:lower() end
      local gi = try(function() return el:get_field("<GenerateInfo>k__BackingField") end)
        or try(function() return el:call("get_GenerateInfo") end)
      -- NOTE: do NOT write this as `base and sk_handle_for(...) or
      -- nil`: Lua truncates a call inside and/or to one value, so
      -- the winning enum NAME would be lost (probe 52's log showed
      -- "-> nil" for exactly this reason - the value was right,
      -- the name was dropped by the same construct).
      local ch, won, wcat = nil, nil, nil
      if base then ch, won, wcat = sk_handle_for(pm, cfields, base) end
      local isBoss, distSq = nil, nil
      if ch then
        isBoss = try(function() return ch:get_field("<IsBoss>k__BackingField") end)
        distSq = try(function() return ch:get_field("<DistanceXZSqFromPlayer>k__BackingField") end)
      end
      local near = (type(distSq) ~= "number") or distSq <= 2500
      SK("  [" .. i .. "] " .. tn .. " handle=" .. tostring(ch ~= nil) ..
         (won and (" via " .. won .. " cat=" .. tostring(wcat)) or "") ..
         " IsBoss=" .. tostring(isBoss) ..
         " distSqFromPlayer=" .. tostring(distSq) ..
         " near=" .. tostring(near) ..
         " el=" .. tostring(el) .. " ch=" .. tostring(ch))
      if not near then
        skipped = skipped + 1
      else
        local applied = nil
        local hit = ch and try(function() return ch:get_field("<Hit>k__BackingField") end)
        -- v12 ELEMENT ladder: try the kill on the list
        -- element itself before touching the handle.
        local elApplied = nil
        if el then
          local elHit = try(function() return el:get_field("<Hit>k__BackingField") end)
          if not elHit then elHit = try(function() return el:call("get_Hit") end) end
          local elBoss = try(function() return el:get_field("<IsBoss>k__BackingField") end)
          local elDist = try(function() return el:get_field("<DistanceXZSqFromPlayer>k__BackingField") end)
          local elImm = try(function() return el:get_field("<IsImmortality>k__BackingField") end)
          SK("    v12 element: Hit=" .. tostring(elHit ~= nil) ..
             " IsBoss=" .. tostring(elBoss) .. " distSq=" .. tostring(elDist) ..
             " IsImmortality=" .. tostring(elImm))
          local etd2 = try(function() return el:get_type_definition() end)
          for _, f in ipairs(etd2 and try(function() return etd2:get_fields() end) or {}) do
            local fn = try(function() return f:get_name() end)
            if fn then
              local low = fn:lower()
              if low:find("hit") or low:find("hp") or low:find("die") or low:find("dead") or low:find("immort") or low:find("boss") or low:find("distance") then
                SK("    v12 element field " .. fn .. " = " ..
                   tostring(try(function() return el:get_field(fn) end)))
              end
            end
          end
          if elImm == true then
            local okI = pcall(function() el:set_field("<IsImmortality>k__BackingField", false) end)
            SK("    v12 element IsImmortality cleared: ok=" .. tostring(okI) ..
               ", reads back " .. tostring(try(function() return el:get_field("<IsImmortality>k__BackingField") end)))
          end
          -- v13: Talos's death gate. Only its element type
          -- logs EnableDead, and it reads false while Talos
          -- survives the full stack. Set it true (read-back)
          -- before the die-loop runs. DeadPointA/B are logged
          -- only - their meaning is not established yet.
          local elDeadA = try(function() return el:get_field("<IsDeadPointA>k__BackingField") end)
          local elDeadB = try(function() return el:get_field("<IsDeadPointB>k__BackingField") end)
          local elEnDead = try(function() return el:get_field("<EnableDead>k__BackingField") end)
          SK("    v13 element death gate: EnableDead=" .. tostring(elEnDead) ..
             " IsDeadPointA=" .. tostring(elDeadA) .. " IsDeadPointB=" .. tostring(elDeadB))
          if elEnDead == false then
            local okE = pcall(function() el:set_field("<EnableDead>k__BackingField", true) end)
            SK("    v13 element EnableDead set true: ok=" .. tostring(okE) ..
               ", reads back " .. tostring(try(function() return el:get_field("<EnableDead>k__BackingField") end)))
          end
          -- v14: Talos's last unexplained difference. Only
          -- its element type has these fields; nil elsewhere
          -- means the rung skips cleanly on other species.
          if elDeadA == false then
            local okA = pcall(function() el:set_field("<IsDeadPointA>k__BackingField", true) end)
            SK("    v14 element IsDeadPointA set true: ok=" .. tostring(okA) ..
               ", reads back " .. tostring(try(function() return el:get_field("<IsDeadPointA>k__BackingField") end)))
          end
          if elDeadB == false then
            local okB = pcall(function() el:set_field("<IsDeadPointB>k__BackingField", true) end)
            SK("    v14 element IsDeadPointB set true: ok=" .. tostring(okB) ..
               ", reads back " .. tostring(try(function() return el:get_field("<IsDeadPointB>k__BackingField") end)))
          end
          if elHit then
            for _, fn in ipairs({ "<IsInvincible>k__BackingField",
                                  "<IsDamageZero>k__BackingField",
                                  "<IsNoDie>k__BackingField" }) do
              local v = try(function() return elHit:get_field(fn) end)
              SK("    v12 element gate " .. fn .. " = " .. tostring(v))
              if v == true then
                local okS = pcall(function() elHit:set_field(fn, false) end)
                SK("    v12 element gate cleared: " .. fn .. " (ok=" .. tostring(okS) .. ")")
              end
            end
            local function elHpRead()
              return try(function() return elHit:call("get_Hp") end)
            end
            local elHp = elHpRead()
            local elGauge = try(function() return elHit:call("get_BossHpGaugeNum") end)
            local elDie = try(function() return elHit:call("get_IsDie") end)
            SK("    v12 element HP: get_Hp=" .. tostring(elHp) ..
               " gauge=" .. tostring(elGauge) .. " IsDie=" .. tostring(elDie))
            local elNreg = 1
            if type(elGauge) == "number" and elGauge > 0 and elGauge <= 16 then
              elNreg = math.floor(elGauge)
            end
            for ri = 0, elNreg - 1 do
              local rh = try(function() return elHit:call("getRegionHp", ri) end)
              SK("    v12 element region " .. ri .. " before: Hp=" .. tostring(rh))
              local okR = pcall(function() elHit:call("setRegionOriginalMaxHp", 0, ri, false) end)
              local rh2 = try(function() return elHit:call("getRegionHp", ri) end)
              SK("    v12 element region-zero " .. ri .. ": ok=" .. tostring(okR) ..
                 ", regionHp=" .. tostring(rh2) .. ", get_Hp=" .. tostring(elHpRead()))
            end
            local okS = pcall(function() elHit:call("set_IsStartDead", true) end)
            local elSD = try(function() return elHit:get_field("<IsStartDead>k__BackingField") end)
            local elDie2 = try(function() return elHit:call("get_IsDie") end)
            local elHp2 = elHpRead()
            SK("    v12 element after IsStartDead(true) ok=" .. tostring(okS) ..
               ": IsStartDead=" .. tostring(elSD) .. " IsDie=" .. tostring(elDie2) ..
               " get_Hp=" .. tostring(elHp2))
            local okD = pcall(function() el:call("killAndSetDieLoop") end)
            local elSD2 = try(function() return elHit:get_field("<IsStartDead>k__BackingField") end)
            local elDie3 = try(function() return elHit:call("get_IsDie") end)
            local elHp3 = elHpRead()
            SK("    v12 element after die-loop ok=" .. tostring(okD) ..
               ": IsStartDead=" .. tostring(elSD2) .. " IsDie=" .. tostring(elDie3) ..
               " get_Hp=" .. tostring(elHp3))
            SK("    v13 element death gate after: EnableDead=" ..
               tostring(try(function() return el:get_field("<EnableDead>k__BackingField") end)) ..
               " IsDeadPointA=" .. tostring(try(function() return el:get_field("<IsDeadPointA>k__BackingField") end)) ..
               " IsDeadPointB=" .. tostring(try(function() return el:get_field("<IsDeadPointB>k__BackingField") end)))
            if type(elHp) == "number" and elHp > 0 and
               (elDie3 == true or (type(elHp3) == "number" and elHp3 <= 0)) then
              elApplied = "v12 element kill (confirm visually)"
            end
          end
        end
        if hit then
          for _, fn in ipairs({ "<IsInvincible>k__BackingField",
                                "<IsDamageZero>k__BackingField",
                                "<IsNoDie>k__BackingField" }) do
            local v = try(function() return hit:get_field(fn) end)
            SK("    gate " .. fn .. " = " .. tostring(v))
            if v == true then
              local okS = pcall(function() hit:set_field(fn, false) end)
              SK("    gate cleared: " .. fn .. " -> false (ok=" .. tostring(okS) .. ")")
            end
          end
        end
        if ch then
          SK("    char IsImmortality=" ..
             tostring(try(function() return ch:get_field("<IsImmortality>k__BackingField") end)) ..
             " IsKilledByMethod=" ..
             tostring(try(function() return ch:get_field("IsKilledByMethod") end)))
          -- v11: clear character immortality first, with a
          -- read-back. Hit gates were already false on the
          -- unkilled boss; this flag was the only true gate.
          local imm = try(function() return ch:get_field("<IsImmortality>k__BackingField") end)
          if imm == true then
            local okI = pcall(function() ch:set_field("<IsImmortality>k__BackingField", false) end)
            local imm2 = try(function() return ch:get_field("<IsImmortality>k__BackingField") end)
            SK("    v11 IsImmortality cleared: ok=" .. tostring(okI) ..
               ", reads back " .. tostring(imm2))
          end
        end
        -- v8 HP-method ladder (probe53): read Hp by method,
        -- try each setter with a read-back, die-loop only at 0.
        local hpMethodApplied = nil
        if ch and hit then
          local function hpRead()
            return try(function() return hit:call("get_Hp") end)
          end
          local hpBefore = hpRead()
          local origMax = try(function() return hit:call("get_OriginalMaxHp") end)
          local redMax = try(function() return hit:call("get_ReducedMaxHp") end)
          local dieBefore = try(function() return hit:call("get_IsDie") end)
          SK("    HP methods: get_Hp=" .. tostring(hpBefore) ..
             " origMax=" .. tostring(origMax) ..
             " reducedMax=" .. tostring(redMax) ..
             " IsDie=" .. tostring(dieBefore))
          if type(hpBefore) == "number" and hpBefore > 0 then
            local attempts = {
              { "setHpValue(0, false)", function() hit:call("setHpValue", 0, false) end },
              { "setHpValue(0, true)", function() hit:call("setHpValue", 0, true) end },
              { "setHp(0, false, 0)", function() hit:call("setHp", 0, false, 0) end },
              { "setHp(0, true, 0)", function() hit:call("setHp", 0, true, 0) end },
            }
            for _, a in ipairs(attempts) do
              local okC = pcall(a[2])
              local back = hpRead()
              SK("    HP attempt " .. a[1] .. ": ok=" .. tostring(okC) ..
                 ", get_Hp reads back " .. tostring(back))
              if okC and type(back) == "number" and back <= 0 then
                hpMethodApplied = "hp-method " .. a[1]
                break
              end
            end
            if hpMethodApplied then
              local dieAfterHp = try(function() return hit:call("get_IsDie") end)
              local killedBy = try(function() return ch:get_field("IsKilledByMethod") end)
              local startDead = try(function() return hit:get_field("<IsStartDead>k__BackingField") end)
              SK("    after HP 0: IsDie=" .. tostring(dieAfterHp) ..
                 " IsKilledByMethod=" .. tostring(killedBy) ..
                 " IsStartDead=" .. tostring(startDead))
              local okD = pcall(function() ch:call("killAndSetDieLoop") end)
              local dieAfterDie = try(function() return hit:call("get_IsDie") end)
              local startDead2 = try(function() return hit:get_field("<IsStartDead>k__BackingField") end)
              local killedBy2 = try(function() return ch:get_field("IsKilledByMethod") end)
              local hpAfterDie = hpRead()
              SK("    die-loop after HP 0: ok=" .. tostring(okD) ..
                 ", IsDie=" .. tostring(dieAfterDie) ..
                 " IsStartDead=" .. tostring(startDead2) ..
                 " IsKilledByMethod=" .. tostring(killedBy2) ..
                 " get_Hp=" .. tostring(hpAfterDie))
            end
          elseif hpBefore == 0 then
            SK("    HP already 0 - skipping setters")
          end
        end
        -- v9 ladder (see the v9 comment above the command):
        -- region HPs, reduced-max, damage-path, death flag.
        local v9Applied = nil
        if ch and hit and not hpMethodApplied then
          local function hpRead9()
            return try(function() return hit:call("get_Hp") end)
          end
          local function deadState9(tag)
            local d = try(function() return hit:call("get_IsDie") end)
            local s = try(function() return hit:get_field("<IsStartDead>k__BackingField") end)
            local k = try(function() return ch:get_field("IsKilledByMethod") end)
            local h = hpRead9()
            SK("    v10 state " .. tag .. ": IsDie=" .. tostring(d) ..
               " IsStartDead=" .. tostring(s) ..
               " IsKilledByMethod=" .. tostring(k) ..
               " get_Hp=" .. tostring(h))
            return d, s, h
          end
          local gauge = try(function() return hit:call("get_BossHpGaugeNum") end)
          SK("    v10 regions: BossHpGaugeNum=" .. tostring(gauge))
          local nreg = 1
          if type(gauge) == "number" and gauge > 0 and gauge <= 16 then
            nreg = math.floor(gauge)
          end
          for ri = 0, nreg - 1 do
            local rh = try(function() return hit:call("getRegionHp", ri) end)
            local ro = try(function() return hit:call("getRegionOriginalMaxHp", ri) end)
            local rr = try(function() return hit:call("getRegionReducedMaxHp", ri) end)
            local rd = try(function() return hit:call("isRegionDie", ri) end)
            SK("    v10 region " .. ri .. ": Hp=" .. tostring(rh) ..
               " origMax=" .. tostring(ro) .. " reducedMax=" .. tostring(rr) ..
               " isDie=" .. tostring(rd))
          end
          -- v10: zero EVERY region, no early break. Region 0
          -- alone only killed one section (the eye lived on
          -- with regions 1-9 intact), so each region's own
          -- read-back is the evidence now, not total Hp.
          local regionZeroed = false
          for ri = 0, nreg - 1 do
            local okR = pcall(function() hit:call("setRegionOriginalMaxHp", 0, ri, false) end)
            local rh = try(function() return hit:call("getRegionHp", ri) end)
            local h = hpRead9()
            SK("    v10 region-zero " .. ri .. " (false): ok=" .. tostring(okR) ..
               ", regionHp=" .. tostring(rh) .. ", get_Hp=" .. tostring(h))
            if type(rh) == "number" and rh <= 0 then regionZeroed = true end
            local okR2 = pcall(function() hit:call("setRegionOriginalMaxHp", 0, ri, true) end)
            local rh2 = try(function() return hit:call("getRegionHp", ri) end)
            local h2 = hpRead9()
            SK("    v10 region-zero " .. ri .. " (true): ok=" .. tostring(okR2) ..
               ", regionHp=" .. tostring(rh2) .. ", get_Hp=" .. tostring(h2))
            if type(rh2) == "number" and rh2 <= 0 then regionZeroed = true end
          end
          if not v9Applied then
            local okM = pcall(function() hit:call("setReducedMaxHp", 0) end)
            local rm = try(function() return hit:call("get_ReducedMaxHp") end)
            local h = hpRead9()
            SK("    v10 setReducedMaxHp(0): ok=" .. tostring(okM) ..
               ", reducedMax=" .. tostring(rm) .. ", get_Hp=" .. tostring(h))
            if type(h) == "number" and h <= 0 then
              v9Applied = "v10 setReducedMaxHp(0)"
            end
          end
          if not v9Applied then
            local cur = hpRead9()
            if type(cur) == "number" and cur > 0 then
              local okV = pcall(function() hit:call("recoverHp", -cur, false, 0, false) end)
              local h = hpRead9()
              SK("    v10 recoverHp(-Hp): ok=" .. tostring(okV) .. ", get_Hp=" .. tostring(h))
              if type(h) == "number" and h <= 0 then
                v9Applied = "v10 recoverHp(-Hp)"
              end
            end
          end
          -- v10: ALWAYS run these (v9 skipped them whenever
          -- region-zero succeeded, so they were never tried
          -- on a Hp-0 enemy at all). do...end keeps the
          -- block count identical to the if...end it replaces.
          do
            local okS = pcall(function() hit:call("set_IsStartDead", true) end)
            local d, s, h = deadState9("after set_IsStartDead(true) ok=" .. tostring(okS))
          end
          do
            local okK = pcall(function() ch:set_field("IsKilledByMethod", true) end)
            local d, s, h = deadState9("after IsKilledByMethod=true ok=" .. tostring(okK))
          end
          do
            local okD = pcall(function() ch:call("killAndSetDieLoop") end)
            local d, s, h = deadState9("after die-loop ok=" .. tostring(okD))
            local immF = try(function() return ch:get_field("<IsImmortality>k__BackingField") end)
            SK("    v11 final IsImmortality=" .. tostring(immF))
            if regionZeroed then
              v9Applied = "v11 all-regions zeroed + immortality cleared (confirm visually)"
            end
          end
        end
        if ch then
          if hpMethodApplied then
            applied = hpMethodApplied
          elseif v9Applied then
            applied = v9Applied
          else
            local sc = hit and try(function() return hit:get_field("<CachedStatusConditionCtrl>k__BackingField") end)
            applied = sk_hp_hunt({ { obj = ch, where = "character" },
                                   { obj = hit, where = "hit" },
                                   { obj = sc, where = "statusCtrl" } })
          end
        end
        -- v12: an element kill outranks a handle label, and
        -- it is the only route that can fire for Rogues
        -- (no handle at all, so the block above never runs).
        if elApplied then applied = elApplied end
        if not applied and ch then
          local td = try(function() return ch:get_type_definition() end)
          local cands = {}
          for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
            local mn = try(function() return m:get_name() end)
            if mn then
              local low = mn:lower()
              if not low:find("^get") and not low:find("^is") and not low:find("^on") then
                if low == "kill" or low == "die" or low == "dead" or
                   low:find("kill") or low:find("requestdead") then
                  cands[#cands + 1] = mn
                end
              end
            end
          end
          SK("    death-method candidates (character): [" .. table.concat(cands, ", ") .. "]")
          for _, mn in ipairs(cands) do
            local okC, resC = pcall(function() return ch:call(mn) end)
            SK("    death call " .. mn .. " (character): ok=" ..
               tostring(okC) .. " -> " .. tostring(resC))
            if okC then applied = "death-call " .. mn .. " (character)" break end
          end
        end
        if not applied and gi then
          local okS = pcall(function() gi:set_field("_IsRequestDelete", true) end)
          SK("    despawn fallback: GenerateInfo._IsRequestDelete -> true (ok=" ..
             tostring(okS) .. ")")
          if okS then applied = "despawn (not a kill - no loot/XP)" end
        end
        done[#done + 1] = tn .. (isBoss == true and " [boss]" or "") ..
          ": " .. (applied or "FAILED - send summon_kill.txt")
      end
    end
  end
  local list2 = em and try(function() return em:get_field("_EnemyList") end)
  local n2 = list2 and try(function() return list2:call("get_Count") end)
  SK("  post-scan _EnemyList count=" .. tostring(n2) ..
     " (was " .. tostring(n) .. ")")
  if #done == 0 then
    if n == 0 then return "no enemies in the enemy list right now - see summon_kill.txt" end
    return "enemies found but all beyond ~50 m - get closer and press Kill again"
  end
  local msg = "kill attempt (" .. #done .. " enemies"
  if skipped > 0 then msg = msg .. ", " .. skipped .. " beyond range skipped" end
  return msg .. "): " .. table.concat(done, "; ") ..
    ". Post-scan count " .. tostring(n2) .. " (was " .. tostring(n) ..
    ") - confirm in-game what actually died"
end
end

do
do
---------------------------------------------------------------- v1.89.68: kill diagnosis (probe 52, READ-ONLY)
-- summon_kill v4 log (13 enemies): chara=nil for EVERY element, yet
-- GenerateInfo exists (the despawn fallback ran) - so the chain
-- breaks past gi, OR the SelectedCharacterID conversion fails, OR
-- the int is not in the CharacterID catalog. And the ladder's
-- "damage-call ok" results were false positives: get_GuardDamage
-- is a getter, onDamageHit is an event handler - ok=true only meant
-- the call didn't throw, not that anything died.
-- This dumps every step raw per element, plus a NAME-based enum
-- lookup (type app.Ch261000 -> CharacterID field ch261000_00)
-- that bypasses the int entirely, plus the element's FULL
-- unfiltered field list (v4's scan only showed hp/dead/damage
-- members, so "fields=[]" hid everything else). Writes
-- summon_killdiag.txt and changes NOTHING in-game.
local function sp52_run()
  local hist = {}
  local function L(x)
    hist[#hist + 1] = x
    wr(DIR .. "summon_killdiag.txt", table.concat(hist, "\n"))
  end
  L("== summon_probe52 (bridge 1.89.68) == kill diagnosis (read-only)")
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  L("  _EnemyList count=" .. tostring(n))
  if not (list and n) then error("enemy list unavailable - load into the world first") end
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfields = ctd and try(function() return ctd:get_fields() end) or {}
  local function enum_by_name(base)
    local fallback = nil
    for _, f in ipairs(cfields) do
      if try(function() return f:is_static() end) then
        local nm = try(function() return f:get_name() end)
        if nm == base .. "_00" then
          return try(function() return f:get_data(nil) end), nm
        end
        if nm and nm:sub(1, #base + 1) == base .. "_" and not fallback then
          fallback = { try(function() return f:get_data(nil) end), nm }
        end
      end
    end
    if fallback then return fallback[1], fallback[2] end
    return nil
  end
  for i = 0, math.min(n, 40) - 1 do
    local el = try(function() return list:call("get_Item", i) end)
    if el then
      local etd = try(function() return el:get_type_definition() end)
      local tn = etd and try(function() return etd:get_full_name() end) or "?"
      L("  [" .. i .. "] type=" .. tn)
      local gi = try(function() return el:get_field("<GenerateInfo>k__BackingField") end)
        or try(function() return el:call("get_GenerateInfo") end)
      L("    gi=" .. tostring(gi ~= nil))
      local ci = gi and try(function() return gi:call("get_CommonInfo") end)
      L("    commonInfo=" .. tostring(ci ~= nil))
      local oid = ci and try(function() return ci:get_field("_ObjectID") end)
      L("    objectID=" .. tostring(oid ~= nil))
      local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
      local w = sel and tonumber(tostring(sel)) or nil
      L("    selectedCharacterID raw=" .. tostring(sel) .. " type=" .. type(sel) ..
         " tonumber=" .. tostring(w))
      if w then
        local found = nil
        for _, f in ipairs(cfields) do
          if try(function() return f:is_static() end) then
            local d = try(function() return f:get_data(nil) end)
            if d and tonumber(tostring(d)) == w then
              found = try(function() return f:get_name() end)
              break
            end
          end
        end
        L("    enumByInt(" .. w .. ")=" .. tostring(found))
      end
      local base = tn:match("app%.(Ch%d+)")
      if base then base = base:lower() end
      -- NOTE: never `base and enum_by_name(base) or nil` - Lua
      -- truncates a call inside and/or to one value, which is why
      -- probe 52's log showed "-> nil" for the name while the
      -- value itself was correct.
      local en, enm = nil, nil
      if base then en, enm = enum_by_name(base) end
      L("    enumByName base=" .. tostring(base) .. " -> " .. tostring(enm) ..
         " value=" .. tostring(en))
      local ch = en and try(function() return pm:call("getInstanceChara", 3, en) end)
      L("    getInstanceChara(3, nameEnum)=" .. tostring(ch ~= nil))
      if ch then
        L("      IsBoss=" .. tostring(try(function() return ch:get_field("<IsBoss>k__BackingField") end)) ..
           " distSq=" .. tostring(try(function() return ch:get_field("<DistanceXZSqFromPlayer>k__BackingField") end)))
        local hit = try(function() return ch:get_field("<Hit>k__BackingField") end)
        L("      Hit=" .. tostring(hit ~= nil))
        if hit then
          local htd = try(function() return hit:get_type_definition() end)
          local fns = {}
          for _, f in ipairs(htd and try(function() return htd:get_fields() end) or {}) do
            local fn = try(function() return f:get_name() end)
            if fn then fns[#fns + 1] = fn end
            if #fns >= 60 then break end
          end
          L("      Hit fields=[" .. table.concat(fns, ", ") .. "]")
        end
      end
      local efns = {}
      for _, f in ipairs(etd and try(function() return etd:get_fields() end) or {}) do
        local fn = try(function() return f:get_name() end)
        if fn then efns[#efns + 1] = fn end
        if #efns >= 60 then break end
      end
      L("    element fields=[" .. table.concat(efns, ", ") .. "]")
      local ehit = try(function() return el:get_field("<Hit>k__BackingField") end)
      L("    element <Hit>=" .. tostring(ehit ~= nil))
    end
  end
  L("== probe52 done - send summon_killdiag.txt ==")
  return hist
end

COMMANDS.summon_probe52 = function()
  local hist = sp52_run()
  return "summon_probe52: " .. (hist[#hist] or "done")
end
end

do
---------------------------------------------------------------- v1.89.72: kill probe 53 - where is HP, what does the death call change
-- v7 verdict (user, certain): killAndSetDieLoop ok=true kills
-- NOBODY visible. The v5 "probably died" verdict is overturned:
-- the call is a no-op on a healthy enemy (or sets a state the
-- AI overrides while HP > 0). So before any more kill designs,
-- find out, on ONE live boss (first handle-found boss, else
-- first handle-found enemy):
--   * character fields WITH values (HP by VALUE, not by name -
--     the v5/v6/v7 name hunt found nothing writable)
--   * Hit fields WITH values + status-controller fields/values
--   * <IsStartDead> / <systemStatus> / <TempStatusFlag> BEFORE
--     and AFTER one killAndSetDieLoop call (does it change
--     anything at all?)
--   * Hit methods WITH signatures (a real damage entry takes
--     a damage value; v4's were getters/handlers)
-- Self-contained (own copies of the enum/handle helpers).
-- The death call is the same one v7 already made on three
-- bosses with no adverse effect. Writes summon_probe53.txt
-- and changes nothing else in-game.
local function p53_enums_for(cfields, base)
  local out, rest = {}, {}
  for _, f in ipairs(cfields) do
    if try(function() return f:is_static() end) then
      local nm = try(function() return f:get_name() end)
      if nm then
        if nm == base .. "_00" then
          out[#out + 1] = { try(function() return f:get_data(nil) end), nm }
        elseif nm:sub(1, #base + 1) == base .. "_" then
          rest[#rest + 1] = { try(function() return f:get_data(nil) end), nm }
        end
      end
    end
  end
  for _, r in ipairs(rest) do out[#out + 1] = r end
  return out
end

local function p53_handle_for(pm, cfields, base)
  for _, cat in ipairs({ 3, 0, 1, 2, 4, 5, 6 }) do
    for _, e in ipairs(p53_enums_for(cfields, base)) do
      local ch = e[1] and try(function() return pm:call("getInstanceChara", cat, e[1]) end)
      if ch then return ch, e[2], cat end
    end
  end
  return nil
end

local function p53_dump_fields(L, title, obj)
  L("  " .. title)
  if not obj then L("    (nil)") return end
  local td = try(function() return obj:get_type_definition() end)
  local fs = td and try(function() return td:get_fields() end) or {}
  L("    type=" .. tostring(td and try(function() return td:get_full_name() end)) ..
    " fields=" .. tostring(#fs))
  for _, f in ipairs(fs) do
    local fn = try(function() return f:get_name() end)
    if fn then
      local v = try(function() return obj:get_field(fn) end)
      L("    " .. fn .. " = " .. tostring(v))
    end
  end
end

COMMANDS.summon_probe53 = function()
  local hist = {}
  local function L(x)
    hist[#hist + 1] = x
    wr(DIR .. "summon_probe53.txt", table.concat(hist, "\n"))
  end
  L("== summon_probe53 (bridge 1.89.72) == death-call diagnosis")
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  L("  _EnemyList count=" .. tostring(n))
  if not (pm and list and n) then error("enemy list unavailable - load into the world first") end
  local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
  local cfields = ctd and try(function() return ctd:get_fields() end) or {}
  local target, targetInfo = nil, nil
  local first = nil
  for i = 0, math.min(n, 40) - 1 do
    local el = try(function() return list:call("get_Item", i) end)
    if el then
      local etd = try(function() return el:get_type_definition() end)
      local tn = etd and try(function() return etd:get_full_name() end) or "?"
      local base = tn:match("app%.(Ch%d+)")
      if base then base = base:lower() end
      local ch, won, wcat = nil, nil, nil
      if base then ch, won, wcat = p53_handle_for(pm, cfields, base) end
      if ch then
        local isBoss = try(function() return ch:get_field("<IsBoss>k__BackingField") end)
        local distSq = try(function() return ch:get_field("<DistanceXZSqFromPlayer>k__BackingField") end)
        local info = "[" .. i .. "] " .. tn .. " via " .. tostring(won) ..
          " cat=" .. tostring(wcat) .. " IsBoss=" .. tostring(isBoss) ..
          " distSq=" .. tostring(distSq)
        if not first then first = { ch = ch, info = info } end
        if isBoss == true then target = { ch = ch, info = info } break end
      end
    end
  end
  target = target or first
  if not target then L("  no handle-found enemy - nothing to probe") return "summon_probe53: no target" end
  local ch = target.ch
  L("  target: " .. target.info)
  local hit = try(function() return ch:get_field("<Hit>k__BackingField") end)
  local sc = hit and try(function() return hit:get_field("<CachedStatusConditionCtrl>k__BackingField") end)
  p53_dump_fields(L, "character fields+values:", ch)
  p53_dump_fields(L, "Hit fields+values:", hit)
  p53_dump_fields(L, "status-controller fields+values:", sc)
  local function snap(tag)
    if not hit then L("  snapshot " .. tag .. ": (no Hit)") return end
    for _, fn in ipairs({ "<IsStartDead>k__BackingField",
                          "<systemStatus>k__BackingField",
                          "<TempStatusFlag>k__BackingField" }) do
      L("  snapshot " .. tag .. " " .. fn .. " = " ..
        tostring(try(function() return hit:get_field(fn) end)))
    end
  end
  snap("BEFORE")
  local td = try(function() return ch:get_type_definition() end)
  local hasDie = false
  for _, m in ipairs(td and try(function() return td:get_methods() end) or {}) do
    if try(function() return m:get_name() end) == "killAndSetDieLoop" then hasDie = true break end
  end
  L("  killAndSetDieLoop present on character: " .. tostring(hasDie))
  if hasDie then
    local okC, resC = pcall(function() return ch:call("killAndSetDieLoop") end)
    L("  death call killAndSetDieLoop: ok=" .. tostring(okC) .. " -> " .. tostring(resC))
  end
  snap("AFTER")
  L("  Hit methods with signatures:")
  if hit then
    local htd = try(function() return hit:get_type_definition() end)
    for _, m in ipairs(htd and try(function() return htd:get_methods() end) or {}) do
      local mn = try(function() return m:get_name() end)
      if mn then
        local pts = try(function() return m:get_param_types() end) or {}
        local ps = {}
        for _, t in ipairs(pts) do
          ps[#ps + 1] = try(function() return t:get_full_name() end) or "?"
        end
        local rt = try(function() return m:get_return_type() end)
        L("    " .. mn .. "(" .. table.concat(ps, ", ") .. ") -> " ..
          tostring(rt and try(function() return rt:get_full_name() end) or "?"))
      end
    end
  end
  L("== probe53 done - send summon_probe53.txt ==")
  return "summon_probe53: " .. (hist[#hist] or "done")
end

---------------------------------------------------------------- v1.89.79: EXP-credit diagnosis (probe 54)
-- User: "I want to be credited xp." A flag kill bypasses
-- damage/kill-credit, so no EXP. Before ANY DamageInfo
-- work, map the pipeline READ-ONLY: killer/attacker/exp
-- fields on a live target + its Hit, damage-method
-- signatures (which name the DamageInfo type), that
-- type's fields, whether a detached instance can even be
-- created from Lua, player EXP storage, and - via an
-- observation-only hook on damageProc - the shape of a
-- REAL DamageInfo from a normal player hit. The hook logs
-- at most 5 hits, then goes silent; it never modifies
-- anything and never blocks a call. Nothing here calls a
-- damage method and nothing here kills anything. The
-- DamageInfo fabrication (if the probe shows it is
-- possible at all) is a later, separately-tested step -
-- it is NOT attempted here.
COMMANDS.summon_probe54 = function()
  local hist = {}
  local function L(x)
    hist[#hist + 1] = x
    wr(DIR .. "summon_expdiag.txt", table.concat(hist, "\n"))
  end
  L("== summon_probe54 (bridge 1.89.79) == EXP-credit diagnosis")
  local function filtFields(title, obj, pats)
    L("  " .. title)
    if not obj then L("    (nil)") return end
    local td = try(function() return obj:get_type_definition() end)
    for _, f in ipairs(td and try(function() return td:get_fields() end) or {}) do
      local fn = try(function() return f:get_name() end)
      if fn then
        local low = fn:lower()
        for _, p in ipairs(pats) do
          if low:find(p) then
            L("    " .. fn .. " = " .. tostring(try(function() return obj:get_field(fn) end)))
            break
          end
        end
      end
    end
  end
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  L("  _EnemyList count=" .. tostring(n))
  local target = nil
  if pm and list and n then
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    local cfields = ctd and try(function() return ctd:get_fields() end) or {}
    for i = 0, math.min(n, 40) - 1 do
      local el = try(function() return list:call("get_Item", i) end)
      if el then
        local etd = try(function() return el:get_type_definition() end)
        local tn = etd and try(function() return etd:get_full_name() end) or "?"
        local base = tn:match("app%.(Ch%d+)")
        if base then base = base:lower() end
        local ch, won, wcat = nil, nil, nil
        if base then ch, won, wcat = p53_handle_for(pm, cfields, base) end
        if ch then
          local isBoss = try(function() return ch:get_field("<IsBoss>k__BackingField") end)
          local distSq = try(function() return ch:get_field("<DistanceXZSqFromPlayer>k__BackingField") end)
          local near = (type(distSq) ~= "number") or distSq <= 2500
          if near then
            target = { ch = ch, tn = tn, won = won }
            if isBoss == true then break end
          end
        end
      end
    end
  end
  local hitTd, dmgTypeName = nil, nil
  if target then
    L("  target: " .. target.tn .. " via " .. tostring(target.won))
    local ch = target.ch
    local hit = try(function() return ch:get_field("<Hit>k__BackingField") end)
    filtFields("target character fields (killer/attacker/exp/reward/dead/die/owner):", ch,
      { "killer", "attacker", "exp", "reward", "dead", "die", "owner" })
    filtFields("target Hit fields (killer/attacker/exp/reward/dead/die/damage):", hit,
      { "killer", "attacker", "exp", "reward", "dead", "die", "damage" })
    if hit then
      hitTd = try(function() return hit:get_type_definition() end)
      L("  target Hit type=" .. tostring(hitTd and try(function() return hitTd:get_full_name() end)))
      for _, m in ipairs(hitTd and try(function() return hitTd:get_methods() end) or {}) do
        local mn = try(function() return m:get_name() end)
        if mn then
          local low = mn:lower()
          if low:find("damage") or low:find("killer") or low:find("attacker") then
            local pts = try(function() return m:get_param_types() end) or {}
            local ps = {}
            for _, t in ipairs(pts) do ps[#ps + 1] = try(function() return t:get_full_name() end) or "?" end
            local rt = try(function() return m:get_return_type() end)
            L("    " .. mn .. "(" .. table.concat(ps, ", ") .. ") -> " ..
              tostring(rt and try(function() return rt:get_full_name() end) or "?"))
            if mn == "damageProc" and #ps >= 1 then dmgTypeName = ps[1] end
          end
        end
      end
    end
  else
    L("  no in-range target - skipping target sections")
  end
  if dmgTypeName then
    L("  DamageInfo type (damageProc param 1): " .. dmgTypeName)
    local dtd = try(function() return sdk.find_type_definition(dmgTypeName) end)
    if dtd then
      for _, f in ipairs(try(function() return dtd:get_fields() end) or {}) do
        L("    DamageInfo field: " .. tostring(try(function() return f:get_name() end)))
      end
    else
      L("    type definition not found")
    end
    local dtd2 = try(function() return sdk.find_type_definition(dmgTypeName) end)
    local okI, inst = pcall(function() return dtd2 and dtd2:create_instance() end)
    L("  TypeDefinition:create_instance: ok=" .. tostring(okI) .. " -> " .. tostring(inst))
    local okS, inst2 = pcall(function() return sdk.create_instance(dmgTypeName) end)
    L("  sdk.create_instance: ok=" .. tostring(okS) .. " -> " .. tostring(inst2))
  else
    L("  damageProc not found on target Hit - DamageInfo type unknown from here")
  end
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  local player = cm and try(function() return cm:call("get_ManualPlayer") end)
  L("  player (ManualPlayer): " .. tostring(player))
  if player then
    filtFields("player character fields (exp/level/job):", player, { "exp", "level", "job" })
    local ctx = name_context_of(player, "app.PlayerPersonalDataContext")
    L("  player PlayerPersonalDataContext: " .. tostring(ctx))
    if ctx then filtFields("player context fields (exp/level/job):", ctx, { "exp", "level", "job" }) end
    local phit = try(function() return player:get_field("<Hit>k__BackingField") end)
    if phit then
      local ptd = try(function() return phit:get_type_definition() end)
      L("  player Hit type=" .. tostring(ptd and try(function() return ptd:get_full_name() end)))
      for _, m in ipairs(ptd and try(function() return ptd:get_methods() end) or {}) do
        local mn = try(function() return m:get_name() end)
        if mn and mn:lower():find("exp") then L("    player Hit method: " .. mn) end
      end
    end
  end
  if not _G.__exp_hook_armed then
    local dm = nil
    if hitTd then
      for _, m in ipairs(try(function() return hitTd:get_methods() end) or {}) do
        if try(function() return m:get_name() end) == "damageProc" then dm = m break end
      end
    end
    if dm then
      local okH, errH = pcall(function()
        sdk.hook(dm, function(hitObj, dmg)
          pcall(function()
            if (_G.__exp_hits or 0) >= 5 then return end
            _G.__exp_hits = (_G.__exp_hits or 0) + 1
            hist[#hist + 1] = "  EXP HOOK hit #" .. _G.__exp_hits ..
              ": DamageInfo type=" .. tostring(dmg and try(function() return dmg:get_type_definition():get_full_name() end))
            if dmg then
              local dtd3 = try(function() return dmg:get_type_definition() end)
              for _, f in ipairs(dtd3 and try(function() return dtd3:get_fields() end) or {}) do
                local fn = try(function() return f:get_name() end)
                if fn then
                  local low = fn:lower()
                  if low:find("attack") or low:find("damage") or low:find("killer") or low:find("owner") or low:find("hitinfo") or low:find("exp") then
                    hist[#hist + 1] = "    DamageInfo " .. fn .. " = " ..
                      tostring(try(function() return dmg:get_field(fn) end))
                  end
                end
              end
            end
            wr(DIR .. "summon_expdiag.txt", table.concat(hist, "\n"))
          end)
        end)
      end)
      if okH then
        _G.__exp_hook_armed = true
        L("  damageProc hook ARMED (logs first 5 real hits, modifies nothing)")
      else
        L("  damageProc hook failed: " .. tostring(errH))
      end
    else
      L("  damageProc method not found on Hit type - hook not armed")
    end
  else
    L("  damageProc hook already armed (hits logged so far: " .. tostring(_G.__exp_hits or 0) .. ")")
  end
  L("== probe54 done - hit an enemy normally, then send summon_expdiag.txt ==")
  return "summon_probe54: done (hook armed, hit something, then re-send the file)"
end
end

---------------------------------------------------------------- v1.89.67: identify nearby enemies (probe 51)
-- The dropdown is missing bosses the user knows exist
-- (troll, beholder) because the only naming source
-- (charRef.lua) has no entries for them - and the game
-- itself attaches no names. The oracle is the user's own
-- eyes: stand next to the creature, press Identify, and
-- this dumps every nearby enemy's type + character id +
-- catalog code. He reports which one he was looking at,
-- and the code gets its name from his word (the Cyclops /
-- Medusa / Satanachia pattern).
local function sp51_run()
  local hist = {}
  local function L(x)
    hist[#hist + 1] = x
    wr(DIR .. "summon_identify.txt", table.concat(hist, "\n"))
  end
  L("== summon_probe51 (bridge 1.89.67) == identify nearby enemies")
  local function chara_of(el)
    local gi = try(function() return el:get_field("<GenerateInfo>k__BackingField") end)
      or try(function() return el:call("get_GenerateInfo") end)
    local ci = gi and try(function() return gi:call("get_CommonInfo") end)
    local oid = ci and try(function() return ci:get_field("_ObjectID") end)
    local sel = oid and try(function() return oid:get_field("_SelectedCharacterID") end)
    return sel and tonumber(tostring(sel)) or nil
  end
  local function code_of(want)
    local ctd = try(function() return sdk.find_type_definition("app.CharacterID") end)
    for _, f in ipairs(ctd and try(function() return ctd:get_fields() end) or {}) do
      if try(function() return f:is_static() end) then
        local d = try(function() return f:get_data(nil) end)
        if d and tonumber(tostring(d)) == want then
          return try(function() return f:get_name() end)
        end
      end
    end
    return nil
  end
  local pm = try(function() return sdk.get_managed_singleton("app.PawnManager") end)
  local em = try(function() return sdk.get_managed_singleton("app.EnemyManager") end)
  local list = em and try(function() return em:get_field("_EnemyList") end)
  local n = list and try(function() return list:call("get_Count") end)
  L("  _EnemyList count=" .. tostring(n))
  if not (list and n) then error("enemy list unavailable - load into the world first") end
  for i = 0, math.min(n, 40) - 1 do
    local el = try(function() return list:call("get_Item", i) end)
    if el then
      local etd = try(function() return el:get_type_definition() end)
      local tn = etd and try(function() return etd:get_full_name() end) or "?"
      local cv = chara_of(el)
      local code = cv and code_of(cv)
      L("  [" .. i .. "] type=" .. tn .. " chara=" .. tostring(cv) ..
         " code=" .. tostring(code))
    end
  end
  L("== identify done - tell me which entry you were standing next to ==")
  return hist
end

COMMANDS.summon_probe51 = function()
  local hist = sp51_run()
  return "summon_probe51: " .. (hist[#hist] or "done")
end
end

---------------------------------------------------------------- v1.24: fast travel (FastTravelAnywhere core, no hotkeys/UI)
-- Engine warp via TimeSkipManager.requestPlayerWarp: clean sector streaming and
-- pawn party teleportation. 6s post-warp fall protection: forces the Jump tab's
-- no-fall-damage field patching on for 6s (saving/restoring the user's setting),
-- plus a skip-hook on the fall-damage handler if it can be found.
-- Altitude modes: "fixed" = pins drop from altitude, landmarks land near ground;
-- "offset" = land <alt> meters above the destination.
local FT = { protect_until = 0, forced = false, saved = nil, hook_ok = false, last_path = "never" }
do
  local td = try(function() return sdk.find_type_definition("app.Human") end)
  local m = td and try(function() return td:get_method("Chara_DamageFromFallHandler(System.Single)") end)
  if m then
    FT.hook_ok = pcall(sdk.hook, m, function(args)
      if os.clock() < FT.protect_until then
        return sdk.PreHookResult.SKIP_ORIGINAL
      end
    end, nil)
    log.info(TAG .. "fast travel: fall-damage hook " .. (FT.hook_ok and "installed" or "FAILED"))
  else
    log.info(TAG .. "fast travel: fall handler NOT FOUND (patch-only protection)")
  end
end

local FT_UI = nil
do
  local td = try(function() return sdk.find_type_definition("app.ui040205") end)
  if td then
    for _, mn in ipairs({ "addMapIconInfoList", "setPin", "setupIconName" }) do
      local m = try(function() return td:get_method(mn) end)
      if m then
        pcall(sdk.hook, m, function(args)
          FT_UI = try(function() return sdk.to_managed_object(args[2]) end) or FT_UI
        end, nil)
      end
    end
  end
end

local function ft_gui_mgr()
  return try(function() return sdk.get_managed_singleton("app.GuiManager") end)
end

local function ft_icon_pos()
  local g = ft_gui_mgr()
  if g then
    local list = try(function() return g:get_field("<MapPinList>k__BackingField") end)
      or try(function() return g:call("get_MapPinList") end)
    local n = (list and try(function() return list:get_Count() end)) or 0
    if n > 0 then
      -- most recently placed pin first; skip ones with empty positions.
      -- <MapPinList> is MapIconInfo[] (array): use Get, not get_Item.
      local function get_pin(i)
        return try(function() return list:call("GetValue", i) end)
          or try(function() return list:call("Get", i) end)
          or try(function() return list:get_Item(i) end)
      end
      -- the game flags the user's active pin with IsEnable=true;
      -- index order is meaningless, so find the enabled one
      for i = 0, n - 1 do
        local icon = get_pin(i)
        local enabled = icon and try(function() return icon:get_field("IsEnable") end)
        if enabled then
          local pos = try(function() return icon:get_field("Pos") end)
            or try(function() return icon:get_field("Position") end)
          if pos and not (pos.x == 0 and pos.z == 0) then
            FT.pin_index = i
            return pos, "pin"
          end
        end
      end
      -- fallback: first pin with a valid position
      for i = 0, n - 1 do
        local icon = get_pin(i)
        local pos = icon and (try(function() return icon:get_field("Pos") end)
          or try(function() return icon:get_field("Position") end))
        if pos and not (pos.x == 0 and pos.z == 0) then
          FT.pin_index = i
          return pos, "pin"
        end
      end
    end
  end
  if FT_UI then
    local sel = try(function() return FT_UI:get_field("SelectedIcon") end)
    local pos = sel and (try(function() return sel:get_field("Pos") end)
      or try(function() return sel:get_field("Position") end))
    if pos then return pos, "landmark" end
  end
  return nil, nil
end

local function ft_quest_pos()
  local g = ft_gui_mgr()
  if not g then return nil end
  return try(function()
    local ml = g:get_field("QuestTargetMarkerList")
      or g:call("getQuestTargetMarkerList")
      or g:get_QuestTargetMarkerList()
    if not ml or ml:get_Count() == 0 then return nil end
    local mk = ml:get_Item(0)
    local pos = mk and mk.Pos
    if not pos or (pos.x == 0 and pos.y == 0 and pos.z == 0) then return nil end
    return pos
  end)
end

local function ft_warp(pos, kind, mode, alt)
  local cm = try(function() return sdk.get_managed_singleton("app.CharacterManager") end)
  if not cm then error("CharacterManager unavailable") end
  local player = try(function() return cm:get_field("<ManualPlayer>k__BackingField") end)
  if not player then error("player not loaded") end
  alt = tonumber(alt) or 350.0
  local ty
  if mode == "offset" then
    ty = (pos.y or 0) + alt
  elseif pos.y and pos.y >= 35.0 then
    -- real altitude (quest markers, valid pins): land just above it
    ty = pos.y + 5.0
  else
    -- no valid altitude (map pins have y=0): drop from high above the
    -- tallest terrain. 6s fall protection lands us safely.
    ty = math.min(math.max(alt, 800.0), 2000.0)
  end
  -- protection window scales with drop height (800m needs ~13s)
  local protect_secs = 6.0
  if not (pos.y and pos.y >= 35.0) and mode ~= "offset" then
    protect_secs = math.min(6.0 + math.max(0, ty - 300.0) / 100.0, 25.0)
  end
  FT.protect_until = os.clock() + protect_secs
  local tsm = try(function() return sdk.get_managed_singleton("app.TimeSkipManager") end)
  local tm = try(function() return sdk.get_managed_singleton("app.TimeManager") end)
  if tsm and tm then
    local ok = pcall(function()
      local hr = tm:get_InGameHour()
      local mn = tm:get_InGameMinute()
      local dy = tm:get_InGameDay()
      local ptd = sdk.find_type_definition("via.Position")
      local upos = ValueType.new(ptd)
      upos.x, upos.y, upos.z = pos.x, ty, pos.z
      local transform = try(function() return player:get_Transform() end)
      local rot = transform and try(function() return transform:get_Rotation() end)
      tsm:call("requestPlayerWarp", hr, mn, dy, upos, rot, nil, true, true)
    end)
    if ok then
      FT.last_path = "engine"
      return string.format("warped to (%.1f, %.1f, %.1f) [pin#%s 6s fall protection: %s]", pos.x, ty, pos.z, tostring(FT.pin_index), FT.hook_ok and "hook+patch" or "patch")
    end
  end
  local transform = try(function() return player:get_Transform() end)
  if not transform then error("warp failed (no TimeSkipManager, no transform)") end
  local ok = pcall(function()
    transform:set_Position(Vector3f.new(pos.x, ty, pos.z))
  end)
  if not ok then error("warp failed") end
  FT.last_path = "direct"
  return string.format("moved to (%.1f, %.1f, %.1f) [pin#%s direct, 6s fall protection: %s]", pos.x, ty, pos.z, tostring(FT.pin_index), FT.hook_ok and "hook+patch" or "patch")
end

-- args: mode ("fixed"/"offset"), altitude-or-offset
COMMANDS.warp_to_pin = function(a)
  local pos, kind = ft_icon_pos()
  if not pos then error("no map pin or icon found - place a pin on the map first") end
  return ft_warp(pos, kind, a[1], a[2])
end

COMMANDS.warp_to_quest = function(a)
  local pos = ft_quest_pos()
  if not pos then error("no active quest marker found") end
  return ft_warp(pos, "landmark", a[1], a[2])
end

---------------------------------------------------------------- v1.41 warp probe
-- Diagnostics for fast travel: fall-hook status, TimeSkipManager presence,
-- requestPlayerWarp found/not-found, interesting TimeSkipManager methods,
-- full field dumps of the first map pin and quest marker (to find the true
-- altitude field), and which warp path the last warp took.
COMMANDS.warp_probe = function()
  local out = {}
  local function L(x) out[#out + 1] = x end
  L("fall hook: " .. (FT.hook_ok and "installed" or "NOT FOUND"))
  local tsm = try(function() return sdk.get_managed_singleton("app.TimeSkipManager") end)
  local tm = try(function() return sdk.get_managed_singleton("app.TimeManager") end)
  L("TimeSkipManager: " .. (tsm and "yes" or "no"))
  L("TimeManager: " .. (tm and "yes" or "no"))
  L("last warp path: " .. FT.last_path)
  if tsm then
    local td = try(function() return tsm:get_type_definition() end)
    local methods = (td and try(function() return td:get_methods() end)) or {}
    local interesting = {}
    for _, m in ipairs(methods) do
      local mn = try(function() return m:get_name() end) or ""
      local l = mn:lower()
      if l:find("warp", 1, true) or l:find("skip", 1, true)
        or (l:find("time", 1, true) and not l:find("get", 1, true)) then
        interesting[#interesting + 1] = mn
      end
    end
    L("TimeSkipManager methods (" .. #methods .. " total): " ..
      (#interesting > 0 and table.concat(interesting, ", ") or "<none interesting>"))
    local rp = td and try(function() return td:get_method("requestPlayerWarp") end)
    L("requestPlayerWarp: " .. (rp and "found" or "NOT FOUND"))
  end
  local function dump_fields(obj, label, cap)
    if type(obj) ~= "userdata" then L(label .. ": <nil>"); return end
    local td = try(function() return obj:get_type_definition() end)
    if not td then L(label .. ": <no typedef>"); return end
    L(label .. " (" .. (try(function() return td:get_full_name() end) or "?") .. "):")
    local n = 0
    for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
      if n >= cap then break end
      local fn = try(function() return f:get_name() end) or "?"
      local v = try(function() return obj:get_field(fn) end)
      local vs
      if type(v) == "userdata" then
        local vt = try(function() return v:get_type_definition() end)
        vs = "<" .. (vt and try(function() return vt:get_full_name() end) or type(v)) .. ">"
        local x = try(function() return v.x end)
        if type(x) == "number" then
          vs = vs .. string.format("(%.1f, %.1f, %.1f)",
            x, try(function() return v.y end) or 0, try(function() return v.z end) or 0)
        end
      else
        vs = tostring(v):sub(1, 60)
      end
      L("  " .. fn .. " = " .. vs)
      n = n + 1
    end
  end
  local g = try(function() return sdk.get_managed_singleton("app.GuiManager") end)
  local list = g and (try(function() return g:get_field("<MapPinList>k__BackingField") end)
    or try(function() return g:call("get_MapPinList") end))
  local np = (list and try(function() return list:get_Count() end)) or 0
  L("map pins: " .. np)
  if np > 0 then dump_fields(try(function() return list:call("GetValue", np - 1) end), "pin[last]", 40) end
  for i = 0, math.min(np, 8) - 1 do
    local icon = try(function() return list:call("GetValue", i) end)
      or try(function() return list:call("Get", i) end)
      or try(function() return list:get_Item(i) end)
    if type(icon) == "userdata" then
      local itd = try(function() return icon:get_type_definition() end)
      local bits = {}
      for _, f in ipairs((itd and try(function() return itd:get_fields() end)) or {}) do
        local fn = try(function() return f:get_name() end) or ""
        local l = fn:lower()
        if l:find("pos", 1, true) or l:find("enable", 1, true) or l:find("active", 1, true)
          or l:find("valid", 1, true) or l:find("visible", 1, true) or l:find("id", 1, true)
          or l:find("time", 1, true) or l:find("no", 1, true) or l:find("index", 1, true)
          or l:find("flag", 1, true) then
          local v = try(function() return icon:get_field(fn) end)
          local vs
          if type(v) == "userdata" then
            local x = try(function() return v.x end)
            if type(x) == "number" then
              vs = string.format("(%.1f, %.1f, %.1f)",
                x, try(function() return v.y end) or 0, try(function() return v.z end) or 0)
            else vs = "<userdata>" end
          else
            vs = tostring(v):sub(1, 40)
          end
          bits[#bits + 1] = fn .. "=" .. vs
        end
      end
      L("pin[" .. i .. "] (" .. (itd and try(function() return itd:get_full_name() end) or "?") ..
        "): " .. (#bits > 0 and table.concat(bits, ", ") or "<no pos/enable fields>"))
    else
      L("pin[" .. i .. "]: <nil>")
    end
  end
  -- terrain height API hunt: is there any ground-height query?
  do
    local out2 = {}
    for _, tn in ipairs({ "app.FieldManager", "via.physics.PhysicsWorld",
        "app.TerrainManager", "via.Terrain" }) do
      local td = try(function() return sdk.find_type_definition(tn) end)
      if td then
        local hm = {}
        for _, m in ipairs(try(function() return td:get_methods() end) or {}) do
          local mn = try(function() return m:get_name() end) or ""
          local l = mn:lower()
          if l:find("height", 1, true) or l:find("ground", 1, true)
            or l:find("terrain", 1, true) or l:find("raycast", 1, true)
            or l:find("ray", 1, true) then
            hm[#hm + 1] = mn
          end
        end
        out2[#out2 + 1] = tn .. ": " .. (#hm > 0 and table.concat(hm, ", ") or "no height methods")
      else
        out2[#out2 + 1] = tn .. ": type not found"
      end
    end
    L("terrain API hunt: " .. table.concat(out2, " // "))
  end
  -- altitude discovery: hook setMapPin + hunt map-UI height methods
  do
    if not FT.pinhook then
      local g2 = try(function() return sdk.get_managed_singleton("app.GuiManager") end)
      local td2 = g2 and try(function() return g2:get_type_definition() end)
      local sm = td2 and try(function() return td2:get_method("setMapPin") end)
      if sm then
        local okh = pcall(sdk.hook, sm, function(hargs)
          if FT.pin_args then return end
          local vals = {}
          for i = 3, 8 do
            local a = hargs[i]
            if a == nil then break end
            local iv = try(function() return sdk.to_int64(a) end)
            local desc = "a" .. (i - 2) .. "=" .. tostring(iv)
            if iv and iv > 65536 then
              local mo = try(function() return sdk.to_managed_object(a) end)
              local x = mo and try(function() return mo.x end)
              if type(x) == "number" then
                desc = desc .. string.format("(%.1f,%.1f,%.1f)", x,
                  try(function() return mo.y end) or 0,
                  try(function() return mo.z end) or 0)
              end
            end
            vals[#vals + 1] = desc
          end
          FT.pin_args = table.concat(vals, " ")
        end, nil)
        FT.pinhook = okh and true or false
        L("setMapPin hook: " .. (FT.pinhook and "installed" or "FAILED"))
      else
        L("setMapPin: method not found")
      end
    else
      L("setMapPin hook: already installed")
    end
    L("setMapPin capture: " .. (FT.pin_args or
      "none yet - place a pin on the map, then run this again"))
    -- map UI height methods
    local utd = try(function() return sdk.find_type_definition("app.ui040205") end)
    if utd then
      local hm = {}
      for _, m in ipairs(try(function() return utd:get_methods() end) or {}) do
        local mn = try(function() return m:get_name() end) or ""
        local l = mn:lower()
        if l:find("height", 1, true) or l:find("alt", 1, true)
          or l:find("ground", 1, true) or l:find("terrain", 1, true)
          or l:find("elevation", 1, true) then
          hm[#hm + 1] = mn
        end
      end
      L("ui040205 height methods: " .. (#hm > 0 and table.concat(hm, ", ") or "<none>"))
    end
  end
  -- pin list type probe: why does get_Item return nil?
  do
    local ltd = list and try(function() return list:get_type_definition() end)
    L("pin list type: " .. (ltd and try(function() return ltd:get_full_name() end) or "<nil>"))
    local ok_it, it_err = pcall(function() return list:get_Item(0) end)
    L("get_Item(0): ok=" .. tostring(ok_it) ..
      " err=" .. (it_err and tostring(it_err):sub(1, 100) or "nil") ..
      " valtype=" .. type(ok_it and it_err or nil))
    if ltd then
      local mns = {}
      for _, m in ipairs(try(function() return ltd:get_methods() end) or {}) do
        local mn = try(function() return m:get_name() end) or ""
        if mn:lower():find("item") or mn:lower():find("get") or mn:lower():find("count") then
          mns[#mns + 1] = mn
        end
      end
      L("pin list accessors: " .. table.concat(mns, ", "))
    end
    if FT_UI then
      local sel = try(function() return FT_UI:get_field("SelectedIcon") end)
      if type(sel) == "userdata" then
        local std = try(function() return sel:get_type_definition() end)
        L("SelectedIcon (" .. (std and try(function() return std:get_full_name() end) or "?") .. "):")
        for _, f in ipairs(try(function() return std:get_fields() end) or {}) do
          local fn = try(function() return f:get_name() end) or ""
          local l = fn:lower()
          if l:find("pos", 1, true) or l:find("enable", 1, true) then
            local v = try(function() return sel:get_field(fn) end)
            local vs
            if type(v) == "userdata" then
              local x = try(function() return v.x end)
              vs = type(x) == "number" and
                string.format("(%.1f, %.1f, %.1f)", x,
                  try(function() return v.y end) or 0,
                  try(function() return v.z end) or 0) or "<userdata>"
            else vs = tostring(v):sub(1, 40) end
            L("  " .. fn .. " = " .. vs)
          end
        end
      else
        L("SelectedIcon: <nil>")
      end
    else
      L("FT_UI: <nil>")
    end
  end
  local ml = g and (try(function() return g:get_field("QuestTargetMarkerList") end)
    or try(function() return g:call("getQuestTargetMarkerList") end)
    or try(function() return g:get_QuestTargetMarkerList() end))
  local nq = (ml and try(function() return ml:get_Count() end)) or 0
  L("quest markers: " .. nq)
  if nq > 0 then dump_fields(try(function() return ml:get_Item(0) end), "quest[0]", 40) end
  -- deep scan: where do pins/markers really live?
  L("FT_UI captured: " .. (FT_UI and "yes" or "no"))
  local plfield = g and try(function() return g:get_field("_MapPinList_k__BackingField") end)
  L("_MapPinList field type: " .. type(plfield))
  local gtd = g and try(function() return g:get_type_definition() end)
  if gtd then
    local ff, mm = {}, {}
    for _, f in ipairs(try(function() return gtd:get_fields() end) or {}) do
      local fn = try(function() return f:get_name() end) or ""
      local l = fn:lower()
      if l:find("pin", 1, true) or l:find("marker", 1, true) or l:find("quest", 1, true) then
        local v = try(function() return g:get_field(fn) end)
        local d = type(v)
        if type(v) == "userdata" then
          local c = try(function() return v:get_Count() end)
          if type(c) == "number" then d = d .. "[n=" .. c .. "]" end
        elseif type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
          d = d .. "=" .. tostring(v):sub(1, 30)
        end
        ff[#ff + 1] = fn .. ":" .. d
      end
    end
    local fj = table.concat(ff, ", ")
    L("GuiManager pin/marker/quest fields (" .. #ff .. "): " ..
      (#ff > 0 and fj:sub(1, 600) or "<none>"))
    for _, m in ipairs(try(function() return gtd:get_methods() end) or {}) do
      local mn = try(function() return m:get_name() end) or ""
      local l = mn:lower()
      if (l:find("marker", 1, true) and l:find("quest", 1, true)) or l:find("mappin", 1, true) then
        mm[#mm + 1] = mn
      end
    end
    L("GuiManager marker methods: " .. (#mm > 0 and table.concat(mm, ", ") or "<none>"))
  end
  for _, cname in ipairs({ "app.MapManager", "app.MapPinManager", "app.FieldManager" }) do
    local so = try(function() return sdk.get_managed_singleton(cname) end)
    L(cname .. ": " .. (type(so) == "userdata" and "exists" or "nil"))
  end
  return (table.concat(out, " // "):gsub("[|;\r\n\t]", " "))
end

---------------------------------------------------------------- v1.46 multi-hook time-skip probe
-- Resting never called requestTimeSkip, so hook ALL time/warp methods of
-- TimeSkipManager and see which one the rest flow actually uses. Run once
-- to install, rest at an inn/camp, run again to read captures.
local TSS = { hooked = false, hits = {} }
local TSS_METHODS = { "requestTimeSkip", "setTime", "warpPlayer", "warp",
  "onWarp", "requestPlayerWarp", "requestOxcartWarp" }
local function tss_install()
  if TSS.hooked then return "already installed" end
  local tsm = try(function() return sdk.get_managed_singleton("app.TimeSkipManager") end)
  if not tsm then return "TimeSkipManager not found" end
  local td = try(function() return tsm:get_type_definition() end)
  if not td then return "no typedef" end
  local n = 0
  for _, mn in ipairs(TSS_METHODS) do
    local m = try(function() return td:get_method(mn) end)
    if m then
      local cb = (function(name)
        return function(hargs)
          if TSS.hits[name] then return end
          local narr, vals = 0, {}
          for i = 3, 10 do
            local a = hargs[i]
            if a == nil then break end
            narr = narr + 1
            local iv = try(function() return sdk.to_int64(a) end)
            vals[#vals + 1] = "a" .. narr .. "=" .. tostring(iv)
          end
          TSS.hits[name] = narr .. " args: " .. table.concat(vals, " ")
        end
      end)(mn)
      if pcall(sdk.hook, m, cb, nil) then n = n + 1 end
    end
  end
  TSS.hooked = true
  return n .. "/" .. #TSS_METHODS .. " hooks installed"
end

COMMANDS.timeskip_probe = function()
  local out = {}
  out[#out + 1] = "install: " .. tss_install()
  local any = false
  for _, mn in ipairs(TSS_METHODS) do
    local h = TSS.hits[mn]
    if h then any = true out[#out + 1] = "FIRED " .. mn .. " <- " .. h end
  end
  if not any then
    out[#out + 1] = "nothing captured yet - rest at an inn/camp, then run this again"
  end
  return (table.concat(out, " // "):gsub("[|;\r\n\t]", " "))
end

---------------------------------------------------------------- v1.50 time-skip overload dump
-- Lists EVERY overload of the time/warp methods from metadata (no invokes,
-- no game-memory dereferencing). Run any time; no rest needed.
COMMANDS.timeskip_sig = function()
  local out = {}
  local tsm = try(function() return sdk.get_managed_singleton("app.TimeSkipManager") end)
  local td = tsm and try(function() return tsm:get_type_definition() end)
  if not td then return "TimeSkipManager unavailable" end
  local methods = try(function() return td:get_methods() end) or {}
  for _, want in ipairs({ "setTime", "onWarp", "requestTimeSkip", "requestPlayerWarp" }) do
    local found = 0
    for _, m in ipairs(methods) do
      local n = try(function() return m:get_name() end) or ""
      if n == want then
        found = found + 1
        local pts = try(function() return m:get_param_types() end)
        local pnames = {}
        if pts then
          for i = 1, #pts do
            local pt = pts[i]
            local pn = try(function() return pt:get_full_name() end) or "?"
            if try(function() return pt:is_by_ref() end) then pn = pn .. "&" end
            pnames[#pnames + 1] = pn
          end
        end
        local rt = try(function() return m:get_return_type() end)
        local rtn = (rt and try(function() return rt:get_full_name() end)) or "?"
        local st = try(function() return m:is_static() end) and "[static] " or ""
        out[#out + 1] = st .. n .. "(" .. table.concat(pnames, ", ") .. ") -> " .. rtn ..
          (pts and "" or " [no param_types API]")
      end
    end
    if found == 0 then out[#out + 1] = want .. ": not found" end
  end
  local extra = {}
  for _, m in ipairs(methods) do
    local n = try(function() return m:get_name() end) or ""
    local ln = n:lower()
    if (ln:find("time") or ln:find("day") or ln:find("skip")) and
       n ~= "setTime" and n ~= "onWarp" and
       n ~= "requestTimeSkip" and n ~= "requestPlayerWarp" then
      extra[#extra + 1] = n
    end
  end
  if #extra > 0 then
    out[#out + 1] = "other time/day/skip methods: " .. table.concat(extra, ", ")
  end
  return (table.concat(out, " // "):gsub("[|;\r\n\t]", " "))
end

---------------------------------------------------------------- v1.51 time-manager field dump
-- Read-only dump of TimeManager + TimeSkipManager fields (name, type,
-- value). No invokes, no writes. Finds where the clock actually lives.
COMMANDS.timemgr_dump = function()
  local out = {}
  for _, tn in ipairs({ "app.TimeManager", "app.TimeSkipManager" }) do
    local o = try(function() return sdk.get_managed_singleton(tn) end)
    if not o then
      out[#out + 1] = tn .. ": singleton not found"
    else
      local td = try(function() return o:get_type_definition() end)
      out[#out + 1] = "== " .. tn .. " =="
      for _, f in ipairs(try(function() return td:get_fields() end) or {}) do
        local fn = try(function() return f:get_name() end) or "?"
        local ft = try(function() return f:get_type() end)
        local ftn = (ft and try(function() return ft:get_full_name() end)) or "?"
        local v = try(function() return f:get_data(o) end)
        local vs
        if type(v) == "string" then vs = string.format("%q", v)
        elseif type(v) == "number" or type(v) == "boolean" then vs = tostring(v)
        elseif v == nil then vs = "nil"
        else
          local mt = try(function() return v:get_type_definition() end)
          vs = "<" .. tostring(mt and mt:get_full_name() or type(v)) .. ">"
        end
        if #vs > 80 then vs = vs:sub(1, 80) .. "..." end
        out[#out + 1] = fn .. " : " .. ftn .. " = " .. vs
      end
    end
  end
  -- recurse into _TimeData (the live clock object)
  do
    local tm = try(function() return sdk.get_managed_singleton("app.TimeManager") end)
    local tdata = tm and try(function() return tm:get_field("_TimeData") end)
    local td2 = tdata and try(function() return tdata:get_type_definition() end)
    if td2 then
      out[#out + 1] = "== app.TimeManager.TimeData =="
      for _, f in ipairs(try(function() return td2:get_fields() end) or {}) do
        local fn = try(function() return f:get_name() end) or "?"
        local ft = try(function() return f:get_type() end)
        local ftn = (ft and try(function() return ft:get_full_name() end)) or "?"
        local v = try(function() return f:get_data(tdata) end)
        local vs
        if type(v) == "string" then vs = string.format("%q", v)
        elseif type(v) == "number" or type(v) == "boolean" then vs = tostring(v)
        elseif v == nil then vs = "nil"
        else
          local mt = try(function() return v:get_type_definition() end)
          vs = "<" .. tostring(mt and mt:get_full_name() or type(v)) .. ">"
        end
        if #vs > 80 then vs = vs:sub(1, 80) .. "..." end
        out[#out + 1] = fn .. " : " .. ftn .. " = " .. vs
      end
    else
      out[#out + 1] = "_TimeData: not accessible"
    end
  end
  -- recurse into _TimeDataLook (possible display copy of the clock)
  do
    local tm = try(function() return sdk.get_managed_singleton("app.TimeManager") end)
    local tlook = tm and try(function() return tm:get_field("_TimeDataLook") end)
    local td3 = tlook and try(function() return tlook:get_type_definition() end)
    if td3 then
      out[#out + 1] = "== app.TimeManager.TimeDataLook =="
      for _, f in ipairs(try(function() return td3:get_fields() end) or {}) do
        local fn = try(function() return f:get_name() end) or "?"
        local ft = try(function() return f:get_type() end)
        local ftn = (ft and try(function() return ft:get_full_name() end)) or "?"
        local v = try(function() return f:get_data(tlook) end)
        local vs
        if type(v) == "string" then vs = string.format("%q", v)
        elseif type(v) == "number" or type(v) == "boolean" then vs = tostring(v)
        elseif v == nil then vs = "nil"
        else
          local mt = try(function() return v:get_type_definition() end)
          vs = "<" .. tostring(mt and mt:get_full_name() or type(v)) .. ">"
        end
        if #vs > 80 then vs = vs:sub(1, 80) .. "..." end
        out[#out + 1] = fn .. " : " .. ftn .. " = " .. vs
      end
    else
      out[#out + 1] = "_TimeDataLook: not accessible"
    end
  end
  return (table.concat(out, " // "):gsub("[|;\r\n\t]", " "))
end

---------------------------------------------------------------- polling loop
local last_poll, last_id = 0, nil

re.on_frame(function()
  -- 6s post-warp fall protection: force no-fall-damage patching, then restore
  local now0 = os.clock()
  if now0 < FT.protect_until then
    if not FT.forced then
      FT.forced = true
      FT.saved = JUMP.nofall
      if not JUMP.nofall then
        JUMP.nofall = true
        pcall(jump_apply)
      end
    end
  elseif FT.forced then
    FT.forced = false
    if not FT.saved then
      JUMP.nofall = false
      pcall(jump_apply)
    end
    FT.saved = nil
  end
  local now = os.clock()
  if now - last_poll < 0.1 then return end
  last_poll = now
  local text = rd(DIR .. "cmd.txt")
  if not text then return end
  text = text:gsub("[\r\n]+$", "")
  if text:sub(-4) ~= "|END" then return end            -- file still being written
  local parts = split(text:sub(1, -5), "|")
  local id, cmd = parts[1], parts[2]
  if not id or id == "" or id == last_id then return end
  last_id = id
  -- The last field is the boot token. ping is exempt so a fresh client can
  -- discover the token; every other command must match this game process.
  local marker = parts[#parts]
  if cmd ~= "ping" and marker ~= ("B:" .. BOOT) then
    write_resp(id, false, "STALE_SESSION")
    return
  end
  local last = #parts
  if marker and marker:sub(1, 2) == "B:" then last = last - 1 end
  local handler = COMMANDS[cmd or ""]
  local ok, res
  if handler then
    local args = {}
    for i = 3, last do args[#args + 1] = parts[i] end
    ok, res = pcall(handler, args)
  else
    ok, res = false, "unknown command"
  end
  if not ok then log.info(TAG .. tostring(cmd) .. " failed: " .. tostring(res)) end
  write_resp(id, ok, res)
end)

write_resp("boot", true, "ddbridge ready")
log.info(TAG .. "v1.89.82 ready (session guard, atomic responses, item stat dump, augment dump, jump height / air time / no fall damage, core skill dump, learn + unlearn core and weapon skills, ability data dump + predicate probe, appraisal dump, ability rule dump, item type map, upgraded skills, ability probe 2, equipment ability probe, set weapon skill level, weapon skill probe, all pawns, duplicate items, items, rating, badges, weapon/core skills, augments, stats, item editor; target = main pawn or player; faster respawn; fast travel; summon probes, summon boss, kill v14)")
