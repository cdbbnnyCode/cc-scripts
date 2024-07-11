-- over-engineered tree farm
-- ver 1.0

-- Copyright (c) 2024 Aidan Yaklin
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

-- Home base peripherals:
-- down = inventory (vacuum hopper, can be used as temp storage)
-- left = inventory (furnace outputs)
-- top  = inventory (furnace inputs)
-- right = inventory (output chest for charcoal, sticks, extra saplings/logs)

local nav = require("nav")
local json = require("json")

-- number of slots in the turtle inventory
local inv_slots = 16

-- minimum fuel needed to start cutting down the tree
-- 1 coal = 80 steps
local fuel_low = 500
-- maximum number of data points to keep track of for statistics
local max_data_points = 50
local furnace_buildup_slow = 64
local furnace_buildup_fast = 8
-- how much charcoal to put back into the system per charcoal collected
local furnace_fuel_factor = 1/5
-- how much extra fuel to keep in the inventory in case of emergency
local fuel_to_keep = 16
-- where to store extra fuel
local fuel_slot = 16
-- how many saplings to keep
local saplings_to_keep = 16
-- save file
local save_file = "tree_save.json"
local nav_save_file = "tree_nav.json"

-- item/block names
local sapling_item = "minecraft:spruce_sapling"
local log_block    = "minecraft:spruce_log"
local leaves_block = "minecraft:spruce_leaves"

-- program state to save to a file
-- note: use os.clock() for real time
local state = {
  id = 1, -- controller state
  -- fuel stats
  cut_fuel_start = 0, -- amount of fuel before cutting down a tree
  cut_fuel_max   = 0, -- maximum amount of fuel used to cut down a tree
  -- growth stats
  grow_start     = 0, -- time when the last sapling was placed
  grow_times     = {}, -- running list of time taken to grow the tree
  log_counts     = {}, -- number of logs collected per tree
  -- sapling stats
  sap_count_prev = 0, -- number of saplings stored before cutting down a tree
  sap_counts     = {}, -- number of saplings collected

  -- dig state
  dig_check      = false,
  dig_state      = 0,
  log_count      = 0
}

-- production rates:
-- 10s per charcoal => 0.1 charcoal per second => 8 turtle moves per second
-- each turtle move takes 8 ticks = 0.4 seconds = 2.5 moves per second
-- with one furnace this can provide for 3.2 turtles simultaneously (ok!)

-- if we bootstrap this so that charcoal is produced using charcoal (instead of planks)
-- 1 charcoal requires 0.125 charcoal and 10 seconds
-- in other words, we need to provide 1.125 logs every 10 seconds to the system, or 0.1125 logs per second
-- mining completes in 0.05 seconds plus 0.4 seconds to move to the next block, so it can provide 2.222
-- logs per second when continuously running
-- if the tree is 4*H blocks high and takes T seconds on average to grow, the system will provide
-- (4*H) / (8.889 * H + T) logs per second on average. We can find a function of minimum grow time
-- for a given height:
-- T <= 26.67 * H
-- For a 15-block tall tree, the growth time must be less than 400 seconds (6 minutes 40 seconds)
-- For a 20-block tall tree, the growth time must be less than 533 seconds (8 minutes 53 seconds)
-- this seems very reasonable

