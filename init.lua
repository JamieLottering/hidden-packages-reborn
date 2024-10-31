local HiddenPackagesMetadata = {
	title = "Hidden Packages Reborn",
	version = "3.0",
	date = "2024-10-30"
}

local GameSession = require("Modules/GameSession.lua")
local GameHUD = require("Modules/GameHUD.lua")
local GameUI = require("Modules/GameUI.lua")
local LEX = require("Modules/LuaEX.lua")

local MAPS_FOLDER = "Maps/" -- should end with a /
local MAP_DEFAULT = "Maps/packages2.map" -- full path to default map
local SONAR_DEFAULT_SOUND = "ui_scanning_Stop"

local SETTINGS_FILE = "SETTINGS.v3.0.json"
local MOD_SETTINGS = { -- saved in SETTINGS_FILE (separate from game save)
	SonarEnabled = false,
	SonarRange = 125,
	SonarSound = SONAR_DEFAULT_SOUND,
	SonarMinimumDelay = 0.0,
	MoneyPerPackage = 1000,
	StreetcredPerPackage = 100,
	ExpPerPackage = 100,
	PackageMultiplier = 1.0,
	MapPath = MAP_DEFAULT,
	ScannerEnabled = false,
	StickyMarkers = 0,
}

local SESSION_DATA = { -- will persist with game saves
	collectedPackageIDs = {}
}

local LOADED_MAP = nil

local HUDMessage_Current = ""
local HUDMessage_Last = 0

-- props
local PACKAGE_PROP = "base/quest/main_quests/prologue/q005/afterlife/entities/q005_hologram_cube.ent"
local PACKAGE_PROP_Z_BOOST = 0.25

-- inits
local activeMappins = {} -- object ids for map pins
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
local SCANNER_SOUND_TICK = 0.0

local RANDOM_ITEMS_POOL = {}

registerForEvent('onShutdown', function() -- mod reload, game shutdown etc
    GameSession.TrySave()
    reset()
end)

