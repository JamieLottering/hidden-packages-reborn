local HiddenPackagesMetadata = {
  title = "Hidden Packages Reborn",
  version = "3.0",
  date = "2024-10-30"
}

local GameSession = require("Modules/GameSession.lua")
local GameHUD = require("Modules/GameHUD.lua")
local GameUI = require("Modules/GameUI.lua")
local LEX = require("Modules/LuaEX.lua")

local MAPS_FOLDER = "Maps/"
local MAP_DEFAULT = MAPS_FOLDER .. "packages2.map"
local SONAR_DEFAULT_SOUND = "dev_sweeper_idle_total"

local SETTINGS_FILE = "SETTINGS.v3.0.json"
local MOD_SETTINGS = {
  ExpPerPackage = 100,
  MapPath = MAP_DEFAULT,
  MoneyPerPackage = 1000,
  PackageMultiplier = 1.0, 
  ScannerEnabled = false,
  SonarEnabled = false,
  SonarMinimumDelay = 0.0,
  SonarRange = 125,
  SonarSound = SONAR_DEFAULT_SOUND,
  StickyMarkers = 0,
  StreetcredPerPackage = 100,
}

local SESSION_DATA = {
  collectedPackageIDs = {}
}

local LOADED_MAP = nil

local HUDMessage_Current = ""
local HUDMessage_Last = 0

local PACKAGE_PROP = "base/quest/main_quests/prologue/q005/afterlife/entities/q005_hologram_cube.ent"
local PACKAGE_PROP_Z_BOOST = 0.25

local activeMappins = {}
local activePackages = {}
local isInGame = false
local isPaused = true
local modActive = true
local NEED_TO_REFRESH = false

local nextCheck = 0

local SONAR_NEXT = 0
local SONAR_LAST = 0
local SCANNER_MARKERS = {}
local SCANNER_OPENED = nil
local SCANNER_NEAREST_PKG = nil

local packageCollectMinDistance = 0.5
local packageCollectCloseDistance = 10

local function listFilesInFolder(folder, ext)
  local files = {}
  for k, v in pairs(dir(folder)) do
    for a, b in pairs(v) do
      if a == "name" then
        if LEX.stringEnds(b, ext) then
          table.insert(files, b)
        end
      end
    end
  end
  return files
end

local function readMap(path)
  if path == false or not LEX.fileExists(path) then
    return nil
  end

  local map = {
    amount = 0,
    display_name = LEX.basename(path),
    display_name_amount = "",
    identifier = LEX.basename(path),
    packages = {},
    filepath = path
  }

  for line in io.lines(path) do
    if (line ~= nil) and (line ~= "") and not (LEX.stringStarts(line, "#")) and not (LEX.stringStarts(line, "//")) then
      if LEX.stringStarts(line, "DISPLAY_NAME:") then
        map.display_name = LEX.trim(string.match(line, ":(.*)"))
      elseif LEX.stringStarts(line, "IDENTIFIER:") then
        map.identifier = LEX.trim(string.match(line, ":(.*)"))
      else
        -- regular coordinates
        local components = {}
        for c in string.gmatch(line, '([^ ]+)') do
          table.insert(components, c)
        end

        local pkg = {}
        pkg.x = tonumber(components[1])
        pkg.y = tonumber(components[2])
        pkg.z = tonumber(components[3])
        pkg.w = tonumber(components[4])
        pkg.identifier = map.identifier ..
        ": x=" .. tostring(pkg.x) .. " y=" .. tostring(pkg.y) .. " z=" .. tostring(pkg.z) .. " w=" .. tostring(pkg.w)
        table.insert(map.packages, pkg)
      end
    end
  end

  map.amount = LEX.tableLen(map.packages)
  if map.amount == 0 or map.display_name == nil or map.identifier == nil then
    return nil
  end

  map.display_name_amount = map.display_name .. " (" .. tostring(map.amount) .. ")"

  return map
end

local function HUDMessage(msg)
  if os:clock() - HUDMessage_Last <= 1 then
    HUDMessage_Current = msg .. "\n" .. HUDMessage_Current
  else
    HUDMessage_Current = msg
  end

  GameHUD.ShowMessage(HUDMessage_Current)
  HUDMessage_Last = os:clock()
end

local function loadSettings()
  if not LEX.fileExists(SETTINGS_FILE) then
    return false
  end

  local file = io.open(SETTINGS_FILE, "r")

  if file == nil then
    return false
  end

  local decodedSettings = json.decode(file:read("*a"))
  file:close()

  MOD_SETTINGS = decodedSettings

  return true
