-- basic quarry using the nav system
-- ver: 0.3

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

local nav = require("nav")
local json = require("json")

local inv_slots = 16

-- head back and refuel if fuel below this point
local fuel_low = 200
-- maximum number of items to refuel with
local refuel_count = 32

-- inventories (orientation relative to start position)
local fuel_side = "S"
local item_side = "W"

local quarry_width = 8 -- width (perpendicular to the facing direction)
local quarry_length = 8 -- length (along the facing direction)
local quarry_align = "left" -- alignment of the quarry relative to the home position (left/right)

local save_file = "quarry_state.json"
local nav_save_file = "quarry_nav.json"
local ore_db_file = "ore_db.json"

-- available options: (TODO)
--
-- options (i.e., stairs) to modify the shape of the quarry
local quarry_features = {} 

local state = {
  quarry_new = true, -- the quarry needs to be started
  go_home = 0,   -- go home or continue digging
  saved_pos = {0, 0, 0}, -- saved digging position when going home
  saved_dir = 0,
  pos_is_saved = false
}

local ore_db

local function tryMoveTo(axis, pos, finalDir)
  local dest = nav.moveTo(axis, pos)
  if dest == nil then
    return false, "invalid axis"
  end

  if dest ~= pos then
    -- doError("Movement blocked")
    return false, "not reached"
  end

  if finalDir ~= nil then
    nav.turnTo(finalDir)
  end

  return true
end

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

-- flow:
--   quarry_new=true, assume no blocks mined and at home position
--   dig down 1, quarry_new=false, start mining forward
--   basically all movement conditional on current position
--     - (x % 2) ~ ((y+1) % 2) determines forward/backward move (0=forward 1=backward)
--     - (y % 2) determines left/right move
-- return to home flow:
--   save position, go_home=1
--   move to y=1 (assume layer above is already clear)
--   move to x=0 z=0
--   go_home=2
--   move to y=0
--   do whatever
--   go_home=3
--   move to y=1, return to saved position on xz plane
--   go_home=4
--   move to saved Y
--   go_home=0
-- if done, go_home=101
--   go_home=101 + x follows the same flow but stops at the end

local MINE_BLOCKED = 1
local MINE_INV_FULL = 2

local function tryMine(down)
  local has, block
  if down then
    has, block = turtle.inspectDown()
  else
    has, block = turtle.inspect()
  end
  if not has then
    return 0
  end
  
  -- check ore db
  local to_check = {block.name}
  local found = {}
  if ore_db.ores[block.name] ~= nil then
    to_check = ore_db.ores[block.name]
  end

  -- check inventory
  local has_space = false
  for i = 1,inv_slots do
    if turtle.getItemCount(i) == 0 then
      has_space = true
      break
    else
      if turtle.getItemSpace(i) > 0 then
        local item = turtle.getItemDetail(i)
        for j, c_item in ipairs(to_check) do
          if c_item == item.name then
            found[c_item] = true
            break
          end
        end
      end
    end
  end
  -- check if all items have space
  if not has_space then
    has_space = true
    for j, c_item in ipairs(to_check) do
      if not found[c_item] then
        has_space = false
        break
      end
    end
  end
  if not has_space then
    return MINE_INV_FULL
  end

  local succ
  if down then
    succ = turtle.digDown()
  else
    succ = turtle.dig()
  end

  if not succ then
    return MINE_BLOCKED
  end
  return 0
end 

local function doQuarry()
  -- returns true if the state changed
  if state.quarry_new then
    local mineRc = tryMine(true) -- dig down
    if mineRc == MINE_INV_FULL then
      -- go home, but we're already home
      state.go_home = 2 
      return true
    end

    if not tryMoveTo("Y", -1, "N") then
      return false
    end
    state.quarry_new = false
    return true
  else
    -- forward/back:
    local pos = nav.getPos()
    local x = pos[1]
    if x < 0 then
      x = -x
    end

    local y = -pos[2] - 1
    local xy = y*(quarry_width-1) + x
    -- move forward (to z=quarry_length) or backward (to z=0)
    local forward = (xy % 2) == 0
    local right = ((y % 2) == 0)
    local moveComplete = false
    if forward then
      nav.turnTo("N") -- ensure we don't try mining backwards
      moveComplete = tryMoveTo("Z", -quarry_length + 1)
    else
      nav.turnTo("S")
      moveComplete = tryMoveTo("Z", 0)
    end
    
    if moveComplete then
      -- if we're still here then we reached our forward/back target
      -- go right/left by 1
      if (right and x >= quarry_width-1) or (not right and x <= 0) then
        -- layer complete
        -- move down
        local mineRc = tryMine(true)
        if mineRc == MINE_INV_FULL then
          state.go_home = 1
          return true
        end
        moveComplete = nav.move("Y", -1)
        if not moveComplete then
          -- can't move down, return home
          state.go_home = 101
          return true
        end
        -- otherwise all is well
        return false
      else
        local actualRight = right
        if quarry_align == "right" then
          actualRight = not actualRight
        end

        local mineRc
        if actualRight then
          nav.turnTo("E")
          mineRc = tryMine(false)
          moveComplete = nav.move("E", 1)
        else
          nav.turnTo("W")
          mineRc = tryMine(false)
          moveComplete = nav.move("W", 1)
        end

        if mineRc == MINE_INV_FULL then
          state.go_home = 1
          return true
        end
      end
    end 

    if not moveComplete then
      -- TODO check for inventories here
      -- dig
      local mineRc = tryMine(false)
      if mineRc == MINE_INV_FULL then
        state.go_home = 1
        return true
      elseif mineRc == MINE_BLOCKED then
        -- probably bedrock reached
        -- return home and finish
        state.go_home = 101
        return true
      end
      -- otherwise keep going normally
      return false
    end
  end
  return false
