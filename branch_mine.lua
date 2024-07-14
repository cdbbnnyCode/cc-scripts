-- branch miner
-- v0.1

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

local fuel_low = 300

local refuel_count = 64

-- inventories (relative to start position)
local fuel_side = "S"
local inv_side = "W"

local main_length = 50
local branch_length = 50
local branch_spacing = 6
local branch_stagger = 3

local save_file = "branch_state.json"
local nav_save_file = "branch_nav.json"
local ore_db_file = "ore_db.json"

local BRANCH_NONE = 1
local BRANCH_W = 2
local BRANCH_E = 3
local BRANCH_RETURN = 4

local state = {
  branch_id = BRANCH_NONE,
  go_home = 0,
  mine_ore = false,
  ore_path = {},
  pos_saved = false,
  saved_pos = {0, 0, 0},
  ore_rare = false
}

local ore_db = nil

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

local MINE_BLOCKED = 1
local MINE_INV_FULL = 2

local function tryMine(dir, ignore_inv)
  if ignore_inv == nil then
    ignore_inv = false
  end

  local has, block
  if dir == "D" then
    has, block = turtle.inspectDown()
  elseif dir == "U" then
    has, block = turtle.inspectUp()
  else
    nav.turnTo(dir)
    has, block = turtle.inspect()
  end
  if not has then
    return 0
  end
  
  if not ignore_inv then
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
  end

  local succ
  if dir == "D" then
    succ = turtle.digDown()
  elseif dir == "U" then
    succ = turtle.digUp()
  else
    succ = turtle.dig()
  end

  if not succ then
    return MINE_BLOCKED
  end
  return 0
end

local MINE_BAD_AXIS = 10

local function tryMineTo(axis, pos, force, finalDir)
  while true do
    local dest = nav.moveTo(axis, pos)
    if dest == nil then
      return MINE_BAD_AXIS
    end

    if dest == pos then
      break
    end

    local dir
    if axis == "X" and dest > pos then
      dir = "E"
    elseif axis == "X" and dest < pos then
      dir = "W"
    elseif axis == "Y" and dest > pos then
      dir = "U"
    elseif axis == "Y" and dest < pos then
      dir = "D"
    elseif axis == "Z" and dest > pos then
      dir = "S"
    elseif axis == "Z" and dest < pos then
      dir = "N"
    end

    -- try to mine
    local rc = tryMine(dir)
    if rc ~= 0 then
      return rc
    end
  end
  return 0
end

local function checkOre(block)
  if block == nil then
    return false
  end
  return (ore_db.ores[block.name] ~= nil and not ore_db.not_ores[block.name])
end

local function isRare(block)
  if block == nil then
    return false
  end
  return ore_db.rare_ores[block.name]
end

local BRANCH_CONTINUE = 0
local BRANCH_DONE = 1
local BRANCH_BLOCKED = 2
local BRANCH_HOME = 3
local BRANCH_ORE = 4

local function doBranch(dir)
  local succ
  local x = nav.getPos()[1]
  if dir == "E" and x >= branch_length then
    return BRANCH_DONE
  elseif dir == "W" and x <= -branch_length then
    return BRANCH_DONE
  end

  -- check for ores
  nav.turnTo("N")
  local has, block = turtle.inspectUp()
  if checkOre(block) then
    return BRANCH_ORE, "U"
  end
  has, block = turtle.inspectDown()
  if checkOre(block) then
    return BRANCH_ORE, "D"
  end
  has, block = turtle.inspect()
  if checkOre(block) then
    return BRANCH_ORE, "N"
  end
  nav.turnTo("S")
  has, block = turtle.inspect()
  if checkOre(block) then
    return BRANCH_ORE, "S"
  end
  nav.turnTo(dir)
  has, block = turtle.inspect()
  if checkOre(block) then
    return BRANCH_ORE, dir
  end

  -- dig and move
  succ = tryMine(dir)
  if succ == MINE_INV_FULL then
    return BRANCH_HOME
  elseif succ == MINE_BLOCKED then
    return BRANCH_BLOCKED
  end

  if dir == "E" then
    succ = nav.move("X", 1)
  else
    succ = nav.move("X", -1)
  end

  if not succ then
    return BRANCH_BLOCKED
  end

  return BRANCH_CONTINUE
end

local ORE_PUSH = 0 -- doOre does the push operation
local ORE_POP = 1
local ORE_DONE = 2
local ORE_BLOCKED = 3