end

local function saveSettings()
  local file = io.open(SETTINGS_FILE, "w")
  local encodedSettings = json.encode(MOD_SETTINGS)

  if file == nil then
    return false
  end

  file:write(encodedSettings)
  file:close()

  return true
end

local function distanceToPackage(index)
  if LOADED_MAP == nil then
    return 0
  end

  local pkg = LOADED_MAP.packages[index]
  return Vector4.Distance(Game.GetPlayer():GetWorldPosition(), Vector4.new(pkg["x"], pkg["y"], pkg["z"], pkg["w"]))
end

local function countCollected(MapPath)
  if LOADED_MAP == nil then
    return 0
  end

  local map
  if MapPath ~= LOADED_MAP.filepath then
    map = readMap(MapPath)
  else
    -- no nead to read the map file again if its already loaded
    map = LOADED_MAP
  end

  if map == nil then
    return 0
  end

  local c = 0
  for k, v in pairs(map.packages) do
    if LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, v["identifier"]) then
      c = c + 1
    end
  end
  return c
end

local function spawnEntity(id, vec)
  local transform = Game.GetPlayer():GetWorldTransform()

  transform:SetPosition(vec)
  transform:SetOrientation(EulerAngles.new(0, 0, 0):ToQuat())

  return WorldFunctionalTests.SpawnEntity(id, transform, '')
end

local function destroyEntity(id)
  local maybeEntity = Game.FindEntityByID(id)

  if not maybeEntity then
    return false
  end

  maybeEntity:GetEntity():Destroy()
  return true
end

local function despawnPackage(index)
  if not activePackages[index] then
    return false
  end

  destroyEntity(activePackages[index])
  activePackages[index] = nil

  return true
end

local function spawnPackage(index)
  if activePackages[index] or LOADED_MAP == nil then
    return false
  end

  local pkg = LOADED_MAP.packages[index]
  local vec = Vector4.new(pkg.x, pkg.y, pkg.z + PACKAGE_PROP_Z_BOOST, pkg.w)
  local maybeEntity = spawnEntity(PACKAGE_PROP, vec)

  if not maybeEntity then
    return false
  end

  activePackages[index] = maybeEntity
  return maybeEntity
end

local function unmarkPackage(index)
  if not activeMappins[index] then
    return false
  end

  Game.GetMappinSystem():UnregisterMappin(activeMappins[index])
  activeMappins[index] = nil

  return true
end

local function removeAllMapPins()
  if LOADED_MAP == nil then
    return
  end
  for k, v in pairs(LOADED_MAP.packages) do
    unmarkPackage(k)
  end
end


local function collectHP(packageIndex)
  if LOADED_MAP == nil then
    return false
  end

  local pkg = LOADED_MAP.packages[packageIndex]

  if not LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg["identifier"]) then
    table.insert(SESSION_DATA.collectedPackageIDs, pkg["identifier"])
  end

  unmarkPackage(packageIndex)
  despawnPackage(packageIndex)

  local collected = countCollected(LOADED_MAP.filepath)
  local nativeSettings = GetMod("nativeSettings")

  if nativeSettings then
    nativeSettings.refresh()
  end

  if collected >= LOADED_MAP.amount then
    Game.GetAudioSystem():Play('ui_jingle_quest_success')
    HUDMessage("ALL HIDDEN PACKAGES COLLECTED!")
  else
    Game.GetAudioSystem():Play('ui_loot_rarity_legendary')
    local msg = "Hidden Package " .. tostring(collected) .. " of " .. tostring(LOADED_MAP.amount)
    HUDMessage(msg)
  end

  local multiplier = 1
  if MOD_SETTINGS.PackageMultiplier > 0 then
    multiplier = MOD_SETTINGS.PackageMultiplier * collected
  end

  local money_reward = MOD_SETTINGS.MoneyPerPackage * multiplier
  if money_reward > 0 then
    Game.AddToInventory("Items.money", money_reward)
  end

  local sc_reward = MOD_SETTINGS.StreetcredPerPackage * multiplier
  if sc_reward > 0 then
    Game.AddExp("StreetCred", sc_reward)
  end

  local xp_reward = MOD_SETTINGS.ExpPerPackage * multiplier
  if xp_reward > 0 then
    Game.AddExp("Level", xp_reward)
  end
end

