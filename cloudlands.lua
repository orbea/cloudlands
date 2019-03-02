local DEBUG                  = false -- dev logging
local DEBUG_GEOMETRIC        = false -- turn off noise from island shapes
local LOWLAND_BIOMES         = false -- If true then determine an island's biome using the biome at altitude "LOWLAND_BIOME_ALTITUDE"
local LOWLAND_BIOME_ALTITUDE = 10    -- Higher than beaches, lower than mountains (See LOWLAND_BIOMES)
local ALTITUDE               = 200   -- average altitude of islands
local ALTITUDE_AMPLITUDE     = 40    -- rough island altitude variance (plus or minus)
local EDDYFIELD_SIZE         = 1     -- size of the "eddy field-lines" that smaller islands follow
local GENERATE_ORES          = false -- set to true for island core stone to contain patches of dirt and sand etc.
local VINE_COVERAGE          = 0.3   -- set to 0 to turn off vines
local REEF_RARITY            = 0.015 -- Chance of a viable island having a reef or atoll
local TREE_RARITY            = 0.06  -- Chance of a viable island having a giant tree growing out the middle
local BIOLUMINESCENCE        = false or -- Allow giant trees variants which have glowing parts 
                               minetest.get_modpath("glowtest")   ~= nil or 
                               minetest.get_modpath("ethereal")   ~= nil or
                               minetest.get_modpath("glow")       ~= nil or
                               minetest.get_modpath("nsspf")      ~= nil or
                               minetest.get_modpath("moonflower") ~= nil -- a world using any of these mods is OK with bioluminescence
local ISLANDS_SEED           = 1000  -- You only need to change this if you want to try different island layouts without changing the map seed

-- Some lists of known node aliases (any nodes which can't be found won't be used).
local NODENAMES_STONE       = {"mapgen_stone",        "mcl_core:stone",        "default:stone"}
local NODENAMES_WATER       = {"mapgen_water_source", "mcl_core:water_source", "default:water_source"}
local NODENAMES_ICE         = {"mapgen_ice",          "mcl_core:ice",          "pedology:ice_white", "default:ice"}
local NODENAMES_GRAVEL      = {"mapgen_gravel",       "mcl_core:gravel",       "default:gravel"}
local NODENAMES_SILT        = {"mapgen_silt", "default:silt", "aotearoa:silt", "darkage:silt", "mapgen_sand", "mcl_core:sand", "default:sand"} -- silt isn't a thing yet, but perhaps one day it will be. Use sand for the bottom of ponds in the meantime.
local NODENAMES_VINES       = {"mcl_core:vine", "vines:side_end", "ethereal:vine"} -- ethereal vines don't grow, so only select that if there's nothing else. 
local NODENAMES_HANGINGVINE = {"vines:vine_end"} 
local NODENAMES_HANGINGROOT = {"vines:root_end"}
local NODENAMES_TREEWOOD    = {"mcl_core:tree",   "default:tree",   "mapgen_tree"}
local NODENAMES_TREELEAVES  = {"mcl_core:leaves", "default:leaves", "mapgen_leaves"}

local MODNAME          = minetest.get_current_modname()
local VINES_REQUIRED_HUMIDITY    = 45
local VINES_REQUIRED_TEMPERATURE = 40
local ICE_REQUIRED_TEMPERATURE   =  5

local coreTypes = {
  {
    territorySize     = 200,
    coresPerTerritory = 3,
    radiusMax         = 96,
    depthMax          = 50,
    thicknessMax      = 8,
    frequency         = 0.1,
    pondWallBuffer    = 0.03,
    requiresNexus     = true,
    exclusive         = false
  },
  {
    territorySize     = 60,
    coresPerTerritory = 1,
    radiusMax         = 40,
    depthMax          = 40,
    thicknessMax      = 4,
    frequency         = 0.1,
    pondWallBuffer    = 0.06,
    requiresNexus     = false,
    exclusive         = true
  },
  {
    territorySize     = 30,
    coresPerTerritory = 3,
    radiusMax         = 16,
    depthMax          = 16,
    thicknessMax      = 2,
    frequency         = 0.1,
    pondWallBuffer    = 0.11, -- larger values will make ponds smaller and further from island edges, so it should be as low as you can get it without the ponds leaking over the edge. A small leak-prone island is at (3160, -2360) on seed 1
    requiresNexus     = false,
    exclusive         = true
  }
}

if minetest.get_biome_data == nil then error(MODNAME .. " requires Minetest v5.0 or greater", 0) end

local function fromSettings(settings_name, default_value)
  local result
  if type(default_value) == "number" then 
    result = tonumber(minetest.settings:get(settings_name) or default_value)
  elseif type(default_value) == "boolean" then 
    result = minetest.settings:get_bool(settings_name, default_value)
  end
  return result
end
-- override any settings with user-specified values before these values are needed
ALTITUDE             = fromSettings(MODNAME .. "_altitude",           ALTITUDE)
ALTITUDE_AMPLITUDE   = fromSettings(MODNAME .. "_altitude_amplitude", ALTITUDE_AMPLITUDE)
GENERATE_ORES        = fromSettings(MODNAME .. "_generate_ores",      GENERATE_ORES)
VINE_COVERAGE        = fromSettings(MODNAME .. "_vine_coverage",      VINE_COVERAGE * 100) / 100
LOWLAND_BIOMES       = fromSettings(MODNAME .. "_use_lowland_biomes", LOWLAND_BIOMES)
TREE_RARITY          = fromSettings(MODNAME .. "_giant_tree_rarety",  TREE_RARITY * 100) / 100
BIOLUMINESCENCE      = fromSettings(MODNAME .. "_bioluminescence",    BIOLUMINESCENCE)

local noiseparams_eddyField = {
	offset      = -1,
	scale       = 2,
	spread      = {x = 350 * EDDYFIELD_SIZE, y = 350 * EDDYFIELD_SIZE, z= 350 * EDDYFIELD_SIZE},
	seed        = ISLANDS_SEED, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 2,
	persistence = 0.7,
	lacunarity  = 2.0,
}
local noiseparams_heightMap = {
	offset      = 0,
	scale       = ALTITUDE_AMPLITUDE,
	spread      = {x = 160, y = 160, z= 160},
	seed        = ISLANDS_SEED, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 3,
	persistence = 0.5,
	lacunarity  = 2.0,
}
local DENSITY_OFFSET = 0.7
local noiseparams_density = {
	offset      = DENSITY_OFFSET,
	scale       = .3,
	spread      = {x = 25, y = 25, z= 25},
	seed        = 1000, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 4,
	persistence = 0.5,
	lacunarity  = 2.0,
}
local SURFACEMAP_OFFSET = 0.5
local noiseparams_surfaceMap = {
	offset      = SURFACEMAP_OFFSET,
	scale       = .5,
	spread      = {x = 40, y = 40, z= 40},
	seed        = ISLANDS_SEED, --WARNING! minetest.get_perlin() will add the server map's seed to this value
	octaves     = 4,
	persistence = 0.5,
	lacunarity  = 2.0,
}
local noiseparams_skyReef = {
	offset      = .3,
	scale       = .9,
	spread      = {x = 3, y = 3, z= 3},
	seed        = 1000,
	octaves     = 2,
	persistence = 0.5,
	lacunarity  = 2.0,
}

local noiseAngle = -15 --degrees to rotate eddyField noise, so that the vertical and horizontal tendencies are off-axis
local ROTATE_COS = math.cos(math.rad(noiseAngle))
local ROTATE_SIN = math.sin(math.rad(noiseAngle))

local noise_eddyField
local noise_heightMap
local noise_density
local noise_surfaceMap
local noise_skyReef

local worldSeed
local nodeId_ignore   = minetest.CONTENT_IGNORE
local nodeId_air
local nodeId_stone
local nodeId_water
local nodeId_ice
local nodeId_silt
local nodeId_gravel
local nodeId_vine
local nodeName_vine

local REQUIRED_DENSITY = 0.4

local randomNumbers = {} -- array of 0-255 random numbers with values between 0 and 1 (inclusive)
local data          = {} -- reuse the massive VoxelManip memory buffers instead of creating on every on_generate()
local surfaceData   = {} -- reuse the massive VoxelManip memory buffers instead of creating on every on_generate()
local biomes        = {}

-- optional region specified in settings to restrict islands too
local region_restrictions = false
local region_min_x, region_min_z, region_max_x, region_max_z = -32000, -32000, 32000, 32000

-- optional biomes specified in settings to restrict islands too
local limit_to_biomes = nil
local limit_to_biomes_altitude = nil

--[[==============================
           Math functions
    ==============================]]--

-- avoid having to perform table lookups each time a common math function is invoked
local math_min, math_max, math_floor, math_sqrt, math_cos, math_abs, math_pow, PI = math.min, math.max, math.floor, math.sqrt, math.cos, math.abs, math.pow, math.pi

local function clip(value, minValue, maxValue)
  if value <= minValue then
    return minValue
  elseif value >= maxValue then
    return maxValue
  else
    return value
  end
end

local function round(value)
  return math_floor(0.5 + value)
end

--[[==============================
           Interop functions
    ==============================]]--

local interop = {}
-- returns the id of the first name in the list that resolves to a node id, or nodeId_ignore if not found
interop.find_node_id = function (node_aliases)
  local result
  for _,alias in ipairs(node_aliases) do
    result = minetest.get_content_id(alias)
    --if DEBUG then minetest.log("info", alias .. " returned " .. result) end

    if result == nodeId_ignore then
      -- registered_aliases isn't documented - not sure I'm using it right
      local altAlias = minetest.registered_aliases[alias]
      if altAlias ~= nil then result = minetest.get_content_id(altAlias) end
    end
    if result ~= nodeId_ignore then return result end
  end
  return result  
end

-- returns the name of the first name in the list that resolves to a node id, or 'ignore' if not found
interop.find_node_name = function (node_aliases)
  return minetest.get_name_from_content_id(interop.find_node_id(node_aliases))
end

-- returns the node name of the clone node.
interop.register_clone = function(node_name, clone_name)
  local node = minetest.registered_nodes[node_name]
  if node == nil then
    minetest.log("error", "cannot clone " .. node_name)
    return nil
  else 
    if clone_name == nil then clone_name = MODNAME .. ":" .. string.gsub(node.name, ":", "_") end
    if minetest.registered_nodes[clone_name] == nil then
      minetest.log("info", "attempting to register: " .. clone_name)
      local clone = {}
      for key, value in pairs(node) do clone[key] = value end
      clone.name = clone_name
      minetest.register_node(clone_name, clone)
      --minetest.log("info", clone_name .. " id: " .. minetest.get_content_id(clone_name))
      --minetest.log("info", clone_name .. ": " .. dump(minetest.registered_nodes[clone_name]))
    end
    return clone_name
  end
end

-- converts "modname:nodename" into (modname, nodename), if no colon is found then modname is nil
interop.split_nodename = function(nodeName)
  local result_modname = nil
  local result_nodename = nodeName

  local pos = nodeName:find(':')
  if pos ~= nil then
    result_modname  = nodeName:sub(0, pos - 1) 
    result_nodename = nodeName:sub(pos + 1) 
  end
  return result_modname, result_nodename
end;


--[[==============================
              SkyTrees
    ==============================]]--

-- If splitting SkyTrees into a seperate mod, perhaps schemlib would be of help - https://forum.minetest.net/viewtopic.php?t=18084