-- flow:
--   plant tree (2x2) - fail if less than 4 saplings available
--     go to z=-2, x=0, face west
--     place sapling
--     go to z=-1, face north
--     place sapling
--     face west
--     place sapling
--     go to z=0, face north
--     place sapling
local S_PLACE_RETRIEVE = 1 -- clean inventory, pull saplings from hopper
local S_PLACE_1        = 2 -- place first sapling
local S_PLACE_2        = 3 -- place second sapling
local S_PLACE_3        = 4 -- place third sapling
local S_PLACE_4        = 5 -- place fourth sapling
--   wait for tree to grow
--     transfer charcoal from furnace to chest if available
--     refuel if below fuel_low
--     periodically empty furnaces
local S_WAIT           = 6 -- wait for tree, periodically transfer furnace outputs
local S_PULL           = 7 -- pull items from furnace output chest
--   cut tree
--     dig block in front
--     go to z=-1
--     dig up until block above is not a log or leaves
--     face west and dig
--     go to x=-1
--     dig down until y=0
--     face north and dig
--     go to z=-2
--     dig up until block above is not a log or leaves
--     face east and dig
--     go to x=0
--     dig down until y=0
--     go to z=0
--     face forward
local S_DIG_AHEAD      = 8 -- dig block in front
local S_DIG_UP         = 9 -- dig up until air
local S_DIG_DOWN       = 10 -- dig down until floor
local S_DIG_TURN       = 11 -- turn to the next move
--  distribute items to furnaces
--    dump collected logs into furnace storage
local S_DIST           = 12 -- move to the top of the stack

-- last valid state ID
local S_LAST           = 12

local function doError(msg)
  print("Error at " .. os.date() .. ":")
  print(msg)
  -- TODO push message to the modem
  -- wait for user input
  -- (thought) maybe exit and retry at some point
  print("Press enter to clear...")
  io.read()

  -- return to the state we were in previously
end

local function tryMoveTo(axis, pos, finalDir)
  local dest = nav.moveTo(axis, pos)
  if dest == nil then
    return false, "invalid axis"
  end

  if dest ~= pos then
    doError("Movement blocked")
    return false, "not reached"
  end

  if finalDir ~= nil then
    nav.turnTo(finalDir)
  end

  return true
end
  

local function dumpToOutput(n, from)
  -- note: assumes output is in front
  -- calls doError if the dump fails
  -- if from is not nil then it should be a table of {name, slot}
  -- if n is nil then it will dump the whole stack

  local n_pushed = 0
  if from ~= nil then
    if n == nil then
      local stack = peripheral.call(from.name, "getItemDetail", from.slot)
      if stack == nil then
        n = 0
      else
        n = stack.count
      end
    end
    n_pushed = peripheral.call(from.name, "pushItems", "front", from.slot, n)
  else
    local count = turtle.getItemCount()
    if n == nil then
      n = count
    end
    turtle.drop(n)
    n_pushed = count - turtle.getItemCount()
  end
  
  if n_pushed < n then
    doError("Output storage is full")
    return false
  end
  return true
end

function doPlaceRetrieve()
  -- remove anything that isn't a sapling or temporary fuel
  -- put all saplings into the hopper
  -- remove everything that isn't a sapling from the hopper
  -- pull 4 saplings from the hopper and start placing
  if not tryMoveTo("X", 0) then
    return false
  end

  if not tryMoveTo("Z", 0, "E") then
    return false
  end

  local hopper = peripheral.wrap("bottom")
  if hopper == nil then
    doError("Can't find hopper below turtle")
    return false
  end
  local stored_saplings = 0

  -- remove garbage from the hopper
  for i = 1,hopper.size() do
    local stack = hopper.getItemDetail(i)
    if stack ~= nil then
      if stack.name ~= sapling_item then
        -- push stack to the chest
        if not dumpToOutput(nil, {name = "bottom", slot = i}) then
          return false
        end
      else
        stored_saplings = stored_saplings + stack.count
        if stored_saplings > saplings_to_keep then
          local to_push = stored_saplings - saplings_to_keep
          -- push excess saplings to the chest
          if not dumpToOutput(to_push, {name = "bottom", slot = i}) then
            return false
          end
          stored_saplings = saplings_to_keep
        end
      end
    end
  end 

  -- remove garbage from the inventory 
  for i = 1,inv_slots do
    if i ~= fuel_slot then
      local stack = turtle.getItemDetail(i)
      if stack ~= nil then
        if stack.name == sapling_item then
          -- put into hopper
          turtle.select(i)
          turtle.dropDown()
          if turtle.getItemCount(i) ~= 0 then
            doError("Hopper is full")
            return false
          end
        else
          -- unprocessed logs and other junk go into the chest
          turtle.select(i)
          turtle.drop()
          if turtle.getItemCount(i) ~= 0 then
            doError("Output storage is full")
            return false
          end
        end
      end
    end
  end

  -- pull 4 saplings from the hopper
  local collected = 0

  turtle.select(1)
  while collected < 4 do
    -- pull 4 items 
    turtle.suckDown(4)
    -- check if we got saplings or something else
    local stack = turtle.getItemDetail(1)
    if stack == nil then
      doError("No saplings available (need " .. (4 - collected) .. ")")
    elseif stack.name ~= sapling_item then
      -- put into the chest
      turtle.drop()
      if turtle.getItemCount(1) ~= 0 then
        doError("Output storage is full")
        return false
      end
    else
      collected = stack.count
    end
  end

  -- success
  return true