local function checkIfPlayerNearAnyPackage()
  if (LOADED_MAP == nil) or (isPaused == true) or (isInGame == false) or (os.clock() < nextCheck) then
    return
  end

  local nextDelay = 1.0
  local playerPos = Game.GetPlayer():GetWorldPosition()

  for index, pkg in pairs(LOADED_MAP.packages) do
    if not (LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg.identifier)) and (math.abs(playerPos.x - pkg.x) <= 100) and (math.abs(playerPos.y - pkg.y) <= 100) then
      if not activePackages[index] then
        spawnPackage(index)
      end

      if not GameUI.IsVehicle() then
        local d = Vector4.Distance(playerPos, Vector4.new(pkg.x, pkg.y, pkg.z, pkg.w))

        if (d <= packageCollectMinDistance) then
          collectHP(index)
        elseif (d <= packageCollectCloseDistance) then
          nextDelay = 0.1
        end
      end
    elseif activePackages[index] then
      despawnPackage(index)
    end
  end

  nextCheck = os.clock() + nextDelay
end

local function findNearestPackageWithinRange(range) -- 0 = any range
  if not isInGame or LOADED_MAP == nil then
    return false
  end

  local nearest = nil
  local nearestPackage = false
  local playerPos = Game.GetPlayer():GetWorldPosition()

  for key, pkg in pairs(LOADED_MAP.packages) do
    if (LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg["identifier"]) == false) and ((math.abs(playerPos.x - pkg.x) <= range and math.abs(playerPos.y - pkg.y) <= range) or range == 0) then
      -- pkg not collected and in range (or range==0)
      local d = Vector4.Distance(playerPos, Vector4.new(pkg.x, pkg.y, pkg.z, pkg.w))
      if (nearest == nil) or (d < nearest) then
        nearest = d
        nearestPackage = key
      end
    end
  end

  return nearestPackage -- returns package index or false
end

local function placeMapPin(x, y, z, w)
  local mappinData = NewObject('gamemappinsMappinData')
  mappinData.mappinType = TweakDBID.new('Mappins.DefaultStaticMappin')
  mappinData.variant = gamedataMappinVariant.CustomPositionVariant
  mappinData.visibleThroughWalls = true

  return Game.GetMappinSystem():RegisterMappin(mappinData, Vector4.new(x, y, z, w))
end

local function markPackage(i) -- i = package index
  if activeMappins[i] or LOADED_MAP == nil then
    return false
  end

  local pkg = LOADED_MAP.packages[i]
  local mappin_id = placeMapPin(pkg["x"], pkg["y"], pkg["z"], pkg["w"])

  if mappin_id then
    activeMappins[i] = mappin_id
    return mappin_id
  end

  return false
end

local function destroyAllPackageObjects()
  if LOADED_MAP == nil then
    return
  end

  for k, v in pairs(LOADED_MAP.packages) do
    despawnPackage(k)
  end
end

local function sonar()
  local NP = findNearestPackageWithinRange(MOD_SETTINGS.SonarRange)

  if not NP or not GameUI.IsDefault() then
    return
  end

  SONAR_NEXT = SONAR_LAST + math.max((MOD_SETTINGS.SonarRange - (MOD_SETTINGS.SonarRange - distanceToPackage(NP))) / 35, 0.1)

  if os.clock() < (SONAR_NEXT + MOD_SETTINGS.SonarMinimumDelay) then
    return
  end

  Game.GetAudioSystem():Play(MOD_SETTINGS.SonarSound)
  SONAR_LAST = os.clock()
end

local function scanner()
  if not MOD_SETTINGS.ScannerEnabled or SCANNER_OPENED == nil then
    return
  end

  local NP = SCANNER_NEAREST_PKG

  if NP and not LEX.tableHasValue(SCANNER_MARKERS, NP) then
    markPackage(NP)
    table.insert(SCANNER_MARKERS, NP)

    if MOD_SETTINGS.StickyMarkers > 0 then
      while LEX.tableLen(SCANNER_MARKERS) > MOD_SETTINGS.StickyMarkers do
        unmarkPackage(SCANNER_MARKERS[1])
        table.remove(SCANNER_MARKERS, 1)
      end
    end
  end
end

local function reset()
  destroyAllPackageObjects()
  removeAllMapPins()
  activePackages = {}
  activeMappins = {}
  nextCheck = 0
  return true
end

local function changeMap(path)
  if path == false then -- false == mod disabled
    reset()
    LOADED_MAP = nil
    return true
  end

  if LEX.fileExists(path) then
    reset()
    LOADED_MAP = readMap(path)
    checkIfPlayerNearAnyPackage()
    return true
  end

  return false