registerForEvent('onInit', function()
	loadSettings()

	LOADED_MAP = readMap(MOD_SETTINGS.MapPath)

	-- scan Maps folder and generate table suitable for nativeSettings
	local mapsPaths = {[1] = false}
	local nsMapsDisplayNames = {[1] = "None"}
	local nsDefaultMap = 1
	local nsCurrentMap = 1
	for k,v in pairs( listFilesInFolder(MAPS_FOLDER, ".map") ) do
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

	-- generate NativeSettings (if available)
	nativeSettings = GetMod("nativeSettings")
	if nativeSettings ~= nil then

		nativeSettings.addTab("/Hidden Packages", HiddenPackagesMetadata.title)

		-- maps

		nativeSettings.addSubcategory("/Hidden Packages/Maps", "Maps")

		nativeSettings.addSelectorString("/Hidden Packages/Maps", "Map", "Maps are stored in \'.../mods/Hidden Packages/Maps\''. If set to None the mod is disabled.", nsMapsDisplayNames, nsCurrentMap, nsDefaultMap, function(value)
			MOD_SETTINGS.MapPath = mapsPaths[value]
			saveSettings()
			NEED_TO_REFRESH = true
		end)

		-- sonar

		nativeSettings.addSubcategory("/Hidden Packages/Sonar", "Sonar")

		nativeSettings.addSwitch("/Hidden Packages/Sonar", "Sonar", "Play a sound when near a package in increasing frequency the closer you get to it", MOD_SETTINGS.SonarEnabled, false, function(state)
			MOD_SETTINGS.SonarEnabled = state
			saveSettings()
		end)

		nativeSettings.addRangeInt("/Hidden Packages/Sonar", "Range", "Sonar starts working when this close to a package", 50, 250, 25, MOD_SETTINGS.SonarRange, 125, function(value)
			MOD_SETTINGS.SonarRange = value
			saveSettings()
		end)

		-- cant be dragged by mouse?
		nativeSettings.addRangeFloat("/Hidden Packages/Sonar", "Minimum Interval", "Sonar will wait atleast this long before playing a sound again. Value is in seconds.", 0.0, 10.0, 0.5, "%.1f", MOD_SETTINGS.SonarMinimumDelay, 0.0, function(value)
 			MOD_SETTINGS.SonarMinimumDelay = value
 			saveSettings()
 		end)
		
		local sonarSoundsCurrent = 1
		local sonarSoundsDefault = 1

		nativeSettings.addSubcategory("/Hidden Packages/Scanner", "Scanner Marker")

		nativeSettings.addSwitch("/Hidden Packages/Scanner", "Scanner Marker", "Nearest package will be marked by using the scanner", MOD_SETTINGS.ScannerEnabled, false, function(state)
			MOD_SETTINGS.ScannerEnabled = state
			saveSettings()
		end)

		nativeSettings.addRangeInt("/Hidden Packages/Scanner", "Sticky Markers", "Keep up to this many packages marked. Markers will disappear after closing the scanner if set to 0.", 0, 10, 1, MOD_SETTINGS.StickyMarkers, 0, function(value)
			MOD_SETTINGS.StickyMarkers = value
			saveSettings()
		end)

 		-- rewards

		nativeSettings.addSubcategory("/Hidden Packages/Rewards", "Rewards")

		nativeSettings.addRangeInt("/Hidden Packages/Rewards", "Money", "Collecting a package rewards you this much money", 0, 5000, 100, MOD_SETTINGS.MoneyPerPackage, 1000, function(value)
			MOD_SETTINGS.MoneyPerPackage = value
			saveSettings()
		end)

		nativeSettings.addRangeInt("/Hidden Packages/Rewards", "XP", "Collecting a package rewards you this much XP", 0, 300, 10, MOD_SETTINGS.ExpPerPackage, 100, function(value)
			MOD_SETTINGS.ExpPerPackage = value
			saveSettings()
		end)

		nativeSettings.addRangeInt("/Hidden Packages/Rewards", "Street Cred", "Collecting a package rewards you this much Street Cred", 0, 300, 10, MOD_SETTINGS.StreetcredPerPackage, 100, function(value)
			MOD_SETTINGS.StreetcredPerPackage = value
			saveSettings()
		end)

		nativeSettings.addRangeFloat("/Hidden Packages/Rewards", "Reward Multiplier", "Multiply rewards (except random items) by how many packages you've collected and this.\n(eg. 1.0 means 5th package = 5x the rewards. 0.0 disables it (every package will give you 1x))", 0.0, 2.0, 0.1, "%.1f", MOD_SETTINGS.PackageMultiplier, 1.0, function(value)
 			MOD_SETTINGS.PackageMultiplier = value
 			saveSettings()
 		end)

		nativeSettings.addSubcategory("/Hidden Packages/Version", HiddenPackagesMetadata.title .. " version " .. HiddenPackagesMetadata.version .. " (" .. HiddenPackagesMetadata.date .. ")")

	end
	-- end NativeSettings

	GameSession.StoreInDir('Sessions')
	GameSession.Persist(SESSION_DATA)
	isInGame = Game.GetPlayer() and Game.GetPlayer():IsAttached() and not Game.GetSystemRequestsHandler():IsPreGame()

    GameSession.OnStart(function()
        isInGame = true
        isPaused = false
        RESET_BUTTON_PRESSED = 0
        
        if NEED_TO_REFRESH then
        	changeMap(MOD_SETTINGS.MapPath)
        	NEED_TO_REFRESH = false
        end

        checkIfPlayerNearAnyPackage() -- otherwise if you made a save near a package and just stand still it wont spawn until you move
    end)

    GameSession.OnEnd(function()
        isInGame = false
        reset()
    end)

	GameSession.OnPause(function()
		isPaused = true
	end)

	GameSession.OnResume(function()
		isPaused = false
		RESET_BUTTON_PRESSED = 0

        if NEED_TO_REFRESH then
        	changeMap(MOD_SETTINGS.MapPath)
        	NEED_TO_REFRESH = false
        end

        -- have to do this here in case user switched settings
		while LEX.tableLen(SCANNER_MARKERS) > MOD_SETTINGS.StickyMarkers do
			-- remove oldest marker (Lua starts at 1)
			unmarkPackage(SCANNER_MARKERS[1])
			table.remove(SCANNER_MARKERS, 1)
		end
	end)

	Observe('PlayerPuppet', 'OnAction', function(action)
		checkIfPlayerNearAnyPackage()
	end)

	GameUI.Listen('ScannerOpen', function()
		if not (MOD_SETTINGS.ScannerEnabled and modActive) then
			return
		end

		SCANNER_OPENED = os.clock()
		SCANNER_NEAREST_PKG = findNearestPackageWithinRange(0)
	end)

	GameUI.Listen('ScannerClose', function()
		if not MOD_SETTINGS.ScannerEnabled then
			return
		end

		SCANNER_OPENED = nil
		SCANNER_NEAREST_PKG = nil
		SCANNER_SOUND_TICK = 0.0

		if MOD_SETTINGS.StickyMarkers == 0 then
			for k,v in pairs(SCANNER_MARKERS) do
				unmarkPackage(v)
				SCANNER_MARKERS[k] = nil
			end
		end

	end)

	GameSession.TryLoad()
end)