end

local function tryPlace(exp_sap)
  turtle.select(1)
  local has, data = turtle.inspect()
  if has then
    return true -- sapling already present
  end

  if turtle.getItemCount(1) < exp_sap then
    nav.moveTo("Z", 0)
    if nav.getPos()[3] ~= 0 then
      doError("Movement blocked")
      return false
    end
    -- go back to the collection state
    return false, S_PLACE_RETRIEVE
  end

  local res = turtle.place()
  if not res then
    doError("Cannot place sapling")
    return false
  end
end

local function place1() 
  -- go to z=-3, face west
  if not tryMoveTo("Z", -3, "W") then
    return false
  end
  return tryPlace(4)
end

local function place2()
  -- go to z=-2, face north
  nav.turnTo("N") -- preemptively turn to the north to reduce number of turns
  if not tryMoveTo("Z", -2, "N") then
    return false
  end
  return tryPlace(3)
end

local function place3()
  -- face west (z=-2)
  if not tryMoveTo("Z", -2, "W") then
    return false
  end
  return tryPlace(2)
end

local function place4()
  nav.turnTo("N")
  if not tryMoveTo("Z", -1, "N") then
    return false
  end
  return tryPlace(1)
end

local function growWait()
  -- check if the tree grew
  if not tryMoveTo("Y", 0) then
    return false
  end
  if not tryMoveTo("Z", 0, "N") then
    return false
  end
  sleep(10)
  -- check if the tree grew
  local has, data = turtle.inspect()
  if has then
    if data.name ~= leaves_block then
      doError("Unexpected block")
      return false  
    end
    local s = turtle.dig()
    if not s then
      doError("Could not mine leaves")
      return false
    end
  end
  if not tryMoveTo("Z", -1, "N") then
    return false
  end
  has, data = turtle.inspect()
  local has_log = false
  if not has then
    -- sapling is missing
    -- assume all 4 saplings are gone
    return false, S_PLACE_RETRIEVE
  elseif data.name == log_block then
    -- log is present
    has_log = true
  elseif data.name ~= sapling_item then
    doError("Unexpected block detected")
    return false
  end
  
  -- move back
  if not tryMoveTo("Z", 0, "N") then
    return false
  end
  
  -- attempt to refuel
  if turtle.getFuelLevel() < 2*fuel_low then
    turtle.select(fuel_slot)
    turtle.refuel()
  end

  -- check if we have spare fuel
  local spare_fuel = turtle.getItemCount(fuel_slot)
  local fast_mode = (spare_fuel < fuel_to_keep / 2)
  
  -- get number of charcoal produced in the furnace
  local furnace = peripheral.wrap("left")
  if furnace == nil then
    doError("Furnace output chest not found")
    return false
  end

  local buildup = furnace_buildup_slow
  if fast_mode then
    buildup = furnace_buildup_fast
  end

  local in_furnace = 0
  for i = 1,furnace.size() do
    local item = furnace.getItemDetail(i)
    if item ~= nil then
      in_furnace = in_furnace + furnace.getItemDetail(i).count
    end
  end

  if in_furnace >= buildup then
    -- pull from furnace
    return true
  elseif in_furnace == 0 then
    -- furnaces are empty
    if turtle.getFuelLevel() < fuel_low then
      doError("No fuel available")
      return false
    end
  end

  if has_log then
    if turtle.getFuelLevel() < fuel_low then
      return false -- wait for fuel
    end
    return false, S_DIG_AHEAD -- start digging
  else
    return false -- wait
  end