end

local function registerNativeSettingsMaps(nativeSettings, nativeSettingsRoot)
  local category = nativeSettingsRoot .. "/Maps"
  local mapsPaths = { [1] = false }
  local nsMapsDisplayNames = { [1] = "None" }
  local nsDefaultMap = 1
  local nsCurrentMap = 1

  for _, v in pairs(listFilesInFolder(MAPS_FOLDER, ".map")) do
    local map_path = MAPS_FOLDER .. v
    local read_map = readMap(map_path)

    if read_map ~= nil then
      local i = LEX.tableLen(mapsPaths) + 1
      nsMapsDisplayNames[i] = read_map["display_name"] .. " (" .. read_map["amount"] .. " pkgs)"
      mapsPaths[i] = map_path
      if map_path == MAP_DEFAULT then
        nsDefaultMap = i
      end
      if map_path == MOD_SETTINGS.MapPath then
        nsCurrentMap = i
      end
    end
  end

  nativeSettings.addSubcategory(category, "Maps")
  nativeSettings.addSelectorString(category, "Map",
    "Maps are stored in \'.../mods/Hidden Packages/Maps\''. If set to None the mod is disabled.", nsMapsDisplayNames,
    nsCurrentMap, nsDefaultMap, function(value)
    MOD_SETTINGS.MapPath = mapsPaths[value]
    saveSettings()
    NEED_TO_REFRESH = true
  end)
end

local function registerNativeSettingsSonar(nativeSettings, nativeSettingsRoot)
  local category = nativeSettingsRoot .. "/Sonar"

  nativeSettings.addSubcategory(category, "Sonar")

  nativeSettings.addSwitch(category, "Sonar",
    "Play a sound when near a package in increasing frequency the closer you get to it", MOD_SETTINGS.SonarEnabled, false,
    function(state)
      MOD_SETTINGS.SonarEnabled = state
      saveSettings()
    end)

  nativeSettings.addRangeInt(category, "Range", "Sonar starts working when this close to a package", 50, 250, 25,
    MOD_SETTINGS.SonarRange, 125, function(value)
    MOD_SETTINGS.SonarRange = value
    saveSettings()
  end)

  nativeSettings.addRangeFloat(category, "Minimum Interval",
    "Sonar will wait atleast this long before playing a sound again. Value is in seconds.", 0.0, 10.0, 0.5, "%.1f",
    MOD_SETTINGS.SonarMinimumDelay, 0.0, function(value)
    MOD_SETTINGS.SonarMinimumDelay = value
    saveSettings()
  end)
end

local function registerNativeSettingsScanner(nativeSettings, nativeSettingsRoot)
  local category = nativeSettingsRoot .. "/Scanner"

  nativeSettings.addSubcategory(category, "Scanner Marker")

  nativeSettings.addSwitch(category, "Scanner Marker", "Nearest package will be marked by using the scanner",
    MOD_SETTINGS.ScannerEnabled, false, function(state)
    MOD_SETTINGS.ScannerEnabled = state
    saveSettings()
  end)

  nativeSettings.addRangeInt(category, "Sticky Markers",
    "Keep up to this many packages marked. Markers will disappear after closing the scanner if set to 0.", 0, 10, 1,
    MOD_SETTINGS.StickyMarkers, 0, function(value)
    MOD_SETTINGS.StickyMarkers = value
    saveSettings()
  end)
end

local function registerNativeSettingsRewards(nativeSettings, nativeSettingsRoot)
  local category = nativeSettingsRoot .. "/Rewards"

  nativeSettings.addSubcategory(category, "Rewards")

  nativeSettings.addRangeInt(category, "Money", "Collecting a package rewards you this much money", 0, 5000, 100,
    MOD_SETTINGS.MoneyPerPackage, 1000, function(value)
    MOD_SETTINGS.MoneyPerPackage = value
    saveSettings()
  end)

  nativeSettings.addRangeInt(category, "XP", "Collecting a package rewards you this much XP", 0, 300, 10,
    MOD_SETTINGS.ExpPerPackage, 100, function(value)
    MOD_SETTINGS.ExpPerPackage = value
    saveSettings()
  end)

  nativeSettings.addRangeInt(category, "Street Cred", "Collecting a package rewards you this much Street Cred", 0, 300,
    10, MOD_SETTINGS.StreetcredPerPackage, 100, function(value)
    MOD_SETTINGS.StreetcredPerPackage = value
    saveSettings()
  end)

  nativeSettings.addRangeFloat(category, "Reward Multiplier",
    "Multiply rewards (except random items) by how many packages you've collected and this.\n(eg. 1.0 means 5th package = 5x the rewards. 0.0 disables it (every package will give you 1x))",
    0.0, 2.0, 0.1, "%.1f", MOD_SETTINGS.PackageMultiplier, 1.0, function(value)
    MOD_SETTINGS.PackageMultiplier = value
    saveSettings()
  end)