registerForEvent('onUpdate', function(delta)
    if LOADED_MAP ~= nil and not isPaused and isInGame and modActive then

    	if MOD_SETTINGS.SonarEnabled then
    		sonar()
    	end

    	if MOD_SETTINGS.ScannerEnabled and SCANNER_OPENED then
    		scanner()
    	end
    end

end)

function spawnPackage(i)
	if activePackages[i] then -- package is already spawned
		return false
	end

	local pkg = LOADED_MAP.packages[i]
	local vec = Vector4.new(pkg.x, pkg.y, pkg.z + PACKAGE_PROP_Z_BOOST, pkg.w)
	local entity = spawnEntity(PACKAGE_PROP, vec)
	
	if entity then -- it got spawned
		activePackages[i] = entity
		return entity
	end

	return false
end

function spawnEntity(ent, vec)
    local transform = Game.GetPlayer():GetWorldTransform()
    transform:SetPosition(vec)
    transform:SetOrientation( EulerAngles.new(0,0,0):ToQuat() ) -- package angle/rotation always 0
    return WorldFunctionalTests.SpawnEntity(ent, transform, '') -- returns ID
end

function despawnPackage(i)
	if activePackages[i] then -- package is spawned
		destroyEntity(activePackages[i])
		activePackages[i] = nil
		return true
	end
    return false
end

function destroyEntity(e)
	if Game.FindEntityByID(e) ~= nil then
        Game.FindEntityByID(e):GetEntity():Destroy()
        return true
    end
    return false
end

function collectHP(packageIndex)
	local pkg = LOADED_MAP.packages[packageIndex]

	if not LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg["identifier"]) then
		table.insert(SESSION_DATA.collectedPackageIDs, pkg["identifier"])
	end
	
	unmarkPackage(packageIndex)
	despawnPackage(packageIndex)

	local collected = countCollected(LOADED_MAP.filepath)
	nativeSettings.refresh()
	
    if collected == LOADED_MAP.amount then
    	-- got all packages
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
	if money_reward	> 0 then
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

function reset()
	destroyAllPackageObjects()
	removeAllMappins()
	activePackages = {}
	activeMappins = {}
	nextCheck = 0
	return true
end

function destroyAllPackageObjects()
	if LOADED_MAP == nil then
		return
	end

	for k,v in pairs(LOADED_MAP.packages) do
		despawnPackage(k)
	end
end

function inVehicle() -- from AdaptiveGraphicsQuality (https://www.nexusmods.com/cyberpunk2077/mods/2920)
	local ws = Game.GetWorkspotSystem()
	local player = Game.GetPlayer()
	if ws and player then
		local info = ws:GetExtendedInfo(player)
		if info then
			return ws:IsActorInWorkspot(player)
				and not not Game['GetMountedVehicle;GameObject'](Game.GetPlayer())
		end
	end
end

function placeMapPin(x,y,z,w)
    local mappinData = NewObject('gamemappinsMappinData')
    mappinData.mappinType = TweakDBID.new('Mappins.DefaultStaticMappin')
    mappinData.variant = gamedataMappinVariant.CustomPositionVariant
    mappinData.visibleThroughWalls = true   

    return Game.GetMappinSystem():RegisterMappin(mappinData, Vector4.new(x, y, z, w))
end

function markPackage(i) -- i = package index
	if activeMappins[i] then
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

function unmarkPackage(i)
	if activeMappins[i] then
        Game.GetMappinSystem():UnregisterMappin(activeMappins[i])
      	activeMappins[i] = nil
        return true
    end
    return false
end	

function removeAllMappins()
	if LOADED_MAP == nil then
		return
	end
	for k,v in pairs(LOADED_MAP.packages) do
		unmarkPackage(k)
	end
end

function findNearestPackageWithinRange(range) -- 0 = any range
	if not isInGame	or LOADED_MAP == nil then
		return false
	end

	local nearest = nil
	local nearestPackage = false
	local playerPos = Game.GetPlayer():GetWorldPosition()

	for key,pkg in pairs(LOADED_MAP.packages) do
		if (LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg["identifier"]) == false) and ( ( math.abs(playerPos.x - pkg.x) <= range and math.abs(playerPos.y - pkg.y) <= range ) or range==0 ) then
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

function markNearestPackage()
	local NP = findNearestPackageWithinRange(0)
	if NP then
		removeAllMappins()
		markPackage(NP)
		HUDMessage("Nearest Package Marked (" .. string.format("%.f", distanceToPackage(NP)) .. "M away)")
		Game.GetAudioSystem():Play('ui_jingle_car_call')
		return NP
	end
	HUDMessage("No packages available")
	return false