end

local function pullFuel()
  nav.turnTo("W")
  local furnace = peripheral.wrap("front")
  if furnace == nil then
    doError("Furnace output chest not found")
    return false
  end

  local furnace_in = peripheral.wrap("top")
  if furnace_in == nil then
    doError("Furnace input chest not found")
    return false
  end

  turtle.select(1)
  while true do
    if not turtle.suck() then
      break
    end
  end

  -- put some into the fuel slot
  local spare_fuel = turtle.getItemCount(fuel_slot)
  local to_refill = fuel_to_keep - spare_fuel
  if to_refill > 0 then
    turtle.transferTo(fuel_slot, to_refill)
  end

  -- put the rest into the output chest
  local collected = 0
  for i = 1,inv_slots do
    if i ~= fuel_slot then
      collected = collected + turtle.getItemCount(i)
    end
  end
  
  -- but put some back into the system also
  local to_redistribute = math.ceil(collected * furnace_fuel_factor)
  print("redistribute: " .. to_redistribute)
  for i = 1,inv_slots do
    if i ~= fuel_slot then
      local count = turtle.getItemCount(i)
      turtle.select(i)
      for j = 1,to_redistribute do
        -- dispense one at a time so that the pipes work correctly
        if turtle.dropUp(1) then
          to_redistribute = to_redistribute - 1
        else
          -- stack is empty
          break
        end
        sleep(1)
      end
      if to_redistribute == 0 then
        break
      end
    end
  end

  if collected > 0 then
    nav.turnTo("E")
    for i = 1,inv_slots do
      if i ~= fuel_slot then
        local stack = turtle.getItemDetail(i)
        if stack ~= nil then
          turtle.select(i)
          if not dumpToOutput(stack.count) then
            return false
          end
        end
      end
    end
  end
  -- return to the wait state
  return false, S_WAIT
end

local function digAhead()
  turtle.select(1)
  
  if not tryMoveTo("Z", -1) then
    return false
  end

  local has, data = turtle.inspect()
  if not has then
    if not tryMoveTo("Z", -2) then
      return false
    end
    return true -- nothing here
  elseif data.name == log_block then
    local s = turtle.dig()
    if not s then
      doError("Could not mine log")
      return false
    end
    if not tryMoveTo("Z", -2) then
      return false
    end
    return true
  else
    doError("Unexpected block detected")
    return false
  end
end

local function digUp()
  local has, data = turtle.inspectUp()
  local y = nav.getPos()[2]
  if not has then
    if state.dig_check then
      state.dig_check = false
      return false, S_DIG_TURN -- top of tree reached
    end
    if not tryMoveTo("Y", y+1) then
      return false
    end
    -- move up and check again
    state.dig_check = true
    return false
  else
    local s = turtle.digUp()
    if not s then
      doError("Could not mine log")
      return false
    end
    state.dig_check = false
    return false
  end
end

local function digDown()
  local has, data = turtle.inspectDown()
  local y = nav.getPos()[2]
  if not has then
    -- just move down
    if not tryMoveTo("Y", y-1) then
      return false
    end
  else
    if data.name == log_block or data.name == leaves_block then
      turtle.digDown()
      return false -- exit (returns to the has=false branch)
    else
      -- assume that this is ground and move to the next state
      return false, S_DIG_TURN
    end
  end
end