local function oreBacktrack()
  if #(state.ore_path) == 0 then
    return ORE_DONE
  end
  local ax_pos = state.ore_path[#(state.ore_path)]
  local ax  = ax_pos[1]
  local pos = ax_pos[2]
  local rc = tryMineTo(ax, pos, true)
  if rc == MINE_BLOCKED then
    return ORE_BLOCKED
  end

  return ORE_POP -- backtrack complete, pop from path
end

local function doOre(rare)
  -- rare = true if the current block was a rare ore
  -- if rare is false, don't expand to non-ore blocks
  -- find adjacent ores
  local adjacent = nil
  local adjRare = false
  local has, block = turtle.inspectUp()
  if (rare and has) or checkOre(block) then
    adjacent = "U"
    adjRare = isRare(block)
  else
    has, block = turtle.inspectDown()
    if (rare and has) or checkOre(block) then
      adjacent = "D"
      adjRare = isRare(block)
    else
      nav.turnTo("N")
      has, block = turtle.inspect()
      if (rare and has) or checkOre(block) then
        adjacent = "N"
        adjRare = isRare(block)
      else
        nav.turnTo("W")
        has, block = turtle.inspect()
        if (rare and has) or checkOre(block) then
          adjacent = "W"
          adjRare = isRare(block)
        else
          nav.turnTo("S")
          has, block = turtle.inspect()
          if (rare and has) or checkOre(block) then
            adjacent = "S"
            adjRare = isRare(block)
          else
            nav.turnTo("E")
            has, block = turtle.inspect()
            if (rare and has) or checkOre(block) then
              adjacent = "E"
              adjRare = isRare(block)
            end -- E
          end -- S
        end -- W
      end -- N
    end -- D
  end -- U

  if adjacent == nil then
    return oreBacktrack()
  else
    -- mine
    local succ = tryMine(adjacent)
    if succ == MINE_INV_FULL then
      return BRANCH_HOME
    elseif succ == MINE_BLOCKED then
      return ORE_BLOCKED
    end
    -- save position
    local axis = nav.getDirAxis(adjacent)
    local xyz = nav.getPos()
    local pos
    if axis == "X" then
      pos = xyz[1]
    elseif axis == "Y" then
      pos = xyz[2]
    elseif axis == "Z" then
      pos = xyz[3]
    end
    state.ore_path[1+#state.ore_path] = {axis, pos}
    saveState()
    -- move
    while not nav.move(adjacent) do
      succ = tryMine(adjacent, true)
      if succ == MINE_BLOCKED then
        return ORE_BLOCKED
      end
    end
    return ORE_PUSH
  end
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

  while true do
    local succ
    if state.go_home == 0 and not state.mine_ore then
      if state.branch_id == BRANCH_NONE then
        local z = nav.getPos()[3]
        if z >= branch_length then
          print("Done")
          return
        end
        local zp = z % branch_spacing
        local rc
        if zp >= branch_stagger then
          rc = tryMineTo("Z", z + (branch_spacing - zp))
          if rc == 0 then
            state.branch_id = BRANCH_W
          end
        else
          rc = tryMineTo("Z", z + (branch_spacing - zp + branch_stagger))
          if rc == 0 then
            state.branch_id = BRANCH_E
          end
        end
        if rc == MINE_BLOCKED then
          state.go_home = 101
        elseif rc == MINE_INV_FULL then
          state.go_home = 1
        end
      elseif state.branch_id == BRANCH_W then
        local rc = doBranch("W")
        if rc == BRANCH_DONE then
          state.branch_id = BRANCH_RETURN
        elseif rc == BRANCH_ORE then
          state.mine_ore = true
        elseif rc == BRANCH_BLOCKED then
          state.go_home = 101
        elseif rc == BRANCH_HOME then
          state.go_home = 1
        end
      elseif state.branch_id == BRANCH_E then
        local rc = doBranch("E")
        if rc == BRANCH_DONE then
          state.branch_id = BRANCH_RETURN
        elseif rc == BRANCH_ORE then
          state.mine_ore = true
        elseif rc == BRANCH_BLOCKED then
          state.go_home = 101
        elseif rc == BRANCH_HOME then
          state.go_home = 1
        end
      elseif state.branch_id == BRANCH_RETURN then
        local rc = tryMineTo("X", 0)
        if rc == MINE_BLOCKED then
          doError("return blocked")
        end
      end
    elseif state.go_home == 1 or state.go_home == 101 then
      local rc = tryMineTo("X", 0)
      if rc == MINE_BLOCKED then
        doError("return blocked")
      else
        state.go_home = state.go_home + 1
      end
    elseif state.go_home == 2 or state.go_home == 102 then
      local rc = tryMineTo("Z", 0)
      if rc == MINE_BLOCKED then
        doError("return blocked")
      else
        state.go_home = state.go_home + 1
      end
    end
  end
end