if SkyTrees == nil then -- If SkyTrees added into other mods, this may have already been defined

  local TREE1_FILE  = 'cloudlands_tree1.mts'
  local TREE2_FILE  = 'cloudlands_tree2.mts'
  local BARK_SUFFIX = '_bark'
  local GLOW_SUFFIX = '_glow'

  SkyTrees = {
    -- Order the trees in this schematicInfo array from the largest island requirements to smallest
    -- The data in each schematicInfo must exactly match what's in the .mts file or things will break
    schematicInfo = { 
      {
        filename = TREE1_FILE,
        size   = {x = 81, y = 106, z = 111},
        center = {x = 49, y =  11, z =  67},
        requiredIslandDepth = 20,
        requiredIslandRadius = 40,
        nodesWithConstructor = {
          {x=35, y=69, z=1}, {x=61, y=51, z=2}, {x=36, y=68, z=2}, {x=68, y=48, z=3}, {x=61, y=50, z=4}, {x=71, y=50, z=5}, {x=58, y=52, z=5}, {x=65, y=50, z=9}, {x=72, y=53, z=11}, {x=41, y=67, z=12}, {x=63, y=48, z=13}, {x=69, y=52, z=13}, {x=33, y=66, z=14}, {x=39, y=68, z=15}, {x=72, y=68, z=15}, {x=40, y=67, z=16}, {x=39, y=66, z=17}, {x=68, y=45, z=19}, {x=69, y=44, z=20}, {x=72, y=55, z=20}, {x=66, y=56, z=20}, {x=58, y=66, z=20}, {x=71, y=58, z=21}, {x=68, y=45, z=22}, {x=70, y=51, z=22}, {x=73, y=55, z=22}, {x=36, y=62, z=22}, {x=70, y=67, z=22}, {x=21, y=65, z=23}, {x=22, y=66, z=23}, {x=53, y=66, z=23}, {x=70, y=68, z=23}, {x=73, y=54, z=24}, {x=75, y=57, z=24}, {x=37, y=63, z=24}, {x=7, y=68, z=24}, {x=69, y=56, z=25}, {x=34, y=58, z=25}, {x=66, y=62, z=25}, {x=64, y=66, z=25}, {x=6, y=67, z=25}, {x=3, y=68, z=25}, {x=68, y=56, z=26}, {x=65, y=57, z=26}, {x=61, y=63, z=26}, {x=31, y=59, z=27}, {x=48, y=62, z=27}, {x=50, y=63, z=27}, {x=78, y=65, z=27}, {x=78, y=52, z=28}, {x=68, y=57, z=28}, {x=76, y=57, z=28}, {x=31, y=60, z=28}, {x=15, y=63, z=28}, {x=16, y=63, z=28}, {x=61, y=64, z=28}, {x=55, y=65, z=28}, {x=25, y=76, z=28}, {x=61, y=76, z=28}, {x=78, y=52, z=29}, {x=77, y=57, z=29}, {x=78, y=57, z=29}, {x=64, y=59, z=29}, {x=31, y=60, z=29}, {x=46, y=65, z=29}, {x=72, y=55, z=30}, {x=70, y=57, z=30}, {x=79, y=59, z=30}, {x=77, y=60, z=30}, {x=17, y=63, z=30}, {x=58, y=63, z=30}, {x=65, y=63, z=30}, {x=36, y=64, z=30}, {x=44, y=65, z=30}, {x=46, y=66, z=30}, {x=30, y=75, z=30}, {x=58, y=76, z=30}, {x=60, y=77, z=30}, {x=50, y=53, z=31}, {x=34, y=58, z=31}, {x=44, y=60, z=31}, {x=58, y=65, z=31}, {x=80, y=67, z=31}, {x=45, y=68, z=31}, {x=59, y=71, z=31}, {x=64, y=73, z=31}, {x=53, y=103, z=31}, {x=37, y=2, z=32}, {x=46, y=54, z=32}, {x=23, y=60, z=32}, {x=66, y=72, z=32}, {x=30, y=74, z=32}, {x=63, y=74, z=32}, {x=64, y=74, z=32}, {x=63, y=78, z=32}, {x=52, y=52, z=33}, {x=77, y=57, z=33}, {x=63, y=59, z=33}, {x=24, y=60, z=33}, {x=18, y=64, z=33}, {x=30, y=65, z=33}, {x=33, y=65, z=33}, {x=74, y=65, z=33}, {x=75, y=65, z=33}, {x=35, y=74, z=33}, {x=58, y=76, z=33}, {x=44, y=55, z=34}, {x=18, y=63, z=34}, {x=45, y=88, z=34}, {x=43, y=93, z=34}, {x=52, y=99, z=34}, {x=37, y=2, z=35}, {x=34, y=4, z=35}, {x=66, y=48, z=35}, {x=46, y=53, z=35}, {x=48, y=53, z=35}, {x=67, y=56, z=35}, {x=35, y=57, z=35}, {x=75, y=57, z=35}, {x=46, y=60, z=35}, {x=20, y=61, z=35}, {x=31, y=65, z=35}, {x=69, y=66, z=35}, {x=49, y=68, z=35}, {x=65, y=71, z=35}, {x=28, y=74, z=35}, {x=42, y=79, z=35}, {x=45, y=95, z=35}, {x=35, y=6, z=36}, {x=45, y=54, z=36}, {x=44, y=55, z=36}, {x=73, y=58, z=36}, {x=71, y=59, z=36}, {x=55, y=61, z=36}, {x=51, y=65, z=36}, {x=63, y=71, z=36}, {x=42, y=94, z=36}, {x=42, y=95, z=36}, {x=46, y=95, z=36}, {x=43, y=98, z=36}, {x=32, y=11, z=37}, {x=36, y=11, z=37}, {x=64, y=48, z=37}, {x=47, y=54, z=37}, {x=33, y=56, z=37}, {x=31, y=59, z=37}, {x=62, y=59, z=37}, {x=45, y=61, z=37}, {x=50, y=65, z=37}, {x=67, y=65, z=37}, {x=60, y=66, z=37}, {x=63, y=72, z=37}, {x=45, y=87, z=37}, {x=48, y=99, z=37}, {x=33, y=7, z=38}, {x=64, y=48, z=38}, {x=33, y=56, z=38}, {x=64, y=58, z=38}, {x=22, y=63, z=38}, {x=61, y=68, z=38}, {x=34, y=73, z=38}, {x=36, y=79, z=38}, {x=46, y=87, z=38}, {x=54, y=88, z=38}, {x=44, y=97, z=38}, {x=52, y=100, z=38}, {x=30, y=42, z=39}, {x=29, y=44, z=39}, {x=64, y=48, z=39}, {x=72, y=52, z=39}, {x=36, y=55, z=39}, {x=63, y=59, z=39}, {x=28, y=61, z=39}, {x=31, y=61, z=39}, {x=69, y=61, z=39}, {x=36, y=79, z=39}, {x=41, y=85, z=39}, {x=48, y=88, z=39}, {x=45, y=94, z=39}, {x=49, y=100, z=39}, {x=70, y=54, z=40}, {x=53, y=59, z=40}, {x=73, y=59, z=40}, {x=21, y=63, z=40}, {x=42, y=76, z=40}, {x=41, y=77, z=40}, {x=44, y=101, z=40}, {x=37, y=6, z=41}, {x=40, y=56, z=41}, {x=21, y=59, z=41}, {x=52, y=59, z=41}, {x=55, y=63, z=41}, {x=35, y=69, z=41}, {x=40, y=79, z=41}, {x=29, y=83, z=41}, {x=56, y=87, z=41}, {x=39, y=10, z=42}, {x=28, y=22, z=42}, {x=27, y=42, z=42}, {x=67, y=48, z=42}, {x=68, y=53, z=42}, {x=70, y=54, z=42}, {x=29, y=55, z=42}, {x=33, y=55, z=42}, {x=71, y=55, z=42}, {x=32, y=61, z=42}, {x=65, y=63, z=42}, {x=34, y=66, z=42}, {x=55, y=87, z=42}, {x=50, y=88, z=42}, {x=53, y=91, z=42}, {x=38, y=8, z=43}, {x=39, y=11, z=43}, {x=32, y=46, z=43}, {x=49, y=59, z=43}, {x=68, y=62, z=43}, {x=32, y=79, z=43}, {x=27, y=82, z=43}, {x=42, y=86, z=43}, {x=43, y=86, z=43}, {x=56, y=88, z=43}, {x=56, y=90, z=43}, {x=40, y=10, z=44}, {x=39, y=12, z=44}, {x=30, y=20, z=44}, {x=30, y=22, z=44}, {x=60, y=57, z=44}, {x=23, y=60, z=44}, {x=71, y=63, z=44}, {x=65, y=65, z=44}, {x=80, y=66, z=44}, {x=34, y=8, z=45}, {x=30, y=42, z=45}, {x=31, y=42, z=45}, {x=47, y=59, z=45}, {x=70, y=62, z=45}, {x=74, y=67, z=45}, {x=37, y=69, z=45}, {x=30, y=16, z=46}, {x=30, y=42, z=46}, {x=32, y=43, z=46}, {x=39, y=54, z=46}, {x=45, y=58, z=46}, {x=59, y=64, z=46}, {x=75, y=64, z=46}, {x=75, y=67, z=46}, {x=35, y=44, z=47}, {x=28, y=52, z=47}, {x=38, y=52, z=47}, {x=63, y=52, z=47}, {x=69, y=54, z=47}, {x=52, y=62, z=47}, {x=35, y=81, z=47}, {x=33, y=43, z=48}, {x=39, y=46, z=48}, {x=33, y=51, z=48}, {x=67, y=51, z=48}, {x=41, y=54, z=48}, {x=54, y=54, z=48}, {x=60, y=54, z=48}, {x=25, y=56, z=48}, {x=62, y=58, z=48}, {x=29, y=61, z=48}, {x=29, y=81, z=48}, {x=41, y=30, z=49}, {x=35, y=44, z=49}, {x=65, y=49, z=49}, {x=35, y=50, z=49}, {x=48, y=51, z=49}, {x=69, y=51, z=49}, {x=59, y=57, z=49}, {x=27, y=58, z=49}, {x=39, y=10, z=50}, {x=41, y=30, z=50}, {x=35, y=44, z=50}, {x=37, y=44, z=50}, {x=63, y=51, z=50}, {x=69, y=54, z=50}, {x=26, y=55, z=50}, {x=54, y=56, z=50}, {x=49, y=65, z=50}, {x=40, y=87, z=50}, {x=5, y=0, z=51}, {x=3, y=1, z=51}, {x=7, y=5, z=51}, {x=64, y=6, z=51}, {x=37, y=7, z=51}, {x=44, y=29, z=51}, {x=69, y=48, z=51}, {x=42, y=50, z=51}, {x=29, y=52, z=51}, {x=64, y=55, z=51}, {x=40, y=59, z=51}, {x=46, y=65, z=51}, {x=52, y=65, z=51}, {x=54, y=57, z=52}, {x=59, y=57, z=52}, {x=47, y=61, z=52}, {x=7, y=0, z=53}, {x=68, y=2, z=53}, {x=63, y=3, z=53}, {x=68, y=3, z=53}, {x=5, y=6, z=53}, {x=8, y=7, z=53}, {x=47, y=49, z=53}, {x=55, y=57, z=53}, {x=32, y=62, z=53}, {x=7, y=2, z=54}, {x=61, y=5, z=54}, {x=66, y=7, z=54}, {x=58, y=9, z=54}, {x=58, y=10, z=54}, {x=44, y=34, z=54}, {x=37, y=46, z=54}, {x=28, y=54, z=54}, {x=52, y=55, z=54}, {x=33, y=59, z=54}, {x=49, y=60, z=54}, {x=11, y=5, z=55}, {x=39, y=8, z=55}, {x=61, y=10, z=55}, {x=57, y=57, z=55}, {x=49, y=71, z=55}, {x=6, y=3, z=56}, {x=57, y=4, z=56}, {x=60, y=5, z=56}, {x=33, y=8, z=56}, {x=55, y=11, z=56}, {x=56, y=11, z=56}, {x=40, y=13, z=56}, {x=39, y=33, z=56}, {x=17, y=7, z=57}, {x=15, y=12, z=57}, {x=49, y=50, z=57}, {x=49, y=58, z=57}, {x=54, y=60, z=57}, {x=19, y=5, z=58}, {x=60, y=5, z=58}, {x=50, y=10, z=58}, {x=34, y=57, z=58}, {x=56, y=59, z=58}, {x=50, y=12, z=59}, {x=14, y=13, z=59}, {x=32, y=13, z=59}, {x=34, y=40, z=59}, {x=30, y=47, z=59}, {x=36, y=57, z=59}, {x=42, y=57, z=59}, {x=16, y=0, z=60}, {x=10, y=8, z=60}, {x=23, y=12, z=60}, {x=31, y=12, z=60}, {x=34, y=39, z=60}, {x=36, y=39, z=60}, {x=51, y=42, z=60}, {x=32, y=55, z=60}, {x=55, y=61, z=60}, {x=51, y=6, z=61}, {x=53, y=6, z=61}, {x=10, y=9, z=61}, {x=51, y=14, z=61}, {x=31, y=54, z=61}, {x=62, y=59, z=61}, {x=17, y=6, z=62}, {x=27, y=9, z=62}, {x=41, y=12, z=62}, {x=43, y=9, z=63}, {x=41, y=13, z=63}, {x=43, y=13, z=63}, {x=31, y=15, z=63}, {x=37, y=32, z=63}, {x=30, y=37, z=63}, {x=50, y=43, z=63}, {x=45, y=45, z=63}, {x=46, y=46, z=63}, {x=33, y=54, z=63}, {x=45, y=55, z=63}, {x=16, y=11, z=64}, {x=39, y=17, z=64}, {x=35, y=26, z=64}, {x=36, y=27, z=64}, {x=38, y=31, z=64}, {x=20, y=14, z=65}, 
          {x=40, y=17, z=65}, {x=32, y=26, z=65}, {x=30, y=32, z=65}, {x=41, y=36, z=65}, {x=29, y=37, z=65}, {x=28, y=40, z=65}, {x=44, y=40, z=65}, {x=47, y=40, z=65}, {x=52, y=9, z=66}, {x=18, y=11, z=66}, {x=26, y=17, z=66}, {x=28, y=40, z=66}, {x=32, y=52, z=66}, {x=22, y=7, z=67}, {x=28, y=7, z=67}, {x=22, y=15, z=67}, {x=28, y=39, z=67}, {x=49, y=44, z=67}, {x=37, y=8, z=68}, {x=27, y=22, z=68}, {x=45, y=47, z=68}, {x=29, y=7, z=69}, {x=47, y=8, z=69}, {x=43, y=21, z=69}, {x=48, y=43, z=69}, {x=42, y=49, z=69}, {x=32, y=60, z=69}, {x=35, y=60, z=69}, {x=37, y=9, z=70}, {x=48, y=11, z=70}, {x=24, y=17, z=70}, {x=26, y=22, z=70}, {x=27, y=37, z=70}, {x=33, y=59, z=70}, {x=30, y=62, z=70}, {x=33, y=8, z=71}, {x=45, y=9, z=71}, {x=47, y=10, z=71}, {x=46, y=11, z=71}, {x=47, y=12, z=71}, {x=44, y=24, z=71}, {x=27, y=29, z=71}, {x=43, y=39, z=71}, {x=47, y=41, z=71}, {x=31, y=45, z=71}, {x=39, y=58, z=71}, {x=44, y=23, z=72}, {x=26, y=29, z=72}, {x=28, y=36, z=72}, {x=36, y=52, z=72}, {x=35, y=1, z=73}, {x=34, y=2, z=74}, {x=42, y=7, z=74}, {x=27, y=8, z=74}, {x=23, y=10, z=74}, {x=46, y=15, z=74}, {x=26, y=16, z=74}, {x=35, y=45, z=74}, {x=42, y=57, z=74}, {x=24, y=8, z=75}, {x=21, y=9, z=75}, {x=44, y=22, z=75}, {x=33, y=42, z=75}, {x=36, y=47, z=75}, {x=20, y=9, z=76}, {x=45, y=18, z=76}, {x=43, y=29, z=76}, {x=38, y=47, z=76}, {x=36, y=51, z=76}, {x=21, y=7, z=77}, {x=18, y=9, z=77}, {x=18, y=10, z=77}, {x=28, y=29, z=77}, {x=30, y=34, z=77}, {x=47, y=16, z=78}, {x=44, y=20, z=78}, {x=29, y=31, z=78}, {x=31, y=35, z=78}, {x=38, y=52, z=78}, {x=42, y=60, z=78}, {x=29, y=7, z=79}, {x=34, y=7, z=79}, {x=45, y=7, z=79}, {x=18, y=8, z=79}, {x=54, y=11, z=79}, {x=45, y=17, z=79}, {x=46, y=32, z=79}, {x=37, y=7, z=80}, {x=52, y=8, z=80}, {x=54, y=9, z=80}, {x=12, y=11, z=80}, {x=30, y=13, z=80}, {x=33, y=13, z=80}, {x=32, y=14, z=80}, {x=32, y=15, z=80}, {x=44, y=17, z=80}, {x=25, y=19, z=80}, {x=27, y=22, z=80}, {x=28, y=23, z=80}, {x=40, y=27, z=80}, {x=33, y=31, z=80}, {x=50, y=7, z=81}, {x=16, y=14, z=81}, {x=44, y=15, z=81}, {x=41, y=21, z=81}, {x=35, y=30, z=81}, {x=38, y=7, z=82}, {x=55, y=8, z=82}, {x=27, y=9, z=82}, {x=41, y=10, z=82}, {x=31, y=16, z=82}, {x=42, y=17, z=82}, {x=39, y=58, z=82}, {x=36, y=6, z=83}, {x=32, y=10, z=83}, {x=39, y=19, z=83}, {x=32, y=23, z=83}, {x=34, y=23, z=83}, {x=35, y=24, z=83}, {x=35, y=26, z=83}, {x=43, y=63, z=83}, {x=51, y=7, z=84}, {x=60, y=9, z=84}, {x=60, y=10, z=84}, {x=43, y=11, z=84}, {x=59, y=11, z=84}, {x=43, y=12, z=84}, {x=20, y=14, z=84}, {x=34, y=7, z=85}, {x=51, y=8, z=85}, {x=7, y=9, z=85}, {x=22, y=10, z=85}, {x=31, y=11, z=85}, {x=49, y=12, z=85}, {x=42, y=13, z=85}, {x=55, y=14, z=85}, {x=30, y=15, z=85}, {x=56, y=7, z=86}, {x=13, y=8, z=86}, {x=7, y=10, z=86}, {x=22, y=10, z=86}, {x=10, y=5, z=87}, {x=12, y=6, z=87}, {x=35, y=6, z=87}, {x=5, y=8, z=87}, {x=6, y=10, z=87}, {x=53, y=10, z=87}, {x=61, y=12, z=87}, {x=41, y=60, z=87}, {x=60, y=4, z=88}, {x=4, y=5, z=88}, {x=35, y=6, z=88}, {x=36, y=6, z=88}, {x=65, y=7, z=88}, {x=13, y=10, z=88}, {x=38, y=5, z=89}, {x=36, y=6, z=89}, {x=56, y=9, z=89}, {x=19, y=11, z=89}, {x=32, y=12, z=89}, {x=45, y=62, z=89}, {x=41, y=68, z=89}, {x=4, y=2, z=90}, {x=60, y=2, z=90}, {x=11, y=3, z=90}, {x=36, y=6, z=90}, {x=57, y=9, z=90}, {x=43, y=59, z=90}, {x=62, y=2, z=91}, {x=10, y=3, z=91}, {x=62, y=10, z=91}, {x=44, y=59, z=91}, {x=20, y=8, z=92}, {x=32, y=12, z=92}, {x=44, y=61, z=92}, {x=43, y=68, z=92}, {x=36, y=1, z=93}, {x=64, y=6, z=93}, {x=35, y=7, z=93}, {x=63, y=7, z=93}, {x=64, y=7, z=93}, {x=19, y=9, z=93}, {x=40, y=12, z=93}, {x=68, y=2, z=94}, {x=65, y=6, z=94}, {x=35, y=8, z=94}, {x=39, y=13, z=94}, {x=38, y=1, z=95}, {x=42, y=2, z=95}, {x=38, y=58, z=95}, {x=39, y=58, z=95}, {x=39, y=1, z=96}, {x=35, y=14, z=96}, {x=40, y=10, z=100}, {x=33, y=12, z=100}, {x=38, y=3, z=104}, {x=38, y=8, z=106}, {x=37, y=2, z=107}, {x=35, y=4, z=108}, {x=39, y=2, z=110}
        }
      },
      {
        filename = TREE2_FILE,
        size   = {x = 62, y = 65, z = 65},
        center = {x = 30, y = 12, z = 36},
        requiredIslandDepth = 16,
        requiredIslandRadius = 24,
        nodesWithConstructor = { {x=35, y=53, z=1}, {x=33, y=59, z=1}, {x=32, y=58, z=3}, {x=31, y=57, z=5}, {x=40, y=58, z=6}, {x=29, y=57, z=7}, {x=39, y=51, z=8}, {x=52, y=53, z=8}, {x=32, y=53, z=9}, {x=25, y=58, z=9}, {x=51, y=51, z=10}, {x=47, y=50, z=11}, {x=50, y=55, z=11}, {x=28, y=57, z=11}, {x=26, y=39, z=12}, {x=30, y=39, z=12}, {x=24, y=40, z=12}, {x=53, y=52, z=12}, {x=29, y=57, z=12}, {x=43, y=59, z=12}, {x=26, y=39, z=13}, {x=36, y=48, z=13}, {x=27, y=39, z=14}, {x=39, y=48, z=14}, {x=33, y=50, z=14}, {x=43, y=50, z=14}, {x=24, y=59, z=14}, {x=41, y=49, z=15}, {x=33, y=12, z=16}, {x=36, y=46, z=16}, {x=50, y=51, z=16}, {x=46, y=57, z=16}, {x=36, y=45, z=17}, {x=27, y=46, z=17}, {x=22, y=48, z=17}, {x=45, y=50, z=17}, {x=31, y=38, z=18}, {x=32, y=38, z=18}, {x=39, y=46, z=18}, {x=51, y=51, z=18}, {x=33, y=10, z=20}, {x=24, y=44, z=20}, {x=44, y=56, z=20}, {x=35, y=13, z=21}, {x=40, y=41, z=21}, {x=39, y=46, z=21}, {x=43, y=47, z=21}, {x=43, y=56, z=22}, {x=26, y=38, z=23}, {x=25, y=39, z=23}, {x=21, y=40, z=23}, {x=40, y=46, z=23}, {x=22, y=47, z=23}, {x=43, y=47, z=23}, {x=45, y=49, z=23}, {x=31, y=60, z=23}, {x=41, y=44, z=24}, {x=19, y=51, z=24}, {x=37, y=58, z=24}, {x=35, y=12, z=25}, {x=24, y=39, z=25}, {x=36, y=39, z=25}, {x=43, y=47, z=25}, {x=20, y=48, z=25}, {x=32, y=11, z=26}, {x=25, y=46, z=26}, {x=39, y=46, z=26}, {x=16, y=47, z=26}, {x=30, y=14, z=27}, {x=38, y=39, z=27}, {x=25, y=41, z=27}, {x=39, y=42, z=27}, {x=13, y=45, z=27}, {x=38, y=46, z=27}, {x=51, y=51, z=27}, {x=12, y=7, z=28}, {x=14, y=7, z=28}, {x=15, y=11, z=28}, {x=20, y=44, z=28}, {x=28, y=46, z=28}, {x=17, y=60, z=28}, {x=11, y=8, z=29}, {x=52, y=9, z=29}, {x=22, y=13, z=29}, {x=15, y=43, z=29}, {x=29, y=46, z=29}, {x=34, y=46, z=29}, {x=16, y=60, z=29}, {x=23, y=0, z=30}, {x=18, y=13, z=30}, {x=30, y=13, z=30}, {x=33, y=30, z=30}, {x=36, y=40, z=30}, {x=9, y=43, z=30}, {x=10, y=43, z=30}, {x=40, y=55, z=30}, {x=20, y=60, z=30}, {x=8, y=61, z=30}, {x=22, y=1, z=31}, {x=26, y=12, z=31}, {x=18, y=14, z=31}, {x=24, y=15, z=31}, {x=34, y=28, z=31}, {x=35, y=30, z=31}, {x=30, y=36, z=31}, {x=9, y=43, z=31}, {x=31, y=48, z=31}, {x=40, y=49, z=31}, {x=8, y=60, z=31}, {x=29, y=13, z=32}, {x=41, y=15, z=32}, {x=39, y=16, z=32}, {x=38, y=17, z=32}, {x=31, y=25, z=32}, {x=34, y=25, z=32}, {x=35, y=28, z=32}, {x=29, y=34, z=32}, {x=29, y=35, z=32}, {x=37, y=35, z=32}, {x=12, y=42, z=32}, {x=15, y=42, z=32}, {x=36, y=48, z=32}, {x=40, y=49, z=32}, {x=43, y=10, z=33}, {x=30, y=28, z=33}, {x=36, y=30, z=33}, {x=36, y=37, z=33}, {x=11, y=42, z=33}, {x=16, y=42, z=33}, {x=25, y=43, z=33}, {x=35, y=49, z=33}, {x=45, y=53, z=33}, {x=25, y=58, z=33}, {x=35, y=9, z=34}, {x=43, y=10, z=34}, {x=44, y=10, z=34}, {x=30, y=13, z=34}, {x=29, y=31, z=34}, {x=18, y=42, z=34}, {x=22, y=42, z=34}, {x=15, y=49, z=34}, {x=52, y=52, z=34}, {x=49, y=53, z=34}, {x=33, y=55, z=34}, {x=49, y=56, z=34}, {x=36, y=10, z=35}, {x=44, y=10, z=35}, {x=23, y=14, z=35}, {x=42, y=14, z=35}, {x=28, y=27, z=35}, {x=36, y=31, z=35}, {x=30, y=35, z=35}, {x=47, y=55, z=35}, {x=28, y=58, z=35}, {x=12, y=59, z=35}, {x=33, y=8, z=36}, {x=47, y=8, z=36}, {x=39, y=15, z=36}, {x=34, y=34, z=36}, {x=18, y=42, z=36}, {x=51, y=51, z=36}, {x=56, y=51, z=36}, {x=48, y=52, z=36}, {x=58, y=52, z=36}, {x=39, y=59, z=36}, {x=35, y=9, z=37}, {x=48, y=9, z=37}, {x=38, y=23, z=37}, {x=33, y=35, z=37}, {x=39, y=35, z=37}, {x=24, y=37, z=37}, {x=10, y=42, z=37}, {x=5, y=44, z=37}, {x=7, y=61, z=37}, {x=24, y=35, z=38}, {x=36, y=38, z=38}, {x=48, y=51, z=38}, {x=46, y=52, z=38}, {x=44, y=53, z=38}, {x=45, y=54, z=38}, {x=13, y=55, z=38}, {x=21, y=55, z=38}, {x=8, y=60, z=38}, {x=33, y=6, z=39}, {x=34, y=9, z=39}, {x=29, y=12, z=39}, {x=27, y=14, z=39}, {x=39, y=32, z=39}, {x=31, y=37, z=39}, {x=22, y=39, z=39}, {x=28, y=43, z=39}, {x=42, y=45, z=39}, {x=5, y=47, z=39}, {x=29, y=57, z=39}, {x=55, y=58, z=39}, {x=21, y=64, z=39}, {x=37, y=11, z=40}, {x=26, y=15, z=40}, {x=41, y=38, z=40}, {x=40, y=41, z=40}, {x=41, y=42, z=40}, {x=8, y=43, z=40}, {x=40, y=44, z=40}, {x=50, y=49, z=40}, {x=61, y=52, z=40}, {x=42, y=55, z=40}, {x=38, y=56, z=40}, {x=35, y=59, z=40}, {x=30, y=20, z=41}, {x=32, y=33, z=41}, {x=34, y=48, z=41}, {x=48, y=48, z=41}, {x=11, y=55, z=41}, {x=9, y=59, z=41}, {x=32, y=23, z=42}, {x=28, y=36, z=42}, {x=18, y=42, z=42}, {x=12, y=43, z=42}, {x=60, y=51, z=42}, {x=11, y=55, z=42}, {x=27, y=56, z=42}, {x=40, y=12, z=43}, {x=41, y=13, z=43}, {x=26, y=39, z=43}, {x=44, y=40, z=43}, {x=13, y=43, z=43}, {x=30, y=58, z=43}, {x=9, y=64, z=43}, {x=27, y=10, z=44}, {x=26, y=11, z=44}, {x=36, y=14, z=44}, {x=41, y=38, z=44}, {x=36, y=39, z=44}, {x=24, y=43, z=44}, {x=1, y=47, z=44}, {x=33, y=50, z=44}, {x=60, y=51, z=44}, {x=24, y=52, z=44}, {x=31, y=59, z=44}, {x=25, y=11, z=45}, {x=25, y=12, z=45}, {x=27, y=12, z=45}, {x=24, y=13, z=45}, {x=34, y=44, z=45}, {x=30, y=56, z=45}, {x=41, y=14, z=46}, {x=40, y=41, z=46}, {x=60, y=52, z=46}, {x=8, y=57, z=46}, {x=34, y=58, z=46}, {x=24, y=9, z=47}, {x=39, y=12, z=47}, {x=23, y=44, z=47}, {x=48, y=44, z=47}, {x=58, y=46, z=47}, {x=8, y=52, z=47}, {x=9, y=58, z=47}, {x=33, y=58, z=47}, {x=36, y=58, z=47}, {x=27, y=11, z=48}, {x=42, y=11, z=48}, {x=15, y=44, z=48}, {x=34, y=44, z=48}, {x=49, y=45, z=48}, {x=31, y=50, z=48}, {x=39, y=52, z=48}, {x=40, y=55, z=48}, {x=9, y=56, z=48}, {x=44, y=13, z=49}, {x=12, y=43, z=49}, {x=59, y=46, z=49}, {x=25, y=52, z=49}, {x=55, y=60, z=49}, {x=20, y=61, z=49}, {x=25, y=8, z=50}, {x=46, y=12, z=50}, {x=43, y=43, z=50}, {x=15, y=44, z=50}, {x=8, y=51, z=50}, {x=3, y=44, z=51}, {x=33, y=44, z=51}, {x=39, y=51, z=51}, {x=46, y=8, z=52}, {x=46, y=10, z=52}, {x=22, y=13, z=52}, {x=58, y=45, z=52}, {x=21, y=11, z=53}, {x=33, y=45, z=53}, {x=60, y=46, z=53}, {x=14, y=49, z=53}, {x=23, y=50, z=53}, {x=41, y=50, z=53}, {x=45, y=55, z=53}, {x=49, y=55, z=53}, {x=38, y=58, z=53}, {x=11, y=46, z=54}, {x=7, y=47, z=54}, {x=28, y=56, z=54}, {x=41, y=58, z=54}, {x=38, y=59, z=54}, {x=49, y=44, z=55}, {x=30, y=58, z=55}, {x=50, y=44, z=56}, {x=54, y=45, z=56}, {x=16, y=49, z=56}, {x=20, y=50, z=56}, {x=20, y=57, z=56}, {x=37, y=44, z=57}, {x=45, y=59, z=57}, {x=24, y=58, z=58}, {x=46, y=60, z=58}, {x=40, y=43, z=59}, {x=39, y=48, z=59}, {x=53, y=49, z=59}, {x=39, y=44, z=60}, {x=41, y=44, z=61} },
      }
    },
    MODNAME = minetest.get_current_modname() -- don't hardcode incase it's copied into other mods
  }

  -- Must be called this during mod load time, as it uses minetest.register_node()
  -- (add an optional dependency for any mod where the tree & leaf textures might be 
  -- sourced from, to ensure they are loaded before this is called)
  SkyTrees.init = function()

    SkyTrees.minimumIslandRadius = 100000
    SkyTrees.minimumIslandDepth  = 100000
    SkyTrees.maximumYOffset      = 0
    SkyTrees.maximumHeight       = 0

    SkyTrees.nodeName_sideVines   = interop.find_node_name(NODENAMES_VINES)
    SkyTrees.nodeName_hangingVine = interop.find_node_name(NODENAMES_HANGINGVINE)
    SkyTrees.nodeName_hangingRoot = interop.find_node_name(NODENAMES_HANGINGROOT)

    for i,tree in pairs(SkyTrees.schematicInfo) do
      local fullFilename = minetest.get_modpath(SkyTrees.MODNAME) .. DIR_DELIM .. tree.filename
  
      if not file_exists(fullFilename) then
        -- remove the schematic from the list
        SkyTrees.schematicInfo[i] = nil
      else
        SkyTrees.minimumIslandRadius = math_min(SkyTrees.minimumIslandRadius, tree.requiredIslandRadius)
        SkyTrees.minimumIslandDepth  = math_min(SkyTrees.minimumIslandDepth,  tree.requiredIslandDepth)
        SkyTrees.maximumYOffset      = math_max(SkyTrees.maximumYOffset,      tree.center.y)
        SkyTrees.maximumHeight       = math_max(SkyTrees.maximumHeight,       tree.size.y)            

        tree.theme = {}
        SkyTrees.schematicInfo[tree.filename] = tree -- so schematicInfo of trees can be indexed by name
      end
    end

    function generate_woodTypes(nodeName_templateWood, overlay, barkoverlay, nodesuffix, description, dropsTemplateWood)

      local trunkNode = minetest.registered_nodes[nodeName_templateWood]
      local newTrunkNode = {}
      for key, value in pairs(trunkNode) do newTrunkNode[key] = value end
      newTrunkNode.name = SkyTrees.MODNAME .. ":" .. nodesuffix
      newTrunkNode.description = description
      if dropsTemplateWood then newTrunkNode.drop = nodeName_templateWood else newTrunkNode.drop = nil end
      
      local tiles = trunkNode.tiles
      if type(tiles) == "table" then
        newTrunkNode.tiles = {}
        for key, value in pairs(tiles) do newTrunkNode.tiles[key] = value .. overlay end
      else
        newTrunkNode.tiles = tiles .. overlay
      end
      
      local newBarkNode = {}
      for key, value in pairs(newTrunkNode) do newBarkNode[key] = value end
      newBarkNode.name = newBarkNode.name .. BARK_SUFFIX
      newBarkNode.description = "Bark of " .. newBarkNode.description
      -- .drop: leave the bark nodes dropping the trunk wood
      
      local tiles = trunkNode.tiles
      if type(tiles) == "table" then
        newBarkNode.tiles = { tiles[#tiles] .. barkoverlay }
      end      

      --minetest.log("info", newTrunkNode.name .. ": " .. dump(newTrunkNode))
      minetest.register_node(newTrunkNode.name, newTrunkNode)
      minetest.register_node(newBarkNode.name,  newBarkNode)
      return newTrunkNode.name
    end

    function generate_leafTypes(nodeName_templateLeaf, overlay, nodesuffix, description, dropsTemplateLeaf, glowVariantBrightness)

      local leafNode = minetest.registered_nodes[nodeName_templateLeaf]
      local newLeafNode = {}
      for key, value in pairs(leafNode) do newLeafNode[key] = value end
      newLeafNode.name = SkyTrees.MODNAME .. ":" .. nodesuffix
      newLeafNode.description = description
      newLeafNode.sunlight_propagates = true -- soo many leaves they otherwise blot out the sun.
      if dropsTemplateLeaf then newLeafNode.drop = nodeName_templateLeaf else newLeafNode.drop = nil end
      
      local tiles = leafNode.tiles
      if type(tiles) == "table" then
        newLeafNode.tiles = {}
        for key, value in pairs(tiles) do newLeafNode.tiles[key] = value .. overlay end
      else
        newLeafNode.tiles = tiles .. overlay
      end
      
      minetest.register_node(newLeafNode.name, newLeafNode)

      if glowVariantBrightness ~= nil and glowVariantBrightness > 0 and BIOLUMINESCENCE then
        local glowingLeafNode = {}
        for key, value in pairs(newLeafNode) do glowingLeafNode[key] = value end
        glowingLeafNode.name = newLeafNode.name .. GLOW_SUFFIX
        glowingLeafNode.description = "Glowing " .. description
        glowingLeafNode.light_source = glowVariantBrightness
        minetest.register_node(glowingLeafNode.name, glowingLeafNode)
      end

      return newLeafNode.name
    end
  
    local templateWood = interop.find_node_name(NODENAMES_TREEWOOD)
    if templateWood == 'ignore' then 
      SkyTrees.disabled = "Could not find any tree nodes"
      return
    end
    local normalwood = generate_woodTypes(templateWood, "", "", "Tree", "Giant tree", true)
    local darkwood   = generate_woodTypes(templateWood, "^[colorize:black:205", "^[colorize:black:205", "darkwood", "Giant Ziricote", false)
    local deadwood   = generate_woodTypes(templateWood, "^[colorize:#EFE6B9:110", "^[colorize:#E8D0A0:110", "deadbleachedwood", "Dead bleached wood", false) -- make use of the bark blocks to introduce some color variance in the tree


    local templateLeaf = interop.find_node_name(NODENAMES_TREELEAVES)
    if templateLeaf == 'ignore' then 
      SkyTrees.disabled = "Could not find any treeleaf nodes"
      return
    end
    local greenleaf1       = generate_leafTypes(templateLeaf, "", "leaves",  "Leaves of a giant tree", false)
    local greenleaf2       = generate_leafTypes(templateLeaf, "^[colorize:#00FF00:16", "leaves2",  "Leaves of a giant tree", false)
    local greenleaf3       = generate_leafTypes(templateLeaf, "^[colorize:#90FF60:28", "leaves3",  "Leaves of a giant tree", false)

    local whiteblossom1    = generate_leafTypes(templateLeaf, "^[colorize:#fffdfd:255", "blossom_white1",    "Blossom", false)
    local whiteblossom2    = generate_leafTypes(templateLeaf, "^[colorize:#fff0f0:255", "blossom_white2",    "Blossom", false)
    local pinkblossom      = generate_leafTypes(templateLeaf, "^[colorize:#FFE3E8:240", "blossom_whitepink", "Blossom", false, 4)

    local sakurablossom1   = generate_leafTypes(templateLeaf, "^[colorize:#ea327c:240", "blossom_red",       "Sakura blossom", false, 4)
    local sakurablossom2   = generate_leafTypes(templateLeaf, "^[colorize:#ffc3dd:240", "blossom_pink",      "Sakura blossom", false)
    
    local wisteriaBlossom1 = generate_leafTypes(templateLeaf, "^[colorize:#8688f9:240", "blossom_wisteria1", "Wisteria blossom", false)
    local wisteriaBlossom2 = generate_leafTypes(templateLeaf, "^[colorize:#ccc9ff:240", "blossom_wisteria2", "Wisteria blossom", false, 6)


    local tree = SkyTrees.schematicInfo[TREE1_FILE]
    if tree ~= nil then

      tree.defaultThemeName = "Green foliage"
      tree.theme[tree.defaultThemeName] = {
        relativeProbability = 5,
        trunk               = normalwood,
        leaves1             = greenleaf1,
        leaves2             = greenleaf2,
        leaves_special      = greenleaf3,
        vineflags           = { leaves = true, hanging_leaves = true },

        init = function(self, position)
          -- if it's hot and humid then add vines
          local viney = minetest.get_heat(position) >= VINES_REQUIRED_TEMPERATURE and minetest.get_humidity(position) >= VINES_REQUIRED_HUMIDITY

          if viney then
            local flagSeed = position.x * 3 + position.z + ISLANDS_SEED
            self.vineflags.hanging_leaves = (flagSeed % 10) <= 3 or (flagSeed % 10) >= 8
            self.vineflags.leaves         = (flagSeed % 10) <= 5
            self.vineflags.bark           = (flagSeed % 10) <= 2
            self.vineflags.hanging_bark   = (flagSeed % 10) <= 1
          end
        end
      }

      tree.theme["Haunted"] = {
        relativeProbability = 2,
        trunk               = darkwood,
        vineflags           = { hanging_roots = true },

        init = function(self, position)
          -- 60% of these trees are a hanging roots variant
          self.vineflags.hanging_roots = (position.x * 3 + position.y + position.z + ISLANDS_SEED) % 10 < 60
        end
      }

      tree.theme["Dead"] = {
        relativeProbability = 0, -- 0 because this theme will be chosen based on location, rather than chance.
        trunk = deadwood
      }

      tree.theme["Sakura"] = {
        relativeProbability = 2,
        trunk               = darkwood,
        leaves1             = sakurablossom2,
        leaves2             = whiteblossom2,
        leaves_special      = sakurablossom1,

        init = function(self, position)
          -- 40% of these trees are a glowing variant
          self.glowing = (position.x * 3 + position.z + ISLANDS_SEED) % 10 <= 3 and BIOLUMINESCENCE
          self.leaves_special = sakurablossom1
          if self.glowing then self.leaves_special = sakurablossom1 .. GLOW_SUFFIX end
        end
      }

    end
    
    tree = SkyTrees.schematicInfo[TREE2_FILE]
    if tree ~= nil then

      -- copy the green leaves theme from tree1
      tree.defaultThemeName = "Green foliage"
      tree.theme[tree.defaultThemeName] = SkyTrees.schematicInfo[TREE1_FILE].theme["Green foliage"]

      tree.theme["Wisteria"] = {
        relativeProbability = 2.5,
        trunk               = normalwood,
        leaves1             = greenleaf1,
        leaves2             = wisteriaBlossom1,
        leaves_special      = wisteriaBlossom2,
        vineflags           = { leaves = true, hanging_leaves = true, hanging_bark = true },

        init = function(self, position)
          -- 40% of these trees are a glowing variant
          self.glowing = (position.x * 3 + position.z + ISLANDS_SEED) % 10 <= 3 and BIOLUMINESCENCE
          self.leaves_special = wisteriaBlossom2
          if self.glowing then self.leaves_special = wisteriaBlossom2 .. GLOW_SUFFIX end

          -- if it's hot and humid then allow vines on the trunk as well
          self.vineflags.bark = minetest.get_heat(position) >= VINES_REQUIRED_TEMPERATURE and minetest.get_humidity(position) >= VINES_REQUIRED_HUMIDITY
        end
      }

      tree.theme["Blossom"] = {
        relativeProbability = 1.5,
        trunk               = normalwood,
        leaves1             = whiteblossom1,
        leaves2             = whiteblossom2,
        leaves_special      = normalwood..BARK_SUFFIX,

        init = function(self, position)
          -- 30% of these trees are a glowing variant
          self.glowing = (position.x * 3 + position.z + ISLANDS_SEED) % 10 <= 2 and BIOLUMINESCENCE
          leaves_special = normalwood..BARK_SUFFIX
          if self.glowing then self.leaves_special = pinkblossom .. GLOW_SUFFIX end
        end
      }      

    end

    -- fill in any omitted fields in the themes with default values
    for _,tree in pairs(SkyTrees.schematicInfo) do
      for _,theme in pairs(tree.theme) do
        if theme.bark                == nil then theme.bark                = theme.trunk .. BARK_SUFFIX end
        if theme.leaves1             == nil then theme.leaves1             = 'ignore'                   end
        if theme.leaves2             == nil then theme.leaves2             = 'ignore'                   end
        if theme.leaves_special      == nil then theme.leaves_special      = theme.leaves1              end

        if theme.vineflags           == nil then theme.vineflags           = {}                         end
        if theme.relativeProbability == nil then theme.relativeProbability = 1.0                        end
        if theme.glowing             == nil then theme.glowing             = false                      end
      end
    end

  end

  -- this is hack to work around how place_schematic() never invalidates its cache
  -- a unique schematic filename is generated for each unique theme
  SkyTrees.getMalleatedFilename = function(schematicInfo, themeName)

    -- create a unique id for the theme
    local theme = schematicInfo.theme[themeName]
    local flags = 0
    if theme.glowing                  then flags = flags +  1 end
    if theme.vineflags.leaves         then flags = flags +  2 end
    if theme.vineflags.hanging_leaves then flags = flags +  4 end
    if theme.vineflags.bark           then flags = flags +  8 end
    if theme.vineflags.hanging_bark   then flags = flags + 16 end
    if theme.vineflags.hanging_roots  then flags = flags + 32 end

    local uniqueId = themeName .. flags

    if schematicInfo.malleatedFilenames == nil then schematicInfo.malleatedFilenames = {} end

    if schematicInfo.malleatedFilenames[uniqueId] == nil then

      local malleationCount = 0
      for _ in pairs(schematicInfo.malleatedFilenames) do malleationCount = malleationCount + 1 end

      local malleatedFilename = minetest.get_modpath(SkyTrees.MODNAME) .. DIR_DELIM
      for i = 1, malleationCount do
        malleatedFilename = malleatedFilename .. '.' .. DIR_DELIM -- should work on both Linux and Windows
      end
      malleatedFilename = malleatedFilename .. schematicInfo.filename
      schematicInfo.malleatedFilenames[uniqueId] = malleatedFilename
    end

    --minetest.log("info", "Malleated file name for " .. uniqueId .. " is " .. schematicInfo.malleatedFilenames[uniqueId])
    return schematicInfo.malleatedFilenames[uniqueId]
  end


  -- Returns true if a tree in this location would be dead
  -- (checks for desert)
  SkyTrees.isDead = function(position)
    heat     = minetest.get_heat(position)
    humidity = minetest.get_humidity(position)

    if humidity <= 10 or (humidity <= 20 and heat >= 80) then
      return true
    end

    local biomeId = minetest.get_biome_data(position).biome
    local biome = biomes[biomeId]
    if biome ~= nil then
      local modname, nodename = interop.split_nodename(biome.node_top)
      if string.find(nodename, "sand") or string.find(nodename, "desert") then
        return true
      end
    end
  end


  -- Returns the name of a suitable theme
  -- Picks a theme from the schematicInfo automatically, based on the themes' relativeProbability, and location.
  SkyTrees.selectTheme = function(position, schematicInfo, choiceSeed)

    local deadThemeName = "Dead"

    if schematicInfo.theme[deadThemeName] ~= nil then 
      -- Tree is dead and bleached in desert biomes
      if SkyTrees.isDead(position) then
        return deadThemeName
      end
    end

    if choiceSeed == nil then choiceSeed = 0 end
    -- Use a known PRNG implementation
    local prng = PcgRandom(
      position.x           * 65732 +
      position.z           * 729   +
      schematicInfo.size.x * 3     +
      choiceSeed
    )

    local sumProbabilities = 0
    for _,theme in pairs(schematicInfo.theme) do 
      sumProbabilities = sumProbabilities + theme.relativeProbability
    end

    local selection = prng:next(0, sumProbabilities * 1000) / 1000
    minetest.log("info", "x: "..position.x.." y: ".. position.y .. " sumProbabilities: " .. sumProbabilities .. ", selection: " .. selection)

    sumProbabilities = 0
    for themeName,theme in pairs(schematicInfo.theme) do 
      if selection <= sumProbabilities + theme.relativeProbability then
        return themeName
      else            
        sumProbabilities = sumProbabilities + theme.relativeProbability
      end
    end

    error(SkyTrees.MODNAME .. " - SkyTrees.selectTheme failed to find a theme", 0) 
    return schematicInfo.defaultThemeName
  end


  -- position is a vector {x, y, z}
  -- rotation must be either 0, 90, 180, or 270
  -- schematicInfo must be one of the items in SkyTrees.schematicInfo[]
  -- topsoil [optional] is the biome's "node_top" - the ground node of the region.
  SkyTrees.placeTree = function(position, rotation, schematicInfo, themeName, topsoil)

    if SkyTrees.disabled ~= nil then 
      error(SkyTrees.MODNAME .. " - SkyTrees are disabled: " .. SkyTrees.disabled, 0) 
      return
    end

    -- returns a new position vector, rotated around (0, 0) to match the schematic rotation (provided the schematic_size is correct!)
    function rotatePositon(position, schematic_size, rotation)
      local result = vector.new(position);
      if rotation == 90 then
        result.x = position.z
        result.z = schematic_size.x - position.x - 1
      elseif rotation == 180 then
        result.x = schematic_size.x - position.x - 1
        result.z = schematic_size.z - position.z - 1
      elseif rotation == 270 then
        result.x = schematic_size.z - position.z - 1
        result.z = position.x
      end
      return result
    end
    
    local rotatedCenter = rotatePositon(schematicInfo.center, schematicInfo.size, rotation);
    local treePos = vector.subtract(position, rotatedCenter)

    if topsoil == nil then 
      topsoil = 'ignore'
      if minetest.get_biome_data == nil then error(SkyTrees.MODNAME .. " requires Minetest v5.0 or greater, or to have minor modifications to support v0.4.x", 0) end
      local treeBiome = minetest.get_biome_data(position).biome
      if treeBiome ~= nil and treeBiome.node_top ~= nil then topsoil = treeBiome.node_top end
    end
  
    if themeName == nil then themeName = SkyTrees.selectTheme(position, schematicInfo) end
    local theme = schematicInfo.theme[themeName]
    if theme == nil then error(MODNAME .. ' called SkyTrees.placeTree("' .. schematicInfo.filename .. '") with invalid theme: ' .. themeName, 0) end    
    if theme.init ~= nil then theme.init(theme, position) end

    -- theme.init() may have changed the vineflags, so update the replacement node names
    if theme.vineflags.hanging_leaves  == true and SkyTrees.nodeName_hangingVine == 'ignore' then theme.vineflags.leaves = true end -- if there are no hanging vines then substitute side_vines
    if theme.vineflags.leaves          == true then theme.leaf_vines         = SkyTrees.nodeName_sideVines    else theme.leaf_vines         = 'ignore' end
    if theme.vineflags.bark            == true then theme.bark_vines         = SkyTrees.nodeName_sideVines    else theme.bark_vines         = 'ignore' end
    if theme.vineflags.hanging_leaves  == true then theme.hanging_leaf_vines = SkyTrees.nodeName_hangingVine else theme.hanging_leaf_vines = 'ignore' end
    if theme.vineflags.hanging_bark    == true then theme.hanging_bark_vines = SkyTrees.nodeName_hangingVine else theme.hanging_bark_vines = 'ignore' end
    if theme.vineflags.hanging_roots   == true and SkyTrees.nodeName_hangingRoot ~= 'ignore' then theme.hanging_bark_vines = SkyTrees.nodeName_hangingRoot end

    local replacements = {
      ['treebark\r\n\r\n~~~ Cloudlands_tree mts by Dr.Frankenstone: Amateur Arborist ~~~\r\n\r\n'] = theme.bark, -- because this node name is always replaced, it can double as space for a text header in the file.
      ['default:tree']       = theme.trunk,
      ['default:leaves']     = theme.leaves1,
      ['leaves_alt']         = theme.leaves2,
      ['leaves_special']     = theme.leaves_special,
      ['leaf_vines']         = theme.leaf_vines,
      ['bark_vines']         = theme.bark_vines,
      ['hanging_leaf_vines'] = theme.hanging_leaf_vines,
      ['hanging_bark_vines'] = theme.hanging_bark_vines,      
      ['default:dirt']       = topsoil
    }
  
    local malleatedFilename = SkyTrees.getMalleatedFilename(schematicInfo, themeName)

    --minetest.log("info", "Placing tree: " .. dump(treePos) .. ", " .. dump(rotatedCenter) .. ", " .. schematicInfo.filename)
    minetest.place_schematic(treePos, malleatedFilename, rotation, replacements, true)

    -- minetest.place_schematic() doesn't invoke node constructors, so use set_node() for any nodes requiring construction
    for i, schematicCoords in pairs(schematicInfo.nodesWithConstructor) do
      if rotation ~= 0 then schematicCoords = rotatePositon(schematicCoords, schematicInfo.size, rotation) end
      local nodePos = vector.add(treePos, schematicCoords)
      local nodeToConstruct = minetest.get_node(nodePos)
      if nodeToConstruct.name == "air" or nodeToConstruct.name == "ignore" then
        --this is now normal - e.g. if vines are set to 'ignore' then the nodeToConstruct won't be there.
        --minetest.log("error", "nodesWithConstructor["..i.."] does not match schematic " .. schematicInfo.filename .. " at " .. nodePos.x..","..nodePos.y..","..nodePos.z.." rotation "..rotation)
      else 
        minetest.set_node(nodePos, nodeToConstruct)
      end
    end

  end

end

SkyTrees.init();


--[[==============================
       Initialization and Mapgen
    ==============================]]--

local function init_mapgen()
  -- invoke get_perlin() here, since it can't be invoked before the environment
  -- is created because it uses the world's seed value.
  noise_eddyField  = minetest.get_perlin(noiseparams_eddyField)
  noise_heightMap  = minetest.get_perlin(noiseparams_heightMap)
  noise_density    = minetest.get_perlin(noiseparams_density)
  noise_surfaceMap = minetest.get_perlin(noiseparams_surfaceMap)
  noise_skyReef    = minetest.get_perlin(noiseparams_skyReef)

  local prng = PcgRandom(122456 + ISLANDS_SEED)
  for i = 0,255 do randomNumbers[i] = prng:next(0, 0x10000) / 0x10000 end

  for k,v in pairs(minetest.registered_biomes) do
    biomes[minetest.get_biome_id(k)] = v;
  end
  if DEBUG then minetest.log("info", "registered biomes: " .. dump(biomes)) end

  nodeId_air      = minetest.get_content_id("air")

  nodeId_stone    = interop.find_node_id(NODENAMES_STONE)
  nodeId_water    = interop.find_node_id(NODENAMES_WATER)
  nodeId_ice      = interop.find_node_id(NODENAMES_ICE)
  nodeId_silt     = interop.find_node_id(NODENAMES_SILT)
  nodeId_gravel   = interop.find_node_id(NODENAMES_GRAVEL)
  nodeId_vine     = interop.find_node_id(NODENAMES_VINES)
  nodeName_vine   = minetest.get_name_from_content_id(nodeId_vine)

  local regionRectStr = minetest.settings:get(MODNAME .. "_limit_rect")
  if type(regionRectStr) == "string" then 
    local minXStr, minZStr, maxXStr, maxZStr = string.match(regionRectStr, '(-?[%d%.]+)[,%s]+(-?[%d%.]+)[,%s]+(-?[%d%.]+)[,%s]+(-?[%d%.]+)')
    if minXStr ~= nil then 
      local minX, minZ, maxX, maxZ = tonumber(minXStr), tonumber(minZStr), tonumber(maxXStr), tonumber(maxZStr)
      if minX ~= nil and maxX ~= nil and minX < maxX then
        region_min_x, region_max_x = minX, maxX
      end
      if minZ ~= nil and maxZ ~= nil and minZ < maxZ then
        region_min_z, region_max_z = minZ, maxZ
      end
    end
  end

  local limitToBiomesStr = minetest.settings:get(MODNAME .. "_limit_biome")
  if type(limitToBiomesStr) == "string" and string.len(limitToBiomesStr) > 0 then
    limit_to_biomes = limitToBiomesStr:lower()
  end
  limit_to_biomes_altitude = tonumber(minetest.settings:get(MODNAME .. "_limit_biome_altitude"))

  region_restrictions =
    region_min_x > -32000 or region_min_z > -32000 
    or region_max_x < 32000 or region_max_z < 32000
    or limit_to_biomes ~= nil
end

-- Updates coreList to include all cores of type coreType within the given bounds
local function addCores(coreList, coreType, x1, z1, x2, z2)

  for z = math_floor(z1 / coreType.territorySize), math_floor(z2 / coreType.territorySize) do
    for x = math_floor(x1 / coreType.territorySize), math_floor(x2 / coreType.territorySize) do

      -- Use a known PRNG implementation, to make life easier for Amidstest
      local prng = PcgRandom(
        x * 8973896 +
        z * 7467838 +
        worldSeed + 8438 + ISLANDS_SEED
      )

      local coresInTerritory = {}

      for i = 1, coreType.coresPerTerritory do
        local coreX = x * coreType.territorySize + prng:next(0, coreType.territorySize - 1)
        local coreZ = z * coreType.territorySize + prng:next(0, coreType.territorySize - 1)

        -- there's strong vertical and horizontal tendency in 2-octave noise,
        -- so rotate it a little to avoid it lining up with the world axis.
        local noiseX = ROTATE_COS * coreX - ROTATE_SIN * coreZ
        local noiseZ = ROTATE_SIN * coreX + ROTATE_COS * coreZ
        local eddyField = noise_eddyField:get2d({x = noiseX, y = noiseZ})

        if (math_abs(eddyField) < coreType.frequency) then

          local nexusConditionMet = not coreType.requiresNexus
          if not nexusConditionMet then
            -- A 'nexus' is a made up name for a place where the eddyField is flat.
            -- There are often many 'field lines' leading out from a nexus.
            -- Like a saddle in the perlin noise the height "coreType.frequency"
            local eddyField_orthA = noise_eddyField:get2d({x = noiseX + 2, y = noiseZ})
            local eddyField_orthB = noise_eddyField:get2d({x = noiseX, y = noiseZ + 2})
            if math_abs(eddyField - eddyField_orthA) + math_abs(eddyField - eddyField_orthB) < 0.02 then
              nexusConditionMet = true
            end
          end

          if nexusConditionMet then
            local radius     = (coreType.radiusMax + prng:next(0, coreType.radiusMax) * 2) / 3 -- give a 33%/66% weighting split between max-radius and random
            local depth      = (coreType.depthMax + prng:next(0, coreType.depthMax) * 2) / 2
            local thickness  = prng:next(0, coreType.thicknessMax)


            if coreX >= x1 and coreX < x2 and coreZ >= z1 and coreZ < z2 then

              local spaceConditionMet = not coreType.exclusive
              if not spaceConditionMet then
                -- see if any other cores occupy this space, and if so then
                -- either deny the core, or raise it
                spaceConditionMet = true
                local minDistSquared = radius * radius * .7

                for _,core in ipairs(coreList) do
                  if core.type.radiusMax == coreType.radiusMax then
                    -- We've reached the cores of the current type. We can't exclude based on all
                    -- cores of the same type as we can't be sure neighboring territories will have been generated.
                    break
                  end
                  if (core.x - coreX)*(core.x - coreX) + (core.z - coreZ)*(core.z - coreZ) <= minDistSquared + core.radius * core.radius then
                    spaceConditionMet = false
                    break
                  end
                end
                if spaceConditionMet then
                  for _,core in ipairs(coresInTerritory) do
                    -- We can assume all cores of the current type are being generated in this territory,
                    -- so we can exclude the core if it overlaps one already in this territory.
                    if (core.x - coreX)*(core.x - coreX) + (core.z - coreZ)*(core.z - coreZ) <= minDistSquared + core.radius * core.radius then
                      spaceConditionMet = false
                      break
                    end
                  end
                end;
              end

              if spaceConditionMet then
                -- all conditions met, we've located a new island core
                --minetest.log("Adding core "..x..","..y..","..z..","..radius);
                local y = round(noise_heightMap:get2d({x = coreX, y = coreZ}))
                local newCore = {
                  x         = coreX,
                  y         = y,
                  z         = coreZ,
                  radius    = radius,
                  thickness = thickness,
                  depth     = depth,
                  type      = coreType,
                }
                coreList[#coreList + 1] = newCore
                coresInTerritory[#coreList + 1] = newCore
              end

            else
              -- We didn't test coreX,coreZ against x1,z1,x2,z2 immediately and save all
              -- that extra work, as that would break the determinism of the prng calls.
              -- i.e. if the area was approached from a different direction then a
              -- territory might end up with a different list of cores.
              -- TODO: filter earlier but advance prng?
            end
          end
        end
      end
    end
  end
end


-- removes any islands that fall outside region restrictions specified in the options
local function removeUnwantedIslands(coreList)

  local testBiome = limit_to_biomes ~= nil
  local get_biome_name = nil
  if testBiome then
    -- minetest.get_biome_name() was added in March 2018, we'll ignore the 
    -- limit_to_biomes option on versions of Minetest that predate this
    get_biome_name = minetest.get_biome_name
    testBiome = get_biome_name ~= nil
    if get_biome_name == nil then
      minetest.log("warning", MODNAME .. " ignoring " .. MODNAME .. "_limit_biome option as Minetest API version too early to support get_biome_name()") 
      limit_to_biomes = nil
    end
  end

  for i = #coreList, 1, -1 do
    local core = coreList[i]
    local coreX = core.x
    local coreZ = core.z

    if coreX < region_min_x or coreX > region_max_x or coreZ < region_min_z or coreZ > region_max_z then
      table.remove(coreList, i)

    elseif testBiome then
      local biomeAltitude
      if (limit_to_biomes_altitude == nil) then biomeAltitude = ALTITUDE + core.y else biomeAltitude = limit_to_biomes_altitude end

      local biomeName = get_biome_name(minetest.get_biome_data({x = coreX, y = biomeAltitude, z = coreZ}).biome)
      if not string.match(limit_to_biomes, biomeName:lower()) then
        table.remove(coreList, i)
      end
    end
  end
end


-- gets an array of all cores which may intersect the draw distance
local function getCores(minp, maxp)
  local result = {}

  for _,coreType in pairs(coreTypes) do
    addCores(
      result,
      coreType,
      minp.x - coreType.radiusMax,
      minp.z - coreType.radiusMax,
      maxp.x + coreType.radiusMax,
      maxp.z + coreType.radiusMax
    )
  end

  -- remove islands only after cores have all generated to avoid the restriction 
  -- settings from rearranging islands.
  if region_restrictions then removeUnwantedIslands(result) end

  return result;
end

local function setCoreBiomeData(core)
  local pos = {x = core.x, y = ALTITUDE + core.y, z = core.z}
  if LOWLAND_BIOMES then pos.y = LOWLAND_BIOME_ALTITUDE end
  core.biomeId     = minetest.get_biome_data(pos).biome
  core.biome       = biomes[core.biomeId]
  core.temperature = minetest.get_heat(pos)
  core.humidity    = minetest.get_humidity(pos)

  if core.temperature == nil then core.temperature = 50 end
  if core.humidity    == nil then core.humidity    = 50 end
end

local function addDetail_vines(decoration_list, core, data, area, minp, maxp)

  if VINE_COVERAGE > 0 and nodeId_vine ~= nodeId_ignore then

    local y = ALTITUDE + core.y
    if y >= minp.y and y <= maxp.y then
      -- if core.biome is nil then renderCores() never rendered it, which means it
      -- doesn't instersect this draw region.
      if core.biome ~= nil and core.humidity >= VINES_REQUIRED_HUMIDITY and core.temperature >= VINES_REQUIRED_TEMPERATURE then

        local nodeId_top
        local nodeId_filler
        local nodeId_stoneBase
        local nodeId_dust
        if core.biome.node_top    == nil then nodeId_top       = nodeId_stone  else nodeId_top       = minetest.get_content_id(core.biome.node_top)    end
        if core.biome.node_filler == nil then nodeId_filler    = nodeId_stone  else nodeId_filler    = minetest.get_content_id(core.biome.node_filler) end
        if core.biome.node_stone  == nil then nodeId_stoneBase = nodeId_stone  else nodeId_stoneBase = minetest.get_content_id(core.biome.node_stone)  end
        if core.biome.node_dust   == nil then nodeId_dust      = nodeId_stone  else nodeId_dust      = minetest.get_content_id(core.biome.node_dust)   end

        local function isIsland(nodeId)
          return (nodeId == nodeId_filler    or nodeId == nodeId_top 
               or nodeId == nodeId_stoneBase or nodeId == nodeId_dust
               or nodeId == nodeId_silt)
        end

        local function findHighestNodeFace(y, solidIndex, emptyIndex)
          -- return the highest y value (or maxp.y) where solidIndex is part of an island
          -- and emptyIndex is not
          local yOffset = 1
          while y + yOffset <= maxp.y and isIsland(data[solidIndex + yOffset * area.ystride]) and not isIsland(data[emptyIndex + yOffset * area.ystride]) do
            yOffset = yOffset + 1
          end
          return y + yOffset - 1
        end

        local radius = round(core.radius)
        local xCropped = math_min(maxp.x, math_max(minp.x, core.x))
        local zStart = math_max(minp.z, core.z - radius)
        local vi = area:index(xCropped, y, zStart)

        for z = 0, math_min(maxp.z, core.z + radius) - zStart do
          local searchIndex = vi + z * area.zstride
          if isIsland(data[searchIndex]) then

            -- add vines to east face
            if randomNumbers[(zStart + z + y) % 256] <= VINE_COVERAGE then
              for x = xCropped + 1, maxp.x do 
                if not isIsland(data[searchIndex + 1]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex + 1)
                  decoration_list[#decoration_list + 1] = {pos={x=x, y=yhighest, z= zStart + z}, node={name = nodeName_vine, param2 = 3}}
                  break 
                end
                searchIndex = searchIndex + 1
              end
            end
            -- add vines to west face
            if randomNumbers[(zStart + z + y + 128) % 256] <= VINE_COVERAGE then
              searchIndex = vi + z * area.zstride
              for x = xCropped - 1, minp.x, -1 do 
                if not isIsland(data[searchIndex - 1]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex - 1)
                  decoration_list[#decoration_list + 1] = {pos={x=x, y=yhighest, z= zStart + z}, node={name = nodeName_vine, param2 = 2}}
                  break 
                end
                searchIndex = searchIndex - 1
              end
            end
          end
        end

        local zCropped = math_min(maxp.z, math_max(minp.z, core.z))
        local xStart = math_max(minp.x, core.x - radius)
        local vi = area:index(xStart, y, zCropped)
        local zstride = area.zstride

        for x = 0, math_min(maxp.x, core.x + radius) - xStart do
          local searchIndex = vi + x
          if isIsland(data[searchIndex]) then

            -- add vines to north face (make it like moss - grows better on the north side)
            if randomNumbers[(xStart + x + y) % 256] <= (VINE_COVERAGE * 1.2) then
              for z = zCropped + 1, maxp.z do 
                if not isIsland(data[searchIndex + zstride]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex + zstride)
                  decoration_list[#decoration_list + 1] = {pos={x=xStart + x, y=yhighest, z=z}, node={name = nodeName_vine, param2 = 5}}
                  break 
                end
                searchIndex = searchIndex + zstride
              end
            end
            -- add vines to south face (make it like moss - grows better on the north side)
            if randomNumbers[(xStart + x + y + 128) % 256] <= (VINE_COVERAGE * 0.8) then
              searchIndex = vi + x
              for z = zCropped - 1, minp.z, -1 do 
                if not isIsland(data[searchIndex - zstride]) then
                  local yhighest = findHighestNodeFace(y, searchIndex, searchIndex - zstride)
                  decoration_list[#decoration_list + 1] = {pos={x=xStart + x, y=yhighest, z=z}, node={name = nodeName_vine, param2 = 4}}
                  break 
                end
                searchIndex = searchIndex - zstride
              end
            end
          end
        end        

      end
    end
  end
end


-- A rare formation of rocks circling or crowning an island
-- returns true if voxels were changed
local function addDetail_skyReef(decoration_list, core, data, area, minp, maxp)

  local coreTop          = ALTITUDE + core.y
  local reefAltitude     = math_floor(coreTop - 1 - core.thickness / 2)
  local reefMaxHeight    = 12
  local reefMaxUnderhang = 4

  if (maxp.y < reefAltitude - reefMaxUnderhang) or (minp.y > reefAltitude + reefMaxHeight) then
    --no reef here
    return false
  end

  local isReef  = core.radius < core.type.radiusMax * 0.4 -- a reef can't extend beyond radiusMax, so needs a small island
  local isAtoll = core.radius > core.type.radiusMax * 0.8
  if not (isReef or isAtoll) then return false end

  local fastHash = 3
  fastHash = (37 * fastHash) + core.x
  fastHash = (37 * fastHash) + core.z
  fastHash = (37 * fastHash) + math_floor(core.radius)
  fastHash = (37 * fastHash) + math_floor(core.depth)
  if ISLANDS_SEED ~= 1000 then fastHash = (37 * fastHash) + ISLANDS_SEED end
  local rarityAdj = 1
  if core.type.requiresNexus and isAtoll then rarityAdj = 4 end -- humongous islands are very rare, and look good as a atoll
  if (REEF_RARITY * rarityAdj * 1000) < math_floor((math_abs(fastHash)) % 1000) then return false end

  local coreX = core.x --save doing a table lookup in the loop
  local coreZ = core.z --save doing a table lookup in the loop
  
  -- Use a known PRNG implementation
  local prng = PcgRandom(
    coreX * 8973896 +
    coreZ * 7467838 +
    worldSeed + 32564
  )

  local reefUnderhang
  local reefOuterRadius = math_floor(core.type.radiusMax)
  local reefInnerRadius = prng:next(core.type.radiusMax * 0.5, core.type.radiusMax * 0.7)
  local reefWidth       = reefOuterRadius - reefInnerRadius
  local noiseOffset     = 0  

  if isReef then
    reefMaxHeight   = round((core.thickness + 4) / 2)
    reefUnderhang   = round(reefMaxHeight / 2)
    noiseOffset     = -0.1
  end
  if isAtoll then
    -- a crown attached to the island
    reefOuterRadius = math_floor(core.radius * 0.8)
    reefWidth       = math_max(4, math_floor(core.radius * 0.15))
    reefInnerRadius = reefOuterRadius - reefWidth
    reefUnderhang   = 0
    if maxp.y < reefAltitude - reefUnderhang then return end -- no atoll here
  end

  local reefHalfWidth           = reefWidth / 2
  local reefMiddleRadius        = (reefInnerRadius + reefOuterRadius) / 2
  local reefOuterRadiusSquared  = reefOuterRadius  * reefOuterRadius
  local reefInnerRadiusSquared  = reefInnerRadius  * reefInnerRadius
  local reefMiddleRadiusSquared = reefMiddleRadius * reefMiddleRadius
  local reefHalfWidthSquared    = reefHalfWidth    * reefHalfWidth

  -- get the biome details for this core
  local nodeId_first
  local nodeId_second  
  local nodeId_top
  local nodeId_filler
  if core.biome == nil then setCoreBiomeData(core) end -- We can't assume the core biome has already been resolved, core might not have been big enough to enter the draw region
  if core.biome.node_top    == nil then nodeId_top    = nodeId_stone  else nodeId_top       = minetest.get_content_id(core.biome.node_top)    end
  if core.biome.node_filler == nil then nodeId_filler = nodeId_stone  else nodeId_filler    = minetest.get_content_id(core.biome.node_filler) end
  if core.biome.node_dust   ~= nil then 
    nodeId_first  = minetest.get_content_id(core.biome.node_dust)
    nodeId_second = nodeId_top
  else
    nodeId_first  = nodeId_top
    nodeId_second = nodeId_filler
  end

  local zStart  = round(math_max(core.z - reefOuterRadius, minp.z))
  local zStop   = round(math_min(core.z + reefOuterRadius, maxp.z))
  local xStart  = round(math_max(core.x - reefOuterRadius, minp.x))
  local xStop   = round(math_min(core.x + reefOuterRadius, maxp.x))
  local yCenter = math_min(math_max(reefAltitude, minp.y), maxp.y)
  local pos = {}

  local dataBufferIndex = area:index(xStart, yCenter, zStart)
  local vi = -1
  for z = zStart, zStop do
    local zDistSquared = (z - coreZ) * (z - coreZ)
    pos.y = z
    for x = xStart, xStop do
      local distanceSquared = (x - coreX) * (x - coreX) + zDistSquared
      if distanceSquared < reefOuterRadiusSquared and distanceSquared > reefInnerRadiusSquared then
        pos.x = x
        local offsetEase = math_abs(distanceSquared - reefMiddleRadiusSquared) / reefHalfWidthSquared
        local fineNoise = noise_skyReef:get2d(pos)
        local reefNoise = (noiseOffset* offsetEase) + fineNoise + 0.2 * noise_surfaceMap:get2d(pos)

        if (reefNoise > 0) then 
          local distance = math_sqrt(distanceSquared)
          local ease = 1 - math_abs(distance - reefMiddleRadius) / reefHalfWidth
          local yStart = math_max(math_floor(reefAltitude - ease * fineNoise * reefUnderhang), minp.y)
          local yStop  = math_min(math_floor(reefAltitude + ease * reefNoise * reefMaxHeight), maxp.y)

          for y = yStart, yStop do
            vi = dataBufferIndex + (y - yCenter) * area.ystride
            if data[vi] == nodeId_air then 
              if y == yStop then 
                data[vi] = nodeId_first
              elseif y == yStop - 1 then 
                data[vi] = nodeId_second
              else 
                data[vi] = nodeId_filler
              end
            end
            surfaceData[vi] = nodeId_air --prevent plants growing inside atolls
          end
        end
      end
      dataBufferIndex = dataBufferIndex + 1
    end
    dataBufferIndex = dataBufferIndex + area.zstride - (xStop - xStart + 1)
  end

  return vi >= 0
end

-- A rarely occuring giant tree growing from the center of the island
-- returns true if tree was added
local function addDetail_skyTree(decoration_list, core, vm, minp, maxp)

  if (core.radius < SkyTrees.minimumIslandRadius) or (core.depth < SkyTrees.minimumIslandDepth) then
    --no tree here
    return false
  end

  local coreTop          = ALTITUDE + core.y
  local treeAltitude     = math_floor(coreTop + core.thickness)

  if (maxp.y < treeAltitude - SkyTrees.maximumYOffset) or (minp.y > treeAltitude + SkyTrees.maximumHeight) then
    --no tree here
    return false
  elseif SkyTrees.disabled ~= nil then 
    -- can't find nodes/textures in this game that are needed to build trees
    return false
  end

  local coreX = core.x --save doing a table lookups
  local coreZ = core.z --save doing a table lookups

  local fastHash = 3
  fastHash = (37 * fastHash) + coreX
  fastHash = (37 * fastHash) + coreZ
  fastHash = (37 * fastHash) + math_floor(core.radius)
  fastHash = (37 * fastHash) + math_floor(core.depth)
  fastHash = (37 * fastHash) + ISLANDS_SEED
  fastHash = (37 * fastHash) + 76276 -- to keep this probability distinct from reefs and atols
  if (TREE_RARITY * 1000) < math_floor((math_abs(fastHash)) % 1000) then return false end

  -- choose a tree that will fit on the island
  local tree

  local skipLargeTree = (fastHash % 10) < 3 -- to allow small trees a chance to spawn on large islands
  if skipLargeTree then
    if SkyTrees.isDead({x = coreX, y = treeAltitude, z = coreZ}) then
      -- small tree currently doesn't have a dead theme, so don't skip the large tree
      skipLargeTree = false
    end
  end


  for i, treeType in pairs(SkyTrees.schematicInfo) do
    if i == 1 and skipLargeTree then
      -- 'continue', to allow small trees a chance to spawn on large islands
    elseif (core.radius >= treeType.requiredIslandRadius) and (core.depth >= treeType.requiredIslandDepth) then
      tree = treeType
      break
    end
  end

  local maxOffsetFromCenter = core.radius - (tree.requiredIslandRadius - 4); -- 4 is an arbitrary number, to allow trees to get closer to the edge
  
  -- Use a known PRNG implementation
  local prng = PcgRandom(
    coreX * 8973896 +
    coreZ * 7467838 +
    worldSeed + 43786
  )

  local treeAngle = 90 * prng:next(0, 3)
  local treePos = {
    x = coreX + math_floor((prng:next(-maxOffsetFromCenter, maxOffsetFromCenter) + prng:next(-maxOffsetFromCenter, maxOffsetFromCenter)) / 2), 
    y = treeAltitude, 
    z = coreZ + math_floor((prng:next(-maxOffsetFromCenter, maxOffsetFromCenter) + prng:next(-maxOffsetFromCenter, maxOffsetFromCenter)) / 2)
  }

  --[[ This check is commented out because redrawing the tree multiple times - every time a chunk it touches 
       gets emitted - might be slower, but helps work around the bugs in place_schematic() where large schematics 
       are spawned incompletely.
       (The bug in question: https://forum.minetest.net/viewtopic.php?f=6&t=22136 )
  if (maxp.y < treePos.y) or (minp.y > treePos.y) or (maxp.x < treePos.x) or (minp.x > treePos.x) or (maxp.z < treePos.z) or (minp.z > treePos.z) then
    -- Now that we know the exact position of the tree, we know it's spawn point is not in this chunk.
    -- In the interests of only drawing trees once, we only invoke placeTree when the chunk containing treePos is emitted.
    return false
  end --]]

  if tree.theme["Dead"] == nil then
    if SkyTrees.isDead(treePos) then
      -- Trees in this location should be dead, but this tree doesn't have a dead theme, so don't put a tree here
      return false
    end
  end

  if core.biome == nil then setCoreBiomeData(core) end -- We shouldn't assume the core biome has already been resolved, it might be below the emerged chunk and unrendered

  minetest.log("info", "core x: "..coreX.." y: ".. coreZ .. " treePos: " .. treePos.x .. ", y: " .. treePos.y)

  SkyTrees.placeTree(treePos, treeAngle, tree, nil, core.biome.node_top)
  return true;
end

-- minified with https://mothereff.in/lua-minifier
local function a(b)if type(b)=="table"then for c,d in ipairs(b)do b[c]=a(d)end;return b else return b:gsub("%a",function(e)e=e:byte()return string.char(e+(e%32<8 and 19 or-7))end)end end;if minetest.get_modpath("default")then local f=MODNAME..a(":jvidli")minetest.register_node(f,{tiles={"crack_anylength.png^[verticalframe:5:4^[brighten"},description=a("Jvidli"),groups={snappy=3,liquid=3,flammable=3,not_in_creative_inventory=1},drawtype="plantlike",walkable=false,liquid_viscosity=8,liquidtype="source",liquid_alternative_flowing=f,liquid_alternative_source=f,liquid_renewable=false,liquid_range=0,sunlight_propagates=true,paramtype="light"})end;local g=minetest.get_content_id(interop.register_clone("air",MODNAME..":tempAir"))local h=a("zljyla:mvzzpspglk_lnn")local i=a("klmhbsa_qbunslslhclz.wun")if minetest.get_modpath("ethereal")~=nil then i=a("laolylhs_myvza_slhclz.wun")end;local j=minetest.get_content_id(h)if j==nodeId_ignore then minetest.register_node(":"..h,{tiles={i.."^[colorize:#280040E0^[noalpha"},description=a("Mvzzpspglk Lnn"),groups={oddly_breakable_by_hand=3,not_in_creative_inventory=1},drawtype="nodebox",paramtype="light",node_box={type="fixed",fixed={{-0.066666,-0.5,-0.066666,0.066666,0.5,0.066666},{-0.133333,-0.476667,-0.133333,0.133333,0.42,0.133333},{-0.2,-0.435,-0.2,0.2,0.31,0.2},{-0.2,-0.36,-0.28,0.2,0.16667,0.28},{-0.28,-0.36,-0.2,0.28,0.16667,0.2}}}})j=minetest.get_content_id(h)end;local k;local l;local m;local n;local o;local p;local q;local r;local s;local t;local u;

local function addDetail_secrets__shhh_dont_tell_people(w,x,y,z,A,B)if x.biome~=nil and x.radius>18 and x.depth>20 and x.radius+x.depth>60 then local C=math_floor(x.x/x.type.territorySize)local D=math_floor(x.z/x.type.territorySize)local E=x.temperature<=5 and x.x%3==0 and noise_surfaceMap:get2d({x=x.x,y=x.z-8})>=0;local F=x.humidity>=60 and x.temperature>=50;if(C+D)%2==0 and(E or F)then local G=7;local H=5;local I=12;local J=ALTITUDE+x.y-I;local K=G*G;local function L(M,N,O,P,Q,R)local S=vector.direction(M,N)local T={}if S.x>0 then T.x=-1 else T.x=1 end;if S.z>0 then T.z=-1 else T.z=1 end;local U={}local function V(W,X,Y)if y[W]==nodeId_air then local Z={}local _;local function a0(a1)return a1~=nodeId_air and a1~=g and(a1==Y or Y==nil)end;if a0(y[W+T.x])and X.x+T.x>=A.x and X.x+T.x<=B.x then if T.x>0 then _=2 else _=3 end;Z[#Z+1]={solid_vi=W+T.x,facing=_}end;if a0(y[W+T.z*z.zstride])and X.z+T.z>=A.z and X.z+T.z<=B.z then if T.z>0 then _=4 else _=5 end;Z[#Z+1]={solid_vi=W+T.z*z.zstride,facing=_}end;local a2=nil;if#Z==1 then a2=Z[1]elseif#Z==2 then local a3=math.abs(S.x)/(math.abs(S.x)+math.abs(S.z))if randomNumbers[(X.x+X.y+X.z)%256]<=a3 then a2=Z[1]else a2=Z[2]end end;if a2~=nil and(Y==nil or Y==y[a2.solid_vi])and y[a2.solid_vi]~=g then local a4=a2.solid_vi;local a5=1;while X.y+a5<=B.y+1 and y[a4+a5*z.ystride]~=nodeId_air and y[W+a5*z.ystride]==nodeId_air and(Y==nil or Y==y[a4+a5*z.ystride])do a5=a5+1 end;U[#U+1]=function(w)local a6=y[a4+(a5-1)*z.ystride]if a6~=g and a6~=nodeId_air and y[W]==nodeId_air then w[#w+1]={pos={x=X.x,y=X.y+a5-1,z=X.z},node={name=nodeName_vine,param2=a2.facing}}end end end end end;local a7={}local function a8(X,O,P,a1,a9)local aa={}local ab=-1;for ac=X.y,X.y+P-1 do if ac>=A.y and ac<=B.y then if ab==-1 then ab=z:index(X.x,ac,X.z)else ab=ab+z.ystride end;for ad,ae in ipairs(O)do local af=X.x+ae.x;local ag=X.z+ae.z;if af>=A.x and af<=B.x and ag>=A.z and ag<=B.z then local W=ab+ae.x+ae.z*z.zstride;if y[W]==nodeId_air then if a9~=nil then aa[#aa+1]=function()a9(X,W,af,ac,ag)end end else y[W]=a1;a7[#a7+1]=W end end end end end;for ad,ah in ipairs(aa)do ah()end end;local function ai(X,aj,ak,al)local function am(an,ao,ap,aq,ar)if aq>an.y and aq+1<=B.y then V(ao+z.ystride,{x=ap,y=aq+1,z=ar})else V(ao,{x=ap,y=aq,z=ar},Q)end end;local as=am;local at=g;if not ak or nodeId_vine==nodeId_ignore then as=nil end;if al and s~=nodeId_ignore then at=s end;a8(X,O,P,at,as)if aj and Q~=nil then a8({x=X.x,y=X.y-1,z=X.z},O,1,Q,as)end end;local au=x.humidity>=VINES_REQUIRED_HUMIDITY and x.temperature>=VINES_REQUIRED_TEMPERATURE;if R==nil then R=0 end;local av=round(vector.distance(M,N))local aw=vector.divide(vector.subtract(N,M),av)local X=vector.new(M)local ax=vector.new(M)ai(M,0>=R,false)for ay=1,av do ax.x=ax.x+aw.x;if round(ax.x)~=X.x then X.x=round(ax.x)ai(X,ay>=R,au,ay<=R-1 and ay>=R-2)end;ax.y=ax.y+aw.y;if round(ax.y)~=X.y then X.y=round(ax.y)ai(X,ay>=R,au,ay<=R-1 and ay>=R-2)end;ax.z=ax.z+aw.z;if round(ax.z)~=X.z then X.z=round(ax.z)ai(X,ay>=R,au,ay<=R-1 and ay>=R-2)end end;for ad,az in ipairs(U)do az(w)end;for ad,aA in ipairs(a7)do if y[aA]==g then y[aA]=nodeId_air;surfaceData[aA]=nodeId_air end end end;local function aB(af,ac,ag,a1)if af>=A.x and af<=B.x and ag>=A.z and ag<=B.z and ac>=A.y and ac<=B.y then y[z:index(af,ac,ag)]=a1 end end;local function aC(X)return X.x>=A.x and X.x<=B.x and X.z>=A.z and X.z<=B.z and X.y>=A.y and X.y<=B.y end;local aD=math_max(x.z-G,A.z)local aE=math_max(x.x-G,A.x)local aF=math_min(x.x+G,B.x)local aG=math_max(J,A.y)local aH=z:index(aE,aG,aD)for ag=aD,math_min(x.z+G,B.z)do for af=aE,aF do local aI=(af-x.x)*(af-x.x)+(ag-x.z)*(ag-x.z)if aI<K then local aJ=1-aI/K;for ac=math_max(A.y,J+math_floor(1.4-aJ)),math_min(B.y,J+1+math_min(H-1,math_floor(0.8+H*aJ)))do y[aH+(ac-aG)*z.ystride]=nodeId_air end end;aH=aH+1 end;aH=aH+z.zstride-(aF-aE+1)end;local Q;if x.biome.node_top==nil then Q=nil else Q=minetest.get_content_id(x.biome.node_top)end;if F then local aK=vector.new(x.type.territorySize*math.floor(x.x/x.type.territorySize)+math.floor(0.5+x.type.territorySize/2),J,x.type.territorySize*math.floor(x.z/x.type.territorySize)+math.floor(0.5+x.type.territorySize/2))local aL=vector.new(x.x,J,x.z)local S=vector.direction(aL,aK)local aM=4;if S.z<0 then aM=-aM end;aL.z=aL.z+aM;aL.x=aL.x+2;S=vector.direction(aL,aK)if vector.length(S)==0 then S=vector.direction({x=0,y=0,z=0},{x=2,y=0,z=1})end;local aN=vector.add(vector.multiply(S,x.radius),{x=0,y=-4,z=0})local aO=4+math.floor(0.5+x.radius*0.3)local O={{x=0,z=0},{x=-1,z=0},{x=1,z=0},{x=0,z=-1},{x=0,z=1}}L(aL,vector.add(aL,aN),O,2,Q,aO)local aP=x.x;local aQ=x.z-aM*0.75;aB(aP,J,aQ,j)if nodeId_gravel~=nodeId_ignore then aB(aP,J-1,aQ,nodeId_gravel)end;if s~=nodeId_ignore then aB(x.x-6,J+3,x.z-1,s)aB(x.x+4,J+4,x.z+3,s)aB(x.x+6,J+1,x.z-3,s)end else if(o~=nodeId_ignore or n~=nodeId_ignore)and k~=nodeId_ignore and l~=nodeId_ignore then local aR=vector.new(x.x-3,J,x.z-7)local aS=vector.add(aR,{x=0,y=0,z=1})local aT=vector.add(aR,{x=8,y=8,z=0})local aU=vector.add(aT,{x=0,y=0,z=-1})local aV=vector.add(aU,{x=-16,y=16,z=0})L(aV,aU,{{x=0,z=0}},3,Q,0)L(aT,aR,{{x=0,z=0}},2,Q,0)local O={{x=0,z=0},{x=1,z=0},{x=0,z=2},{x=0,z=1},{x=1,z=1}}L(aS,aS,O,2,Q,0)aB(x.x+2,J,x.z+5,k)aB(x.x+2,J,x.z+4,l)aB(x.x+2,J,x.z+2,k)aB(x.x+2,J,x.z+1,l)aB(x.x+4,J,x.z+2,k)aB(x.x+4,J,x.z+1,l)if m~=nodeId_ignore then w[#w+1]={pos={x=x.x,y=J+2,z=x.z+6},node={name=minetest.get_name_from_content_id(m),param2=4}}end;if p~=nodeId_ignore then aB(x.x-4,J+1,x.z+5,p)end;if q~=nodeId_ignore then aB(x.x-6,J+1,x.z,q)end;if r~=nodeId_ignore then aB(x.x-5,J,x.z+2,r)end;if s~=nodeId_ignore then aB(x.x+4,J+4,x.z-3,s)end;local aW;local aX=nil;local aY=nil;if n~=nodeId_ignore then local X={x=x.x-3,y=J+1,z=x.z+6}local aZ=minetest.get_name_from_content_id(n)local a_=minetest.get_node(X).name;if a_~=aZ and not a_:find("chest")then minetest.set_node(X,{name=aZ})end;if aC(X)then y[z:index(X.x,X.y,X.z)]=n;aY=minetest.get_inventory({type="node",pos=X})end end;if o~=nodeId_ignore then local X={x=x.x-2,y=J+1,z=x.z+6}aW=X;if minetest.get_node(X).name~=t then minetest.set_node(X,{name=t})end;if aC(X)then y[z:index(X.x,X.y,X.z)]=o;if not u then aX=minetest.get_inventory({type="node",pos=X})end end end;if aX~=nil or aY~=nil then local b0="yvjr"if x.biome.node_filler~=nil then local b1=string.lower(x.biome.node_filler)..string.lower(x.biome.node_top)if string.match(b1,"ice")or string.match(b1,"snow")or string.match(b1,"frozen")then b0="pjl"end end;local b2=a("klmhbsa:ivvr_dypaalu")if u then b2=a("tjs_ivvrz:dypaalu_ivvr")end;local b3=ItemStack(b2)local b4={}b4.title=a("Dlkklss Vbawvza")b4.text=a("Aol hlyvzaha pz svza.\n\n".."Vby zhschnl haaltwaz aoyvbnovba aol upnoa zhclk tvza vm aol\n".."wyvcpzpvuz.\n".."                                    ---====---\n\n".."Aopz pzshuk pz opnosf lewvzlk huk aol dlhaoly kpk uva aylha\n".."aol aluaz dlss. Dl ohcl lushynlk h zolsalylk jyhn pu aol "..b0 ..",\n".."iba pa pz shivyvbz dvyr huk aol jvukpapvu vm zvtl vm aol whyaf\n".."pz iljvtpun jhbzl mvy jvujlyu.\n\n".."Xbpal h qvbyulf pz ylxbpylk. Uvivkf dpss svvr mvy bz olyl.\n\n".."TjUpzo pz haaltwapun av zaylunaolu aol nspklyz.\n\n".."                                    ---====---")local b5="Zvtl vm aol mbu vm Tpuljyhma dhz wpjrpun hwhya ovd pa ".."dvyrlk huk alhzpun vba hss paz zljylaz. P ovwl fvb luqvflk :)".."\n\n".."'uvivkf mvbuk pa! P dhz zv ohwwf hivba aoha, P mpuhssf ruld ".."zvtlaopun hivba aol nhtl aol wshflyz kpku'a ruvd.' -- Uvajo 2012 ".."(ylkkpa.jvt/y/Tpuljyhma/jvttluaz/xxlux/tpujlyhma_h_wvza_tvyalt/)".."\n\n".."Mlls myll av pucvscl aol lnn, vy Ilya, pu vaoly tvkz."if u then b4.text=b4.title.."\n\n"..b4.text end;b4.owner=a("Ilya Zohjrslavu")b4.author=b4.owner;b4.description=a("Kphyf vm Ilya Zohrslavu")b4.page=1;b4.page_max=1;b4.generation=0;b3:get_meta():from_table({fields=b4})if aX==nil then if aY~=nil then aY:add_item("main",b3)end else aX:add_item("books",b3)local b6={}b6.get_player_name=function()return"server"end;minetest.registered_nodes[t].on_metadata_inventory_put(aW,"books",1,b3,b6)end end;if aY~=nil then local b7;local function b8(b9,ba)for ad,bb in ipairs(b9)do if minetest.registered_items[bb]~=nil then b7=ItemStack(bb.." "..ba)aY:add_item("main",b7)break end end end;b8({"mcl_tools:pick_iron","default:pick_steel"},1)b8({"binoculars:binoculars"},1)b8({"mcl_core:wood","default:wood"},10)b8({"mcl_torches:torch","default:torch"},3)end end end end end end;

local function init_secrets__shhh_dont_tell_people()k=interop.find_node_id(a({"ilkz:ilk_avw"}))l=interop.find_node_id(a({"ilkz:ilk_ivaavt"}))m=interop.find_node_id(a({"tjs_avyjolz:avyjo_dhss","klmhbsa:avyjo_dhss"}))n=interop.find_node_id(a({"jolza","tjs_jolzaz:jolza","klmhbsa:jolza"}))p=interop.find_node_id(a({"ekljvy:ihyyls","jvaahnlz:ihyyls","ovtlkljvy:jvwwly_whuz","clzzlsz:zalls_ivaasl","tjs_msvdlywvaz:msvdly_wva"}))q=interop.find_node_id(a({"jhzasl:hucps","jvaahnlz:hucps","tjs_hucpsz:hucps","klmhbsa:hucps"}))r=interop.find_node_id(a({"ovtlkljvy:ahisl","ekljvy:dvyrilujo","tjs_jyhmapun_ahisl:jyhmapun_ahisl","klmhbsa:ahisl","yhukvt_ibpskpunz:ilujo"}))s=interop.find_node_id(a({"tjs_jvyl:jvidli","ekljvy:jvidli","ovtlkljvy:jvidli_wshuasprl","klmhbsa:jvidli"}))local bd=a("tjs_ivvrz:ivvrzolsm")o=interop.find_node_id({bd,a("klmhbsa:ivvrzolsm")})t=minetest.get_name_from_content_id(o)u=t==bd;local f=MODNAME..a(":jvidli")if s~=nodeId_ignore then minetest.register_alias(f,minetest.get_name_from_content_id(s))else s=minetest.get_content_id(f)end end


local function renderCores(cores, minp, maxp, blockseed)

  local voxelsWereManipulated = false

  -- "Surface" nodes are written to a seperate buffer so that minetest.generate_decorations() can
  -- be called on just the ground surface, otherwise jungle trees will grow on top of chunk boundaries
  -- where the bottom of an island has been emerged but not the top.
  -- The two buffers are combined after minetest.generate_decorations() has run.
  local vm, emerge_min, emerge_max = minetest.get_mapgen_object("voxelmanip")
  vm:get_data(data)        -- put all nodes except the ground surface in this array
  vm:get_data(surfaceData) -- put only the ground surface nodes in this array
  local area = VoxelArea:new{MinEdge=emerge_min, MaxEdge=emerge_max}

  local currentBiomeId = -1
  local nodeId_dust
  local nodeId_top
  local nodeId_filler
  local nodeId_stoneBase
  local depth_top
  local depth_filler
  local fillerFallsWithGravity
  local floodableDepth
  
  for z = minp.z, maxp.z do

    local dataBufferIndex = area:index(minp.x, minp.y, z)
    for x = minp.x, maxp.x do
      for _,core in pairs(cores) do
        local coreTop = ALTITUDE + core.y

        local distanceSquared = (x - core.x)*(x - core.x) + (z - core.z)*(z - core.z)
        local radius        = core.radius
        local radiusSquared = radius * radius

        if distanceSquared <= radiusSquared then

          -- get the biome details for this core
          if core.biome == nil then setCoreBiomeData(core) end          
          if currentBiomeId ~= core.biomeId then
            if core.biome.node_top    == nil then nodeId_top       = nodeId_stone  else nodeId_top       = minetest.get_content_id(core.biome.node_top)    end
            if core.biome.node_filler == nil then nodeId_filler    = nodeId_stone  else nodeId_filler    = minetest.get_content_id(core.biome.node_filler) end
            if core.biome.node_stone  == nil then nodeId_stoneBase = nodeId_stone  else nodeId_stoneBase = minetest.get_content_id(core.biome.node_stone)  end
            if core.biome.node_dust   == nil then nodeId_dust      = nodeId_ignore else nodeId_dust      = minetest.get_content_id(core.biome.node_dust)   end

            if core.biome.depth_top    == nil then depth_top    = 1 else depth_top    = core.biome.depth_top    end
            if core.biome.depth_filler == nil then depth_filler = 3 else depth_filler = core.biome.depth_filler end
            fillerFallsWithGravity = core.biome.node_filler ~= nil and minetest.registered_items[core.biome.node_filler].groups.falling_node == 1

            --[[Commented out as unnecessary, as a supporting node will be added, but uncommenting 
                this will make the strata transition less noisey.
            if fillerFallsWithGravity then
              -- the filler node is affected by gravity and can fall if unsupported, so keep that layer thinner than
              -- core.thickness when possible.
              --depth_filler = math_min(depth_filler, math_max(1, core.thickness - 1))
            end--]]

            floodableDepth = 0
            if nodeId_top ~= nodeId_stone and minetest.registered_items[core.biome.node_top].floodable then 
              -- nodeId_top is a node that water floods through, so we can't have ponds appearing at this depth
              floodableDepth = depth_top
            end
						
            currentBiomeId = core.biomeId
          end

          -- decide on a shape
          local horz_easing
          local noise_weighting = 1
          local shapeType = math_floor(core.depth + radius + core.x) % 5
          if shapeType < 2 then
            -- convex
            -- squared easing function, e = 1 - x²
              horz_easing = 1 - distanceSquared / radiusSquared
          elseif shapeType == 2 then
            -- conical
            -- linear easing function, e = 1 - x
            horz_easing = 1 - math_sqrt(distanceSquared) / radius
          else 
            -- concave
            -- root easing function blended/scaled with square easing function,
            -- x = normalised distance from center of core
            -- a = 1 - x²
            -- b = 1 - √x
            -- e = 0.8*a*x + 1.2*b*(1 - x)

            local radiusRoot = core.radiusRoot
            if radiusRoot == nil then
              radiusRoot = math_sqrt(radius)
              core.radiusRoot = radiusRoot
            end			

            local squared  = 1 - distanceSquared / radiusSquared
            local distance = math_sqrt(distanceSquared)
            local distance_normalized = distance / radius
            local root = 1 - math_sqrt(distance) / radiusRoot
            horz_easing = math_min(1, 0.8*distance_normalized*squared + 1.2*(1-distance_normalized)*root)

            -- this seems to be a more delicate shape that gets wiped out by the
            -- density noise, so lower that
            noise_weighting = 0.63 
          end
          if radius + core.depth > 80 then
            -- larger islands shapes have a slower easing transition, which leaves large areas 
            -- dominated by the density noise, so reduce the density noise when the island is large.
            -- (the numbers here are arbitrary)            
            if radius + core.depth > 120 then 
              noise_weighting = 0.35
            else
              noise_weighting = math_min(0.6, noise_weighting)
            end
          end

          local surfaceNoise = noise_surfaceMap:get2d({x = x, y = z})
          if DEBUG_GEOMETRIC then surfaceNoise = SURFACEMAP_OFFSET end
          local surface = round(surfaceNoise * 3 * (core.thickness + 1) * horz_easing) -- if you change this formular then update maxSufaceRise in on_generated()
          local coreBottom = math_floor(coreTop - (core.thickness + core.depth))
          local noisyDepthOfFiller = depth_filler;
          if noisyDepthOfFiller >= 3 then noisyDepthOfFiller = noisyDepthOfFiller + math_floor(randomNumbers[(x + z) % 256] * 3) - 1 end

          local yBottom       = math_max(minp.y, coreBottom - 4) -- the -4 is for rare instances when density noise pushes the bottom of the island deeper
          local yBottomIndex  = dataBufferIndex + area.ystride * (yBottom - minp.y) -- equivalent to yBottomIndex = area:index(x, yBottom, z)
          local topBlockIndex = -1
          local bottomBlockIndex = -1
          local vi = yBottomIndex
          local densityNoise  = nil

          for y = yBottom, math_min(maxp.y, coreTop + surface) do
            local vert_easing = math_min(1, (y - coreBottom) / core.depth)

            -- If you change the densityNoise calculation, remember to similarly update the copy of this calculation in the pond code
            densityNoise = noise_density:get3d({x = x, y = y - coreTop, z = z}) -- TODO: Optimize this!!
            densityNoise = noise_weighting * densityNoise + (1 - noise_weighting) * DENSITY_OFFSET

            if DEBUG_GEOMETRIC then densityNoise = DENSITY_OFFSET end

            if densityNoise * ((horz_easing + vert_easing) / 2) >= REQUIRED_DENSITY then
              if vi > topBlockIndex then topBlockIndex = vi end
              if bottomBlockIndex < 0 and y > minp.y then bottomBlockIndex = vi end -- if y==minp.y then we don't know for sure this is the lowest block

              if y > coreTop + surface - depth_top and data[vi] == nodeId_air then
                surfaceData[vi] = nodeId_top
                data[vi] = nodeId_top -- will be overwritten by surfaceData[] later, but means we can decorate based on data[]
              elseif y >= coreTop + surface - (depth_top + noisyDepthOfFiller) then
                data[vi] = nodeId_filler
                surfaceData[vi] = nodeId_air -- incase we have intersected another island
              else
                data[vi] = nodeId_stoneBase
                surfaceData[vi] = nodeId_air -- incase we have intersected another island
              end
            end
            vi = vi + area.ystride
          end

          -- ensure nodeId_top blocks also cover the rounded sides of islands (which may be lower
          -- than the flat top), then dust the top surface.
          if topBlockIndex >= 0 then
            voxelsWereManipulated = true;

            -- we either have the highest block, or maxp.y - but we don't want to set maxp.y nodes to nodeId_top
            -- (we will err on the side of caution when we can't distinguish the top of a island's side from maxp.y)
            if maxp.y >= coreTop + surface or vi > topBlockIndex + area.ystride then
              if topBlockIndex > yBottomIndex and data[topBlockIndex - area.ystride] ~= nodeId_air and data[topBlockIndex + area.ystride] == nodeId_air then
                -- We only set a block to nodeId_top if there's a block under it "holding it up" as
                -- it's better to leave 1-deep noise as stone/whatever.
                --data[topBlockIndex] = nodeId_top
                surfaceData[topBlockIndex] = nodeId_top
              end
              if nodeId_dust ~= nodeId_ignore and data[topBlockIndex + area.ystride] == nodeId_air then
                -- writing the dust to the data buffer instead of surfaceData means a snow layer
                -- won't prevent tree growth
                data[topBlockIndex + area.ystride] = nodeId_dust
              end
            end

            if fillerFallsWithGravity and bottomBlockIndex >= 0 and data[bottomBlockIndex] == nodeId_filler then
              -- the bottom node is affected by gravity and can fall if unsupported, put some support in
              data[bottomBlockIndex] = nodeId_stoneBase
            end
          end

          -- add ponds of water, trying to make sure they're not on an edge.
          -- (the only time a pond needs to be rendered when densityNoise is nil (i.e. when there was no land at this x, z),
          -- is when the pond is at minp.y - i.e. the reason no land was rendered is it was below minp.y)
          if surfaceNoise < 0 and (densityNoise ~= nil or (coreTop + surface < minp.y and coreTop >= minp.y)) and nodeId_water ~= nodeId_ignore then            
            local pondWallBuffer = core.type.pondWallBuffer
            local pondBottom = nodeId_filler
            local pondWater  = nodeId_water
            if radius > 18 and core.depth > 15 and nodeId_silt ~= nodeId_ignore then 
              -- only give ponds a sandbed when islands are large enough for it not to stick out the side or bottom
              pondBottom = nodeId_silt 
            end
            if core.temperature <= ICE_REQUIRED_TEMPERATURE and nodeId_ice ~= nodeId_ignore then pondWater = nodeId_ice end

            if densityNoise == nil then
              -- Rare edge case. If the pond is at minp.y, then no land has been rendered, so 
              -- densityNoise hasn't been calculated. Calculate it now.
              densityNoise = noise_density:get3d({x = x, y = minp.y, z = z})
              densityNoise = noise_weighting * densityNoise + (1 - noise_weighting) * DENSITY_OFFSET
              if DEBUG_GEOMETRIC then densityNoise = DENSITY_OFFSET end
            end

            local surfaceDensity = densityNoise * ((horz_easing + 1) / 2)
            local onTheEdge = math_sqrt(distanceSquared) + 1 >= radius
            for y = math_max(minp.y, coreTop + surface), math_min(maxp.y, coreTop - floodableDepth) do
              if surfaceDensity > REQUIRED_DENSITY then
                local vi  = dataBufferIndex + area.ystride * (y - minp.y) -- this is the same as vi = area:index(x, y, z)

                if surfaceDensity > (REQUIRED_DENSITY + pondWallBuffer) and not onTheEdge then
                  surfaceData[vi] = pondWater
                  --data[vi] = nodeId_air -- commented out because it causes vines to think this is the edge, if you uncomment this you MUST update isIsland()
                  if y > minp.y then data[vi - area.ystride] = pondBottom end
                  --remove any dust above ponds
                  if y < maxp.y and data[vi + area.ystride] == nodeId_dust then data[vi + area.ystride] = nodeId_air end
                else
                  -- make sure there are some walls to keep the water in
                  if y == coreTop then 
                    surfaceData[vi] = nodeId_top
                  else
                    surfaceData[vi] = nodeId_air
                    data[vi] = nodeId_filler
                  end
                end;
              end
            end            
          end;

        end
      end
      dataBufferIndex = dataBufferIndex + 1
    end
  end

  local decorations = {}
  for _,core in ipairs(cores) do
    addDetail_vines(decorations, core, data, area, minp, maxp)
    voxelsWereManipulated = addDetail_skyReef(decorations, core, data, area, minp, maxp) or voxelsWereManipulated
    addDetail_secrets__shhh_dont_tell_people(decorations, core, data, area, minp, maxp)
  end

  if voxelsWereManipulated then
    -- Generate decorations on surfaceData only, then combine surfaceData and decorations
    -- with the main data buffer. This avoids trees growing off dirt exposed by maxp.y
    -- (A faster way would be nice, overgeneration perhaps?)
    vm:set_data(surfaceData)
    minetest.generate_decorations(vm)
    vm:get_data(surfaceData)
    for i, value in ipairs(surfaceData) do 
      if value ~= nodeId_air then data[i] = value end
    end

    vm:set_data(data)    
    if GENERATE_ORES then minetest.generate_ores(vm) end

    for _,core in ipairs(cores) do addDetail_skyTree(decorations, core, vm, minp, maxp) end
    for _,decoration in ipairs(decorations) do
      local nodeAtPos = minetest.get_node(decoration.pos)
      if nodeAtPos.name == "air" or nodeAtPos.name == "ignore" then minetest.set_node(decoration.pos, decoration.node) end
    end

    vm:set_lighting({day=0, night=0}) -- Can't do the flags="nolight" trick here as mod is designed to run with other mapgens
    --vm:calc_lighting()
    vm:calc_lighting(nil, nil, false) -- turning off propegation of shadows from the chunk above will only avoid shadows on the land in some circumstances
    vm:write_to_map() -- seems to be unnecessary when other mods that use vm are running
  end
end


local function on_generated(minp, maxp, blockseed)

  local memUsageT0
  local osClockT0 = os.clock()
  if DEBUG then memUsageT0 = collectgarbage("count") end

  local maxCoreThickness = coreTypes[1].thicknessMax -- the first island is the biggest/thickest
  local maxCoreDepth     = coreTypes[1].radiusMax * 3 / 2
  local maxSufaceRise    = 3 * (maxCoreThickness + 1)

  if minp.y > ALTITUDE + (ALTITUDE_AMPLITUDE + maxSufaceRise + 10) or   -- the 10 is an arbitrary number because sometimes the noise values exceed their normal range.
     maxp.y < ALTITUDE - (ALTITUDE_AMPLITUDE + maxCoreThickness + maxCoreDepth + 1) then
    -- Hallelujah Mountains don't generate here
    return
  end

  if noise_eddyField == nil then 
    init_mapgen() 
    init_secrets__shhh_dont_tell_people()
  end
  local cores = getCores(minp, maxp)

  if DEBUG then
    minetest.log("info", "Cores for on_generated(): " .. #cores)
    for _,core in pairs(cores) do
      minetest.log("core ("..core.x..","..core.y..","..core.z..") r"..core.radius);
    end
  end

  if #cores > 0 then
    -- voxelmanip has mem-leaking issues, avoid creating one if we're not going to need it
    renderCores(cores, minp, maxp, blockseed)

    if DEBUG then 
      minetest.log(
        "info", 
        MODNAME .. " took " 
        .. round((os.clock() - osClockT0) * 1000)
        .. "ms for " .. #cores .. " cores. Uncollected memory delta: " 
        .. round(collectgarbage("count") - memUsageT0) .. " KB"
      ) 
    end
  end
end


minetest.register_on_generated(on_generated)

minetest.register_on_mapgen_init(
  -- invoked after mods initially run but before the environment is created, while the mapgen is being initialized
  function(mgparams)
    worldSeed = mgparams.seed
    --if DEBUG then minetest.set_mapgen_params({mgname = "singlenode"--[[, flags = "nolight"]]}) end
  end
)