local function digTurn()
  local st = state.dig_state
  if st == 0 then
    nav.turnTo("W")
    local has = turtle.detect()
    if has then
      local s = turtle.dig()
      if not s then
        doError("Could not mine log")
        return false
      end
    end
    if not tryMoveTo("X", -1) then
      return false
    end
    state.dig_state = 1
    return false, S_DIG_DOWN
  elseif st == 1 then
    nav.turnTo("N")
    local has = turtle.detect()
    if has then
      local s = turtle.dig()
      if not s then
        doError("Could not mine log")
        return false
      end
    end
    if not tryMoveTo("Z", -3) then
      return false
    end
    state.dig_state = 2
    return false, S_DIG_UP
  elseif st == 2 then
    nav.turnTo("E")
    local has = turtle.detect()
    if has then
      local s = turtle.dig()
      if not s then
        doError("Could not mine log")
        return false
      end
    end
    if not tryMoveTo("X", 0) then
      return false
    end
    state.dig_state = 3
    return false, S_DIG_DOWN
  elseif st == 3 then
    if not tryMoveTo("Z", 0, "W") then
      return false
    end
    state.dig_state = 0
    return true
  else
    state.dig_state = 0
    return false
  end
end

local function distribute()
  -- dump collected logs to furnace inputs
  local furnace_in = peripheral.wrap("top")
  if furnace_in == nil then
    doError("Furnace input chest not found")
    return false
  end

  for i = 1,inv_slots do
    if i ~= fuel_slot then
      local stack = turtle.getItemDetail(i)
      if stack ~= nil and stack.name == log_block then
        turtle.select(i)
        turtle.dropUp()
        if turtle.getItemCount() > 0 then
          -- if the whole stack wasn't pushed then the chest is full
          -- exit, the excess will go to the output storage
          return true
        end
      end
    end
  end
  return true
end

-- Home base peripherals:
-- down = inventory (vacuum hopper, can be used as temp storage)
-- left = inventory (furnace outputs chest)
-- top  = inventory (furnace inputs chest)
-- right = inventory (output chest for charcoal, sticks, extra saplings/logs)

local function loadState()
  local f = io.open(save_file, "r")

  if f == nil then
    return false
  end

  local line = f:read()
  local success = line ~= nil
  
  if success then
    local d = json.decode(line)
    for k,v in pairs(state) do
      state[k] = d[k]
    end
  end

  f:close()
  return success
end

local function saveState()
  local f = io.open(save_file, "w")
  
  f:write(json.encode(state)):write("\n")
  f:close()

  return true
end

-- state machine controller
local function main()
  -- load the state from the file
  nav.init(nav_save_file)
  loadState()

  while true do
    -- execute the current state
    local s, n
    print("executing state " .. state.id)
    if state.id == S_PLACE_RETRIEVE then
      s, n = doPlaceRetrieve()
    elseif state.id == S_PLACE_1 then
      s, n = place1()
    elseif state.id == S_PLACE_2 then
      s, n = place2()
    elseif state.id == S_PLACE_3 then
      s, n = place3()
    elseif state.id == S_PLACE_4 then
      s, n = place4()
    elseif state.id == S_WAIT then
      s, n = growWait()
    elseif state.id == S_PULL then
      s, n = pullFuel()
    elseif state.id == S_DIG_AHEAD then
      s, n = digAhead()
    elseif state.id == S_DIG_UP then
      s, n = digUp()
    elseif state.id == S_DIG_DOWN then
      s, n = digDown()
    elseif state.id == S_DIG_TURN then
      s, n = digTurn()
    elseif state.id == S_DIST then
      s, n = distribute()
    end
    -- change the state
    if s then
      -- success = move to the next state
      state.id = state.id + 1
      if state.id > S_LAST then
        state.id = 1
      end
    else
      -- fail = move to the specified state or retry the current state
      if n ~= nil then
        state.id = n
      end
    end
    -- save the state
    saveState()
  end
end

main()
