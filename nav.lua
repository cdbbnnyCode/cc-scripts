-- GPSless turtle navigation
-- Version 0.2

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

local json = require("json")

local nav = { _version = "0.1" }

-- anything greater than 4 is not a valid horizontal direction
local dir_names = {"N", "W", "S", "E", "U", "D"}
local dir_indices = {
  ["N"] = 1, ["W"] = 2, ["S"] = 3, ["E"] = 4, 
  ["U"] = 5, ["D"] = 6, ["X"] = 4, ["Y"] = 5, ["Z"] = 3
}

local axis_names = {"X", "Y", "Z"}
local axis_indices = {
  ["X"] = 1, ["Y"] = 2, ["Z"] = 3
}

local nav_state = {
  pos = {0, 0, 0},
  dir = 1,
  store_file = nil
}

local function savePos()
  if nav_state.store_file == nil then
    return false
  end

  print("[nav] p=<" .. nav_state.pos[1] .. "," .. nav_state.pos[2] .. "," .. nav_state.pos[3] .. "> d=" .. dir_names[nav_state.dir])
  local to_save = {pos = nav_state.pos, dir = nav_state.dir}

  local f = io.open(nav_state.store_file, "w")

  f:write(json.encode(to_save)):write("\n")

  f:close()

  return true
end

local function loadPos()
  if nav_state.store_file == nil then
    return false
  end

  local f = io.open(nav_state.store_file, "r")

  if f == nil then
    return false
  end

  local line = f:read()
  local success = line ~= nil

  if success then
    local d = json.decode(line)
    nav_state.pos = d.pos
    nav_state.dir = d.dir
  end

  f:close()
  return success
end

nav.init = function(store_file)
  nav_state.store_file = store_file
  return loadPos() -- load the position if the file exists
end

-- basic movement

local function turnTo(dir)
  local dist = dir - nav_state.dir
  if dist == 2 or dist == -2 then
    turtle.turnLeft()
    turtle.turnLeft()
  elseif dist == 1 or dist == -3 then
    turtle.turnLeft()
  elseif dist == -1 or dist == 3 then
    turtle.turnRight()
  end

  if dist ~= 0 then
    nav_state.dir = dir
    savePos()
  end
end

nav.turnTo = function(dir)
  if type(dir) == "string" then
    dir = dir_indices[string.upper(dir)]
  end
  if dir > 4 then
    return false
  else
    turnTo(dir)
    return true
  end
end

local function moveXZ(dir, distance)
  -- distance should be positive in this function
  print("[nav] move " .. dir_names[dir] .. " " .. distance)
  local own_dir = nav_state.dir
  local rev = false
  if dir - own_dir == 2 or dir - own_dir == -2 then
    -- can move backwards
    rev = true
  else
    turnTo(dir)
  end
  local n = 0

  while n < distance do
    local success
    if rev then
      success = turtle.back()
    else
      success = turtle.forward()
    end

    if not success then
      return n, "blocked"
    end

    -- update position
    n = n + 1
    if dir == 1 then     -- north
      nav_state.pos[3] = nav_state.pos[3] - 1
    elseif dir == 2 then -- west
      nav_state.pos[1] = nav_state.pos[1] - 1
    elseif dir == 3 then -- south
      nav_state.pos[3] = nav_state.pos[3] + 1
    elseif dir == 4 then -- east
      nav_state.pos[1] = nav_state.pos[1] + 1
    end
    savePos()
  end

  return n, "ok"
end

local function moveY(up, distance)
  -- distance should be positive again
  if up then
    print("[nav] move up " .. distance)
  else
    print("[nav] move down " .. distance)
  end
  local n = 0

  while n < distance do
    local success = false
    if up then
      success = turtle.up()
    else
      success = turtle.down()
    end

    if not success then
      return n, "blocked"
    end

    n = n + 1
    if up then
      nav_state.pos[2] = nav_state.pos[2] + 1
    else
      nav_state.pos[2] = nav_state.pos[2] - 1
    end
    savePos()
  end

  return n, "ok"
end

-- simple relative movement

nav.north = function(n)
  if n < 0 then
    return moveXZ(3, -n) -- move south
  else
    return moveXZ(1, n)
  end
end

nav.south = function(n)
  if n < 0 then
    return moveXZ(1, -n) -- move north
  else
    return moveXZ(3, n)
  end
end

nav.east = function(n)
  if n < 0 then
    return moveXZ(2, -n) -- move west
  else
    return moveXZ(4, n)
  end
end

nav.west = function(n)
  if n < 0 then
    return moveXZ(4, -n) -- move east
  else
    return moveXZ(2, n)
  end
end

nav.up = function(n)
  if n < 0 then
    return moveY(false, -n)
  else
    return moveY(true, n)
  end
end

nav.down = function(n)
  if n < 0 then
    return moveY(true, -n)
  else
    return moveY(false, n)
  end
end

-- generic relative movement

nav.move = function(dir, n)
  if type(dir) == "string" then
    dir = dir_indices[string.upper(dir)]
  end
  if dir == 1 then
    return nav.north(n)
  elseif dir == 2 then
    return nav.west(n)
  elseif dir == 3 then
    return nav.south(n)
  elseif dir == 4 then
    return nav.east(n)
  elseif dir == 5 then
    return nav.up(n)
  elseif dir == 6 then
    return nav.down(n)
  else
    return 0, "invalid dir"
  end
end

-- generic absolute movement

nav.moveTo = function(axis, coord)
  if type(axis) == "string" then
    axis = axis_indices[string.upper(axis)]
  end

  local start = {nav_state.pos[1], nav_state.pos[2], nav_state.pos[3]}
  local dist

  if axis == 1 then -- X
    local dist = nav.east(coord - start[1])
    if coord - start[1] < 0 then
      dist = -dist
    end
    return dist + start[1]
  elseif axis == 2 then -- Y
    local dist = nav.up(coord - start[2])
    if coord - start[2] < 0 then
      dist = -dist
    end
    return dist + start[2]
  elseif axis == 3 then -- Z
    local dist = nav.south(coord - start[3])
    if coord - start[3] < 0 then
      dist = -dist
    end
    return dist + start[3]
  else
    return nil, "invalid axis"
  end
end

-- getters

nav.getDir = function()
  return dir_names[nav_state.dir]
end

nav.getPos = function()
  return nav_state.pos
end

-- miscellaneous

nav.resetPos = function()
  nav_state.pos = {0, 0, 0}
  nav_state.dir = 1
  savePos()
end

return nav