end

local function onGameSessionStart()
  isInGame = true
  isPaused = false
  RESET_BUTTON_PRESSED = 0

  if NEED_TO_REFRESH then
    changeMap(MOD_SETTINGS.MapPath)
    NEED_TO_REFRESH = false
  end

  checkIfPlayerNearAnyPackage()
end

local function onGameSessionEnd()
  isInGame = false
  reset()
end

local function onGameSessionPause()
  isPaused = true
end

local function onGameSessionResume()
  isPaused = false
  RESET_BUTTON_PRESSED = 0

  if NEED_TO_REFRESH then
    changeMap(MOD_SETTINGS.MapPath)
    NEED_TO_REFRESH = false
  end

  while LEX.tableLen(SCANNER_MARKERS) > MOD_SETTINGS.StickyMarkers do
    unmarkPackage(SCANNER_MARKERS[1])
    table.remove(SCANNER_MARKERS, 1)
  end
end

local function onPlayerAction()
  checkIfPlayerNearAnyPackage()
end

local function initGameSession()
  GameSession.StoreInDir('Sessions')
  GameSession.Persist(SESSION_DATA)

  GameSession.OnStart(onGameSessionStart)
  GameSession.OnEnd(onGameSessionEnd)
  GameSession.OnPause(onGameSessionPause)
  GameSession.OnResume(onGameSessionResume)

  Observe('PlayerPuppet', 'OnAction', onPlayerAction)

  GameSession.TryLoad()
end

local function onScannerOpen()
  if not (MOD_SETTINGS.ScannerEnabled and modActive) then
    return
  end

  SCANNER_OPENED = os.clock()
  SCANNER_NEAREST_PKG = findNearestPackageWithinRange(0)
end

local function onScannerClose()
  if not MOD_SETTINGS.ScannerEnabled then
    return
  end

  SCANNER_OPENED = nil
  SCANNER_NEAREST_PKG = nil

  if MOD_SETTINGS.StickyMarkers == 0 then
    for k, v in pairs(SCANNER_MARKERS) do
      unmarkPackage(v)
      SCANNER_MARKERS[k] = nil
    end
  end
end

local function initGameUI()
  GameUI.Listen('ScannerOpen', onScannerOpen)
  GameUI.Listen('ScannerClose', onScannerClose)
end

local function onUpdate()
  if LOADED_MAP ~= nil and not isPaused and isInGame and modActive then
    if MOD_SETTINGS.SonarEnabled then
      sonar()
    end

    if MOD_SETTINGS.ScannerEnabled and SCANNER_OPENED then
      scanner()
    end
  end
end

local function registerNativeSettings()
  local nativeSettings = GetMod("nativeSettings")
  if nativeSettings == nil then
    return
  end

  local nativeSettingsRoot = "/Hidden Packages"

  nativeSettings.addTab(nativeSettingsRoot, HiddenPackagesMetadata.title)
  nativeSettings.addSubcategory(nativeSettingsRoot .. "/Version",
    HiddenPackagesMetadata.title ..
    " version " .. HiddenPackagesMetadata.version .. " (" .. HiddenPackagesMetadata.date .. ")")

  registerNativeSettingsMaps(nativeSettings, nativeSettingsRoot)
  registerNativeSettingsSonar(nativeSettings, nativeSettingsRoot)
  registerNativeSettingsScanner(nativeSettings, nativeSettingsRoot)
  registerNativeSettingsRewards(nativeSettings, nativeSettingsRoot)
end

local function onShutdown()
  GameSession.TrySave()
  reset()
end

local function onInit ()
  isInGame = Game.GetPlayer() and Game.GetPlayer():IsAttached() and not Game.GetSystemRequestsHandler():IsPreGame()
  LOADED_MAP = readMap(MOD_SETTINGS.MapPath)

  loadSettings()
  registerNativeSettings()
  initGameSession()
  initGameUI()
end

-- Event Registration
registerForEvent('onInit', onInit)
registerForEvent('onShutdown', onShutdown)
registerForEvent('onUpdate', onUpdate)