end

function changeMap(path)
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

function checkIfPlayerNearAnyPackage()
	if (LOADED_MAP == nil) or (isPaused == true) or (isInGame == false) or (os.clock() < nextCheck) then
		-- no map is loaded/game is paused/game has not loaded/not time to check yet: return and do nothing
		return
	end

	local nextDelay = 1.0 -- default check interval
	local playerPos = Game.GetPlayer():GetWorldPosition() -- get player coordinates

	for index,pkg in pairs(LOADED_MAP.packages) do -- iterate over packages in loaded map
		if not (LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, pkg.identifier)) and (math.abs(playerPos.x - pkg.x) <= 100) and (math.abs(playerPos.y - pkg.y) <= 100) then
			-- package is not collected AND is in the neighborhood 
			if not activePackages[index] then -- package is not spawned
				spawnPackage(index)
			end

			if not inVehicle() then -- player not in vehicle = package can be collected
				-- finally calculate exact distance
				local d = Vector4.Distance(playerPos, Vector4.new(pkg.x, pkg.y, pkg.z, pkg.w))

				if (d <= 0.5) then -- player is practically at the package = collect it
					collectHP(index) 
				elseif (d <= 10) then -- player is very close to package = check frequently
					nextDelay = 0.1 
				end
			end

		elseif activePackages[index] then -- package is spawned but we're not in its neighborhood or its been collected = despawn it
			despawnPackage(index)
		end
	end

	nextCheck = os.clock() + nextDelay
end

function HUDMessage(msg)
	if os:clock() - HUDMessage_Last <= 1 then
		HUDMessage_Current = msg .. "\n" .. HUDMessage_Current
	else
		HUDMessage_Current = msg
	end

	GameHUD.ShowMessage(HUDMessage_Current)
	HUDMessage_Last = os:clock()
end

function countCollected(MapPath)
	-- cant just check length of collectedPackageIDs as it may include packages from other location files
	local map
	if MapPath ~= LOADED_MAP.filepath then
		map = readMap(MapPath)
	else
		-- no nead to read the map file again if its already loaded
		map = LOADED_MAP
	end

	local c = 0
	for k,v in pairs(map.packages) do
		if LEX.tableHasValue(SESSION_DATA.collectedPackageIDs, v["identifier"]) then
			c = c + 1
		end
	end
	return c
end

function distanceToPackage(i)
	local pkg = LOADED_MAP.packages[i]
	return Vector4.Distance(Game.GetPlayer():GetWorldPosition(), Vector4.new(pkg["x"], pkg["y"], pkg["z"], pkg["w"]))
end

function saveSettings()
	local file = io.open(SETTINGS_FILE, "w")
	local j = json.encode(MOD_SETTINGS)
	file:write(j)
	file:close()
end

function loadSettings()
	if not LEX.fileExists(SETTINGS_FILE) then
		return false
	end

	local file = io.open(SETTINGS_FILE, "r")
	local j = json.decode(file:read("*a"))
	file:close()

	MOD_SETTINGS = j

	return true
end

function listFilesInFolder(folder, ext)
	local files = {}
	for k,v in pairs(dir(folder)) do
		for a,b in pairs(v) do
			if a == "name" then
				if LEX.stringEnds(b, ext) then
					table.insert(files, b)
				end
			end
		end
	end
	return files
end

function readMap(path)
	--print("readMap", path)
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
					table.insert(components,c)
				end

				local pkg = {}
				pkg.x = tonumber(components[1])
				pkg.y = tonumber(components[2])
				pkg.z = tonumber(components[3])
				pkg.w = tonumber(components[4])
				pkg.identifier = map.identifier .. ": x=" .. tostring(pkg.x) .. " y=" .. tostring(pkg.y) .. " z=" .. tostring(pkg.z) .. " w=" .. tostring(pkg.w)
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

function sonar()
    local NP = findNearestPackageWithinRange(MOD_SETTINGS.SonarRange)
    if NP then
        SONAR_NEXT = SONAR_LAST + math.max((MOD_SETTINGS.SonarRange - (MOD_SETTINGS.SonarRange - distanceToPackage(NP))) / 35, 0.1)
    else
        return
    end

    if os.clock() < (SONAR_NEXT + MOD_SETTINGS.SonarMinimumDelay) then
        return
    end

    if GameUI.IsDefault() then  -- Only play sounds during normal gameplay
        Game.GetAudioSystem():Play(MOD_SETTINGS.SonarSound)
    end

    SONAR_LAST = os.clock()
end

function scanner()
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