end

local function home1()
  -- go to y=1, x=0, z=0
  -- return true if success
  if not tryMoveTo("Y", 1) then
    doError("homing blocked")
    return false
  end
  if not tryMoveTo("X", 0) then
    doError("homing blocked")
    return false
  end
  if not tryMoveTo("Z", 0) then
    doError("homing blocked")
    return false
  end
  return true
end

local function home2()
  -- go to y=0
  -- return true if success
  if not tryMoveTo("Y", 0) then
    doError("homing blocked")
    return false
  end
  return true
end

local function home3()
  -- go to y=1 again
  if not tryMoveTo("Y", 1) then
    doError("return blocked")
    return false
  end
  if not tryMoveTo("X", state.saved_pos[1]) then
    doError("return blocked")
    return false
  end
  if not tryMoveTo("Z", state.saved_pos[3]) then
    doError("return blocked")
    return false
  end
  return true
end

local function home4()
  -- go to saved Y
  if not tryMoveTo("Y", state.saved_pos[2]) then
    doError("return blocked")
    return false
  end
  return true
end

local function dumpStack()
  turtle.drop()
  return turtle.getItemCount()
end

local function doRefuel()
  -- assumes at home position, current slot is empty
  if not nav.turnTo(fuel_side) then
    doError("Give fuel")
  else
    turtle.suck(refuel_count)
  end
  if not turtle.refuel() then
    turtle.dropUp() -- throw away
    return false -- and try again
  end
  return true
end

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

local function loadOreDb()
  local f = io.open(ore_db_file, "r")
  local fdata = f:read("a")
  if fdata == nil then
    return false
  end
  ore_db = json.decode(fdata)
  
  return true
end

local function main()
  nav.init(nav_save_file)
  loadState()
  loadOreDb()

  -- run the state machine in a loop
  -- until we hit an end condition
  while true do
    local succ
    if state.go_home == 0 then
      -- mine
      succ = doQuarry()
      
      if turtle.getFuelLevel() < fuel_low and state.go_home == 0 then
        state.go_home = 1 -- go home on the next step
        succ = true -- save state
      end
    else
      if state.go_home == 1 or state.go_home == 101 then
        -- go home (1)
        print("home1")
        if not state.pos_is_saved then
          local curr_pos = nav.getPos()
          state.saved_pos = {curr_pos[1], curr_pos[2], curr_pos[3]}
          state.saved_dir = nav.getDir() 
          -- marker so that we don't overwrite the saved pos
          state.pos_is_saved = true
          saveState()
        end
        succ = home1()
      elseif state.go_home == 2 or state.go_home == 102 then
        -- don't need the saved marker anymore
        state.pos_is_saved = false
        saveState()
        -- go home (2)
        print("home2")
        succ = home2()
        if succ then
          -- at home, dispense items and refuel
          nav.turnTo(item_side)
          local dispensed = false
          while not dispensed do
            dispensed = true -- true unless proven otherwise
            for i = 1,inv_slots do
              turtle.select(i)
              local remaining = dumpStack()
              if remaining > 0 then
                doError("Item storage full")
                dispensed = false
              end
            end
          end

          if state.go_home < 100 and turtle.getFuelLevel() < 2*fuel_low then
            -- make sure we have fuel before returning
            -- even if we didn't come here for fuel
            local refuelOk = false
            while not refuelOk do
              refuelOk = doRefuel()
            end
          end
        end
      elseif state.go_home == 3 then
        print("home3")
        succ = home3()
      elseif state.go_home == 4 then
        print("home4")
        succ = home4()
      elseif state.go_home == 5 then
        state.go_home = -1 -- increments to 0
        succ = true
      elseif state.go_home >= 103 then
        print("Quarry finished")
        return
      end
      -- in go-home sequence; incrment state
      if succ then
        state.go_home = state.go_home + 1
      end
    end
    if succ then
      saveState()
    end
  end
end

main()
