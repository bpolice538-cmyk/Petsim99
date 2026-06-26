if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- Remove executor check that might be causing issues
-- Just check if we can require
local success, Network = pcall(function()
	return require(game.ReplicatedStorage.Library.Client.Network)
end)

if not success then
	Players.LocalPlayer:Kick("Unsupported executor")
	return
end

local PlayerPet = require(game.ReplicatedStorage.Library.Client.PlayerPet)
local InstancingCmds = require(game.ReplicatedStorage.Library.Client.InstancingCmds)
local MiscItem = require(game.ReplicatedStorage.Library.Items.MiscItem)
local EggCmds = require(game.ReplicatedStorage.Library.Client.EggCmds)
local CustomEggsCmds = require(game.ReplicatedStorage.Library.Client.CustomEggsCmds)
local Signal = require(game.ReplicatedStorage.Library.Signal)

local localPlayer = Players.LocalPlayer
local enterPosition = nil
local isInMiniChestRoom = false
local currentMiniChestRoomUID = nil
local isOnRoof = false
local miniChestIndex = 1

-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false
_G.IsTeleportingToSpawn = false
_G.IsScanningMode = false -- Flag to indicate scanning mode

-- ============================================
-- SCAN HEIGHT OFFSET SYSTEM
-- ============================================
local SCAN_HEIGHT_OFFSET = 100 -- Height above rooms during scan
local NORMAL_HEIGHT_OFFSET = 2 -- Normal height when not scanning

-- ============================================
-- HALLWAY NAVIGATION SYSTEM
-- ============================================
local hallwayWaypoints = {}
local currentHallwayIndex = 1

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

-- ============================================
-- ENHANCED HALLWAY POSITION FINDER
-- ============================================
local function findHallwayPosition(roomModel)
	local hallwayPos = nil
	local doorFrontPos = nil
	
	-- Look for locked doors first
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if lockedDoors then
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock and lock.Transparency < 1 then
				-- Get the door position
				local doorCFrame = child.CFrame
				local doorPosition = child.Position
				
				-- The door's LookVector points to the FRONT of the door
				local doorFront = doorCFrame.LookVector
				
				-- Calculate position in front of the door (hallway side)
				doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				hallwayPos = doorFrontPos
				print("🚪 Found locked door at: " .. tostring(doorPosition))
				print("🚪 Door front direction: " .. tostring(doorFront))
				print("🚪 Hallway position (front of door): " .. tostring(hallwayPos))
				break
			end
		end
	end
	
	-- If no locked doors, look for regular doors
	if not hallwayPos then
		local doors = roomModel:FindFirstChild("Doors")
		if doors then
			for _, door in ipairs(doors:GetChildren()) do
				if door:IsA("BasePart") then
					local doorCFrame = door.CFrame
					local doorPosition = door.Position
					local doorFront = doorCFrame.LookVector
					doorFrontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
					hallwayPos = doorFrontPos
					break
				end
			end
		end
	end
	
	-- Check for HallwayParts
	if not hallwayPos then
		local hallwayParts = roomModel:FindFirstChild("HallwayParts")
		if hallwayParts then
			for _, part in ipairs(hallwayParts:GetChildren()) do
				if part:IsA("BasePart") then
					hallwayPos = part.Position + Vector3.new(0, 2, 0)
					break
				end
			end
		end
	end
	
	-- If still no position, use room center with offset
	if not hallwayPos then
		local centerCFrame = roomModel:GetBoundingBox()
		hallwayPos = centerCFrame.Position + Vector3.new(0, 2, 0)
		print("⚠️ No door found, using room center as hallway position")
	end
	
	return hallwayPos, doorFrontPos
end

-- ============================================
-- ENHANCED HALLWAY WALKING SYSTEM
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	print("🚶 Starting hallway walk from: " .. tostring(startPos))
	print("🚶 Target: " .. tostring(targetPos))
	
	-- Generate waypoints along the path
	local direction = (targetPos - startPos).Unit
	local distance = (targetPos - startPos).Magnitude
	
	-- If distance is small, just move directly
	if distance < 15 then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
		print("✅ Short distance - direct move")
		return true
	end
	
	-- Create waypoints every 5 studs
	local waypoints = {}
	local numWaypoints = math.ceil(distance / 5)
	
	for i = 1, numWaypoints do
		local t = i / numWaypoints
		local waypoint = startPos + (direction * (distance * t))
		-- Keep the Y position consistent to avoid falling
		waypoint = Vector3.new(waypoint.X, startPos.Y + 1, waypoint.Z)
		table.insert(waypoints, waypoint)
	end
	
	-- Add final target
	table.insert(waypoints, targetPos)
	
	print("🚶 Walking through hallway with " .. #waypoints .. " waypoints...")
	
	-- Walk through each waypoint
	local currentWaypoint = 1
	local timeout = 45
	local startTime = tick()
	local stuckCount = 0
	local lastPos = rootPart.Position
	local waypointReached = false
	
	while currentWaypoint <= #waypoints and tick() - startTime < timeout do
		local targetWaypoint = waypoints[currentWaypoint]
		
		-- Move to current waypoint
		humanoid:MoveTo(targetWaypoint)
		
		-- Wait until we reach the waypoint or get stuck
		local waypointTimeout = 4
		local waypointStart = tick()
		
		while tick() - waypointStart < waypointTimeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distToWaypoint = (currentPos - targetWaypoint).Magnitude
			
			-- Check if we reached the waypoint
			if distToWaypoint < 3 then
				waypointReached = true
				print("✅ Reached waypoint " .. currentWaypoint .. "/" .. #waypoints)
				break
			end
			
			-- Check if stuck
			if (currentPos - lastPos).Magnitude < 0.3 then
				stuckCount = stuckCount + 1
				if stuckCount > 15 then -- 1.5 seconds stuck
					print("⚠️ Stuck at waypoint " .. currentWaypoint .. ", teleporting to next...")
					-- Teleport to next waypoint
					rootPart.Anchored = true
					rootPart.CFrame = CFrame.new(targetWaypoint)
					task.wait(0.2)
					rootPart.Anchored = false
					waypointReached = true
					break
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
		end
		
		currentWaypoint = currentWaypoint + 1
	end
	
	-- Final check: make sure we're at the target
	local finalDist = (rootPart.Position - targetPos).Magnitude
	if finalDist > 5 then
		print("⚠️ Didn't reach target! Teleporting directly...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
		return true
	end
	
	print("✅ Successfully walked through hallway!")
	return true
end

-- ============================================
-- TP TO SPAWN
-- ============================================
local function TPtoSpawn()
	if _G.IsTeleportingToSpawn then
		print("⚠️ Already teleporting to spawn!")
		return
	end
	
	_G.IsTeleportingToSpawn = true
	_G.Teleporting = true
	
	local character = getCharacter()
	if not character then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local heightOffset = _G.IsScanningMode and SCAN_HEIGHT_OFFSET or NORMAL_HEIGHT_OFFSET
	local pos = enterPosition + Vector3.new(0, heightOffset, 0)
	print("🏠 Teleporting to spawn position: " .. tostring(pos))

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
	
	task.wait(0.5)
	_G.IsTeleportingToSpawn = false
	_G.Teleporting = false
	print("✅ Successfully teleported to spawn!")
end

-- ============================================
-- VOID PROTECTION
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if rootPart.Position.Y < -50 then
			print("⚠️ Detected falling into void! Teleporting to spawn...")
			if enterPosition then
				TPtoSpawn()
			else
				local folder = getGeneratedBackrooms()
				if folder then
					local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
					if spawnRoom then
						local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
						if spawnLocation then
							enterPosition = spawnLocation.Position
							TPtoSpawn()
						end
					end
				end
			end
		end
		
		if rootPart.Position.Y < 0 and rootPart.Position.Y > -50 and enterPosition then
			print("⚠️ Character below map! Teleporting to spawn...")
			TPtoSpawn()
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - IMPROVED
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return false
	end

	local character = getCharacter()
	if not character then
		return false
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return false
	end

	-- Find the lock part and door part
	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		print("⚠️ Room already unlocked or no lock found!")
		return true
	end

	-- Get door position and CFrame
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	
	-- The door's LookVector points to the FRONT of the door
	local doorFront = doorCFrame.LookVector
	
	-- Calculate positions
	local frontOffset = doorFront * 8 -- Stand further back for better visibility
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Door Front Direction: " .. tostring(doorFront))
	print("🚪 Teleporting to HALLWAY in front of door at: " .. tostring(teleportPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		-- Teleport to hallway position (in front of door)
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.5)
		rootPart.Anchored = false
	end
	
	print("🔓 Walking to door to unlock...")
	
	-- Walk to the door front
	if humanoid then
		humanoid:MoveTo(doorFrontPos)
		task.wait(1)
	end
	
	-- Try to unlock the door
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	
	task.wait(1)
	
	-- Check if door is unlocked
	local isUnlocked = true
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			isUnlocked = false
			break
		end
	end
	
	if not isUnlocked then
		print("⚠️ Door unlock failed! Trying again...")
		activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
		task.wait(1)
	end
	
	-- Get the target position
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking through door to target position: " .. tostring(targetPos))
	
	-- Walk through to the target
	if humanoid then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
	end
	
	-- Walk through hallway from door to target
	WalkThroughHallway(doorFrontPos, targetPos)
	
	print("✅ Room unlocked and target reached successfully!")
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

-- ============================================
-- FAST EGG HATCHING - 0.01 MILLISECOND (INSTANT)
-- ============================================
local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs in batches of " .. batchSize .. "!")
		else
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				local isMatch = (not targetMult) or room.EggMultiplier >= targetMult

				if isMatch and room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT TO ANOMALY
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("✨ Teleported to Anomaly (250x Egg)!")
	return true
end

-- ============================================
-- TELEPORT TO MINI CHEST
-- ============================================
local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode for farming

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	-- Use normal height offset (not 100 studs above)
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + NORMAL_HEIGHT_OFFSET,
		roomCenter.Z
	)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", centerPos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(centerPos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
	
	local actionText = actionType or "Unknown"
	local indexText = roomIndex and (" #" .. roomIndex .. "/" .. #_G.AllMiniChestRooms) or ""
	print("📦 Teleported to CENTER of Mini Chest Room" .. indexText .. " (" .. actionText .. " action)!")
end

-- ============================================
-- ENHANCED TELEPORT TO ROOM - WITH HALLWAY NAVIGATION
-- ============================================
local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode for farming

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	-- Get the target position (egg or boss location)
	local targetPos = nil
	
	-- Find egg if it's an egg room
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- Find boss if it's a boss room
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- If no specific target, use room center
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- Get the hallway position (front of door)
	local hallwayPos, doorFrontPos = findHallwayPosition(roomModel)
	
	-- Check if locked room
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		-- Check if room is already unlocked
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			print("🔒 Room is locked! Teleporting to HALLWAY in front of door...")
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				print("⚠️ Failed to unlock room! Teleporting to spawn...")
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			print("✅ Room unlocked and walked to target!")
			return
		else
			print("✅ Room is already unlocked!")
		end
	end

	-- For unlocked rooms or regular rooms, teleport to hallway
	if hallwayPos then
		print("🚪 Teleporting to HALLWAY position: " .. tostring(hallwayPos))
		
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		Network.Fire("RequestStreaming", hallwayPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(hallwayPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		
		-- Walk through hallway to target
		print("🚶 Walking through hallway to target: " .. tostring(targetPos))
		local success = WalkThroughHallway(hallwayPos, targetPos)
		
		if not success then
			print("⚠️ Hallway walk failed! Teleporting directly to target...")
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(targetPos)
			task.wait(0.3)
			rootPart.Anchored = false
		end
	else
		-- No hallway found, teleport directly
		print("⚠️ No hallway found! Teleporting directly to target...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	_G.Teleporting = false
	print("✅ Arrived at target!")
end

-- ============================================
-- GET NEXT MINI CHEST ROOM
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

-- ============================================
-- GET NEAREST MINI CHEST ROOM
-- ============================================
local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - MAX 400 ROOMS - WITH 100 STUD HEIGHT OFFSET
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true
	_G.IsScanningMode = true -- Enable scanning mode (100 studs above)

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan (100 studs above)...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning... (100 studs above)")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			warn("WAITING FOR BACKROOMS...")
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
			warn("SAVED SPAWN POSITION", enterPosition)
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.MiniChestActionType = "Cycle"
	
	local totalScanned = 0
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		local miniChestCount = 0
		local bossCount = 0
		local eggCount = 0
		local lockedEggCount = 0

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local hallwayPos, doorFrontPos = findHallwayPosition(room)
						
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil,
							HallwayPos = hallwayPos,
							DoorFrontPos = doorFrontPos
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						totalScanned = totalScanned + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms (100 studs above)")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							bossCount = bossCount + 1
							print("🏠 Found Boss Room #" .. bossCount)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							miniChestCount = miniChestCount + 1
							print("📦 Found Mini Chest Room #" .. miniChestCount .. " (ID: " .. roomId .. ")")
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
							eggCount = eggCount + 1
							print("🥚 Found Free Egg Room #" .. eggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							lockedEggCount = lockedEggCount + 1
							print("🔒 Found Locked Egg Room #" .. lockedEggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepCoinRoom") ~= nil then
							print("💰 Found Coin Room: " .. roomId)
						end
					end
				end
			end
		end
		
		if miniChestCount > 0 then
			print("📦 Total Mini Chest Rooms found: " .. miniChestCount)
		end
		if bossCount > 0 then
			print("👑 Total Boss Rooms found: " .. bossCount)
		end
		if eggCount > 0 then
			print("🥚 Total Free Egg Rooms found: " .. eggCount)
		end
		if lockedEggCount > 0 then
			print("🔒 Total Locked Egg Rooms found: " .. lockedEggCount)
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
				print("No unvisited rooms, exploring random room")
			else
				warn("No rooms found at all!")
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
				
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Use hallway position if available, with 100 stud height offset
						local teleportPos = room.HallwayPos or (room.Position + Vector3.new(0, SCAN_HEIGHT_OFFSET, 0))
						-- Add height offset for scanning
						teleportPos = teleportPos + Vector3.new(0, SCAN_HEIGHT_OFFSET, 0)
						Network.Fire("RequestStreaming", teleportPos)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(teleportPos)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
				
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
				
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
				print("📦 Mini Chest Rooms total: " .. #_G.AllMiniChestRooms)
				print("👑 Boss Rooms total: " .. #_G.AllBossRooms)
			end
				
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	_G.IsScanningMode = false -- Exit scanning mode after scan
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE FOR BOSS
-- ============================================
local directionArrow = nil
local directionLine = nil
local directionText = nil
local arrowFolder = nil

local function CreateDirectionGuide()
	if arrowFolder then
		arrowFolder:Destroy()
		arrowFolder = nil
	end
	
	arrowFolder = Instance.new("Folder")
	arrowFolder.Name = "DirectionGuide"
	arrowFolder.Parent = workspace.CurrentCamera
	
	directionArrow = Instance.new("Part")
	directionArrow.Name = "Arrow"
	directionArrow.Size = Vector3.new(2, 6, 2)
	directionArrow.Shape = Enum.PartType.Cylinder
	directionArrow.Anchored = true
	directionArrow.CanCollide = false
	directionArrow.Transparency = 0.3
	directionArrow.Material = Enum.Material.Neon
	directionArrow.Color = Color3.fromRGB(255, 50, 50)
	directionArrow.Parent = arrowFolder
	
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(4, 2, 4)
	tip.Shape = Enum.PartType.Cylinder
	tip.Anchored = true
	tip.CanCollide = false
	tip.Transparency = 0.2
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 100, 100)
	tip.Parent = arrowFolder
	
	directionLine = Instance.new("Part")
	directionLine.Name = "Line"
	directionLine.Size = Vector3.new(0.5, 1, 0.5)
	directionLine.Anchored = true
	directionLine.CanCollide = false
	directionLine.Transparency = 0.4
	directionLine.Material = Enum.Material.Neon
	directionLine.Color = Color3.fromRGB(255, 200, 50)
	directionLine.Parent = arrowFolder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DistanceLabel"
	billboard.Adornee = directionArrow
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = arrowFolder
	
	directionText = Instance.new("TextLabel")
	directionText.Size = UDim2.new(1, 0, 1, 0)
	directionText.BackgroundTransparency = 1
	directionText.Text = "👑 BOSS: 0 studs"
	directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
	directionText.TextSize = 16
	directionText.Font = Enum.Font.GothamBold
	directionText.TextStrokeTransparency = 0.3
	directionText.Parent = billboard
	
	task.spawn(function()
		while arrowFolder and arrowFolder.Parent do
			task.wait(0.05)
			if directionArrow then
				local pulse = 0.3 + math.sin(tick() * 3) * 0.15
				directionArrow.Transparency = pulse
				if directionLine then
					directionLine.Transparency = pulse + 0.1
				end
			end
		end
	end)
	
	return arrowFolder
end

local function UpdateDirectionGuide()
	if not _G.ShowDirectionGuide then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if #_G.AllBossRooms == 0 then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if not arrowFolder then
		CreateDirectionGuide()
	end
	
	local character = getCharacter()
	if not character then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local nearestBoss = nil
	local minDist = math.huge
	for _, boss in ipairs(_G.AllBossRooms) do
		local dist = (boss.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearestBoss = boss
		end
	end
	
	if not nearestBoss then
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return
	end
	
	local bossPos = nearestBoss.Position
	local playerPos = rootPart.Position
	local direction = (bossPos - playerPos).Unit
	
	local arrowPos = playerPos + Vector3.new(0, 8, 0)
	local distance = (bossPos - playerPos).Magnitude
	
	if directionArrow and directionArrow.Parent then
		directionArrow.Position = arrowPos
		directionArrow.CFrame = CFrame.lookAt(arrowPos, arrowPos + direction)
		
		local tip = arrowFolder:FindFirstChild("Tip")
		if tip then
			tip.Position = arrowPos + direction * 4
			tip.CFrame = CFrame.lookAt(tip.Position, tip.Position + direction)
		end
		
		if directionLine then
			local midPoint = (playerPos + bossPos) / 2
			local lineLength = distance
			directionLine.Size = Vector3.new(0.5, lineLength, 0.5)
			directionLine.Position = midPoint
			directionLine.CFrame = CFrame.lookAt(midPoint, bossPos)
		end
		
		if directionText then
			local distText = string.format("👑 BOSS: %.0f studs", distance)
			if distance < 50 then
				distText = "👑 BOSS: 🔥 CLOSE! " .. math.floor(distance) .. " studs"
			elseif distance < 100 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs ⬅️"
			elseif distance < 200 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🏃"
			else
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🚀"
			end
			directionText.Text = distText
			
			if distance < 50 then
				directionText.TextColor3 = Color3.fromRGB(255, 50, 50)
			elseif distance < 100 then
				directionText.TextColor3 = Color3.fromRGB(255, 150, 50)
			else
				directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
			end
		end
	end
	
	local angle = math.deg(math.atan2(direction.X, direction.Z))
	local compass = ""
	if angle > -22.5 and angle <= 22.5 then compass = "⬆️ North"
	elseif angle > 22.5 and angle <= 67.5 then compass = "↗️ Northeast"
	elseif angle > 67.5 and angle <= 112.5 then compass = "➡️ East"
	elseif angle > 112.5 and angle <= 157.5 then compass = "↘️ Southeast"
	elseif angle > 157.5 or angle <= -157.5 then compass = "⬇️ South"
	elseif angle > -157.5 and angle <= -112.5 then compass = "↙️ Southwest"
	elseif angle > -112.5 and angle <= -67.5 then compass = "⬅️ West"
	elseif angle > -67.5 and angle <= -22.5 then compass = "↖️ Northwest"
	end
	
	if not UpdateDirectionGuide.lastPrint or tick() - UpdateDirectionGuide.lastPrint > 5 then
		UpdateDirectionGuide.lastPrint = tick()
		print("🎯 BOSS Direction: " .. compass .. " | Distance: " .. math.floor(distance) .. " studs")
	end
end

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			print("✨ Auto teleporting to Anomaly (250x Egg)!")
			_G.IsScanningMode = false -- Exit scanning mode
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP - FAST HATCH SUPPORT (0.01ms delay)
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
				print("🔄 Cycle complete! Starting next cycle with Next Mini...")
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				print("📦 [Phase 1/2] Teleporting to NEXT Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Next")
				end
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				print("📦 [Phase 2/2] Teleporting to NEAREST Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Nearest")
				end
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				else
					print("⏱️ Waiting " .. _G.MiniChestCooldown .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- Direction Guide Update Loop
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- ORIGINAL ANTI AFK METHOD
-- ============================================
localPlayer.Idled:Connect(function()
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI - WITH MINIMIZE AND RED DOT CLICKER
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	-- MINIMIZE BUTTON
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "🗕"
	retractButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	retractButton.TextSize = 12
	retractButton.Font = Enum.Font.GothamBold
	retractButton.ZIndex = 11
	retractButton.Parent = titleBar
	
	local isRetracted = false
	
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 22, 0, 20)
	closeButton.Position = UDim2.new(1, -26, 0, 3)
	closeButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 1
	closeButton.BorderColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.Text = "✕"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
		print("❌ UI Closed")
	end)
	
	closeButton.MouseEnter:Connect(function()
		closeButton.BackgroundTransparency = 0
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.BackgroundTransparency = 0.2
	end)
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		
		button.MouseButton1Click:Connect(callback)
		
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.fromRGB(70, 70, 120)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 0.2
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		end)
		
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	-- Status label
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	-- Room count label
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	-- Buttons
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Free Egg Room found!") end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Locked Egg Room found!") end
	end)
	createButton("✨ TP Anomaly (250x)", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then 
			print("No Boss Room found! Scan first!")
			return 
		end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			print("🚪 Teleporting to Boss Room: " .. nearestBoss.Id)
			TeleportToRoom(nearestBoss.uid)
		else
			print("❌ No Boss Room found near you!")
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
		print("Cleared all scanned rooms")
	end)
	
	-- Toggles
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
		print("Auto Boss: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		print("Auto Hatch: " .. (value and "ON" or "OFF"))
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
		print("Fast Hatch: " .. (value and "ON" or "OFF"))
		if value then
			print("⚡ Fast Hatch: 0.01ms delay (INSTANT!)")
		end
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
		print("Auto Best Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
		print("Auto Locked Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
		print("Auto Anomaly: " .. (value and "ON" or "OFF"))
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
			print("Auto Mini: ON")
		else
			print("Auto Mini: OFF")
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
		print("Infinite Pet Speed: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🚫 No Hatch Anim", function(value)
		if (not canDoAction()) then return end
		
		if workspace.CurrentCamera:FindFirstChild("Eggs") or workspace.CurrentCamera:FindFirstChild("Pets") then
			print("⚠️ Cannot disable hatch animation - Eggs or Pets found in camera")
			return
		end
		
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		if not scripts then
			print("⚠️ PlayerScripts not found")
			return
		end
		
		local scriptInstance = nil
		for _, descendant in ipairs(scripts:GetDescendants()) do
			if descendant.Name == "Egg Opening Frontend" then
				scriptInstance = descendant
				break
			end
		end
		
		if not scriptInstance then
			print("⚠️ Egg Opening Frontend script not found")
			return
		end
		
		scriptInstance.Enabled = (not value)
		_G.DisableHatchAnimation = value
		print("No Hatch Anim: " .. (value and "ON (Disabled hatch animation)" or "OFF (Enabled hatch animation)"))
	end)
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- Clicker section
	createButton("🖱️ Set Clicker Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			print("📍 Click position set to center of screen")
		end
	end)
	
	createToggle("🖱️ Auto Clicker", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	-- RETRACT/MINIMIZE FUNCTIONALITY
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "🎮"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 200, 0, 150)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
			title.Text = "🎮 BR UI"
		end
	end)
	
	-- DRAGGING FUNCTIONALITY
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	
	-- ============================================
	-- RED DOT CLICKER
	-- ============================================
	local screenSize = workspace.CurrentCamera.ViewportSize
	local dotSize = 20
	local dotX = screenSize.X / 2 - dotSize / 2
	local dotY = screenSize.Y / 2 + 50 - dotSize / 2
	
	local redDot = Instance.new("Frame")
	redDot.Name = "RedDot"
	redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
	redDot.Position = UDim2.new(0, dotX, 0, dotY)
	redDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	redDot.BackgroundTransparency = 0.3
	redDot.BorderSizePixel = 1.5
	redDot.BorderColor3 = Color3.fromRGB(255, 0, 0)
	redDot.ZIndex = 999999
	redDot.Parent = screenGui
	
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = redDot
	
	local dotGlow = Instance.new("Frame")
	dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
	dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
	dotGlow.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	dotGlow.BackgroundTransparency = 0.1
	dotGlow.BorderSizePixel = 1
	dotGlow.BorderColor3 = Color3.fromRGB(255, 100, 100)
	dotGlow.ZIndex = 999998
	dotGlow.Parent = redDot
	
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = dotGlow
	
	local dotCenter = Instance.new("Frame")
	dotCenter.Size = UDim2.new(0, 4, 0, 4)
	dotCenter.Position = UDim2.new(0.5, -2, 0.5, -2)
	dotCenter.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.BackgroundTransparency = 0.3
	dotCenter.BorderSizePixel = 1
	dotCenter.BorderColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.ZIndex = 1000000
	dotCenter.Parent = redDot
	
	local dotCenterCorner = Instance.new("UICorner")
	dotCenterCorner.CornerRadius = UDim.new(1, 0)
	dotCenterCorner.Parent = dotCenter
	
	_G.AutoClickerX = dotX + dotSize / 2
	_G.AutoClickerY = dotY + dotSize / 2
	
	local dotDragging = false
	local dotDragStart, dotStartPos
	
	redDot.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dotDragging then
				dotDragging = false
				redDot.BackgroundTransparency = 0.3
			end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseMovement then
			if dotDragging then
				local delta = input.Position - dotDragStart
				local newX = dotStartPos.X.Offset + delta.X
				local newY = dotStartPos.Y.Offset + delta.Y
				local screenSize = workspace.CurrentCamera.ViewportSize
				newX = math.max(0, math.min(newX, screenSize.X - dotSize))
				newY = math.max(0, math.min(newY, screenSize.Y - dotSize))
				redDot.Position = UDim2.new(0, newX, 0, newY)
				_G.AutoClickerX = newX + dotSize / 2
				_G.AutoClickerY = newY + dotSize / 2
			end
		end
	end)
	
	dotGlow.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	redDot.MouseEnter:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.15
			redDot.Size = UDim2.new(0, dotSize + 4, 0, dotSize + 4)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - (dotSize + 4)/2, 0, _G.AutoClickerY - (dotSize + 4)/2)
			dotGlow.Size = UDim2.new(0, dotSize + 10, 0, dotSize + 10)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 10)/2, 0.5, -(dotSize + 10)/2)
		end
	end)
	
	redDot.MouseLeave:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.3
			redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - dotSize/2, 0, _G.AutoClickerY - dotSize/2)
			dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
		end
	end)
	
	return screenGui
end

-- ============================================
-- CREATE UI
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED")
print("   • Teleports 100 studs ABOVE rooms during scan")
print("   • Returns to normal height for farming")
print("   • Completely invisible to other players")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("⚡ Infinite Pet Speed: OFF")
print("🚫 No Hatch Animation: OFF")
print("⚡ Fast Hatch: OFF - 0.01ms delay (INSTANT!)")
print("🖱️ Red Dot Clicker: Drag to position")
print("🗕 Click minimize button to retract UI")
print("=========================================")
print("🚪 HALLWAY NAVIGATION SYSTEM:")
print("   • Finds door position and front direction")
print("   • Teleports to HALLWAY in front of door")
print("   • Walks to door, unlocks with key")
print("   • Walks through to target entity")
print("   • Auto-recovery if stuck")
print("=========================================")
print("🛡️ VOID PROTECTION:")
print("   • Detects falling into void")
print("   • Automatically teleports to spawn")
print("=========================================")

-- Start automatic scan after UI loads
task.wait(2)
Scan()-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false
_G.IsTeleportingToSpawn = false
_G.IsScanningMode = false -- Flag to indicate scanning mode

-- ============================================
-- SCAN HEIGHT OFFSET SYSTEM (UNDERGROUND)
-- ============================================
local SCAN_HEIGHT_OFFSET = -100 -- 100 studs UNDERGROUND during scan
local NORMAL_HEIGHT_OFFSET = 2 -- Normal height when not scanning
local SCAN_IS_ACTIVE = false -- Track if scan is currently running

-- ============================================
-- HALLWAY NAVIGATION SYSTEM
-- ============================================
local hallwayWaypoints = {}
local currentHallwayIndex = 1

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	local character = localPlayer.Character
	if not character then
		character = localPlayer.CharacterAdded:Wait()
	end
	return character
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

-- ============================================
-- ENHANCED HALLWAY POSITION FINDER
-- ============================================
local function findHallwayPosition(roomModel)
	local hallwayPos = nil
	local doorFrontPos = nil
	
	-- Look for locked doors first
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if lockedDoors then
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock and lock.Transparency < 1 then
				-- Get the door position
				local doorCFrame = child.CFrame
				local doorPosition = child.Position
				
				-- The door's LookVector points to the FRONT of the door
				local doorFront = doorCFrame.LookVector
				
				-- Calculate position in front of the door (hallway side)
				doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				hallwayPos = doorFrontPos
				break
			end
		end
	end
	
	-- If no locked doors, look for regular doors
	if not hallwayPos then
		local doors = roomModel:FindFirstChild("Doors")
		if doors then
			for _, door in ipairs(doors:GetChildren()) do
				if door:IsA("BasePart") then
					local doorCFrame = door.CFrame
					local doorPosition = door.Position
					local doorFront = doorCFrame.LookVector
					doorFrontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
					hallwayPos = doorFrontPos
					break
				end
			end
		end
	end
	
	-- Check for HallwayParts
	if not hallwayPos then
		local hallwayParts = roomModel:FindFirstChild("HallwayParts")
		if hallwayParts then
			for _, part in ipairs(hallwayParts:GetChildren()) do
				if part:IsA("BasePart") then
					hallwayPos = part.Position + Vector3.new(0, 2, 0)
					break
				end
			end
		end
	end
	
	-- If still no position, use room center with offset
	if not hallwayPos then
		local centerCFrame = roomModel:GetBoundingBox()
		hallwayPos = centerCFrame.Position + Vector3.new(0, 2, 0)
	end
	
	return hallwayPos, doorFrontPos
end

-- ============================================
-- ENHANCED HALLWAY WALKING SYSTEM
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	-- Generate waypoints along the path
	local direction = (targetPos - startPos).Unit
	local distance = (targetPos - startPos).Magnitude
	
	-- If distance is small, just move directly
	if distance < 15 then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
		return true
	end
	
	-- Create waypoints every 5 studs
	local waypoints = {}
	local numWaypoints = math.ceil(distance / 5)
	
	for i = 1, numWaypoints do
		local t = i / numWaypoints
		local waypoint = startPos + (direction * (distance * t))
		waypoint = Vector3.new(waypoint.X, startPos.Y + 1, waypoint.Z)
		table.insert(waypoints, waypoint)
	end
	
	table.insert(waypoints, targetPos)
	
	-- Walk through each waypoint
	local currentWaypoint = 1
	local timeout = 45
	local startTime = tick()
	local stuckCount = 0
	local lastPos = rootPart.Position
	
	while currentWaypoint <= #waypoints and tick() - startTime < timeout do
		local targetWaypoint = waypoints[currentWaypoint]
		humanoid:MoveTo(targetWaypoint)
		
		local waypointTimeout = 4
		local waypointStart = tick()
		
		while tick() - waypointStart < waypointTimeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distToWaypoint = (currentPos - targetWaypoint).Magnitude
			
			if distToWaypoint < 3 then
				break
			end
			
			if (currentPos - lastPos).Magnitude < 0.3 then
				stuckCount = stuckCount + 1
				if stuckCount > 15 then
					rootPart.Anchored = true
					rootPart.CFrame = CFrame.new(targetWaypoint)
					task.wait(0.2)
					rootPart.Anchored = false
					break
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
		end
		
		currentWaypoint = currentWaypoint + 1
	end
	
	-- Final check
	local finalDist = (rootPart.Position - targetPos).Magnitude
	if finalDist > 5 then
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	return true
end

-- ============================================
-- TP TO SPAWN
-- ============================================
local function TPtoSpawn()
	if _G.IsTeleportingToSpawn then
		return
	end
	
	_G.IsTeleportingToSpawn = true
	_G.Teleporting = true
	
	local character = getCharacter()
	if not character then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local heightOffset = (_G.IsScanningMode and SCAN_HEIGHT_OFFSET) or NORMAL_HEIGHT_OFFSET
	local pos = enterPosition + Vector3.new(0, heightOffset, 0)

	pcall(function()
		Network.Fire("RequestStreaming", pos)
	end)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
	
	task.wait(0.5)
	_G.IsTeleportingToSpawn = false
	_G.Teleporting = false
end

-- ============================================
-- VOID PROTECTION - FIXED
-- ============================================
task.spawn(function()
	while game:IsLoaded() do
		task.wait(0.5)
		
		-- Skip void protection if scanning mode is active
		if not (_G.IsScanningMode or SCAN_IS_ACTIVE) then
			local character = getCharacter()
			if character then
				local rootPart = character:FindFirstChild("HumanoidRootPart")
				if rootPart and rootPart.Position.Y < -50 then
					print("⚠️ Detected falling into void! Teleporting to spawn...")
					if enterPosition then
						pcall(TPtoSpawn)
					else
						local folder = getGeneratedBackrooms()
						if folder then
							local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
							if spawnRoom then
								local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
								if spawnLocation then
									enterPosition = spawnLocation.Position
									pcall(TPtoSpawn)
								end
							end
						end
					end
				end
			end
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - IMPROVED
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return false
	end

	local character = getCharacter()
	if not character then
		return false
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		return false
	end

	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		return true
	end

	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	local doorFront = doorCFrame.LookVector
	
	local frontOffset = doorFront * 8
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		pcall(function()
			Network.Fire("RequestStreaming", teleportPos)
		end)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.5)
		rootPart.Anchored = false
	end
	
	if humanoid then
		humanoid:MoveTo(doorFrontPos)
		task.wait(1)
	end
	
	pcall(function()
		activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	end)
	task.wait(1)
	
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	
	if humanoid then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
	end
	
	WalkThroughHallway(doorFrontPos, targetPos)
	
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs!")
		else
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				if room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT FUNCTIONS
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true
	_G.IsScanningMode = false

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	pcall(function()
		Network.Fire("RequestStreaming", pos)
	end)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	return true
end

local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + NORMAL_HEIGHT_OFFSET,
		roomCenter.Z
	)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	pcall(function()
		Network.Fire("RequestStreaming", centerPos)
	end)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(centerPos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
end

local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	local targetPos = nil
	
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	local hallwayPos, doorFrontPos = findHallwayPosition(roomModel)
	
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			return
		end
	end

	if hallwayPos then
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		pcall(function()
			Network.Fire("RequestStreaming", hallwayPos)
		end)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(hallwayPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		WalkThroughHallway(hallwayPos, targetPos)
	else
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	_G.Teleporting = false
end

-- ============================================
-- GET ROOM FUNCTIONS
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - UNDERGROUND SCANNING
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true
	_G.IsScanningMode = true
	SCAN_IS_ACTIVE = true

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan (100 studs UNDERGROUND)...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning... (underground)")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		local retries = 0
		while retries < 10 and not folder do
			folder = getGeneratedBackrooms()
			task.wait(0.5)
			retries = retries + 1
		end
		if not folder or #folder:GetChildren() == 0 then
			print("Failed to find GeneratedBackrooms!")
			_G.IsScanning = false
			_G.IsScanningMode = false
			SCAN_IS_ACTIVE = false
			return
		end
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local hallwayPos, doorFrontPos = findHallwayPosition(room)
						
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil,
							HallwayPos = hallwayPos,
							DoorFrontPos = doorFrontPos
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms (underground)")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
						end
					end
				end
			end
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	local noProgressCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			noProgressCount = noProgressCount + 1
			if noProgressCount > 50 then
				print("Too much teleporting, breaking scan")
				break
			end
			continue
		end
		
		noProgressCount = 0

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
			else
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
				
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Teleport UNDERGROUND for scanning
						local teleportPos = Vector3.new(room.Position.X, SCAN_HEIGHT_OFFSET, room.Position.Z)
						pcall(function()
							Network.Fire("RequestStreaming", teleportPos)
						end)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(teleportPos)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
				
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
				
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
			end
				
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	_G.IsScanningMode = false
	SCAN_IS_ACTIVE = false
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while game:IsLoaded() do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while game:IsLoaded() do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					pcall(function()
						Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					end)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while game:IsLoaded() do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			_G.IsScanningMode = false
			_G.Teleporting = true
			pcall(function()
				Network.Fire("RequestStreaming", pos)
			end)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP
-- ============================================
task.spawn(function()
	while game:IsLoaded() do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while game:IsLoaded() do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while game:IsLoaded() do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while game:IsLoaded() do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- ANTI AFK
-- ============================================
localPlayer.Idled:Connect(function()
	Signal.Fire("ResetIdleTimer")
	pcall(function()
		VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	end)
	task.wait(1)
	pcall(function()
		VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	end)
end)

task.spawn(function()
	while game:IsLoaded() do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI (SHORTENED VERSION)
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		button.MouseButton1Click:Connect(callback)
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) end
	end)
	createButton("✨ TP Anomaly", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then return end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			TeleportToRoom(nearestBoss.uid)
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	end)
	
	createToggle("🤖 Auto Boss", function(value) _G.AutoMiniBoss = value end)
	createToggle("🥚 Auto Hatch", function(value) _G.AutoHatch = value end)
	createToggle("⚡ Fast Hatch", function(value) _G.FastHatch = value end)
	createToggle("🥚 Auto Best Egg", function(value) _G.AutoTPBestEgg = value end)
	createToggle("🔒 Auto Locked Egg", function(value) _G.AutoTPLockedEgg = value end)
	createToggle("✨ Auto Anomaly", function(value) _G.AutoTPAnomaly = value end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
		end
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	return screenGui
end

-- ============================================
-- START SCRIPT
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 SCAN MODE: 100 studs UNDERGROUND")
print("   • Completely invisible to other players")
print("   • Auto-switches to normal height for farming")
print("=========================================")

task.wait(2)
pcall(Scan)-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false
_G.IsTeleportingToSpawn = false
_G.IsScanningMode = false -- Flag to indicate scanning mode

-- ============================================
-- SCAN HEIGHT OFFSET SYSTEM (UNDERGROUND)
-- ============================================
local SCAN_HEIGHT_OFFSET = -100 -- 100 studs UNDERGROUND during scan
local NORMAL_HEIGHT_OFFSET = 2 -- Normal height when not scanning
local SCAN_IS_ACTIVE = false -- Track if scan is currently running

-- ============================================
-- HALLWAY NAVIGATION SYSTEM
-- ============================================
local hallwayWaypoints = {}
local currentHallwayIndex = 1

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

-- ============================================
-- ENHANCED HALLWAY POSITION FINDER
-- ============================================
local function findHallwayPosition(roomModel)
	local hallwayPos = nil
	local doorFrontPos = nil
	
	-- Look for locked doors first
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if lockedDoors then
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock and lock.Transparency < 1 then
				-- Get the door position
				local doorCFrame = child.CFrame
				local doorPosition = child.Position
				
				-- The door's LookVector points to the FRONT of the door
				local doorFront = doorCFrame.LookVector
				
				-- Calculate position in front of the door (hallway side)
				doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				hallwayPos = doorFrontPos
				break
			end
		end
	end
	
	-- If no locked doors, look for regular doors
	if not hallwayPos then
		local doors = roomModel:FindFirstChild("Doors")
		if doors then
			for _, door in ipairs(doors:GetChildren()) do
				if door:IsA("BasePart") then
					local doorCFrame = door.CFrame
					local doorPosition = door.Position
					local doorFront = doorCFrame.LookVector
					doorFrontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
					hallwayPos = doorFrontPos
					break
				end
			end
		end
	end
	
	-- Check for HallwayParts
	if not hallwayPos then
		local hallwayParts = roomModel:FindFirstChild("HallwayParts")
		if hallwayParts then
			for _, part in ipairs(hallwayParts:GetChildren()) do
				if part:IsA("BasePart") then
					hallwayPos = part.Position + Vector3.new(0, 2, 0)
					break
				end
			end
		end
	end
	
	-- If still no position, use room center with offset
	if not hallwayPos then
		local centerCFrame = roomModel:GetBoundingBox()
		hallwayPos = centerCFrame.Position + Vector3.new(0, 2, 0)
	end
	
	return hallwayPos, doorFrontPos
end

-- ============================================
-- ENHANCED HALLWAY WALKING SYSTEM
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	-- Generate waypoints along the path
	local direction = (targetPos - startPos).Unit
	local distance = (targetPos - startPos).Magnitude
	
	-- If distance is small, just move directly
	if distance < 15 then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
		return true
	end
	
	-- Create waypoints every 5 studs
	local waypoints = {}
	local numWaypoints = math.ceil(distance / 5)
	
	for i = 1, numWaypoints do
		local t = i / numWaypoints
		local waypoint = startPos + (direction * (distance * t))
		waypoint = Vector3.new(waypoint.X, startPos.Y + 1, waypoint.Z)
		table.insert(waypoints, waypoint)
	end
	
	table.insert(waypoints, targetPos)
	
	-- Walk through each waypoint
	local currentWaypoint = 1
	local timeout = 45
	local startTime = tick()
	local stuckCount = 0
	local lastPos = rootPart.Position
	
	while currentWaypoint <= #waypoints and tick() - startTime < timeout do
		local targetWaypoint = waypoints[currentWaypoint]
		humanoid:MoveTo(targetWaypoint)
		
		local waypointTimeout = 4
		local waypointStart = tick()
		
		while tick() - waypointStart < waypointTimeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distToWaypoint = (currentPos - targetWaypoint).Magnitude
			
			if distToWaypoint < 3 then
				break
			end
			
			if (currentPos - lastPos).Magnitude < 0.3 then
				stuckCount = stuckCount + 1
				if stuckCount > 15 then
					rootPart.Anchored = true
					rootPart.CFrame = CFrame.new(targetWaypoint)
					task.wait(0.2)
					rootPart.Anchored = false
					break
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
		end
		
		currentWaypoint = currentWaypoint + 1
	end
	
	-- Final check
	local finalDist = (rootPart.Position - targetPos).Magnitude
	if finalDist > 5 then
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	return true
end

-- ============================================
-- TP TO SPAWN
-- ============================================
local function TPtoSpawn()
	if _G.IsTeleportingToSpawn then
		return
	end
	
	_G.IsTeleportingToSpawn = true
	_G.Teleporting = true
	
	local character = getCharacter()
	if not character then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local heightOffset = (_G.IsScanningMode and SCAN_HEIGHT_OFFSET) or NORMAL_HEIGHT_OFFSET
	local pos = enterPosition + Vector3.new(0, heightOffset, 0)

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
	
	task.wait(0.5)
	_G.IsTeleportingToSpawn = false
	_G.Teleporting = false
end

-- ============================================
-- VOID PROTECTION - FIXED
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		
		-- Skip void protection if scanning mode is active
		if _G.IsScanningMode or SCAN_IS_ACTIVE then
			continue
		end
		
		local character = getCharacter()
		if not character then continue end
		
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		-- Only check if position is too low AND not in scanning mode
		if rootPart.Position.Y < -50 then
			print("⚠️ Detected falling into void! Teleporting to spawn...")
			if enterPosition then
				TPtoSpawn()
			else
				local folder = getGeneratedBackrooms()
				if folder then
					local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
					if spawnRoom then
						local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
						if spawnLocation then
							enterPosition = spawnLocation.Position
							TPtoSpawn()
						end
					end
				end
			end
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - IMPROVED
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return false
	end

	local character = getCharacter()
	if not character then
		return false
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		return false
	end

	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		return true
	end

	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	local doorFront = doorCFrame.LookVector
	
	local frontOffset = doorFront * 8
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.5)
		rootPart.Anchored = false
	end
	
	if humanoid then
		humanoid:MoveTo(doorFrontPos)
		task.wait(1)
	end
	
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	task.wait(1)
	
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	
	if humanoid then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
	end
	
	WalkThroughHallway(doorFrontPos, targetPos)
	
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs!")
		else
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				if room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT FUNCTIONS
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true
	_G.IsScanningMode = false

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	return true
end

local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + NORMAL_HEIGHT_OFFSET,
		roomCenter.Z
	)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", centerPos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(centerPos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
end

local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	local targetPos = nil
	
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	local hallwayPos, doorFrontPos = findHallwayPosition(roomModel)
	
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			return
		end
	end

	if hallwayPos then
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		Network.Fire("RequestStreaming", hallwayPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(hallwayPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		WalkThroughHallway(hallwayPos, targetPos)
	else
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	_G.Teleporting = false
end

-- ============================================
-- GET ROOM FUNCTIONS
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - UNDERGROUND SCANNING
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true
	_G.IsScanningMode = true
	SCAN_IS_ACTIVE = true

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan (100 studs UNDERGROUND)...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning... (underground)")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local hallwayPos, doorFrontPos = findHallwayPosition(room)
						
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil,
							HallwayPos = hallwayPos,
							DoorFrontPos = doorFrontPos
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms (underground)")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
						end
					end
				end
			end
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
			else
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
				
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Teleport UNDERGROUND for scanning
						local teleportPos = Vector3.new(room.Position.X, SCAN_HEIGHT_OFFSET, room.Position.Z)
						Network.Fire("RequestStreaming", teleportPos)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(teleportPos)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
				
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
				
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
			end
				
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	_G.IsScanningMode = false
	SCAN_IS_ACTIVE = false
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			_G.IsScanningMode = false
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- ANTI AFK
-- ============================================
localPlayer.Idled:Connect(function()
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI (SHORTENED VERSION)
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		button.MouseButton1Click:Connect(callback)
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) end
	end)
	createButton("✨ TP Anomaly", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then return end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			TeleportToRoom(nearestBoss.uid)
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	end)
	
	createToggle("🤖 Auto Boss", function(value) _G.AutoMiniBoss = value end)
	createToggle("🥚 Auto Hatch", function(value) _G.AutoHatch = value end)
	createToggle("⚡ Fast Hatch", function(value) _G.FastHatch = value end)
	createToggle("🥚 Auto Best Egg", function(value) _G.AutoTPBestEgg = value end)
	createToggle("🔒 Auto Locked Egg", function(value) _G.AutoTPLockedEgg = value end)
	createToggle("✨ Auto Anomaly", function(value) _G.AutoTPAnomaly = value end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
		end
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	return screenGui
end

-- ============================================
-- START SCRIPT
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 SCAN MODE: 100 studs UNDERGROUND")
print("   • Completely invisible to other players")
print("   • Auto-switches to normal height for farming")
print("=========================================")

task.wait(2)
Scan()-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false
_G.IsTeleportingToSpawn = false
_G.IsScanningMode = false -- Flag to indicate scanning mode

-- ============================================
-- SCAN HEIGHT OFFSET SYSTEM (UNDERGROUND)
-- ============================================
local SCAN_HEIGHT_OFFSET = -100 -- 100 studs UNDERGROUND during scan
local NORMAL_HEIGHT_OFFSET = 2 -- Normal height when not scanning

-- ============================================
-- HALLWAY NAVIGATION SYSTEM
-- ============================================
local hallwayWaypoints = {}
local currentHallwayIndex = 1

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

-- ============================================
-- ENHANCED HALLWAY POSITION FINDER
-- ============================================
local function findHallwayPosition(roomModel)
	local hallwayPos = nil
	local doorFrontPos = nil
	
	-- Look for locked doors first
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if lockedDoors then
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock and lock.Transparency < 1 then
				-- Get the door position
				local doorCFrame = child.CFrame
				local doorPosition = child.Position
				
				-- The door's LookVector points to the FRONT of the door
				local doorFront = doorCFrame.LookVector
				
				-- Calculate position in front of the door (hallway side)
				doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				hallwayPos = doorFrontPos
				print("🚪 Found locked door at: " .. tostring(doorPosition))
				print("🚪 Door front direction: " .. tostring(doorFront))
				print("🚪 Hallway position (front of door): " .. tostring(hallwayPos))
				break
			end
		end
	end
	
	-- If no locked doors, look for regular doors
	if not hallwayPos then
		local doors = roomModel:FindFirstChild("Doors")
		if doors then
			for _, door in ipairs(doors:GetChildren()) do
				if door:IsA("BasePart") then
					local doorCFrame = door.CFrame
					local doorPosition = door.Position
					local doorFront = doorCFrame.LookVector
					doorFrontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
					hallwayPos = doorFrontPos
					break
				end
			end
		end
	end
	
	-- Check for HallwayParts
	if not hallwayPos then
		local hallwayParts = roomModel:FindFirstChild("HallwayParts")
		if hallwayParts then
			for _, part in ipairs(hallwayParts:GetChildren()) do
				if part:IsA("BasePart") then
					hallwayPos = part.Position + Vector3.new(0, 2, 0)
					break
				end
			end
		end
	end
	
	-- If still no position, use room center with offset
	if not hallwayPos then
		local centerCFrame = roomModel:GetBoundingBox()
		hallwayPos = centerCFrame.Position + Vector3.new(0, 2, 0)
		print("⚠️ No door found, using room center as hallway position")
	end
	
	return hallwayPos, doorFrontPos
end

-- ============================================
-- ENHANCED HALLWAY WALKING SYSTEM
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	print("🚶 Starting hallway walk from: " .. tostring(startPos))
	print("🚶 Target: " .. tostring(targetPos))
	
	-- Generate waypoints along the path
	local direction = (targetPos - startPos).Unit
	local distance = (targetPos - startPos).Magnitude
	
	-- If distance is small, just move directly
	if distance < 15 then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
		print("✅ Short distance - direct move")
		return true
	end
	
	-- Create waypoints every 5 studs
	local waypoints = {}
	local numWaypoints = math.ceil(distance / 5)
	
	for i = 1, numWaypoints do
		local t = i / numWaypoints
		local waypoint = startPos + (direction * (distance * t))
		-- Keep the Y position consistent to avoid falling
		waypoint = Vector3.new(waypoint.X, startPos.Y + 1, waypoint.Z)
		table.insert(waypoints, waypoint)
	end
	
	-- Add final target
	table.insert(waypoints, targetPos)
	
	print("🚶 Walking through hallway with " .. #waypoints .. " waypoints...")
	
	-- Walk through each waypoint
	local currentWaypoint = 1
	local timeout = 45
	local startTime = tick()
	local stuckCount = 0
	local lastPos = rootPart.Position
	local waypointReached = false
	
	while currentWaypoint <= #waypoints and tick() - startTime < timeout do
		local targetWaypoint = waypoints[currentWaypoint]
		
		-- Move to current waypoint
		humanoid:MoveTo(targetWaypoint)
		
		-- Wait until we reach the waypoint or get stuck
		local waypointTimeout = 4
		local waypointStart = tick()
		
		while tick() - waypointStart < waypointTimeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distToWaypoint = (currentPos - targetWaypoint).Magnitude
			
			-- Check if we reached the waypoint
			if distToWaypoint < 3 then
				waypointReached = true
				print("✅ Reached waypoint " .. currentWaypoint .. "/" .. #waypoints)
				break
			end
			
			-- Check if stuck
			if (currentPos - lastPos).Magnitude < 0.3 then
				stuckCount = stuckCount + 1
				if stuckCount > 15 then -- 1.5 seconds stuck
					print("⚠️ Stuck at waypoint " .. currentWaypoint .. ", teleporting to next...")
					-- Teleport to next waypoint
					rootPart.Anchored = true
					rootPart.CFrame = CFrame.new(targetWaypoint)
					task.wait(0.2)
					rootPart.Anchored = false
					waypointReached = true
					break
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
		end
		
		currentWaypoint = currentWaypoint + 1
	end
	
	-- Final check: make sure we're at the target
	local finalDist = (rootPart.Position - targetPos).Magnitude
	if finalDist > 5 then
		print("⚠️ Didn't reach target! Teleporting directly...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
		return true
	end
	
	print("✅ Successfully walked through hallway!")
	return true
end

-- ============================================
-- TP TO SPAWN
-- ============================================
local function TPtoSpawn()
	if _G.IsTeleportingToSpawn then
		print("⚠️ Already teleporting to spawn!")
		return
	end
	
	_G.IsTeleportingToSpawn = true
	_G.Teleporting = true
	
	local character = getCharacter()
	if not character then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local heightOffset = _G.IsScanningMode and SCAN_HEIGHT_OFFSET or NORMAL_HEIGHT_OFFSET
	local pos = enterPosition + Vector3.new(0, heightOffset, 0)
	print("🏠 Teleporting to spawn position: " .. tostring(pos))

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
	
	task.wait(0.5)
	_G.IsTeleportingToSpawn = false
	_G.Teleporting = false
	print("✅ Successfully teleported to spawn!")
end

-- ============================================
-- VOID PROTECTION - UPDATED FOR UNDERGROUND SCANNING
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		-- Only trigger void protection if we're NOT in scanning mode
		-- When scanning, we're intentionally underground
		if not _G.IsScanningMode then
			if rootPart.Position.Y < -50 then
				print("⚠️ Detected falling into void! Teleporting to spawn...")
				if enterPosition then
					TPtoSpawn()
				else
					local folder = getGeneratedBackrooms()
					if folder then
						local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
						if spawnRoom then
							local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
							if spawnLocation then
								enterPosition = spawnLocation.Position
								TPtoSpawn()
							end
						end
					end
				end
			end
			
			if rootPart.Position.Y < 0 and rootPart.Position.Y > -50 and enterPosition then
				print("⚠️ Character below map! Teleporting to spawn...")
				TPtoSpawn()
			end
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - IMPROVED
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return false
	end

	local character = getCharacter()
	if not character then
		return false
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return false
	end

	-- Find the lock part and door part
	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		print("⚠️ Room already unlocked or no lock found!")
		return true
	end

	-- Get door position and CFrame
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	
	-- The door's LookVector points to the FRONT of the door
	local doorFront = doorCFrame.LookVector
	
	-- Calculate positions
	local frontOffset = doorFront * 8 -- Stand further back for better visibility
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Door Front Direction: " .. tostring(doorFront))
	print("🚪 Teleporting to HALLWAY in front of door at: " .. tostring(teleportPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		-- Teleport to hallway position (in front of door)
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.5)
		rootPart.Anchored = false
	end
	
	print("🔓 Walking to door to unlock...")
	
	-- Walk to the door front
	if humanoid then
		humanoid:MoveTo(doorFrontPos)
		task.wait(1)
	end
	
	-- Try to unlock the door
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	
	task.wait(1)
	
	-- Check if door is unlocked
	local isUnlocked = true
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			isUnlocked = false
			break
		end
	end
	
	if not isUnlocked then
		print("⚠️ Door unlock failed! Trying again...")
		activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
		task.wait(1)
	end
	
	-- Get the target position
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking through door to target position: " .. tostring(targetPos))
	
	-- Walk through to the target
	if humanoid then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
	end
	
	-- Walk through hallway from door to target
	WalkThroughHallway(doorFrontPos, targetPos)
	
	print("✅ Room unlocked and target reached successfully!")
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

-- ============================================
-- FAST EGG HATCHING - 0.01 MILLISECOND (INSTANT)
-- ============================================
local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs in batches of " .. batchSize .. "!")
		else
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				local isMatch = (not targetMult) or room.EggMultiplier >= targetMult

				if isMatch and room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT TO ANOMALY
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("✨ Teleported to Anomaly (250x Egg)!")
	return true
end

-- ============================================
-- TELEPORT TO MINI CHEST
-- ============================================
local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode for farming

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	-- Use normal height offset (not underground)
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + NORMAL_HEIGHT_OFFSET,
		roomCenter.Z
	)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", centerPos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(centerPos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
	
	local actionText = actionType or "Unknown"
	local indexText = roomIndex and (" #" .. roomIndex .. "/" .. #_G.AllMiniChestRooms) or ""
	print("📦 Teleported to CENTER of Mini Chest Room" .. indexText .. " (" .. actionText .. " action)!")
end

-- ============================================
-- ENHANCED TELEPORT TO ROOM - WITH HALLWAY NAVIGATION
-- ============================================
local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode for farming

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	-- Get the target position (egg or boss location)
	local targetPos = nil
	
	-- Find egg if it's an egg room
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- Find boss if it's a boss room
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- If no specific target, use room center
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- Get the hallway position (front of door)
	local hallwayPos, doorFrontPos = findHallwayPosition(roomModel)
	
	-- Check if locked room
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		-- Check if room is already unlocked
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			print("🔒 Room is locked! Teleporting to HALLWAY in front of door...")
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				print("⚠️ Failed to unlock room! Teleporting to spawn...")
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			print("✅ Room unlocked and walked to target!")
			return
		else
			print("✅ Room is already unlocked!")
		end
	end

	-- For unlocked rooms or regular rooms, teleport to hallway
	if hallwayPos then
		print("🚪 Teleporting to HALLWAY position: " .. tostring(hallwayPos))
		
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		Network.Fire("RequestStreaming", hallwayPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(hallwayPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		
		-- Walk through hallway to target
		print("🚶 Walking through hallway to target: " .. tostring(targetPos))
		local success = WalkThroughHallway(hallwayPos, targetPos)
		
		if not success then
			print("⚠️ Hallway walk failed! Teleporting directly to target...")
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(targetPos)
			task.wait(0.3)
			rootPart.Anchored = false
		end
	else
		-- No hallway found, teleport directly
		print("⚠️ No hallway found! Teleporting directly to target...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	_G.Teleporting = false
	print("✅ Arrived at target!")
end

-- ============================================
-- GET NEXT MINI CHEST ROOM
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

-- ============================================
-- GET NEAREST MINI CHEST ROOM
-- ============================================
local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - MAX 400 ROOMS - WITH -100 STUD HEIGHT OFFSET (UNDERGROUND)
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true
	_G.IsScanningMode = true -- Enable scanning mode (underground)

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan (100 studs UNDERGROUND)...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning... (100 studs underground)")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			warn("WAITING FOR BACKROOMS...")
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
			warn("SAVED SPAWN POSITION", enterPosition)
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.MiniChestActionType = "Cycle"
	
	local totalScanned = 0
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		local miniChestCount = 0
		local bossCount = 0
		local eggCount = 0
		local lockedEggCount = 0

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local hallwayPos, doorFrontPos = findHallwayPosition(room)
						
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil,
							HallwayPos = hallwayPos,
							DoorFrontPos = doorFrontPos
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						totalScanned = totalScanned + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms (underground)")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							bossCount = bossCount + 1
							print("🏠 Found Boss Room #" .. bossCount)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							miniChestCount = miniChestCount + 1
							print("📦 Found Mini Chest Room #" .. miniChestCount .. " (ID: " .. roomId .. ")")
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
							eggCount = eggCount + 1
							print("🥚 Found Free Egg Room #" .. eggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							lockedEggCount = lockedEggCount + 1
							print("🔒 Found Locked Egg Room #" .. lockedEggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepCoinRoom") ~= nil then
							print("💰 Found Coin Room: " .. roomId)
						end
					end
				end
			end
		end
		
		if miniChestCount > 0 then
			print("📦 Total Mini Chest Rooms found: " .. miniChestCount)
		end
		if bossCount > 0 then
			print("👑 Total Boss Rooms found: " .. bossCount)
		end
		if eggCount > 0 then
			print("🥚 Total Free Egg Rooms found: " .. eggCount)
		end
		if lockedEggCount > 0 then
			print("🔒 Total Locked Egg Rooms found: " .. lockedEggCount)
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
				print("No unvisited rooms, exploring random room")
			else
				warn("No rooms found at all!")
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
				
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Use hallway position if available, with -100 stud height offset (underground)
						local teleportPos = room.HallwayPos or (room.Position + Vector3.new(0, 0, 0))
						-- Add height offset for scanning (UNDERGROUND)
						teleportPos = Vector3.new(teleportPos.X, SCAN_HEIGHT_OFFSET, teleportPos.Z)
						Network.Fire("RequestStreaming", teleportPos)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(teleportPos)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
				
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
				
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
				print("📦 Mini Chest Rooms total: " .. #_G.AllMiniChestRooms)
				print("👑 Boss Rooms total: " .. #_G.AllBossRooms)
			end
				
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	_G.IsScanningMode = false -- Exit scanning mode after scan
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE FOR BOSS
-- ============================================
local directionArrow = nil
local directionLine = nil
local directionText = nil
local arrowFolder = nil

local function CreateDirectionGuide()
	if arrowFolder then
		arrowFolder:Destroy()
		arrowFolder = nil
	end
	
	arrowFolder = Instance.new("Folder")
	arrowFolder.Name = "DirectionGuide"
	arrowFolder.Parent = workspace.CurrentCamera
	
	directionArrow = Instance.new("Part")
	directionArrow.Name = "Arrow"
	directionArrow.Size = Vector3.new(2, 6, 2)
	directionArrow.Shape = Enum.PartType.Cylinder
	directionArrow.Anchored = true
	directionArrow.CanCollide = false
	directionArrow.Transparency = 0.3
	directionArrow.Material = Enum.Material.Neon
	directionArrow.Color = Color3.fromRGB(255, 50, 50)
	directionArrow.Parent = arrowFolder
	
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(4, 2, 4)
	tip.Shape = Enum.PartType.Cylinder
	tip.Anchored = true
	tip.CanCollide = false
	tip.Transparency = 0.2
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 100, 100)
	tip.Parent = arrowFolder
	
	directionLine = Instance.new("Part")
	directionLine.Name = "Line"
	directionLine.Size = Vector3.new(0.5, 1, 0.5)
	directionLine.Anchored = true
	directionLine.CanCollide = false
	directionLine.Transparency = 0.4
	directionLine.Material = Enum.Material.Neon
	directionLine.Color = Color3.fromRGB(255, 200, 50)
	directionLine.Parent = arrowFolder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DistanceLabel"
	billboard.Adornee = directionArrow
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = arrowFolder
	
	directionText = Instance.new("TextLabel")
	directionText.Size = UDim2.new(1, 0, 1, 0)
	directionText.BackgroundTransparency = 1
	directionText.Text = "👑 BOSS: 0 studs"
	directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
	directionText.TextSize = 16
	directionText.Font = Enum.Font.GothamBold
	directionText.TextStrokeTransparency = 0.3
	directionText.Parent = billboard
	
	task.spawn(function()
		while arrowFolder and arrowFolder.Parent do
			task.wait(0.05)
			if directionArrow then
				local pulse = 0.3 + math.sin(tick() * 3) * 0.15
				directionArrow.Transparency = pulse
				if directionLine then
					directionLine.Transparency = pulse + 0.1
				end
			end
		end
	end)
	
	return arrowFolder
end

local function UpdateDirectionGuide()
	if not _G.ShowDirectionGuide then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if #_G.AllBossRooms == 0 then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if not arrowFolder then
		CreateDirectionGuide()
	end
	
	local character = getCharacter()
	if not character then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local nearestBoss = nil
	local minDist = math.huge
	for _, boss in ipairs(_G.AllBossRooms) do
		local dist = (boss.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearestBoss = boss
		end
	end
	
	if not nearestBoss then
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return
	end
	
	local bossPos = nearestBoss.Position
	local playerPos = rootPart.Position
	local direction = (bossPos - playerPos).Unit
	
	local arrowPos = playerPos + Vector3.new(0, 8, 0)
	local distance = (bossPos - playerPos).Magnitude
	
	if directionArrow and directionArrow.Parent then
		directionArrow.Position = arrowPos
		directionArrow.CFrame = CFrame.lookAt(arrowPos, arrowPos + direction)
		
		local tip = arrowFolder:FindFirstChild("Tip")
		if tip then
			tip.Position = arrowPos + direction * 4
			tip.CFrame = CFrame.lookAt(tip.Position, tip.Position + direction)
		end
		
		if directionLine then
			local midPoint = (playerPos + bossPos) / 2
			local lineLength = distance
			directionLine.Size = Vector3.new(0.5, lineLength, 0.5)
			directionLine.Position = midPoint
			directionLine.CFrame = CFrame.lookAt(midPoint, bossPos)
		end
		
		if directionText then
			local distText = string.format("👑 BOSS: %.0f studs", distance)
			if distance < 50 then
				distText = "👑 BOSS: 🔥 CLOSE! " .. math.floor(distance) .. " studs"
			elseif distance < 100 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs ⬅️"
			elseif distance < 200 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🏃"
			else
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🚀"
			end
			directionText.Text = distText
			
			if distance < 50 then
				directionText.TextColor3 = Color3.fromRGB(255, 50, 50)
			elseif distance < 100 then
				directionText.TextColor3 = Color3.fromRGB(255, 150, 50)
			else
				directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
			end
		end
	end
	
	local angle = math.deg(math.atan2(direction.X, direction.Z))
	local compass = ""
	if angle > -22.5 and angle <= 22.5 then compass = "⬆️ North"
	elseif angle > 22.5 and angle <= 67.5 then compass = "↗️ Northeast"
	elseif angle > 67.5 and angle <= 112.5 then compass = "➡️ East"
	elseif angle > 112.5 and angle <= 157.5 then compass = "↘️ Southeast"
	elseif angle > 157.5 or angle <= -157.5 then compass = "⬇️ South"
	elseif angle > -157.5 and angle <= -112.5 then compass = "↙️ Southwest"
	elseif angle > -112.5 and angle <= -67.5 then compass = "⬅️ West"
	elseif angle > -67.5 and angle <= -22.5 then compass = "↖️ Northwest"
	end
	
	if not UpdateDirectionGuide.lastPrint or tick() - UpdateDirectionGuide.lastPrint > 5 then
		UpdateDirectionGuide.lastPrint = tick()
		print("🎯 BOSS Direction: " .. compass .. " | Distance: " .. math.floor(distance) .. " studs")
	end
end

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			print("✨ Auto teleporting to Anomaly (250x Egg)!")
			_G.IsScanningMode = false -- Exit scanning mode
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP - FAST HATCH SUPPORT (0.01ms delay)
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
				print("🔄 Cycle complete! Starting next cycle with Next Mini...")
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				print("📦 [Phase 1/2] Teleporting to NEXT Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Next")
				end
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				print("📦 [Phase 2/2] Teleporting to NEAREST Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Nearest")
				end
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				else
					print("⏱️ Waiting " .. _G.MiniChestCooldown .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- Direction Guide Update Loop
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- ORIGINAL ANTI AFK METHOD
-- ============================================
localPlayer.Idled:Connect(function()
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI - WITH MINIMIZE AND RED DOT CLICKER
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	-- MINIMIZE BUTTON
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "🗕"
	retractButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	retractButton.TextSize = 12
	retractButton.Font = Enum.Font.GothamBold
	retractButton.ZIndex = 11
	retractButton.Parent = titleBar
	
	local isRetracted = false
	
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 22, 0, 20)
	closeButton.Position = UDim2.new(1, -26, 0, 3)
	closeButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 1
	closeButton.BorderColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.Text = "✕"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
		print("❌ UI Closed")
	end)
	
	closeButton.MouseEnter:Connect(function()
		closeButton.BackgroundTransparency = 0
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.BackgroundTransparency = 0.2
	end)
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		
		button.MouseButton1Click:Connect(callback)
		
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.fromRGB(70, 70, 120)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 0.2
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		end)
		
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	-- Status label
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	-- Room count label
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	-- Buttons
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Free Egg Room found!") end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Locked Egg Room found!") end
	end)
	createButton("✨ TP Anomaly (250x)", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then 
			print("No Boss Room found! Scan first!")
			return 
		end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			print("🚪 Teleporting to Boss Room: " .. nearestBoss.Id)
			TeleportToRoom(nearestBoss.uid)
		else
			print("❌ No Boss Room found near you!")
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
		print("Cleared all scanned rooms")
	end)
	
	-- Toggles
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
		print("Auto Boss: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		print("Auto Hatch: " .. (value and "ON" or "OFF"))
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
		print("Fast Hatch: " .. (value and "ON" or "OFF"))
		if value then
			print("⚡ Fast Hatch: 0.01ms delay (INSTANT!)")
		end
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
		print("Auto Best Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
		print("Auto Locked Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
		print("Auto Anomaly: " .. (value and "ON" or "OFF"))
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
			print("Auto Mini: ON")
		else
			print("Auto Mini: OFF")
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
		print("Infinite Pet Speed: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🚫 No Hatch Anim", function(value)
		if (not canDoAction()) then return end
		
		if workspace.CurrentCamera:FindFirstChild("Eggs") or workspace.CurrentCamera:FindFirstChild("Pets") then
			print("⚠️ Cannot disable hatch animation - Eggs or Pets found in camera")
			return
		end
		
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		if not scripts then
			print("⚠️ PlayerScripts not found")
			return
		end
		
		local scriptInstance = nil
		for _, descendant in ipairs(scripts:GetDescendants()) do
			if descendant.Name == "Egg Opening Frontend" then
				scriptInstance = descendant
				break
			end
		end
		
		if not scriptInstance then
			print("⚠️ Egg Opening Frontend script not found")
			return
		end
		
		scriptInstance.Enabled = (not value)
		_G.DisableHatchAnimation = value
		print("No Hatch Anim: " .. (value and "ON (Disabled hatch animation)" or "OFF (Enabled hatch animation)"))
	end)
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- Clicker section
	createButton("🖱️ Set Clicker Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			print("📍 Click position set to center of screen")
		end
	end)
	
	createToggle("🖱️ Auto Clicker", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	-- RETRACT/MINIMIZE FUNCTIONALITY
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "🎮"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 200, 0, 150)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
			title.Text = "🎮 BR UI"
		end
	end)
	
	-- DRAGGING FUNCTIONALITY
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	
	-- ============================================
	-- RED DOT CLICKER
	-- ============================================
	local screenSize = workspace.CurrentCamera.ViewportSize
	local dotSize = 20
	local dotX = screenSize.X / 2 - dotSize / 2
	local dotY = screenSize.Y / 2 + 50 - dotSize / 2
	
	local redDot = Instance.new("Frame")
	redDot.Name = "RedDot"
	redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
	redDot.Position = UDim2.new(0, dotX, 0, dotY)
	redDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	redDot.BackgroundTransparency = 0.3
	redDot.BorderSizePixel = 1.5
	redDot.BorderColor3 = Color3.fromRGB(255, 0, 0)
	redDot.ZIndex = 999999
	redDot.Parent = screenGui
	
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = redDot
	
	local dotGlow = Instance.new("Frame")
	dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
	dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
	dotGlow.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	dotGlow.BackgroundTransparency = 0.1
	dotGlow.BorderSizePixel = 1
	dotGlow.BorderColor3 = Color3.fromRGB(255, 100, 100)
	dotGlow.ZIndex = 999998
	dotGlow.Parent = redDot
	
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = dotGlow
	
	local dotCenter = Instance.new("Frame")
	dotCenter.Size = UDim2.new(0, 4, 0, 4)
	dotCenter.Position = UDim2.new(0.5, -2, 0.5, -2)
	dotCenter.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.BackgroundTransparency = 0.3
	dotCenter.BorderSizePixel = 1
	dotCenter.BorderColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.ZIndex = 1000000
	dotCenter.Parent = redDot
	
	local dotCenterCorner = Instance.new("UICorner")
	dotCenterCorner.CornerRadius = UDim.new(1, 0)
	dotCenterCorner.Parent = dotCenter
	
	_G.AutoClickerX = dotX + dotSize / 2
	_G.AutoClickerY = dotY + dotSize / 2
	
	local dotDragging = false
	local dotDragStart, dotStartPos
	
	redDot.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dotDragging then
				dotDragging = false
				redDot.BackgroundTransparency = 0.3
			end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseMovement then
			if dotDragging then
				local delta = input.Position - dotDragStart
				local newX = dotStartPos.X.Offset + delta.X
				local newY = dotStartPos.Y.Offset + delta.Y
				local screenSize = workspace.CurrentCamera.ViewportSize
				newX = math.max(0, math.min(newX, screenSize.X - dotSize))
				newY = math.max(0, math.min(newY, screenSize.Y - dotSize))
				redDot.Position = UDim2.new(0, newX, 0, newY)
				_G.AutoClickerX = newX + dotSize / 2
				_G.AutoClickerY = newY + dotSize / 2
			end
		end
	end)
	
	dotGlow.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	redDot.MouseEnter:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.15
			redDot.Size = UDim2.new(0, dotSize + 4, 0, dotSize + 4)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - (dotSize + 4)/2, 0, _G.AutoClickerY - (dotSize + 4)/2)
			dotGlow.Size = UDim2.new(0, dotSize + 10, 0, dotSize + 10)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 10)/2, 0.5, -(dotSize + 10)/2)
		end
	end)
	
	redDot.MouseLeave:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.3
			redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - dotSize/2, 0, _G.AutoClickerY - dotSize/2)
			dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
		end
	end)
	
	return screenGui
end

-- ============================================
-- CREATE UI
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED")
print("   • Teleports 100 studs UNDERGROUND during scan")
print("   • Completely invisible to other players")
print("   • Returns to normal height for farming")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("⚡ Infinite Pet Speed: OFF")
print("🚫 No Hatch Animation: OFF")
print("⚡ Fast Hatch: OFF - 0.01ms delay (INSTANT!)")
print("🖱️ Red Dot Clicker: Drag to position")
print("🗕 Click minimize button to retract UI")
print("=========================================")
print("🚪 HALLWAY NAVIGATION SYSTEM:")
print("   • Finds door position and front direction")
print("   • Teleports to HALLWAY in front of door")
print("   • Walks to door, unlocks with key")
print("   • Walks through to target entity")
print("=========================================")
print("🛡️ VOID PROTECTION:")
print("   • Disabled during scanning mode")
print("   • Active during normal gameplay")
print("   • Auto-teleports to spawn if falling")
print("=========================================")

-- Start automatic scan after UI loads
task.wait(2)
Scan()-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false
_G.IsTeleportingToSpawn = false
_G.IsScanningMode = false -- Flag to indicate scanning mode

-- ============================================
-- SCAN HEIGHT OFFSET SYSTEM
-- ============================================
local SCAN_HEIGHT_OFFSET = 100 -- Height above rooms during scan
local NORMAL_HEIGHT_OFFSET = 2 -- Normal height when not scanning

-- ============================================
-- HALLWAY NAVIGATION SYSTEM
-- ============================================
local hallwayWaypoints = {}
local currentHallwayIndex = 1

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

-- ============================================
-- ENHANCED HALLWAY POSITION FINDER
-- ============================================
local function findHallwayPosition(roomModel)
	local hallwayPos = nil
	local doorFrontPos = nil
	
	-- Look for locked doors first
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if lockedDoors then
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock and lock.Transparency < 1 then
				-- Get the door position
				local doorCFrame = child.CFrame
				local doorPosition = child.Position
				
				-- The door's LookVector points to the FRONT of the door
				local doorFront = doorCFrame.LookVector
				
				-- Calculate position in front of the door (hallway side)
				doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				hallwayPos = doorFrontPos
				print("🚪 Found locked door at: " .. tostring(doorPosition))
				print("🚪 Door front direction: " .. tostring(doorFront))
				print("🚪 Hallway position (front of door): " .. tostring(hallwayPos))
				break
			end
		end
	end
	
	-- If no locked doors, look for regular doors
	if not hallwayPos then
		local doors = roomModel:FindFirstChild("Doors")
		if doors then
			for _, door in ipairs(doors:GetChildren()) do
				if door:IsA("BasePart") then
					local doorCFrame = door.CFrame
					local doorPosition = door.Position
					local doorFront = doorCFrame.LookVector
					doorFrontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
					hallwayPos = doorFrontPos
					break
				end
			end
		end
	end
	
	-- Check for HallwayParts
	if not hallwayPos then
		local hallwayParts = roomModel:FindFirstChild("HallwayParts")
		if hallwayParts then
			for _, part in ipairs(hallwayParts:GetChildren()) do
				if part:IsA("BasePart") then
					hallwayPos = part.Position + Vector3.new(0, 2, 0)
					break
				end
			end
		end
	end
	
	-- If still no position, use room center with offset
	if not hallwayPos then
		local centerCFrame = roomModel:GetBoundingBox()
		hallwayPos = centerCFrame.Position + Vector3.new(0, 2, 0)
		print("⚠️ No door found, using room center as hallway position")
	end
	
	return hallwayPos, doorFrontPos
end

-- ============================================
-- ENHANCED HALLWAY WALKING SYSTEM
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	print("🚶 Starting hallway walk from: " .. tostring(startPos))
	print("🚶 Target: " .. tostring(targetPos))
	
	-- Generate waypoints along the path
	local direction = (targetPos - startPos).Unit
	local distance = (targetPos - startPos).Magnitude
	
	-- If distance is small, just move directly
	if distance < 15 then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
		print("✅ Short distance - direct move")
		return true
	end
	
	-- Create waypoints every 5 studs
	local waypoints = {}
	local numWaypoints = math.ceil(distance / 5)
	
	for i = 1, numWaypoints do
		local t = i / numWaypoints
		local waypoint = startPos + (direction * (distance * t))
		-- Keep the Y position consistent to avoid falling
		waypoint = Vector3.new(waypoint.X, startPos.Y + 1, waypoint.Z)
		table.insert(waypoints, waypoint)
	end
	
	-- Add final target
	table.insert(waypoints, targetPos)
	
	print("🚶 Walking through hallway with " .. #waypoints .. " waypoints...")
	
	-- Walk through each waypoint
	local currentWaypoint = 1
	local timeout = 45
	local startTime = tick()
	local stuckCount = 0
	local lastPos = rootPart.Position
	local waypointReached = false
	
	while currentWaypoint <= #waypoints and tick() - startTime < timeout do
		local targetWaypoint = waypoints[currentWaypoint]
		
		-- Move to current waypoint
		humanoid:MoveTo(targetWaypoint)
		
		-- Wait until we reach the waypoint or get stuck
		local waypointTimeout = 4
		local waypointStart = tick()
		
		while tick() - waypointStart < waypointTimeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distToWaypoint = (currentPos - targetWaypoint).Magnitude
			
			-- Check if we reached the waypoint
			if distToWaypoint < 3 then
				waypointReached = true
				print("✅ Reached waypoint " .. currentWaypoint .. "/" .. #waypoints)
				break
			end
			
			-- Check if stuck
			if (currentPos - lastPos).Magnitude < 0.3 then
				stuckCount = stuckCount + 1
				if stuckCount > 15 then -- 1.5 seconds stuck
					print("⚠️ Stuck at waypoint " .. currentWaypoint .. ", teleporting to next...")
					-- Teleport to next waypoint
					rootPart.Anchored = true
					rootPart.CFrame = CFrame.new(targetWaypoint)
					task.wait(0.2)
					rootPart.Anchored = false
					waypointReached = true
					break
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
		end
		
		currentWaypoint = currentWaypoint + 1
	end
	
	-- Final check: make sure we're at the target
	local finalDist = (rootPart.Position - targetPos).Magnitude
	if finalDist > 5 then
		print("⚠️ Didn't reach target! Teleporting directly...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
		return true
	end
	
	print("✅ Successfully walked through hallway!")
	return true
end

-- ============================================
-- TP TO SPAWN
-- ============================================
local function TPtoSpawn()
	if _G.IsTeleportingToSpawn then
		print("⚠️ Already teleporting to spawn!")
		return
	end
	
	_G.IsTeleportingToSpawn = true
	_G.Teleporting = true
	
	local character = getCharacter()
	if not character then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local heightOffset = _G.IsScanningMode and SCAN_HEIGHT_OFFSET or NORMAL_HEIGHT_OFFSET
	local pos = enterPosition + Vector3.new(0, heightOffset, 0)
	print("🏠 Teleporting to spawn position: " .. tostring(pos))

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
	
	task.wait(0.5)
	_G.IsTeleportingToSpawn = false
	_G.Teleporting = false
	print("✅ Successfully teleported to spawn!")
end

-- ============================================
-- VOID PROTECTION
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if rootPart.Position.Y < -50 then
			print("⚠️ Detected falling into void! Teleporting to spawn...")
			if enterPosition then
				TPtoSpawn()
			else
				local folder = getGeneratedBackrooms()
				if folder then
					local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
					if spawnRoom then
						local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
						if spawnLocation then
							enterPosition = spawnLocation.Position
							TPtoSpawn()
						end
					end
				end
			end
		end
		
		if rootPart.Position.Y < 0 and rootPart.Position.Y > -50 and enterPosition then
			print("⚠️ Character below map! Teleporting to spawn...")
			TPtoSpawn()
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - IMPROVED
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return false
	end

	local character = getCharacter()
	if not character then
		return false
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return false
	end

	-- Find the lock part and door part
	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		print("⚠️ Room already unlocked or no lock found!")
		return true
	end

	-- Get door position and CFrame
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	
	-- The door's LookVector points to the FRONT of the door
	local doorFront = doorCFrame.LookVector
	
	-- Calculate positions
	local frontOffset = doorFront * 8 -- Stand further back for better visibility
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Door Front Direction: " .. tostring(doorFront))
	print("🚪 Teleporting to HALLWAY in front of door at: " .. tostring(teleportPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		-- Teleport to hallway position (in front of door)
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.5)
		rootPart.Anchored = false
	end
	
	print("🔓 Walking to door to unlock...")
	
	-- Walk to the door front
	if humanoid then
		humanoid:MoveTo(doorFrontPos)
		task.wait(1)
	end
	
	-- Try to unlock the door
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	
	task.wait(1)
	
	-- Check if door is unlocked
	local isUnlocked = true
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			isUnlocked = false
			break
		end
	end
	
	if not isUnlocked then
		print("⚠️ Door unlock failed! Trying again...")
		activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
		task.wait(1)
	end
	
	-- Get the target position
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking through door to target position: " .. tostring(targetPos))
	
	-- Walk through to the target
	if humanoid then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
	end
	
	-- Walk through hallway from door to target
	WalkThroughHallway(doorFrontPos, targetPos)
	
	print("✅ Room unlocked and target reached successfully!")
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

-- ============================================
-- FAST EGG HATCHING - 0.01 MILLISECOND (INSTANT)
-- ============================================
local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs in batches of " .. batchSize .. "!")
		else
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				local isMatch = (not targetMult) or room.EggMultiplier >= targetMult

				if isMatch and room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT TO ANOMALY
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("✨ Teleported to Anomaly (250x Egg)!")
	return true
end

-- ============================================
-- TELEPORT TO MINI CHEST
-- ============================================
local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode for farming

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	-- Use normal height offset (not 100 studs above)
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + NORMAL_HEIGHT_OFFSET,
		roomCenter.Z
	)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", centerPos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(centerPos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
	
	local actionText = actionType or "Unknown"
	local indexText = roomIndex and (" #" .. roomIndex .. "/" .. #_G.AllMiniChestRooms) or ""
	print("📦 Teleported to CENTER of Mini Chest Room" .. indexText .. " (" .. actionText .. " action)!")
end

-- ============================================
-- ENHANCED TELEPORT TO ROOM - WITH HALLWAY NAVIGATION
-- ============================================
local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true
	_G.IsScanningMode = false -- Exit scanning mode for farming

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	-- Get the target position (egg or boss location)
	local targetPos = nil
	
	-- Find egg if it's an egg room
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- Find boss if it's a boss room
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- If no specific target, use room center
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
		end
	end
	
	-- Get the hallway position (front of door)
	local hallwayPos, doorFrontPos = findHallwayPosition(roomModel)
	
	-- Check if locked room
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		-- Check if room is already unlocked
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			print("🔒 Room is locked! Teleporting to HALLWAY in front of door...")
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				print("⚠️ Failed to unlock room! Teleporting to spawn...")
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			print("✅ Room unlocked and walked to target!")
			return
		else
			print("✅ Room is already unlocked!")
		end
	end

	-- For unlocked rooms or regular rooms, teleport to hallway
	if hallwayPos then
		print("🚪 Teleporting to HALLWAY position: " .. tostring(hallwayPos))
		
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		Network.Fire("RequestStreaming", hallwayPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(hallwayPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		
		-- Walk through hallway to target
		print("🚶 Walking through hallway to target: " .. tostring(targetPos))
		local success = WalkThroughHallway(hallwayPos, targetPos)
		
		if not success then
			print("⚠️ Hallway walk failed! Teleporting directly to target...")
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(targetPos)
			task.wait(0.3)
			rootPart.Anchored = false
		end
	else
		-- No hallway found, teleport directly
		print("⚠️ No hallway found! Teleporting directly to target...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	_G.Teleporting = false
	print("✅ Arrived at target!")
end

-- ============================================
-- GET NEXT MINI CHEST ROOM
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

-- ============================================
-- GET NEAREST MINI CHEST ROOM
-- ============================================
local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - MAX 400 ROOMS - WITH 100 STUD HEIGHT OFFSET
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true
	_G.IsScanningMode = true -- Enable scanning mode (100 studs above)

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan (100 studs above)...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning... (100 studs above)")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			warn("WAITING FOR BACKROOMS...")
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
			warn("SAVED SPAWN POSITION", enterPosition)
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.MiniChestActionType = "Cycle"
	
	local totalScanned = 0
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		local miniChestCount = 0
		local bossCount = 0
		local eggCount = 0
		local lockedEggCount = 0

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local hallwayPos, doorFrontPos = findHallwayPosition(room)
						
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil,
							HallwayPos = hallwayPos,
							DoorFrontPos = doorFrontPos
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						totalScanned = totalScanned + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms (100 studs above)")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							bossCount = bossCount + 1
							print("🏠 Found Boss Room #" .. bossCount)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							miniChestCount = miniChestCount + 1
							print("📦 Found Mini Chest Room #" .. miniChestCount .. " (ID: " .. roomId .. ")")
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
							eggCount = eggCount + 1
							print("🥚 Found Free Egg Room #" .. eggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							lockedEggCount = lockedEggCount + 1
							print("🔒 Found Locked Egg Room #" .. lockedEggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepCoinRoom") ~= nil then
							print("💰 Found Coin Room: " .. roomId)
						end
					end
				end
			end
		end
		
		if miniChestCount > 0 then
			print("📦 Total Mini Chest Rooms found: " .. miniChestCount)
		end
		if bossCount > 0 then
			print("👑 Total Boss Rooms found: " .. bossCount)
		end
		if eggCount > 0 then
			print("🥚 Total Free Egg Rooms found: " .. eggCount)
		end
		if lockedEggCount > 0 then
			print("🔒 Total Locked Egg Rooms found: " .. lockedEggCount)
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
				print("No unvisited rooms, exploring random room")
			else
				warn("No rooms found at all!")
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
				
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Use hallway position if available, with 100 stud height offset
						local teleportPos = room.HallwayPos or (room.Position + Vector3.new(0, SCAN_HEIGHT_OFFSET, 0))
						-- Add height offset for scanning
						teleportPos = teleportPos + Vector3.new(0, SCAN_HEIGHT_OFFSET, 0)
						Network.Fire("RequestStreaming", teleportPos)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(teleportPos)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
				
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
				
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
				print("📦 Mini Chest Rooms total: " .. #_G.AllMiniChestRooms)
				print("👑 Boss Rooms total: " .. #_G.AllBossRooms)
			end
				
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	_G.IsScanningMode = false -- Exit scanning mode after scan
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE FOR BOSS
-- ============================================
local directionArrow = nil
local directionLine = nil
local directionText = nil
local arrowFolder = nil

local function CreateDirectionGuide()
	if arrowFolder then
		arrowFolder:Destroy()
		arrowFolder = nil
	end
	
	arrowFolder = Instance.new("Folder")
	arrowFolder.Name = "DirectionGuide"
	arrowFolder.Parent = workspace.CurrentCamera
	
	directionArrow = Instance.new("Part")
	directionArrow.Name = "Arrow"
	directionArrow.Size = Vector3.new(2, 6, 2)
	directionArrow.Shape = Enum.PartType.Cylinder
	directionArrow.Anchored = true
	directionArrow.CanCollide = false
	directionArrow.Transparency = 0.3
	directionArrow.Material = Enum.Material.Neon
	directionArrow.Color = Color3.fromRGB(255, 50, 50)
	directionArrow.Parent = arrowFolder
	
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(4, 2, 4)
	tip.Shape = Enum.PartType.Cylinder
	tip.Anchored = true
	tip.CanCollide = false
	tip.Transparency = 0.2
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 100, 100)
	tip.Parent = arrowFolder
	
	directionLine = Instance.new("Part")
	directionLine.Name = "Line"
	directionLine.Size = Vector3.new(0.5, 1, 0.5)
	directionLine.Anchored = true
	directionLine.CanCollide = false
	directionLine.Transparency = 0.4
	directionLine.Material = Enum.Material.Neon
	directionLine.Color = Color3.fromRGB(255, 200, 50)
	directionLine.Parent = arrowFolder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DistanceLabel"
	billboard.Adornee = directionArrow
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = arrowFolder
	
	directionText = Instance.new("TextLabel")
	directionText.Size = UDim2.new(1, 0, 1, 0)
	directionText.BackgroundTransparency = 1
	directionText.Text = "👑 BOSS: 0 studs"
	directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
	directionText.TextSize = 16
	directionText.Font = Enum.Font.GothamBold
	directionText.TextStrokeTransparency = 0.3
	directionText.Parent = billboard
	
	task.spawn(function()
		while arrowFolder and arrowFolder.Parent do
			task.wait(0.05)
			if directionArrow then
				local pulse = 0.3 + math.sin(tick() * 3) * 0.15
				directionArrow.Transparency = pulse
				if directionLine then
					directionLine.Transparency = pulse + 0.1
				end
			end
		end
	end)
	
	return arrowFolder
end

local function UpdateDirectionGuide()
	if not _G.ShowDirectionGuide then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if #_G.AllBossRooms == 0 then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if not arrowFolder then
		CreateDirectionGuide()
	end
	
	local character = getCharacter()
	if not character then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local nearestBoss = nil
	local minDist = math.huge
	for _, boss in ipairs(_G.AllBossRooms) do
		local dist = (boss.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearestBoss = boss
		end
	end
	
	if not nearestBoss then
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return
	end
	
	local bossPos = nearestBoss.Position
	local playerPos = rootPart.Position
	local direction = (bossPos - playerPos).Unit
	
	local arrowPos = playerPos + Vector3.new(0, 8, 0)
	local distance = (bossPos - playerPos).Magnitude
	
	if directionArrow and directionArrow.Parent then
		directionArrow.Position = arrowPos
		directionArrow.CFrame = CFrame.lookAt(arrowPos, arrowPos + direction)
		
		local tip = arrowFolder:FindFirstChild("Tip")
		if tip then
			tip.Position = arrowPos + direction * 4
			tip.CFrame = CFrame.lookAt(tip.Position, tip.Position + direction)
		end
		
		if directionLine then
			local midPoint = (playerPos + bossPos) / 2
			local lineLength = distance
			directionLine.Size = Vector3.new(0.5, lineLength, 0.5)
			directionLine.Position = midPoint
			directionLine.CFrame = CFrame.lookAt(midPoint, bossPos)
		end
		
		if directionText then
			local distText = string.format("👑 BOSS: %.0f studs", distance)
			if distance < 50 then
				distText = "👑 BOSS: 🔥 CLOSE! " .. math.floor(distance) .. " studs"
			elseif distance < 100 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs ⬅️"
			elseif distance < 200 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🏃"
			else
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🚀"
			end
			directionText.Text = distText
			
			if distance < 50 then
				directionText.TextColor3 = Color3.fromRGB(255, 50, 50)
			elseif distance < 100 then
				directionText.TextColor3 = Color3.fromRGB(255, 150, 50)
			else
				directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
			end
		end
	end
	
	local angle = math.deg(math.atan2(direction.X, direction.Z))
	local compass = ""
	if angle > -22.5 and angle <= 22.5 then compass = "⬆️ North"
	elseif angle > 22.5 and angle <= 67.5 then compass = "↗️ Northeast"
	elseif angle > 67.5 and angle <= 112.5 then compass = "➡️ East"
	elseif angle > 112.5 and angle <= 157.5 then compass = "↘️ Southeast"
	elseif angle > 157.5 or angle <= -157.5 then compass = "⬇️ South"
	elseif angle > -157.5 and angle <= -112.5 then compass = "↙️ Southwest"
	elseif angle > -112.5 and angle <= -67.5 then compass = "⬅️ West"
	elseif angle > -67.5 and angle <= -22.5 then compass = "↖️ Northwest"
	end
	
	if not UpdateDirectionGuide.lastPrint or tick() - UpdateDirectionGuide.lastPrint > 5 then
		UpdateDirectionGuide.lastPrint = tick()
		print("🎯 BOSS Direction: " .. compass .. " | Distance: " .. math.floor(distance) .. " studs")
	end
end

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			print("✨ Auto teleporting to Anomaly (250x Egg)!")
			_G.IsScanningMode = false -- Exit scanning mode
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP - FAST HATCH SUPPORT (0.01ms delay)
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
				print("🔄 Cycle complete! Starting next cycle with Next Mini...")
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				print("📦 [Phase 1/2] Teleporting to NEXT Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Next")
				end
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				print("📦 [Phase 2/2] Teleporting to NEAREST Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Nearest")
				end
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				else
					print("⏱️ Waiting " .. _G.MiniChestCooldown .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- Direction Guide Update Loop
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- ORIGINAL ANTI AFK METHOD
-- ============================================
localPlayer.Idled:Connect(function()
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI - WITH MINIMIZE AND RED DOT CLICKER
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	-- MINIMIZE BUTTON
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "🗕"
	retractButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	retractButton.TextSize = 12
	retractButton.Font = Enum.Font.GothamBold
	retractButton.ZIndex = 11
	retractButton.Parent = titleBar
	
	local isRetracted = false
	
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 22, 0, 20)
	closeButton.Position = UDim2.new(1, -26, 0, 3)
	closeButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 1
	closeButton.BorderColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.Text = "✕"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
		print("❌ UI Closed")
	end)
	
	closeButton.MouseEnter:Connect(function()
		closeButton.BackgroundTransparency = 0
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.BackgroundTransparency = 0.2
	end)
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		
		button.MouseButton1Click:Connect(callback)
		
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.fromRGB(70, 70, 120)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 0.2
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		end)
		
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	-- Status label
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	-- Room count label
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	-- Buttons
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Free Egg Room found!") end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Locked Egg Room found!") end
	end)
	createButton("✨ TP Anomaly (250x)", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then 
			print("No Boss Room found! Scan first!")
			return 
		end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			print("🚪 Teleporting to Boss Room: " .. nearestBoss.Id)
			TeleportToRoom(nearestBoss.uid)
		else
			print("❌ No Boss Room found near you!")
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
		print("Cleared all scanned rooms")
	end)
	
	-- Toggles
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
		print("Auto Boss: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		print("Auto Hatch: " .. (value and "ON" or "OFF"))
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
		print("Fast Hatch: " .. (value and "ON" or "OFF"))
		if value then
			print("⚡ Fast Hatch: 0.01ms delay (INSTANT!)")
		end
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
		print("Auto Best Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
		print("Auto Locked Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
		print("Auto Anomaly: " .. (value and "ON" or "OFF"))
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
			print("Auto Mini: ON")
		else
			print("Auto Mini: OFF")
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
		print("Infinite Pet Speed: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🚫 No Hatch Anim", function(value)
		if (not canDoAction()) then return end
		
		if workspace.CurrentCamera:FindFirstChild("Eggs") or workspace.CurrentCamera:FindFirstChild("Pets") then
			print("⚠️ Cannot disable hatch animation - Eggs or Pets found in camera")
			return
		end
		
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		if not scripts then
			print("⚠️ PlayerScripts not found")
			return
		end
		
		local scriptInstance = nil
		for _, descendant in ipairs(scripts:GetDescendants()) do
			if descendant.Name == "Egg Opening Frontend" then
				scriptInstance = descendant
				break
			end
		end
		
		if not scriptInstance then
			print("⚠️ Egg Opening Frontend script not found")
			return
		end
		
		scriptInstance.Enabled = (not value)
		_G.DisableHatchAnimation = value
		print("No Hatch Anim: " .. (value and "ON (Disabled hatch animation)" or "OFF (Enabled hatch animation)"))
	end)
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- Clicker section
	createButton("🖱️ Set Clicker Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			print("📍 Click position set to center of screen")
		end
	end)
	
	createToggle("🖱️ Auto Clicker", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	-- RETRACT/MINIMIZE FUNCTIONALITY
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "🎮"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 200, 0, 150)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
			title.Text = "🎮 BR UI"
		end
	end)
	
	-- DRAGGING FUNCTIONALITY
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	
	-- ============================================
	-- RED DOT CLICKER
	-- ============================================
	local screenSize = workspace.CurrentCamera.ViewportSize
	local dotSize = 20
	local dotX = screenSize.X / 2 - dotSize / 2
	local dotY = screenSize.Y / 2 + 50 - dotSize / 2
	
	local redDot = Instance.new("Frame")
	redDot.Name = "RedDot"
	redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
	redDot.Position = UDim2.new(0, dotX, 0, dotY)
	redDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	redDot.BackgroundTransparency = 0.3
	redDot.BorderSizePixel = 1.5
	redDot.BorderColor3 = Color3.fromRGB(255, 0, 0)
	redDot.ZIndex = 999999
	redDot.Parent = screenGui
	
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = redDot
	
	local dotGlow = Instance.new("Frame")
	dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
	dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
	dotGlow.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	dotGlow.BackgroundTransparency = 0.1
	dotGlow.BorderSizePixel = 1
	dotGlow.BorderColor3 = Color3.fromRGB(255, 100, 100)
	dotGlow.ZIndex = 999998
	dotGlow.Parent = redDot
	
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = dotGlow
	
	local dotCenter = Instance.new("Frame")
	dotCenter.Size = UDim2.new(0, 4, 0, 4)
	dotCenter.Position = UDim2.new(0.5, -2, 0.5, -2)
	dotCenter.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.BackgroundTransparency = 0.3
	dotCenter.BorderSizePixel = 1
	dotCenter.BorderColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.ZIndex = 1000000
	dotCenter.Parent = redDot
	
	local dotCenterCorner = Instance.new("UICorner")
	dotCenterCorner.CornerRadius = UDim.new(1, 0)
	dotCenterCorner.Parent = dotCenter
	
	_G.AutoClickerX = dotX + dotSize / 2
	_G.AutoClickerY = dotY + dotSize / 2
	
	local dotDragging = false
	local dotDragStart, dotStartPos
	
	redDot.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dotDragging then
				dotDragging = false
				redDot.BackgroundTransparency = 0.3
			end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseMovement then
			if dotDragging then
				local delta = input.Position - dotDragStart
				local newX = dotStartPos.X.Offset + delta.X
				local newY = dotStartPos.Y.Offset + delta.Y
				local screenSize = workspace.CurrentCamera.ViewportSize
				newX = math.max(0, math.min(newX, screenSize.X - dotSize))
				newY = math.max(0, math.min(newY, screenSize.Y - dotSize))
				redDot.Position = UDim2.new(0, newX, 0, newY)
				_G.AutoClickerX = newX + dotSize / 2
				_G.AutoClickerY = newY + dotSize / 2
			end
		end
	end)
	
	dotGlow.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	redDot.MouseEnter:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.15
			redDot.Size = UDim2.new(0, dotSize + 4, 0, dotSize + 4)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - (dotSize + 4)/2, 0, _G.AutoClickerY - (dotSize + 4)/2)
			dotGlow.Size = UDim2.new(0, dotSize + 10, 0, dotSize + 10)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 10)/2, 0.5, -(dotSize + 10)/2)
		end
	end)
	
	redDot.MouseLeave:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.3
			redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - dotSize/2, 0, _G.AutoClickerY - dotSize/2)
			dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
		end
	end)
	
	return screenGui
end

-- ============================================
-- CREATE UI
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED")
print("   • Teleports 100 studs ABOVE rooms during scan")
print("   • Returns to normal height for farming")
print("   • Completely invisible to other players")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("⚡ Infinite Pet Speed: OFF")
print("🚫 No Hatch Animation: OFF")
print("⚡ Fast Hatch: OFF - 0.01ms delay (INSTANT!)")
print("🖱️ Red Dot Clicker: Drag to position")
print("🗕 Click minimize button to retract UI")
print("=========================================")
print("🚪 HALLWAY NAVIGATION SYSTEM:")
print("   • Finds door position and front direction")
print("   • Teleports to HALLWAY in front of door")
print("   • Walks to door, unlocks with key")
print("   • Walks through to target entity")
print("   • Auto-recovery if stuck")
print("=========================================")
print("🛡️ VOID PROTECTION:")
print("   • Detects falling into void")
print("   • Automatically teleports to spawn")
print("=========================================")

-- Start automatic scan after UI loads
task.wait(2)
Scan()-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false
_G.IsTeleportingToSpawn = false

-- ============================================
-- HALLWAY NAVIGATION SYSTEM
-- ============================================
local hallwayWaypoints = {}
local currentHallwayIndex = 1

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

-- ============================================
-- ENHANCED HALLWAY POSITION FINDER
-- ============================================
local function findHallwayPosition(roomModel)
	local hallwayPos = nil
	local doorFrontPos = nil
	
	-- Look for locked doors first
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if lockedDoors then
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock and lock.Transparency < 1 then
				-- Get the door position
				local doorCFrame = child.CFrame
				local doorPosition = child.Position
				
				-- The door's LookVector points to the FRONT of the door
				local doorFront = doorCFrame.LookVector
				
				-- Calculate position in front of the door (hallway side)
				doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				hallwayPos = doorFrontPos
				print("🚪 Found locked door at: " .. tostring(doorPosition))
				print("🚪 Door front direction: " .. tostring(doorFront))
				print("🚪 Hallway position (front of door): " .. tostring(hallwayPos))
				break
			end
		end
	end
	
	-- If no locked doors, look for regular doors
	if not hallwayPos then
		local doors = roomModel:FindFirstChild("Doors")
		if doors then
			for _, door in ipairs(doors:GetChildren()) do
				if door:IsA("BasePart") then
					local doorCFrame = door.CFrame
					local doorPosition = door.Position
					local doorFront = doorCFrame.LookVector
					doorFrontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
					hallwayPos = doorFrontPos
					break
				end
			end
		end
	end
	
	-- Check for HallwayParts
	if not hallwayPos then
		local hallwayParts = roomModel:FindFirstChild("HallwayParts")
		if hallwayParts then
			for _, part in ipairs(hallwayParts:GetChildren()) do
				if part:IsA("BasePart") then
					hallwayPos = part.Position + Vector3.new(0, 2, 0)
					break
				end
			end
		end
	end
	
	-- If still no position, use room center with offset
	if not hallwayPos then
		local centerCFrame = roomModel:GetBoundingBox()
		hallwayPos = centerCFrame.Position + Vector3.new(0, 2, 0)
		print("⚠️ No door found, using room center as hallway position")
	end
	
	return hallwayPos, doorFrontPos
end

-- ============================================
-- ENHANCED HALLWAY WALKING SYSTEM
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	print("🚶 Starting hallway walk from: " .. tostring(startPos))
	print("🚶 Target: " .. tostring(targetPos))
	
	-- Generate waypoints along the path
	local direction = (targetPos - startPos).Unit
	local distance = (targetPos - startPos).Magnitude
	
	-- If distance is small, just move directly
	if distance < 15 then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
		print("✅ Short distance - direct move")
		return true
	end
	
	-- Create waypoints every 5 studs
	local waypoints = {}
	local numWaypoints = math.ceil(distance / 5)
	
	for i = 1, numWaypoints do
		local t = i / numWaypoints
		local waypoint = startPos + (direction * (distance * t))
		-- Keep the Y position consistent to avoid falling
		waypoint = Vector3.new(waypoint.X, startPos.Y + 1, waypoint.Z)
		table.insert(waypoints, waypoint)
	end
	
	-- Add final target
	table.insert(waypoints, targetPos)
	
	print("🚶 Walking through hallway with " .. #waypoints .. " waypoints...")
	
	-- Walk through each waypoint
	local currentWaypoint = 1
	local timeout = 45
	local startTime = tick()
	local stuckCount = 0
	local lastPos = rootPart.Position
	local waypointReached = false
	
	while currentWaypoint <= #waypoints and tick() - startTime < timeout do
		local targetWaypoint = waypoints[currentWaypoint]
		
		-- Move to current waypoint
		humanoid:MoveTo(targetWaypoint)
		
		-- Wait until we reach the waypoint or get stuck
		local waypointTimeout = 4
		local waypointStart = tick()
		
		while tick() - waypointStart < waypointTimeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distToWaypoint = (currentPos - targetWaypoint).Magnitude
			
			-- Check if we reached the waypoint
			if distToWaypoint < 3 then
				waypointReached = true
				print("✅ Reached waypoint " .. currentWaypoint .. "/" .. #waypoints)
				break
			end
			
			-- Check if stuck
			if (currentPos - lastPos).Magnitude < 0.3 then
				stuckCount = stuckCount + 1
				if stuckCount > 15 then -- 1.5 seconds stuck
					print("⚠️ Stuck at waypoint " .. currentWaypoint .. ", teleporting to next...")
					-- Teleport to next waypoint
					rootPart.Anchored = true
					rootPart.CFrame = CFrame.new(targetWaypoint)
					task.wait(0.2)
					rootPart.Anchored = false
					waypointReached = true
					break
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
		end
		
		currentWaypoint = currentWaypoint + 1
	end
	
	-- Final check: make sure we're at the target
	local finalDist = (rootPart.Position - targetPos).Magnitude
	if finalDist > 5 then
		print("⚠️ Didn't reach target! Teleporting directly...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
		return true
	end
	
	print("✅ Successfully walked through hallway!")
	return true
end

-- ============================================
-- TP TO SPAWN
-- ============================================
local function TPtoSpawn()
	if _G.IsTeleportingToSpawn then
		print("⚠️ Already teleporting to spawn!")
		return
	end
	
	_G.IsTeleportingToSpawn = true
	_G.Teleporting = true
	
	local character = getCharacter()
	if not character then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local pos = enterPosition + Vector3.new(0, 4, 0)
	print("🏠 Teleporting to spawn position: " .. tostring(pos))

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
	
	task.wait(0.5)
	_G.IsTeleportingToSpawn = false
	_G.Teleporting = false
	print("✅ Successfully teleported to spawn!")
end

-- ============================================
-- VOID PROTECTION
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if rootPart.Position.Y < -50 then
			print("⚠️ Detected falling into void! Teleporting to spawn...")
			if enterPosition then
				TPtoSpawn()
			else
				local folder = getGeneratedBackrooms()
				if folder then
					local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
					if spawnRoom then
						local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
						if spawnLocation then
							enterPosition = spawnLocation.Position
							TPtoSpawn()
						end
					end
				end
			end
		end
		
		if rootPart.Position.Y < 0 and rootPart.Position.Y > -50 and enterPosition then
			print("⚠️ Character below map! Teleporting to spawn...")
			TPtoSpawn()
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - IMPROVED
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return false
	end

	local character = getCharacter()
	if not character then
		return false
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return false
	end

	-- Find the lock part and door part
	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		print("⚠️ Room already unlocked or no lock found!")
		return true
	end

	-- Get door position and CFrame
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	
	-- The door's LookVector points to the FRONT of the door
	local doorFront = doorCFrame.LookVector
	
	-- Calculate positions
	local frontOffset = doorFront * 8 -- Stand further back for better visibility
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Door Front Direction: " .. tostring(doorFront))
	print("🚪 Teleporting to HALLWAY in front of door at: " .. tostring(teleportPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		-- Teleport to hallway position (in front of door)
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.5)
		rootPart.Anchored = false
	end
	
	print("🔓 Walking to door to unlock...")
	
	-- Walk to the door front
	if humanoid then
		humanoid:MoveTo(doorFrontPos)
		task.wait(1)
	end
	
	-- Try to unlock the door
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	
	task.wait(1)
	
	-- Check if door is unlocked
	local isUnlocked = true
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			isUnlocked = false
			break
		end
	end
	
	if not isUnlocked then
		print("⚠️ Door unlock failed! Trying again...")
		activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
		task.wait(1)
	end
	
	-- Get the target position
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking through door to target position: " .. tostring(targetPos))
	
	-- Walk through to the target
	if humanoid then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
	end
	
	-- Walk through hallway from door to target
	WalkThroughHallway(doorFrontPos, targetPos)
	
	print("✅ Room unlocked and target reached successfully!")
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

-- ============================================
-- FAST EGG HATCHING - 0.01 MILLISECOND (INSTANT)
-- ============================================
local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs in batches of " .. batchSize .. "!")
		else
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				local isMatch = (not targetMult) or room.EggMultiplier >= targetMult

				if isMatch and room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT TO ANOMALY
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("✨ Teleported to Anomaly (250x Egg)!")
	return true
end

-- ============================================
-- TELEPORT TO MINI CHEST
-- ============================================
local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + 2,
		roomCenter.Z
	)
	
	local abovePos = centerPos + Vector3.new(0, 100, 0)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", abovePos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(abovePos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
	
	local actionText = actionType or "Unknown"
	local indexText = roomIndex and (" #" .. roomIndex .. "/" .. #_G.AllMiniChestRooms) or ""
	print("📦 Teleported to CENTER of Mini Chest Room" .. indexText .. " (" .. actionText .. " action)!")
end

-- ============================================
-- ENHANCED TELEPORT TO ROOM - WITH HALLWAY NAVIGATION
-- ============================================
local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	-- Get the target position (egg or boss location)
	local targetPos = nil
	
	-- Find egg if it's an egg room
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- Find boss if it's a boss room
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- If no specific target, use room center
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, 2, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- Get the hallway position (front of door)
	local hallwayPos, doorFrontPos = findHallwayPosition(roomModel)
	
	-- Check if locked room
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		-- Check if room is already unlocked
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			print("🔒 Room is locked! Teleporting to HALLWAY in front of door...")
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				print("⚠️ Failed to unlock room! Teleporting to spawn...")
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			print("✅ Room unlocked and walked to target!")
			return
		else
			print("✅ Room is already unlocked!")
		end
	end

	-- For unlocked rooms or regular rooms, teleport to hallway
	if hallwayPos then
		print("🚪 Teleporting to HALLWAY position: " .. tostring(hallwayPos))
		
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		Network.Fire("RequestStreaming", hallwayPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(hallwayPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		
		-- Walk through hallway to target
		print("🚶 Walking through hallway to target: " .. tostring(targetPos))
		local success = WalkThroughHallway(hallwayPos, targetPos)
		
		if not success then
			print("⚠️ Hallway walk failed! Teleporting directly to target...")
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(targetPos)
			task.wait(0.3)
			rootPart.Anchored = false
		end
	else
		-- No hallway found, teleport directly
		print("⚠️ No hallway found! Teleporting directly to target...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	_G.Teleporting = false
	print("✅ Arrived at target!")
end

-- ============================================
-- GET NEXT MINI CHEST ROOM
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

-- ============================================
-- GET NEAREST MINI CHEST ROOM
-- ============================================
local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - MAX 400 ROOMS
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning...")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			warn("WAITING FOR BACKROOMS...")
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
			warn("SAVED SPAWN POSITION", enterPosition)
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.MiniChestActionType = "Cycle"
	
	local totalScanned = 0
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		local miniChestCount = 0
		local bossCount = 0
		local eggCount = 0
		local lockedEggCount = 0

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local hallwayPos, doorFrontPos = findHallwayPosition(room)
						
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil,
							HallwayPos = hallwayPos,
							DoorFrontPos = doorFrontPos
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						totalScanned = totalScanned + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							bossCount = bossCount + 1
							print("🏠 Found Boss Room #" .. bossCount)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							miniChestCount = miniChestCount + 1
							print("📦 Found Mini Chest Room #" .. miniChestCount .. " (ID: " .. roomId .. ")")
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
							eggCount = eggCount + 1
							print("🥚 Found Free Egg Room #" .. eggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							lockedEggCount = lockedEggCount + 1
							print("🔒 Found Locked Egg Room #" .. lockedEggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepCoinRoom") ~= nil then
							print("💰 Found Coin Room: " .. roomId)
						end
					end
				end
			end
		end
		
		if miniChestCount > 0 then
			print("📦 Total Mini Chest Rooms found: " .. miniChestCount)
		end
		if bossCount > 0 then
			print("👑 Total Boss Rooms found: " .. bossCount)
		end
		if eggCount > 0 then
			print("🥚 Total Free Egg Rooms found: " .. eggCount)
		end
		if lockedEggCount > 0 then
			print("🔒 Total Locked Egg Rooms found: " .. lockedEggCount)
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
				print("No unvisited rooms, exploring random room")
			else
				warn("No rooms found at all!")
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
				
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Use hallway position if available
						local teleportPos = room.HallwayPos or (room.Position + Vector3.new(0, 3, 0))
						Network.Fire("RequestStreaming", teleportPos)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(teleportPos)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
				
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
				
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
				print("📦 Mini Chest Rooms total: " .. #_G.AllMiniChestRooms)
				print("👑 Boss Rooms total: " .. #_G.AllBossRooms)
			end
				
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE FOR BOSS
-- ============================================
local directionArrow = nil
local directionLine = nil
local directionText = nil
local arrowFolder = nil

local function CreateDirectionGuide()
	if arrowFolder then
		arrowFolder:Destroy()
		arrowFolder = nil
	end
	
	arrowFolder = Instance.new("Folder")
	arrowFolder.Name = "DirectionGuide"
	arrowFolder.Parent = workspace.CurrentCamera
	
	directionArrow = Instance.new("Part")
	directionArrow.Name = "Arrow"
	directionArrow.Size = Vector3.new(2, 6, 2)
	directionArrow.Shape = Enum.PartType.Cylinder
	directionArrow.Anchored = true
	directionArrow.CanCollide = false
	directionArrow.Transparency = 0.3
	directionArrow.Material = Enum.Material.Neon
	directionArrow.Color = Color3.fromRGB(255, 50, 50)
	directionArrow.Parent = arrowFolder
	
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(4, 2, 4)
	tip.Shape = Enum.PartType.Cylinder
	tip.Anchored = true
	tip.CanCollide = false
	tip.Transparency = 0.2
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 100, 100)
	tip.Parent = arrowFolder
	
	directionLine = Instance.new("Part")
	directionLine.Name = "Line"
	directionLine.Size = Vector3.new(0.5, 1, 0.5)
	directionLine.Anchored = true
	directionLine.CanCollide = false
	directionLine.Transparency = 0.4
	directionLine.Material = Enum.Material.Neon
	directionLine.Color = Color3.fromRGB(255, 200, 50)
	directionLine.Parent = arrowFolder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DistanceLabel"
	billboard.Adornee = directionArrow
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = arrowFolder
	
	directionText = Instance.new("TextLabel")
	directionText.Size = UDim2.new(1, 0, 1, 0)
	directionText.BackgroundTransparency = 1
	directionText.Text = "👑 BOSS: 0 studs"
	directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
	directionText.TextSize = 16
	directionText.Font = Enum.Font.GothamBold
	directionText.TextStrokeTransparency = 0.3
	directionText.Parent = billboard
	
	task.spawn(function()
		while arrowFolder and arrowFolder.Parent do
			task.wait(0.05)
			if directionArrow then
				local pulse = 0.3 + math.sin(tick() * 3) * 0.15
				directionArrow.Transparency = pulse
				if directionLine then
					directionLine.Transparency = pulse + 0.1
				end
			end
		end
	end)
	
	return arrowFolder
end

local function UpdateDirectionGuide()
	if not _G.ShowDirectionGuide then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if #_G.AllBossRooms == 0 then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if not arrowFolder then
		CreateDirectionGuide()
	end
	
	local character = getCharacter()
	if not character then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local nearestBoss = nil
	local minDist = math.huge
	for _, boss in ipairs(_G.AllBossRooms) do
		local dist = (boss.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearestBoss = boss
		end
	end
	
	if not nearestBoss then
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return
	end
	
	local bossPos = nearestBoss.Position
	local playerPos = rootPart.Position
	local direction = (bossPos - playerPos).Unit
	
	local arrowPos = playerPos + Vector3.new(0, 8, 0)
	local distance = (bossPos - playerPos).Magnitude
	
	if directionArrow and directionArrow.Parent then
		directionArrow.Position = arrowPos
		directionArrow.CFrame = CFrame.lookAt(arrowPos, arrowPos + direction)
		
		local tip = arrowFolder:FindFirstChild("Tip")
		if tip then
			tip.Position = arrowPos + direction * 4
			tip.CFrame = CFrame.lookAt(tip.Position, tip.Position + direction)
		end
		
		if directionLine then
			local midPoint = (playerPos + bossPos) / 2
			local lineLength = distance
			directionLine.Size = Vector3.new(0.5, lineLength, 0.5)
			directionLine.Position = midPoint
			directionLine.CFrame = CFrame.lookAt(midPoint, bossPos)
		end
		
		if directionText then
			local distText = string.format("👑 BOSS: %.0f studs", distance)
			if distance < 50 then
				distText = "👑 BOSS: 🔥 CLOSE! " .. math.floor(distance) .. " studs"
			elseif distance < 100 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs ⬅️"
			elseif distance < 200 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🏃"
			else
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🚀"
			end
			directionText.Text = distText
			
			if distance < 50 then
				directionText.TextColor3 = Color3.fromRGB(255, 50, 50)
			elseif distance < 100 then
				directionText.TextColor3 = Color3.fromRGB(255, 150, 50)
			else
				directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
			end
		end
	end
	
	local angle = math.deg(math.atan2(direction.X, direction.Z))
	local compass = ""
	if angle > -22.5 and angle <= 22.5 then compass = "⬆️ North"
	elseif angle > 22.5 and angle <= 67.5 then compass = "↗️ Northeast"
	elseif angle > 67.5 and angle <= 112.5 then compass = "➡️ East"
	elseif angle > 112.5 and angle <= 157.5 then compass = "↘️ Southeast"
	elseif angle > 157.5 or angle <= -157.5 then compass = "⬇️ South"
	elseif angle > -157.5 and angle <= -112.5 then compass = "↙️ Southwest"
	elseif angle > -112.5 and angle <= -67.5 then compass = "⬅️ West"
	elseif angle > -67.5 and angle <= -22.5 then compass = "↖️ Northwest"
	end
	
	if not UpdateDirectionGuide.lastPrint or tick() - UpdateDirectionGuide.lastPrint > 5 then
		UpdateDirectionGuide.lastPrint = tick()
		print("🎯 BOSS Direction: " .. compass .. " | Distance: " .. math.floor(distance) .. " studs")
	end
end

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			print("✨ Auto teleporting to Anomaly (250x Egg)!")
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP - FAST HATCH SUPPORT (0.01ms delay)
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
				print("🔄 Cycle complete! Starting next cycle with Next Mini...")
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				print("📦 [Phase 1/2] Teleporting to NEXT Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Next")
				end
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				print("📦 [Phase 2/2] Teleporting to NEAREST Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Nearest")
				end
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				else
					print("⏱️ Waiting " .. _G.MiniChestCooldown .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- Direction Guide Update Loop
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- ORIGINAL ANTI AFK METHOD
-- ============================================
localPlayer.Idled:Connect(function()
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI - WITH MINIMIZE AND RED DOT CLICKER
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	-- MINIMIZE BUTTON
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "🗕"
	retractButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	retractButton.TextSize = 12
	retractButton.Font = Enum.Font.GothamBold
	retractButton.ZIndex = 11
	retractButton.Parent = titleBar
	
	local isRetracted = false
	
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 22, 0, 20)
	closeButton.Position = UDim2.new(1, -26, 0, 3)
	closeButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 1
	closeButton.BorderColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.Text = "✕"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
		print("❌ UI Closed")
	end)
	
	closeButton.MouseEnter:Connect(function()
		closeButton.BackgroundTransparency = 0
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.BackgroundTransparency = 0.2
	end)
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		
		button.MouseButton1Click:Connect(callback)
		
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.fromRGB(70, 70, 120)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 0.2
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		end)
		
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	-- Status label
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	-- Room count label
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	-- Buttons
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Free Egg Room found!") end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Locked Egg Room found!") end
	end)
	createButton("✨ TP Anomaly (250x)", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then 
			print("No Boss Room found! Scan first!")
			return 
		end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			print("🚪 Teleporting to Boss Room: " .. nearestBoss.Id)
			TeleportToRoom(nearestBoss.uid)
		else
			print("❌ No Boss Room found near you!")
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
		print("Cleared all scanned rooms")
	end)
	
	-- Toggles
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
		print("Auto Boss: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		print("Auto Hatch: " .. (value and "ON" or "OFF"))
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
		print("Fast Hatch: " .. (value and "ON" or "OFF"))
		if value then
			print("⚡ Fast Hatch: 0.01ms delay (INSTANT!)")
		end
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
		print("Auto Best Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
		print("Auto Locked Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
		print("Auto Anomaly: " .. (value and "ON" or "OFF"))
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
			print("Auto Mini: ON")
		else
			print("Auto Mini: OFF")
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
		print("Infinite Pet Speed: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🚫 No Hatch Anim", function(value)
		if (not canDoAction()) then return end
		
		if workspace.CurrentCamera:FindFirstChild("Eggs") or workspace.CurrentCamera:FindFirstChild("Pets") then
			print("⚠️ Cannot disable hatch animation - Eggs or Pets found in camera")
			return
		end
		
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		if not scripts then
			print("⚠️ PlayerScripts not found")
			return
		end
		
		local scriptInstance = nil
		for _, descendant in ipairs(scripts:GetDescendants()) do
			if descendant.Name == "Egg Opening Frontend" then
				scriptInstance = descendant
				break
			end
		end
		
		if not scriptInstance then
			print("⚠️ Egg Opening Frontend script not found")
			return
		end
		
		scriptInstance.Enabled = (not value)
		_G.DisableHatchAnimation = value
		print("No Hatch Anim: " .. (value and "ON (Disabled hatch animation)" or "OFF (Enabled hatch animation)"))
	end)
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- Clicker section
	createButton("🖱️ Set Clicker Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			print("📍 Click position set to center of screen")
		end
	end)
	
	createToggle("🖱️ Auto Clicker", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	-- RETRACT/MINIMIZE FUNCTIONALITY
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "🎮"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 200, 0, 150)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
			title.Text = "🎮 BR UI"
		end
	end)
	
	-- DRAGGING FUNCTIONALITY
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	
	-- ============================================
	-- RED DOT CLICKER
	-- ============================================
	local screenSize = workspace.CurrentCamera.ViewportSize
	local dotSize = 20
	local dotX = screenSize.X / 2 - dotSize / 2
	local dotY = screenSize.Y / 2 + 50 - dotSize / 2
	
	local redDot = Instance.new("Frame")
	redDot.Name = "RedDot"
	redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
	redDot.Position = UDim2.new(0, dotX, 0, dotY)
	redDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	redDot.BackgroundTransparency = 0.3
	redDot.BorderSizePixel = 1.5
	redDot.BorderColor3 = Color3.fromRGB(255, 0, 0)
	redDot.ZIndex = 999999
	redDot.Parent = screenGui
	
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = redDot
	
	local dotGlow = Instance.new("Frame")
	dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
	dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
	dotGlow.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	dotGlow.BackgroundTransparency = 0.1
	dotGlow.BorderSizePixel = 1
	dotGlow.BorderColor3 = Color3.fromRGB(255, 100, 100)
	dotGlow.ZIndex = 999998
	dotGlow.Parent = redDot
	
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = dotGlow
	
	local dotCenter = Instance.new("Frame")
	dotCenter.Size = UDim2.new(0, 4, 0, 4)
	dotCenter.Position = UDim2.new(0.5, -2, 0.5, -2)
	dotCenter.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.BackgroundTransparency = 0.3
	dotCenter.BorderSizePixel = 1
	dotCenter.BorderColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.ZIndex = 1000000
	dotCenter.Parent = redDot
	
	local dotCenterCorner = Instance.new("UICorner")
	dotCenterCorner.CornerRadius = UDim.new(1, 0)
	dotCenterCorner.Parent = dotCenter
	
	_G.AutoClickerX = dotX + dotSize / 2
	_G.AutoClickerY = dotY + dotSize / 2
	
	local dotDragging = false
	local dotDragStart, dotStartPos
	
	redDot.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dotDragging then
				dotDragging = false
				redDot.BackgroundTransparency = 0.3
			end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseMovement then
			if dotDragging then
				local delta = input.Position - dotDragStart
				local newX = dotStartPos.X.Offset + delta.X
				local newY = dotStartPos.Y.Offset + delta.Y
				local screenSize = workspace.CurrentCamera.ViewportSize
				newX = math.max(0, math.min(newX, screenSize.X - dotSize))
				newY = math.max(0, math.min(newY, screenSize.Y - dotSize))
				redDot.Position = UDim2.new(0, newX, 0, newY)
				_G.AutoClickerX = newX + dotSize / 2
				_G.AutoClickerY = newY + dotSize / 2
			end
		end
	end)
	
	dotGlow.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	redDot.MouseEnter:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.15
			redDot.Size = UDim2.new(0, dotSize + 4, 0, dotSize + 4)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - (dotSize + 4)/2, 0, _G.AutoClickerY - (dotSize + 4)/2)
			dotGlow.Size = UDim2.new(0, dotSize + 10, 0, dotSize + 10)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 10)/2, 0.5, -(dotSize + 10)/2)
		end
	end)
	
	redDot.MouseLeave:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.3
			redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - dotSize/2, 0, _G.AutoClickerY - dotSize/2)
			dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
		end
	end)
	
	return screenGui
end

-- ============================================
-- CREATE UI
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("⚡ Infinite Pet Speed: OFF")
print("🚫 No Hatch Animation: OFF")
print("⚡ Fast Hatch: OFF - 0.01ms delay (INSTANT!)")
print("🖱️ Red Dot Clicker: Drag to position")
print("🗕 Click minimize button to retract UI")
print("=========================================")
print("🚪 HALLWAY NAVIGATION SYSTEM:")
print("   • Finds door position and front direction")
print("   • Teleports to HALLWAY in front of door")
print("   • Walks to door, unlocks with key")
print("   • Walks through to target entity")
print("   • Auto-recovery if stuck")
print("=========================================")
print("🛡️ VOID PROTECTION:")
print("   • Detects falling into void")
print("   • Automatically teleports to spawn")
print("   • Resets teleport flags")
print("=========================================")

-- Start automatic scan after UI loads
task.wait(2)
Scan()-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false

-- ============================================
-- HALLWAY POSITION TRACKING
-- ============================================
local hallwayPositions = {}
local currentHallwayIndex = 1

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

-- ============================================
-- FIND HALLWAY POSITION FOR A ROOM
-- ============================================
local function findHallwayPosition(roomModel)
	-- Look for hallway connection points
	local hallwayPos = nil
	
	-- Check for specific hallway parts
	local hallwayParts = roomModel:FindFirstChild("HallwayParts")
	if hallwayParts then
		for _, part in ipairs(hallwayParts:GetChildren()) do
			if part:IsA("BasePart") then
				hallwayPos = part.Position + Vector3.new(0, 2, 0)
				break
			end
		end
	end
	
	-- If no hallway parts, look for door
	if not hallwayPos then
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock then
					hallwayPos = lock.Position + Vector3.new(0, 2, 0)
					break
				end
			end
		end
	end
	
	-- If still no position, use room position offset
	if not hallwayPos then
		local centerCFrame = roomModel:GetBoundingBox()
		hallwayPos = centerCFrame.Position + Vector3.new(0, 2, 0)
	end
	
	return hallwayPos
end

-- ============================================
-- WALK THROUGH HALLWAY
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	-- Generate waypoints along the path
	local direction = (targetPos - startPos).Unit
	local distance = (targetPos - startPos).Magnitude
	
	-- If distance is small, just move directly
	if distance < 10 then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
		return true
	end
	
	-- Create waypoints every 5 studs
	local waypoints = {}
	local numWaypoints = math.floor(distance / 5)
	
	for i = 1, numWaypoints do
		local t = i / numWaypoints
		local waypoint = startPos + (direction * (distance * t))
		-- Keep the Y position consistent to avoid falling
		waypoint = Vector3.new(waypoint.X, startPos.Y, waypoint.Z)
		table.insert(waypoints, waypoint)
	end
	table.insert(waypoints, targetPos)
	
	print("🚶 Walking through hallway with " .. #waypoints .. " waypoints...")
	
	-- Walk through each waypoint
	local currentWaypoint = 1
	local timeout = 30
	local startTime = tick()
	local stuckCount = 0
	local lastPos = rootPart.Position
	
	while currentWaypoint <= #waypoints and tick() - startTime < timeout do
		local targetWaypoint = waypoints[currentWaypoint]
		
		-- Move to current waypoint
		humanoid:MoveTo(targetWaypoint)
		
		-- Wait until we reach the waypoint or get stuck
		local waypointTimeout = 3
		local waypointStart = tick()
		local reached = false
		
		while tick() - waypointStart < waypointTimeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distToWaypoint = (currentPos - targetWaypoint).Magnitude
			
			-- Check if we reached the waypoint
			if distToWaypoint < 3 then
				reached = true
				print("✅ Reached waypoint " .. currentWaypoint .. "/" .. #waypoints)
				break
			end
			
			-- Check if stuck
			if (currentPos - lastPos).Magnitude < 0.3 then
				stuckCount = stuckCount + 1
				if stuckCount > 10 then -- 1 second stuck
					print("⚠️ Stuck at waypoint " .. currentWaypoint .. ", moving to next...")
					reached = true -- Force move to next waypoint
					break
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
		end
		
		currentWaypoint = currentWaypoint + 1
	end
	
	-- Final check: make sure we're at the target
	local finalDist = (rootPart.Position - targetPos).Magnitude
	if finalDist > 5 then
		print("⚠️ Didn't reach target! Teleporting...")
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
		return true
	end
	
	print("✅ Reached target!")
	return true
end

local function TPtoSpawn()
	if not canDoAction() then
		return
	end

	local character = getCharacter()
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		return
	end

	local pos = enterPosition + Vector3.new(0, 4, 0)

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
end

-- ============================================
-- VOID PROTECTION
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if rootPart.Position.Y < -50 then
			print("⚠️ Detected falling into void! Teleporting to spawn...")
			if enterPosition then
				TPtoSpawn()
			else
				local folder = getGeneratedBackrooms()
				if folder then
					local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
					if spawnRoom then
						local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
						if spawnLocation then
							enterPosition = spawnLocation.Position
							TPtoSpawn()
						end
					end
				end
			end
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - AUTO UNLOCK WITH KEY & WALK TO TARGET
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return
	end

	local character = getCharacter()
	if not character then
		return
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return false
	end

	-- Find the lock part and door part
	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		print("⚠️ Room already unlocked or no lock found!")
		return true
	end

	-- Get door position and CFrame
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	
	-- The door's LookVector points to the FRONT of the door
	local doorFront = doorCFrame.LookVector
	
	-- Teleport to the FRONT of the door
	local frontOffset = doorFront * 5
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Door Front Direction: " .. tostring(doorFront))
	print("🚪 Teleporting to FRONT of door at: " .. tostring(teleportPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	
	task.wait(0.8)
	
	-- Get the target position
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking to target position: " .. tostring(targetPos))
	
	-- Walk through hallway
	WalkThroughHallway(teleportPos, targetPos)
	
	print("✅ Room unlocked and target reached successfully!")
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

-- ============================================
-- FAST EGG HATCHING - 0.01 MILLISECOND (INSTANT)
-- ============================================
local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			-- Fast hatch: hatch in batches of 1000 with 0.01ms delay (basically instant)
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001) -- 0.01 milliseconds (basically instant)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs in batches of " .. batchSize .. "!")
		else
			-- Normal hatch: hatch ALL at once
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				local isMatch = (not targetMult) or room.EggMultiplier >= targetMult

				if isMatch and room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT TO ANOMALY
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("✨ Teleported to Anomaly (250x Egg)!")
	return true
end

-- ============================================
-- TELEPORT TO MINI CHEST
-- ============================================
local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + 2,
		roomCenter.Z
	)
	
	local abovePos = centerPos + Vector3.new(0, 100, 0)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", abovePos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(abovePos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
	
	local actionText = actionType or "Unknown"
	local indexText = roomIndex and (" #" .. roomIndex .. "/" .. #_G.AllMiniChestRooms) or ""
	print("📦 Teleported to CENTER of Mini Chest Room" .. indexText .. " (" .. actionText .. " action)!")
end

-- ============================================
-- TELEPORT TO ROOM - WITH HALLWAY WALKING
-- ============================================
local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	-- Get the target position (egg or boss location)
	local targetPos = nil
	
	-- Find egg if it's an egg room
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- Find boss if it's a boss room
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- If no specific target, use room center
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, 2, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- Get the hallway position (where to teleport to)
	local hallwayPos = findHallwayPosition(roomModel)
	
	-- Check if locked room
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		-- Check if room is already unlocked
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			print("🔒 Room is locked! Teleporting to FRONT of door to unlock...")
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				print("⚠️ Failed to unlock room! Teleporting to spawn...")
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			print("✅ Room unlocked and walked to target!")
			return
		else
			print("✅ Room is already unlocked!")
		end
	end

	-- Teleport to hallway position
	print("🚪 Teleporting to hallway position: " .. tostring(hallwayPos))
	
	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character
	
	Network.Fire("RequestStreaming", hallwayPos)
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(hallwayPos)
	
	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)
	
	task.wait(0.5)
	
	-- Now walk through hallway to target
	print("🚶 Walking through hallway to target: " .. tostring(targetPos))
	WalkThroughHallway(hallwayPos, targetPos)
	
	_G.Teleporting = false
	print("✅ Arrived at target!")
end

-- ============================================
-- GET NEXT MINI CHEST ROOM
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

-- ============================================
-- GET NEAREST MINI CHEST ROOM
-- ============================================
local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - MAX 400 ROOMS
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning...")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			warn("WAITING FOR BACKROOMS...")
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
			warn("SAVED SPAWN POSITION", enterPosition)
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.MiniChestActionType = "Cycle"
	
	local totalScanned = 0
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		local miniChestCount = 0
		local bossCount = 0
		local eggCount = 0
		local lockedEggCount = 0

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil,
							HallwayPos = findHallwayPosition(room) -- Save hallway position
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						totalScanned = totalScanned + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							bossCount = bossCount + 1
							print("🏠 Found Boss Room #" .. bossCount)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							miniChestCount = miniChestCount + 1
							print("📦 Found Mini Chest Room #" .. miniChestCount .. " (ID: " .. roomId .. ")")
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
							eggCount = eggCount + 1
							print("🥚 Found Free Egg Room #" .. eggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							lockedEggCount = lockedEggCount + 1
							print("🔒 Found Locked Egg Room #" .. lockedEggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepCoinRoom") ~= nil then
							print("💰 Found Coin Room: " .. roomId)
						end
					end
				end
			end
		end
		
		if miniChestCount > 0 then
			print("📦 Total Mini Chest Rooms found: " .. miniChestCount)
		end
		if bossCount > 0 then
			print("👑 Total Boss Rooms found: " .. bossCount)
		end
		if eggCount > 0 then
			print("🥚 Total Free Egg Rooms found: " .. eggCount)
		end
		if lockedEggCount > 0 then
			print("🔒 Total Locked Egg Rooms found: " .. lockedEggCount)
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
				print("No unvisited rooms, exploring random room")
			else
				warn("No rooms found at all!")
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
				visitedCount = visitedCount + 1
				
				if not _G.Teleporting then
					_G.Teleporting = true
					local character = getCharacter()
					if character then
						local rootPart = character:FindFirstChild("HumanoidRootPart")
						if rootPart then
							Network.Fire("RequestStreaming", room.Position)
							rootPart.Anchored = true
							rootPart.CFrame = CFrame.new(room.Position) + Vector3.new(0, 3, 0)
							task.wait(0.2)
							rootPart.Anchored = false
						end
					end
					_G.Teleporting = false
				end
				task.wait(0.2)
				RunService.RenderStepped:Wait()
				
				local beforeCount = #_G.ScannedRooms
				scanExistingRooms()
				local afterCount = #_G.ScannedRooms
				
				if afterCount == beforeCount then
					noNewRoomsCount = noNewRoomsCount + 1
				else
					noNewRoomsCount = 0
					print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
					print("📦 Mini Chest Rooms total: " .. #_G.AllMiniChestRooms)
					print("👑 Boss Rooms total: " .. #_G.AllBossRooms)
				end
				
				if noNewRoomsCount > 5 then
					print("No new rooms found, returning to spawn to refresh")
					TPtoSpawn()
					task.wait(0.5)
					noNewRoomsCount = 0
					scanExistingRooms()
				end
			end

			if loopCount % 20 == 0 then
				print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
			end
		end

	_G.IsScanning = false
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE FOR BOSS
-- ============================================
local directionArrow = nil
local directionLine = nil
local directionText = nil
local arrowFolder = nil

local function CreateDirectionGuide()
	if arrowFolder then
		arrowFolder:Destroy()
		arrowFolder = nil
	end
	
	arrowFolder = Instance.new("Folder")
	arrowFolder.Name = "DirectionGuide"
	arrowFolder.Parent = workspace.CurrentCamera
	
	directionArrow = Instance.new("Part")
	directionArrow.Name = "Arrow"
	directionArrow.Size = Vector3.new(2, 6, 2)
	directionArrow.Shape = Enum.PartType.Cylinder
	directionArrow.Anchored = true
	directionArrow.CanCollide = false
	directionArrow.Transparency = 0.3
	directionArrow.Material = Enum.Material.Neon
	directionArrow.Color = Color3.fromRGB(255, 50, 50)
	directionArrow.Parent = arrowFolder
	
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(4, 2, 4)
	tip.Shape = Enum.PartType.Cylinder
	tip.Anchored = true
	tip.CanCollide = false
	tip.Transparency = 0.2
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 100, 100)
	tip.Parent = arrowFolder
	
	directionLine = Instance.new("Part")
	directionLine.Name = "Line"
	directionLine.Size = Vector3.new(0.5, 1, 0.5)
	directionLine.Anchored = true
	directionLine.CanCollide = false
	directionLine.Transparency = 0.4
	directionLine.Material = Enum.Material.Neon
	directionLine.Color = Color3.fromRGB(255, 200, 50)
	directionLine.Parent = arrowFolder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DistanceLabel"
	billboard.Adornee = directionArrow
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = arrowFolder
	
	directionText = Instance.new("TextLabel")
	directionText.Size = UDim2.new(1, 0, 1, 0)
	directionText.BackgroundTransparency = 1
	directionText.Text = "👑 BOSS: 0 studs"
	directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
	directionText.TextSize = 16
	directionText.Font = Enum.Font.GothamBold
	directionText.TextStrokeTransparency = 0.3
	directionText.Parent = billboard
	
	task.spawn(function()
		while arrowFolder and arrowFolder.Parent do
			task.wait(0.05)
			if directionArrow then
				local pulse = 0.3 + math.sin(tick() * 3) * 0.15
				directionArrow.Transparency = pulse
				if directionLine then
					directionLine.Transparency = pulse + 0.1
				end
			end
		end
	end)
	
	return arrowFolder
end

local function UpdateDirectionGuide()
	if not _G.ShowDirectionGuide then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if #_G.AllBossRooms == 0 then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if not arrowFolder then
		CreateDirectionGuide()
	end
	
	local character = getCharacter()
	if not character then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local nearestBoss = nil
	local minDist = math.huge
	for _, boss in ipairs(_G.AllBossRooms) do
		local dist = (boss.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearestBoss = boss
		end
	end
	
	if not nearestBoss then
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return
	end
	
	local bossPos = nearestBoss.Position
	local playerPos = rootPart.Position
	local direction = (bossPos - playerPos).Unit
	
	local arrowPos = playerPos + Vector3.new(0, 8, 0)
	local distance = (bossPos - playerPos).Magnitude
	
	if directionArrow and directionArrow.Parent then
		directionArrow.Position = arrowPos
		directionArrow.CFrame = CFrame.lookAt(arrowPos, arrowPos + direction)
		
		local tip = arrowFolder:FindFirstChild("Tip")
		if tip then
			tip.Position = arrowPos + direction * 4
			tip.CFrame = CFrame.lookAt(tip.Position, tip.Position + direction)
		end
		
		if directionLine then
			local midPoint = (playerPos + bossPos) / 2
			local lineLength = distance
			directionLine.Size = Vector3.new(0.5, lineLength, 0.5)
			directionLine.Position = midPoint
			directionLine.CFrame = CFrame.lookAt(midPoint, bossPos)
		end
		
		if directionText then
			local distText = string.format("👑 BOSS: %.0f studs", distance)
			if distance < 50 then
				distText = "👑 BOSS: 🔥 CLOSE! " .. math.floor(distance) .. " studs"
			elseif distance < 100 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs ⬅️"
			elseif distance < 200 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🏃"
			else
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🚀"
			end
			directionText.Text = distText
			
			if distance < 50 then
				directionText.TextColor3 = Color3.fromRGB(255, 50, 50)
			elseif distance < 100 then
				directionText.TextColor3 = Color3.fromRGB(255, 150, 50)
			else
				directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
			end
		end
	end
	
	local angle = math.deg(math.atan2(direction.X, direction.Z))
	local compass = ""
	if angle > -22.5 and angle <= 22.5 then compass = "⬆️ North"
	elseif angle > 22.5 and angle <= 67.5 then compass = "↗️ Northeast"
	elseif angle > 67.5 and angle <= 112.5 then compass = "➡️ East"
	elseif angle > 112.5 and angle <= 157.5 then compass = "↘️ Southeast"
	elseif angle > 157.5 or angle <= -157.5 then compass = "⬇️ South"
	elseif angle > -157.5 and angle <= -112.5 then compass = "↙️ Southwest"
	elseif angle > -112.5 and angle <= -67.5 then compass = "⬅️ West"
	elseif angle > -67.5 and angle <= -22.5 then compass = "↖️ Northwest"
	end
	
	if not UpdateDirectionGuide.lastPrint or tick() - UpdateDirectionGuide.lastPrint > 5 then
		UpdateDirectionGuide.lastPrint = tick()
		print("🎯 BOSS Direction: " .. compass .. " | Distance: " .. math.floor(distance) .. " studs")
	end
end

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			print("✨ Auto teleporting to Anomaly (250x Egg)!")
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP - FAST HATCH SUPPORT (0.01ms delay)
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
				print("🔄 Cycle complete! Starting next cycle with Next Mini...")
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				print("📦 [Phase 1/2] Teleporting to NEXT Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Next")
				end
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				print("📦 [Phase 2/2] Teleporting to NEAREST Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Nearest")
				end
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				else
					print("⏱️ Waiting " .. _G.MiniChestCooldown .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- Direction Guide Update Loop
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- ORIGINAL ANTI AFK METHOD
-- ============================================
localPlayer.Idled:Connect(function()
	-- ANTI AFK
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI - WITH MINIMIZE AND RED DOT CLICKER
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	-- MINIMIZE BUTTON
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "🗕"
	retractButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	retractButton.TextSize = 12
	retractButton.Font = Enum.Font.GothamBold
	retractButton.ZIndex = 11
	retractButton.Parent = titleBar
	
	local isRetracted = false
	
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 22, 0, 20)
	closeButton.Position = UDim2.new(1, -26, 0, 3)
	closeButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 1
	closeButton.BorderColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.Text = "✕"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
		print("❌ UI Closed")
	end)
	
	closeButton.MouseEnter:Connect(function()
		closeButton.BackgroundTransparency = 0
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.BackgroundTransparency = 0.2
	end)
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		
		button.MouseButton1Click:Connect(callback)
		
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.fromRGB(70, 70, 120)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 0.2
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		end)
		
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	-- Status label
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	-- Room count label
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	-- Buttons
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Free Egg Room found!") end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Locked Egg Room found!") end
	end)
	createButton("✨ TP Anomaly (250x)", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then 
			print("No Boss Room found! Scan first!")
			return 
		end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			print("🚪 Teleporting to Boss Room: " .. nearestBoss.Id)
			TeleportToRoom(nearestBoss.uid)
		else
			print("❌ No Boss Room found near you!")
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
		print("Cleared all scanned rooms")
	end)
	
	-- Toggles
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
		print("Auto Boss: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		print("Auto Hatch: " .. (value and "ON" or "OFF"))
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
		print("Fast Hatch: " .. (value and "ON" or "OFF"))
		if value then
			print("⚡ Fast Hatch: 0.01ms delay (INSTANT!)")
		end
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
		print("Auto Best Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
		print("Auto Locked Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
		print("Auto Anomaly: " .. (value and "ON" or "OFF"))
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
			print("Auto Mini: ON")
		else
			print("Auto Mini: OFF")
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
		print("Infinite Pet Speed: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🚫 No Hatch Anim", function(value)
		if (not canDoAction()) then return end
		
		-- Check if Eggs or Pets exist in camera
		if workspace.CurrentCamera:FindFirstChild("Eggs") or workspace.CurrentCamera:FindFirstChild("Pets") then
			print("⚠️ Cannot disable hatch animation - Eggs or Pets found in camera")
			return
		end
		
		-- Find the Egg Opening Frontend script
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		if not scripts then
			print("⚠️ PlayerScripts not found")
			return
		end
		
		local scriptInstance = nil
		for _, descendant in ipairs(scripts:GetDescendants()) do
			if descendant.Name == "Egg Opening Frontend" then
				scriptInstance = descendant
				break
			end
		end
		
		if not scriptInstance then
			print("⚠️ Egg Opening Frontend script not found")
			return
		end
		
		-- Disable or enable the script
		scriptInstance.Enabled = (not value)
		_G.DisableHatchAnimation = value
		print("No Hatch Anim: " .. (value and "ON (Disabled hatch animation)" or "OFF (Enabled hatch animation)"))
	end)
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- Clicker section
	createButton("🖱️ Set Clicker Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			print("📍 Click position set to center of screen")
		end
	end)
	
	createToggle("🖱️ Auto Clicker", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	-- RETRACT/MINIMIZE FUNCTIONALITY
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "🎮"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 200, 0, 150)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
			title.Text = "🎮 BR UI"
		end
	end)
	
	-- DRAGGING FUNCTIONALITY
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	
	-- ============================================
	-- RED DOT CLICKER
	-- ============================================
	local screenSize = workspace.CurrentCamera.ViewportSize
	local dotSize = 20
	local dotX = screenSize.X / 2 - dotSize / 2
	local dotY = screenSize.Y / 2 + 50 - dotSize / 2
	
	local redDot = Instance.new("Frame")
	redDot.Name = "RedDot"
	redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
	redDot.Position = UDim2.new(0, dotX, 0, dotY)
	redDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	redDot.BackgroundTransparency = 0.3
	redDot.BorderSizePixel = 1.5
	redDot.BorderColor3 = Color3.fromRGB(255, 0, 0)
	redDot.ZIndex = 999999
	redDot.Parent = screenGui
	
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = redDot
	
	local dotGlow = Instance.new("Frame")
	dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
	dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
	dotGlow.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	dotGlow.BackgroundTransparency = 0.1
	dotGlow.BorderSizePixel = 1
	dotGlow.BorderColor3 = Color3.fromRGB(255, 100, 100)
	dotGlow.ZIndex = 999998
	dotGlow.Parent = redDot
	
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = dotGlow
	
	local dotCenter = Instance.new("Frame")
	dotCenter.Size = UDim2.new(0, 4, 0, 4)
	dotCenter.Position = UDim2.new(0.5, -2, 0.5, -2)
	dotCenter.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.BackgroundTransparency = 0.3
	dotCenter.BorderSizePixel = 1
	dotCenter.BorderColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.ZIndex = 1000000
	dotCenter.Parent = redDot
	
	local dotCenterCorner = Instance.new("UICorner")
	dotCenterCorner.CornerRadius = UDim.new(1, 0)
	dotCenterCorner.Parent = dotCenter
	
	_G.AutoClickerX = dotX + dotSize / 2
	_G.AutoClickerY = dotY + dotSize / 2
	
	local dotDragging = false
	local dotDragStart, dotStartPos
	
	redDot.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dotDragging then
				dotDragging = false
				redDot.BackgroundTransparency = 0.3
			end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseMovement then
			if dotDragging then
				local delta = input.Position - dotDragStart
				local newX = dotStartPos.X.Offset + delta.X
				local newY = dotStartPos.Y.Offset + delta.Y
				local screenSize = workspace.CurrentCamera.ViewportSize
				newX = math.max(0, math.min(newX, screenSize.X - dotSize))
				newY = math.max(0, math.min(newY, screenSize.Y - dotSize))
				redDot.Position = UDim2.new(0, newX, 0, newY)
				_G.AutoClickerX = newX + dotSize / 2
				_G.AutoClickerY = newY + dotSize / 2
			end
		end
	end)
	
	dotGlow.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	redDot.MouseEnter:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.15
			redDot.Size = UDim2.new(0, dotSize + 4, 0, dotSize + 4)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - (dotSize + 4)/2, 0, _G.AutoClickerY - (dotSize + 4)/2)
			dotGlow.Size = UDim2.new(0, dotSize + 10, 0, dotSize + 10)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 10)/2, 0.5, -(dotSize + 10)/2)
		end
	end)
	
	redDot.MouseLeave:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.3
			redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - dotSize/2, 0, _G.AutoClickerY - dotSize/2)
			dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
		end
	end)
	
	return screenGui
end

-- ============================================
-- CREATE UI
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("⚡ Infinite Pet Speed: OFF")
print("🚫 No Hatch Animation: OFF")
print("⚡ Fast Hatch: OFF - 0.01ms delay (INSTANT!)")
print("🖱️ Red Dot Clicker: Drag to position")
print("🗕 Click minimize button to retract UI")
print("=========================================")
print("🔒 LOCK DOOR SYSTEM:")
print("   • Pinpoints hallway location during scan")
print("   • Teleports to hallway (not door)")
print("   • Walks through hallway to target")
print("   • Auto-recovery if teleport fails")
print("=========================================")

task.wait(2)
Scan()-- ============================================
-- GLOBAL VARIABLES
-- ============================================
_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
_G.AutoBreakMiniChest = false
_G.UI = nil
_G.AntiAFK = true
_G.ChestSearchRadius = 100
_G.AutoClickerEnabled = false
_G.AutoClickerX = 0
_G.AutoClickerY = 0
_G.AutoClickerInterval = 5
_G.AllBossRooms = {}
_G.AllMiniChestRooms = {}
_G.ShowDirectionGuide = true
_G.AutoTeleportMiniChest = false
_G.AutoTPAnomaly = false
_G.MiniChestCycleIndex = 1
_G.LastMiniChestTeleportTime = 0
_G.MiniChestCooldown = 210
_G.MiniChestCooldownMin = 1
_G.MiniChestCooldownMax = 600
_G.MiniChestActionType = "Cycle"

-- NEW FEATURES
_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.AutoTapper = false
_G.ExecutedScript = nil
_G.FastHatch = false

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

local function TPtoSpawn()
	if not canDoAction() then
		return
	end

	local character = getCharacter()
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		return
	end

	local pos = enterPosition + Vector3.new(0, 4, 0)

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
end

-- ============================================
-- VOID PROTECTION
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if rootPart.Position.Y < -50 then
			print("⚠️ Detected falling into void! Teleporting to spawn...")
			if enterPosition then
				TPtoSpawn()
			else
				local folder = getGeneratedBackrooms()
				if folder then
					local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
					if spawnRoom then
						local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
						if spawnLocation then
							enterPosition = spawnLocation.Position
							TPtoSpawn()
						end
					end
				end
			end
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - AUTO UNLOCK WITH KEY & WALK TO TARGET
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return
	end

	local character = getCharacter()
	if not character then
		return
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return false
	end

	-- Find the lock part and door part
	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		print("⚠️ Room already unlocked or no lock found!")
		return true
	end

	-- Get door position and CFrame
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	
	-- The door's LookVector points to the FRONT of the door
	local doorFront = doorCFrame.LookVector
	
	-- Teleport to the FRONT of the door
	local frontOffset = doorFront * 5
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Door Front Direction: " .. tostring(doorFront))
	print("🚪 Teleporting to FRONT of door at: " .. tostring(teleportPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	
	task.wait(0.8)
	
	-- Get the target position
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking to target position: " .. tostring(targetPos))
	
	if humanoid and rootPart then
		-- WALK to target (not teleport)
		humanoid:MoveTo(targetPos)
		
		-- Keep walking with waypoint updates
		local startTime = tick()
		local timeout = 10
		local lastPos = rootPart.Position
		local stuckCount = 0
		
		while tick() - startTime < timeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distance = (currentPos - targetPos).Magnitude
			
			if distance < 3 then
				print("✅ Reached target position!")
				break
			end
			
			-- Check if stuck
			if (currentPos - lastPos).Magnitude < 0.5 then
				stuckCount = stuckCount + 1
				if stuckCount > 20 then -- 2 seconds stuck
					print("⚠️ Character stuck! Retrying move...")
					humanoid:MoveTo(targetPos)
					stuckCount = 0
				end
			else
				stuckCount = 0
			end
			
			lastPos = currentPos
			
			-- Keep moving towards target
			if distance > 10 then
				humanoid:MoveTo(targetPos)
			end
		end
		
		-- Fallback: teleport if still not there
		local finalDist = (rootPart.Position - targetPos).Magnitude
		if finalDist > 5 then
			print("⚠️ Walking timeout! Teleporting to target...")
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(targetPos)
			task.wait(0.3)
			rootPart.Anchored = false
		end
	end
	
	print("✅ Room unlocked and target reached successfully!")
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

-- ============================================
-- FAST EGG HATCHING - 0.01 MILLISECOND (INSTANT)
-- ============================================
local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			-- Fast hatch: hatch in batches of 1000 with 0.01ms delay (basically instant)
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.00001) -- 0.01 milliseconds (basically instant)
				if totalHatched % 10000 == 0 then
					print("⚡ Fast hatched " .. totalHatched .. "/" .. maxHatch .. " eggs...")
				end
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs in batches of " .. batchSize .. "!")
		else
			-- Normal hatch: hatch ALL at once
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				local isMatch = (not targetMult) or room.EggMultiplier >= targetMult

				if isMatch and room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT TO ANOMALY
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("✨ Teleported to Anomaly (250x Egg)!")
	return true
end

-- ============================================
-- TELEPORT TO MINI CHEST
-- ============================================
local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + 2,
		roomCenter.Z
	)
	
	local abovePos = centerPos + Vector3.new(0, 100, 0)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", abovePos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(abovePos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
	
	local actionText = actionType or "Unknown"
	local indexText = roomIndex and (" #" .. roomIndex .. "/" .. #_G.AllMiniChestRooms) or ""
	print("📦 Teleported to CENTER of Mini Chest Room" .. indexText .. " (" .. actionText .. " action)!")
end

-- ============================================
-- TELEPORT TO ROOM - WALK FROM DOOR TO TARGET
-- ============================================
local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	-- Get the target position (egg or boss location)
	local targetPos = nil
	
	-- Find egg if it's an egg room
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- Find boss if it's a boss room
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- If no specific target, use room center
	if not targetPos then
		local success, centerCFrame = pcall(function()
			return roomModel:GetBoundingBox()
		end)
		if success and centerCFrame then
			targetPos = centerCFrame.Position + Vector3.new(0, 2, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- Check if locked room
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		-- Check if room is already unlocked
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			print("🔒 Room is locked! Teleporting to FRONT of door to unlock...")
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				print("⚠️ Failed to unlock room! Teleporting to spawn...")
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			print("✅ Room unlocked and walked to target!")
			return
		else
			print("✅ Room is already unlocked! Teleporting to FRONT of door and walking in...")
		end
	end

	-- For ALL rooms, teleport to FRONT of door then WALK to target
	-- Find the door
	local doorPart = nil
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	
	if lockedDoors then
		-- Find the door part (first child with a Lock)
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock then
				doorPart = child
				break
			end
		end
	end
	
	-- If we found a door, teleport to its front
	if doorPart then
		local doorPosition = doorPart.Position
		local doorCFrame = doorPart.CFrame
		local doorFront = doorCFrame.LookVector
		
		-- Teleport to the FRONT of the door
		local frontOffset = doorFront * 5
		local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
		
		-- Make sure the position is valid
		if teleportPos.Y > 1000 or teleportPos.Y < -100 then
			print("⚠️ Door position seems invalid! Using room center instead...")
			teleportPos = targetPos + Vector3.new(0, 5, 0)
		end
		
		print("🚪 Teleporting to FRONT of door at: " .. tostring(teleportPos))
		
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		
		-- Now WALK to the target position through the hallway
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and rootPart then
			print("🚶 Walking through hallway to target: " .. tostring(targetPos))
			humanoid:MoveTo(targetPos)
			
			-- Walk with waypoint updates to avoid void
			local startTime = tick()
			local timeout = 10
			local lastPos = rootPart.Position
			local stuckCount = 0
			local pathPoints = {}
			local pointIndex = 1
			
			-- Generate waypoints along the path
			local direction = (targetPos - teleportPos).Unit
			local distance = (targetPos - teleportPos).Magnitude
			local numPoints = math.min(math.floor(distance / 5), 20)
			
			for i = 1, numPoints do
				local t = i / numPoints
				local waypoint = teleportPos + (direction * (distance * t))
				waypoint = Vector3.new(waypoint.X, teleportPos.Y, waypoint.Z) -- Keep same height
				table.insert(pathPoints, waypoint)
			end
			table.insert(pathPoints, targetPos)
			
			while tick() - startTime < timeout do
				task.wait(0.1)
				local currentPos = rootPart.Position
				local distance = (currentPos - targetPos).Magnitude
				
				if distance < 3 then
					print("✅ Reached target position!")
					break
				end
				
				-- Check if stuck
				if (currentPos - lastPos).Magnitude < 0.5 then
					stuckCount = stuckCount + 1
					if stuckCount > 20 then
						print("⚠️ Character stuck! Moving to next waypoint...")
						if pointIndex <= #pathPoints then
							humanoid:MoveTo(pathPoints[pointIndex])
							pointIndex = pointIndex + 1
						else
							humanoid:MoveTo(targetPos)
						end
						stuckCount = 0
					end
				else
					stuckCount = 0
				end
				
				lastPos = currentPos
				
				-- Keep moving towards target
				if distance > 10 and pointIndex <= #pathPoints then
					if (currentPos - pathPoints[pointIndex]).Magnitude < 5 then
						pointIndex = pointIndex + 1
					end
					if pointIndex <= #pathPoints then
						humanoid:MoveTo(pathPoints[pointIndex])
					end
				elseif distance > 10 then
					humanoid:MoveTo(targetPos)
				end
			end
			
			-- Fallback: teleport if still not there
			local finalDist = (rootPart.Position - targetPos).Magnitude
			if finalDist > 5 then
				print("⚠️ Walking timeout! Teleporting to target...")
				rootPart.Anchored = true
				rootPart.CFrame = CFrame.new(targetPos)
				task.wait(0.3)
				rootPart.Anchored = false
			end
		end
		
		_G.Teleporting = false
		print("✅ Arrived at target!")
		return
	end
	
	-- Fallback: If no door found, teleport directly to target
	print("⚠️ No door found! Teleporting directly to target...")
	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character
	
	if targetPos.Y > 1000 or targetPos.Y < -100 then
		targetPos = roomData.Position + Vector3.new(0, 5, 0)
	end
	
	Network.Fire("RequestStreaming", targetPos)
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(targetPos)
	
	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)
	
	_G.Teleporting = false
	print("📌 Teleported to target!")
end

-- ============================================
-- GET NEXT MINI CHEST ROOM
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

-- ============================================
-- GET NEAREST MINI CHEST ROOM
-- ============================================
local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - MAX 400 ROOMS
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning...")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			warn("WAITING FOR BACKROOMS...")
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
			warn("SAVED SPAWN POSITION", enterPosition)
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.MiniChestActionType = "Cycle"
	
	local totalScanned = 0
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		local miniChestCount = 0
		local bossCount = 0
		local eggCount = 0
		local lockedEggCount = 0

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						totalScanned = totalScanned + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							bossCount = bossCount + 1
							print("🏠 Found Boss Room #" .. bossCount)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							miniChestCount = miniChestCount + 1
							print("📦 Found Mini Chest Room #" .. miniChestCount .. " (ID: " .. roomId .. ")")
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
							eggCount = eggCount + 1
							print("🥚 Found Free Egg Room #" .. eggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							lockedEggCount = lockedEggCount + 1
							print("🔒 Found Locked Egg Room #" .. lockedEggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepCoinRoom") ~= nil then
							print("💰 Found Coin Room: " .. roomId)
						end
					end
				end
			end
		end
		
		if miniChestCount > 0 then
			print("📦 Total Mini Chest Rooms found: " .. miniChestCount)
		end
		if bossCount > 0 then
			print("👑 Total Boss Rooms found: " .. bossCount)
		end
		if eggCount > 0 then
			print("🥚 Total Free Egg Rooms found: " .. eggCount)
		end
		if lockedEggCount > 0 then
			print("🔒 Total Locked Egg Rooms found: " .. lockedEggCount)
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
				print("No unvisited rooms, exploring random room")
			else
				warn("No rooms found at all!")
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
			
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						Network.Fire("RequestStreaming", room.Position)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(room.Position) + Vector3.new(0, 3, 0)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
			
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
			
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
				print("📦 Mini Chest Rooms total: " .. #_G.AllMiniChestRooms)
				print("👑 Boss Rooms total: " .. #_G.AllBossRooms)
			end
			
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE FOR BOSS
-- ============================================
local directionArrow = nil
local directionLine = nil
local directionText = nil
local arrowFolder = nil

local function CreateDirectionGuide()
	if arrowFolder then
		arrowFolder:Destroy()
		arrowFolder = nil
	end
	
	arrowFolder = Instance.new("Folder")
	arrowFolder.Name = "DirectionGuide"
	arrowFolder.Parent = workspace.CurrentCamera
	
	directionArrow = Instance.new("Part")
	directionArrow.Name = "Arrow"
	directionArrow.Size = Vector3.new(2, 6, 2)
	directionArrow.Shape = Enum.PartType.Cylinder
	directionArrow.Anchored = true
	directionArrow.CanCollide = false
	directionArrow.Transparency = 0.3
	directionArrow.Material = Enum.Material.Neon
	directionArrow.Color = Color3.fromRGB(255, 50, 50)
	directionArrow.Parent = arrowFolder
	
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(4, 2, 4)
	tip.Shape = Enum.PartType.Cylinder
	tip.Anchored = true
	tip.CanCollide = false
	tip.Transparency = 0.2
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 100, 100)
	tip.Parent = arrowFolder
	
	directionLine = Instance.new("Part")
	directionLine.Name = "Line"
	directionLine.Size = Vector3.new(0.5, 1, 0.5)
	directionLine.Anchored = true
	directionLine.CanCollide = false
	directionLine.Transparency = 0.4
	directionLine.Material = Enum.Material.Neon
	directionLine.Color = Color3.fromRGB(255, 200, 50)
	directionLine.Parent = arrowFolder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DistanceLabel"
	billboard.Adornee = directionArrow
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = arrowFolder
	
	directionText = Instance.new("TextLabel")
	directionText.Size = UDim2.new(1, 0, 1, 0)
	directionText.BackgroundTransparency = 1
	directionText.Text = "👑 BOSS: 0 studs"
	directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
	directionText.TextSize = 16
	directionText.Font = Enum.Font.GothamBold
	directionText.TextStrokeTransparency = 0.3
	directionText.Parent = billboard
	
	task.spawn(function()
		while arrowFolder and arrowFolder.Parent do
			task.wait(0.05)
			if directionArrow then
				local pulse = 0.3 + math.sin(tick() * 3) * 0.15
				directionArrow.Transparency = pulse
				if directionLine then
					directionLine.Transparency = pulse + 0.1
				end
			end
		end
	end)
	
	return arrowFolder
end

local function UpdateDirectionGuide()
	if not _G.ShowDirectionGuide then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if #_G.AllBossRooms == 0 then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if not arrowFolder then
		CreateDirectionGuide()
	end
	
	local character = getCharacter()
	if not character then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local nearestBoss = nil
	local minDist = math.huge
	for _, boss in ipairs(_G.AllBossRooms) do
		local dist = (boss.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearestBoss = boss
		end
	end
	
	if not nearestBoss then
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return
	end
	
	local bossPos = nearestBoss.Position
	local playerPos = rootPart.Position
	local direction = (bossPos - playerPos).Unit
	
	local arrowPos = playerPos + Vector3.new(0, 8, 0)
	local distance = (bossPos - playerPos).Magnitude
	
	if directionArrow and directionArrow.Parent then
		directionArrow.Position = arrowPos
		directionArrow.CFrame = CFrame.lookAt(arrowPos, arrowPos + direction)
		
		local tip = arrowFolder:FindFirstChild("Tip")
		if tip then
			tip.Position = arrowPos + direction * 4
			tip.CFrame = CFrame.lookAt(tip.Position, tip.Position + direction)
		end
		
		if directionLine then
			local midPoint = (playerPos + bossPos) / 2
			local lineLength = distance
			directionLine.Size = Vector3.new(0.5, lineLength, 0.5)
			directionLine.Position = midPoint
			directionLine.CFrame = CFrame.lookAt(midPoint, bossPos)
		end
		
		if directionText then
			local distText = string.format("👑 BOSS: %.0f studs", distance)
			if distance < 50 then
				distText = "👑 BOSS: 🔥 CLOSE! " .. math.floor(distance) .. " studs"
			elseif distance < 100 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs ⬅️"
			elseif distance < 200 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🏃"
			else
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🚀"
			end
			directionText.Text = distText
			
			if distance < 50 then
				directionText.TextColor3 = Color3.fromRGB(255, 50, 50)
			elseif distance < 100 then
				directionText.TextColor3 = Color3.fromRGB(255, 150, 50)
			else
				directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
			end
		end
	end
	
	local angle = math.deg(math.atan2(direction.X, direction.Z))
	local compass = ""
	if angle > -22.5 and angle <= 22.5 then compass = "⬆️ North"
	elseif angle > 22.5 and angle <= 67.5 then compass = "↗️ Northeast"
	elseif angle > 67.5 and angle <= 112.5 then compass = "➡️ East"
	elseif angle > 112.5 and angle <= 157.5 then compass = "↘️ Southeast"
	elseif angle > 157.5 or angle <= -157.5 then compass = "⬇️ South"
	elseif angle > -157.5 and angle <= -112.5 then compass = "↙️ Southwest"
	elseif angle > -112.5 and angle <= -67.5 then compass = "⬅️ West"
	elseif angle > -67.5 and angle <= -22.5 then compass = "↖️ Northwest"
	end
	
	if not UpdateDirectionGuide.lastPrint or tick() - UpdateDirectionGuide.lastPrint > 5 then
		UpdateDirectionGuide.lastPrint = tick()
		print("🎯 BOSS Direction: " .. compass .. " | Distance: " .. math.floor(distance) .. " studs")
	end
end

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			print("✨ Auto teleporting to Anomaly (250x Egg)!")
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP - FAST HATCH SUPPORT (0.01ms delay)
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
				print("🔄 Cycle complete! Starting next cycle with Next Mini...")
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				print("📦 [Phase 1/2] Teleporting to NEXT Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Next")
				end
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				print("📦 [Phase 2/2] Teleporting to NEAREST Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Nearest")
				end
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				else
					print("⏱️ Waiting " .. _G.MiniChestCooldown .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- Direction Guide Update Loop
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- ORIGINAL ANTI AFK METHOD
-- ============================================
localPlayer.Idled:Connect(function()
	-- ANTI AFK
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI - WITH MINIMIZE AND RED DOT CLICKER
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	-- MINIMIZE BUTTON
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "🗕"
	retractButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	retractButton.TextSize = 12
	retractButton.Font = Enum.Font.GothamBold
	retractButton.ZIndex = 11
	retractButton.Parent = titleBar
	
	local isRetracted = false
	
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 22, 0, 20)
	closeButton.Position = UDim2.new(1, -26, 0, 3)
	closeButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 1
	closeButton.BorderColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.Text = "✕"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
		print("❌ UI Closed")
	end)
	
	closeButton.MouseEnter:Connect(function()
		closeButton.BackgroundTransparency = 0
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.BackgroundTransparency = 0.2
	end)
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		
		button.MouseButton1Click:Connect(callback)
		
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.fromRGB(70, 70, 120)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 0.2
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		end)
		
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	-- Status label
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	-- Room count label
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	-- Buttons
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Free Egg Room found!") end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Locked Egg Room found!") end
	end)
	createButton("✨ TP Anomaly (250x)", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then 
			print("No Boss Room found! Scan first!")
			return 
		end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then
			print("🚪 Teleporting to Boss Room: " .. nearestBoss.Id)
			TeleportToRoom(nearestBoss.uid)
		else
			print("❌ No Boss Room found near you!")
		end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		 _G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
		print("Cleared all scanned rooms")
	end)
	
	-- Toggles
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
		print("Auto Boss: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		print("Auto Hatch: " .. (value and "ON" or "OFF"))
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
		print("Fast Hatch: " .. (value and "ON" or "OFF"))
		if value then
			print("⚡ Fast Hatch: 0.01ms delay (INSTANT!)")
		end
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
		print("Auto Best Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
		print("Auto Locked Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
		print("Auto Anomaly: " .. (value and "ON" or "OFF"))
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
			print("Auto Mini: ON")
		else
			print("Auto Mini: OFF")
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
		print("Infinite Pet Speed: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🚫 No Hatch Anim", function(value)
		if (not canDoAction()) then return end
		
		-- Check if Eggs or Pets exist in camera
		if workspace.CurrentCamera:FindFirstChild("Eggs") or workspace.CurrentCamera:FindFirstChild("Pets") then
			print("⚠️ Cannot disable hatch animation - Eggs or Pets found in camera")
			return
		end
		
		-- Find the Egg Opening Frontend script
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		if not scripts then
			print("⚠️ PlayerScripts not found")
			return
		end
		
		local scriptInstance = nil
		for _, descendant in ipairs(scripts:GetDescendants()) do
			if descendant.Name == "Egg Opening Frontend" then
				scriptInstance = descendant
				break
			end
		end
		
		if not scriptInstance then
			print("⚠️ Egg Opening Frontend script not found")
			return
		end
		
		-- Disable or enable the script
		scriptInstance.Enabled = (not value)
		_G.DisableHatchAnimation = value
		print("No Hatch Anim: " .. (value and "ON (Disabled hatch animation)" or "OFF (Enabled hatch animation)"))
	end)
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- Clicker section
	createButton("🖱️ Set Clicker Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			print("📍 Click position set to center of screen")
		end
	end)
	
	createToggle("🖱️ Auto Clicker", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	-- RETRACT/MINIMIZE FUNCTIONALITY
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "🎮"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 200, 0, 150)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
			title.Text = "🎮 BR UI"
		end
	end)
	
	-- DRAGGING FUNCTIONALITY
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	
	-- ============================================
	-- RED DOT CLICKER
	-- ============================================
	local screenSize = workspace.CurrentCamera.ViewportSize
	local dotSize = 20
	local dotX = screenSize.X / 2 - dotSize / 2
	local dotY = screenSize.Y / 2 + 50 - dotSize / 2
	
	local redDot = Instance.new("Frame")
	redDot.Name = "RedDot"
	redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
	redDot.Position = UDim2.new(0, dotX, 0, dotY)
	redDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	redDot.BackgroundTransparency = 0.3
	redDot.BorderSizePixel = 1.5
	redDot.BorderColor3 = Color3.fromRGB(255, 0, 0)
	redDot.ZIndex = 999999
	redDot.Parent = screenGui
	
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = redDot
	
	local dotGlow = Instance.new("Frame")
	dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
	dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
	dotGlow.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	dotGlow.BackgroundTransparency = 0.1
	dotGlow.BorderSizePixel = 1
	dotGlow.BorderColor3 = Color3.fromRGB(255, 100, 100)
	dotGlow.ZIndex = 999998
	dotGlow.Parent = redDot
	
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = dotGlow
	
	local dotCenter = Instance.new("Frame")
	dotCenter.Size = UDim2.new(0, 4, 0, 4)
	dotCenter.Position = UDim2.new(0.5, -2, 0.5, -2)
	dotCenter.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.BackgroundTransparency = 0.3
	dotCenter.BorderSizePixel = 1
	dotCenter.BorderColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.ZIndex = 1000000
	dotCenter.Parent = redDot
	
	local dotCenterCorner = Instance.new("UICorner")
	dotCenterCorner.CornerRadius = UDim.new(1, 0)
	dotCenterCorner.Parent = dotCenter
	
	_G.AutoClickerX = dotX + dotSize / 2
	_G.AutoClickerY = dotY + dotSize / 2
	
	local dotDragging = false
	local dotDragStart, dotStartPos
	
	redDot.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dotDragging then
				dotDragging = false
				redDot.BackgroundTransparency = 0.3
			end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseMovement then
			if dotDragging then
				local delta = input.Position - dotDragStart
				local newX = dotStartPos.X.Offset + delta.X
				local newY = dotStartPos.Y.Offset + delta.Y
				local screenSize = workspace.CurrentCamera.ViewportSize
				newX = math.max(0, math.min(newX, screenSize.X - dotSize))
				newY = math.max(0, math.min(newY, screenSize.Y - dotSize))
				redDot.Position = UDim2.new(0, newX, 0, newY)
				_G.AutoClickerX = newX + dotSize / 2
				_G.AutoClickerY = newY + dotSize / 2
			end
		end
	end)
	
	dotGlow.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	redDot.MouseEnter:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.15
			redDot.Size = UDim2.new(0, dotSize + 4, 0, dotSize + 4)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - (dotSize + 4)/2, 0, _G.AutoClickerY - (dotSize + 4)/2)
			dotGlow.Size = UDim2.new(0, dotSize + 10, 0, dotSize + 10)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 10)/2, 0.5, -(dotSize + 10)/2)
		end
	end)
	
	redDot.MouseLeave:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.3
			redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - dotSize/2, 0, _G.AutoClickerY - dotSize/2)
			dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
		end
	end)
	
	return screenGui
end

-- ============================================
-- CREATE UI
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("⚡ Infinite Pet Speed: OFF")
print("🚫 No Hatch Animation: OFF")
print("⚡ Fast Hatch: OFF - 0.01ms delay (INSTANT!)")
print("🖱️ Red Dot Clicker: Drag to position")
print("🗕 Click minimize button to retract UI")
print("=========================================")
print("🔒 LOCK DOOR SYSTEM:")
print("   • Teleports to FRONT of door")
print("   • Unlocks with key if needed")
print("   • WALKS through hallway to target (no void)")
print("   • Waypoint navigation to stay safe")
print("=========================================")

task.wait(2)
Scan()_G.FastHatch = false

-- ============================================
-- AUTO MINI CHEST FIX - NEW VARIABLES
-- ============================================
local autoMiniLastActionTime = 0
local autoMiniInitialized = false
local autoMiniPhase = "Next"

-- ============================================
-- INFINITE PET SPEED
-- ============================================
local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================
local function getCharacter()
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

local function canDoAction()
	return (not _G.IsScanning) and (not _G.Teleporting)
end

local function createMessage(msg)
	if workspace:FindFirstChildOfClass("Message") then
		return
	end
	local message = Instance.new("Message", workspace)
	message.Text = msg
	return message
end

local function serverHop(reason)
	local message = createMessage(reason)

	local success = pcall(function()
		local api = "https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100"

		local function list(cursor)
			local Raw = game:HttpGet(api .. ((cursor and "&cursor=" .. cursor) or ""))
			return HttpService:JSONDecode(Raw)
		end

		local servers = list()
		for _, server in ipairs(servers.data) do
			if server.playing < server.maxPlayers and server.id ~= game.JobId then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, localPlayer)
				return true
			end
		end
	end)

	if not success then
		TeleportService:Teleport(game.PlaceId, localPlayer)
	else
		game.Debris:AddItem(message, 10)
	end
end

local function getGeneratedBackrooms()
	local container = workspace:FindFirstChild("__THINGS")
	if not container then return nil end
	
	local instanceContainer = container:FindFirstChild("__INSTANCE_CONTAINER")
	if not instanceContainer then return nil end

	local active = instanceContainer:FindFirstChild("Active")
	if not active then return nil end

	local backrooms = active:FindFirstChild("Backrooms")
	if not backrooms then return nil end

	return backrooms:FindFirstChild("GeneratedBackrooms")
end

local function findRoomDataByUID(roomUID)
	return _G.ScannedRoomsMap[roomUID]
end

local function TPtoSpawn()
	if not canDoAction() then
		return
	end

	local character = getCharacter()
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	if typeof(enterPosition) ~= "Vector3" then
		print("No spawn found. Please scan rooms first!")
		return
	end

	local pos = enterPosition + Vector3.new(0, 4, 0)

	Network.Fire("RequestStreaming", pos)

	task.delay(0.25, function()
		if character.Parent then
			if rootPart.Anchored == true then
				rootPart.Anchored = false
			end
			character:PivotTo(CFrame.new(pos))
		end
	end)
	
	isInMiniChestRoom = false
	currentMiniChestRoomUID = nil
	isOnRoof = false
	miniChestIndex = 1
end

-- ============================================
-- VOID PROTECTION
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if rootPart.Position.Y < -50 then
			print("⚠️ Detected falling into void! Teleporting to spawn...")
			if enterPosition then
				TPtoSpawn()
			else
				local folder = getGeneratedBackrooms()
				if folder then
					local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
					if spawnRoom then
						local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
						if spawnLocation then
							enterPosition = spawnLocation.Position
							TPtoSpawn()
						end
					end
				end
			end
		end
	end
end)

-- ============================================
-- LOCK DOOR SYSTEM - AUTO UNLOCK WITH KEY & WALK TO TARGET
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

local function UnlockRoom(roomUID, targetPosition)
	if _G.IsScanning == true then
		return
	end

	local character = getCharacter()
	if not character then
		return
	end

	local ownsKey = keyCheck()
	if not ownsKey then
		print("⚠️ No key found! Cannot unlock room.")
		return false
	end

	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return false
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return false
	end

	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return false
	end

	-- Find the lock part and door part
	local lockedPart = nil
	local doorPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			doorPart = child
			break
		end
	end

	if not lockedPart then
		print("⚠️ Room already unlocked or no lock found!")
		return true
	end

	-- Get door position and CFrame
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	
	-- The door's LookVector points to the FRONT of the door
	-- FRONT = doorCFrame.LookVector (faces into the room)
	local doorFront = doorCFrame.LookVector
	
	-- Teleport to the FRONT of the door (where the lock is accessible)
	local frontOffset = doorFront * 5  -- 5 studs in front
	local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Door Front Direction: " .. tostring(doorFront))
	print("🚪 Teleporting to FRONT of door at: " .. tostring(teleportPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	if rootPart then
		-- Teleport to front of door
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	
	-- Wait for door to unlock
	task.wait(0.8)
	
	-- Get the target position (either provided or room center)
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking to target position: " .. tostring(targetPos))
	
	if humanoid and rootPart then
		-- Move to target
		humanoid:MoveTo(targetPos)
		
		-- Wait for walking with timeout
		local timeout = 5
		local startTime = tick()
		local reachedTarget = false
		
		while tick() - startTime < timeout do
			task.wait(0.1)
			local currentPos = rootPart.Position
			local distance = (currentPos - targetPos).Magnitude
			
			if distance < 5 then
				reachedTarget = true
				print("✅ Reached target position!")
				break
			end
			
			if distance > 50 then
				print("⚠️ Character seems stuck, retrying move...")
				humanoid:MoveTo(targetPos)
			end
		end
		
		if not reachedTarget then
			print("⚠️ Walking timeout! Teleporting to target...")
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(targetPos)
			task.wait(0.3)
			rootPart.Anchored = false
		end
	end
	
	print("✅ Room unlocked and target reached successfully!")
	return true
end

-- ============================================
-- EGG SYSTEM FUNCTIONS
-- ============================================
local function getNearestEgg(character)
	if character == nil then
		return
	end

	local closestEgg = nil
	local minDist = 40

	for _, egg in pairs(CustomEggsCmds.All()) do
		if egg._position then
			local dist = (egg._position - character:GetPivot().Position).Magnitude
			if dist < minDist then
				minDist = dist
				closestEgg = egg
			end
		end
	end

	return closestEgg
end

-- ============================================
-- FAST EGG HATCHING - BATCH 1000
-- ============================================
local function FastHatchEgg(egg)
	if not egg then return end
	
	pcall(function()
		local maxHatch = EggCmds.GetMaxHatch(egg._dir)
		
		if _G.FastHatch then
			-- Fast hatch: hatch in batches of 1000 for maximum speed
			local batchSize = 1000
			local totalHatched = 0
			
			for i = 1, maxHatch, batchSize do
				local hatchCount = math.min(batchSize, maxHatch - i + 1)
				Network.Invoke("CustomEggs_Hatch", egg._uid, hatchCount)
				totalHatched = totalHatched + hatchCount
				task.wait(0.01) -- Very fast!
			end
			print("⚡ Fast hatched " .. totalHatched .. " eggs in batches of " .. batchSize .. "!")
		else
			-- Normal hatch: hatch ALL at once
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
			print("🥚 Hatched " .. maxHatch .. " eggs!")
		end
	end)
end

local function getBestEggRoom()
	local bestRoom = nil
	local maxMult = -1

	for _, room in ipairs(_G.ScannedRooms) do
		if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier ~= nil then
			if room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end

	return bestRoom
end

local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil

	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			if (not room.ExpireTime) or (room.ExpireTime - workspace:GetServerTimeNow() > 0) then
				local isMatch = (not targetMult) or room.EggMultiplier >= targetMult

				if isMatch and room.EggMultiplier > maxMult then
					maxMult = room.EggMultiplier
					bestRoom = room
				end
			end
		end
	end

	return bestRoom
end

-- ============================================
-- TELEPORT TO ANOMALY
-- ============================================
local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		print("⚠️ No active anomaly found!")
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
		print("⚠️ Anomaly position not found!")
		return false
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return false
	end

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("✨ Teleported to Anomaly (250x Egg)!")
	return true
end

-- ============================================
-- TELEPORT TO MINI CHEST
-- ============================================
local function TeleportToMiniChestAbove(roomUID, roomIndex, actionType)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	
	local centerCFrame, roomSize = roomModel:GetBoundingBox()
	local roomCenter = centerCFrame.Position
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	local centerPos = Vector3.new(
		roomCenter.X,
		roomCenter.Y + 2,
		roomCenter.Z
	)
	
	local abovePos = centerPos + Vector3.new(0, 100, 0)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", abovePos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(abovePos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	_G.LastMiniChestTeleportTime = tick()
	
	local actionText = actionType or "Unknown"
	local indexText = roomIndex and (" #" .. roomIndex .. "/" .. #_G.AllMiniChestRooms) or ""
	print("📦 Teleported to CENTER of Mini Chest Room" .. indexText .. " (" .. actionText .. " action)!")
end

-- ============================================
-- TELEPORT TO ROOM - ALWAYS GO TO DOOR FIRST, THEN WALK
-- ============================================
local function TeleportToRoom(roomUID)
	if _G.Teleporting then
		return
	end

	_G.Teleporting = true

	local character = getCharacter()
	if not character then
		_G.Teleporting = false
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.Teleporting = false
		return
	end

	local roomData = findRoomDataByUID(roomUID)
	if not roomData then
		warn("NO ROOM DATA")
		_G.Teleporting = false
		return
	end

	local roomModel = roomData.Model
	local roomId = roomData.Id

	-- Get the target position (egg or boss location)
	local targetPos = nil
	
	-- Find egg if it's an egg room
	if roomId == "DeepLockedEggRoom" then
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- Find boss if it's a boss room
	if roomId == "GameMastersStage" then
		local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
		if breakZone then
			targetPos = breakZone:GetPivot().Position + Vector3.new(0, 2, 0)
		end
	end
	
	-- If no specific target, use room center
	if not targetPos then
		local centerCFrame, roomSize = roomModel:GetBoundingBox()
		targetPos = centerCFrame.Position + Vector3.new(0, 2, 0)
	end
	
	-- Check if locked room
	local isLockedRoom = (roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage")
	
	if isLockedRoom then
		-- Check if room is already unlocked
		local lockedDoors = roomModel:FindFirstChild("LockedDoors")
		local isUnlocked = true
		
		if lockedDoors then
			for _, child in ipairs(lockedDoors:GetChildren()) do
				local lock = child:FindFirstChild("Lock")
				if lock and lock.Transparency < 1 then
					isUnlocked = false
					break
				end
			end
		end
		
		if not isUnlocked then
			print("🔒 Room is locked! Teleporting to FRONT of door to unlock...")
			local unlocked = UnlockRoom(roomUID, targetPos)
			if not unlocked then
				print("⚠️ Failed to unlock room! Teleporting to spawn...")
				TPtoSpawn()
				_G.Teleporting = false
				return
			end
			task.wait(0.5)
			_G.Teleporting = false
			print("✅ Room unlocked and walked to target!")
			return
		else
			print("✅ Room is already unlocked! Teleporting to FRONT of door and walking in...")
		end
	end

	-- For ALL rooms (locked or unlocked), teleport to FRONT of door then walk to target
	-- Find the door
	local doorPart = nil
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	
	if lockedDoors then
		-- Find the door part (first child with a Lock)
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock then
				doorPart = child
				break
			end
		end
	end
	
	-- If we found a door, teleport to its front
	if doorPart then
		local doorPosition = doorPart.Position
		local doorCFrame = doorPart.CFrame
		local doorFront = doorCFrame.LookVector
		
		-- Teleport to the FRONT of the door
		local frontOffset = doorFront * 5  -- 5 studs in front
		local teleportPos = doorPosition + frontOffset + Vector3.new(0, 2, 0)
		
		print("🚪 Teleporting to FRONT of door at: " .. tostring(teleportPos))
		
		local forceField = Instance.new("ForceField")
		forceField.Visible = false
		forceField.Parent = character
		
		Network.Fire("RequestStreaming", teleportPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(teleportPos)
		
		task.delay(1.5, function()
			if forceField and forceField.Parent then 
				forceField:Destroy() 
			end
			rootPart.Anchored = false
		end)
		
		task.wait(0.5)
		
		-- Now WALK to the target position
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid and rootPart then
			print("🚶 Walking to target position: " .. tostring(targetPos))
			humanoid:MoveTo(targetPos)
			
			-- Wait for walking with timeout
			local timeout = 5
			local startTime = tick()
			local reachedTarget = false
			
			while tick() - startTime < timeout do
				task.wait(0.1)
				local currentPos = rootPart.Position
				local distance = (currentPos - targetPos).Magnitude
				
				if distance < 5 then
					reachedTarget = true
					print("✅ Reached target position!")
					break
				end
				
				if distance > 50 then
					print("⚠️ Character seems stuck, retrying move...")
					humanoid:MoveTo(targetPos)
				end
			end
			
			if not reachedTarget then
				print("⚠️ Walking timeout! Teleporting to target...")
				rootPart.Anchored = true
				rootPart.CFrame = CFrame.new(targetPos)
				task.wait(0.3)
				rootPart.Anchored = false
			end
		end
		
		_G.Teleporting = false
		print("✅ Arrived at target!")
		return
	end
	
	-- Fallback: If no door found, teleport directly to target
	print("⚠️ No door found! Teleporting directly to target...")
	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character
	
	Network.Fire("RequestStreaming", targetPos)
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(targetPos)
	
	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)
	
	_G.Teleporting = false
	print("📌 Teleported to target!")
end

-- ============================================
-- GET NEXT MINI CHEST ROOM
-- ============================================
local function GetNextMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local room = _G.AllMiniChestRooms[_G.MiniChestCycleIndex]
	local index = _G.MiniChestCycleIndex
	
	_G.MiniChestCycleIndex = _G.MiniChestCycleIndex + 1
	if _G.MiniChestCycleIndex > #_G.AllMiniChestRooms then
		_G.MiniChestCycleIndex = 1
	end
	
	return room, index
end

-- ============================================
-- GET NEAREST MINI CHEST ROOM
-- ============================================
local function GetNearestMiniChestRoom()
	if #_G.AllMiniChestRooms == 0 then
		return nil
	end
	
	local character = getCharacter()
	if not character then return _G.AllMiniChestRooms[1], 1 end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return _G.AllMiniChestRooms[1], 1 end
	
	local nearest = nil
	local minDist = math.huge
	local nearestIndex = 1
	
	for i, mini in ipairs(_G.AllMiniChestRooms) do
		local dist = (mini.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearest = mini
			nearestIndex = i
		end
	end
	
	return nearest, nearestIndex
end

-- ============================================
-- SCAN FUNCTION - MAX 400 ROOMS
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true

	local message = createMessage("Exploring the backrooms...")
	print("Starting FAST scan...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning...")
	end

	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			warn("WAITING FOR BACKROOMS...")
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
	if spawnRoom then
		local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
		if spawnLocation then
			enterPosition = spawnLocation.Position
			warn("SAVED SPAWN POSITION", enterPosition)
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.MiniChestActionType = "Cycle"
	
	local totalScanned = 0
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 
		end

		local miniChestCount = 0
		local bossCount = 0
		local eggCount = 0
		local lockedEggCount = 0

		for _, room in ipairs(folder:GetChildren()) do
			if room:GetAttribute("DeepRoom") == true then
				local roomUID = room:GetAttribute("RoomUID")
				if roomUID then
					local existing = _G.ScannedRoomsMap[roomUID]
					local roomId = room:GetAttribute("RoomID")
					local roomCFrame = room:GetPivot()

					if not existing then
						local mult = room:GetAttribute("EggMultiplier") or 0
						local roomData = {
							uid = roomUID,
							Id = roomId,
							Model = room,
							CFrame = roomCFrame,
							Position = roomCFrame.Position,
							EggMultiplier = mult > 0 and mult or nil
						}

						table.insert(_G.ScannedRooms, roomData)
						_G.ScannedRoomsMap[roomUID] = roomData
						totalScanned = totalScanned + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							bossCount = bossCount + 1
							print("🏠 Found Boss Room #" .. bossCount)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							miniChestCount = miniChestCount + 1
							print("📦 Found Mini Chest Room #" .. miniChestCount .. " (ID: " .. roomId .. ")")
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
							eggCount = eggCount + 1
							print("🥚 Found Free Egg Room #" .. eggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							lockedEggCount = lockedEggCount + 1
							print("🔒 Found Locked Egg Room #" .. lockedEggCount .. " (ID: " .. roomId .. ") with " .. (roomData.EggMultiplier or 0) .. "x multiplier")
						end
						
						if string.match(roomId, "DeepCoinRoom") ~= nil then
							print("💰 Found Coin Room: " .. roomId)
						end
					end
				end
			end
		end
		
		if miniChestCount > 0 then
			print("📦 Total Mini Chest Rooms found: " .. miniChestCount)
		end
		if bossCount > 0 then
			print("👑 Total Boss Rooms found: " .. bossCount)
		end
		if eggCount > 0 then
			print("🥚 Total Free Egg Rooms found: " .. eggCount)
		end
		if lockedEggCount > 0 then
			print("🔒 Total Locked Egg Rooms found: " .. lockedEggCount)
		end
	end

	scanExistingRooms()
	print("Initial scan complete. Found " .. #_G.ScannedRooms .. " rooms")
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)

	local maxLoops = 200
	local loopCount = 0
	local noNewRoomsCount = 0
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		local character = getCharacter()
		if not character then
			task.wait(0.1)
			continue
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then
			task.wait(0.1)
			continue
		end

		local room = nil
		local minDistance = math.huge
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					room = r
				end
			end
		end

		if not room then
			if #_G.ScannedRooms > 0 then
				room = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
				print("No unvisited rooms, exploring random room")
			else
				warn("No rooms found at all!")
				break
			end
		end

		if room then
			_G.VistedRooms[room.uid] = true
			visitedCount = visitedCount + 1
			
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						Network.Fire("RequestStreaming", room.Position)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(room.Position) + Vector3.new(0, 3, 0)
						task.wait(0.2)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			task.wait(0.2)
			RunService.RenderStepped:Wait()
			
			local beforeCount = #_G.ScannedRooms
			scanExistingRooms()
			local afterCount = #_G.ScannedRooms
			
			if afterCount == beforeCount then
				noNewRoomsCount = noNewRoomsCount + 1
			else
				noNewRoomsCount = 0
				print("Found " .. (afterCount - beforeCount) .. " new rooms! Total: " .. afterCount)
				print("📦 Mini Chest Rooms total: " .. #_G.AllMiniChestRooms)
				print("👑 Boss Rooms total: " .. #_G.AllBossRooms)
			end
			
			if noNewRoomsCount > 5 then
				print("No new rooms found, returning to spawn to refresh")
				TPtoSpawn()
				task.wait(0.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
		end

		if loopCount % 20 == 0 then
			print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== FAST SCAN FINISHED ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
	print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
local function autoClick()
	if not _G.AutoClickerEnabled then return end
	
	pcall(function()
		local VirtualInputManager = game:GetService("VirtualInputManager")
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
		task.wait(0.02)
		VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
	end)
end

task.spawn(function()
	while true do
		task.wait(_G.AutoClickerInterval)
		if _G.AutoClickerEnabled then
			pcall(autoClick)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE FOR BOSS
-- ============================================
local directionArrow = nil
local directionLine = nil
local directionText = nil
local arrowFolder = nil

local function CreateDirectionGuide()
	if arrowFolder then
		arrowFolder:Destroy()
		arrowFolder = nil
	end
	
	arrowFolder = Instance.new("Folder")
	arrowFolder.Name = "DirectionGuide"
	arrowFolder.Parent = workspace.CurrentCamera
	
	directionArrow = Instance.new("Part")
	directionArrow.Name = "Arrow"
	directionArrow.Size = Vector3.new(2, 6, 2)
	directionArrow.Shape = Enum.PartType.Cylinder
	directionArrow.Anchored = true
	directionArrow.CanCollide = false
	directionArrow.Transparency = 0.3
	directionArrow.Material = Enum.Material.Neon
	directionArrow.Color = Color3.fromRGB(255, 50, 50)
	directionArrow.Parent = arrowFolder
	
	local tip = Instance.new("Part")
	tip.Name = "Tip"
	tip.Size = Vector3.new(4, 2, 4)
	tip.Shape = Enum.PartType.Cylinder
	tip.Anchored = true
	tip.CanCollide = false
	tip.Transparency = 0.2
	tip.Material = Enum.Material.Neon
	tip.Color = Color3.fromRGB(255, 100, 100)
	tip.Parent = arrowFolder
	
	directionLine = Instance.new("Part")
	directionLine.Name = "Line"
	directionLine.Size = Vector3.new(0.5, 1, 0.5)
	directionLine.Anchored = true
	directionLine.CanCollide = false
	directionLine.Transparency = 0.4
	directionLine.Material = Enum.Material.Neon
	directionLine.Color = Color3.fromRGB(255, 200, 50)
	directionLine.Parent = arrowFolder
	
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DistanceLabel"
	billboard.Adornee = directionArrow
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.Parent = arrowFolder
	
	directionText = Instance.new("TextLabel")
	directionText.Size = UDim2.new(1, 0, 1, 0)
	directionText.BackgroundTransparency = 1
	directionText.Text = "👑 BOSS: 0 studs"
	directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
	directionText.TextSize = 16
	directionText.Font = Enum.Font.GothamBold
	directionText.TextStrokeTransparency = 0.3
	directionText.Parent = billboard
	
	task.spawn(function()
		while arrowFolder and arrowFolder.Parent do
			task.wait(0.05)
			if directionArrow then
				local pulse = 0.3 + math.sin(tick() * 3) * 0.15
				directionArrow.Transparency = pulse
				if directionLine then
					directionLine.Transparency = pulse + 0.1
				end
			end
		end
	end)
	
	return arrowFolder
end

local function UpdateDirectionGuide()
	if not _G.ShowDirectionGuide then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if #_G.AllBossRooms == 0 then
		if arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		return
	end
	
	if not arrowFolder then
		CreateDirectionGuide()
	end
	
	local character = getCharacter()
	if not character then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return 
	end
	
	local nearestBoss = nil
	local minDist = math.huge
	for _, boss in ipairs(_G.AllBossRooms) do
		local dist = (boss.Position - rootPart.Position).Magnitude
		if dist < minDist then
			minDist = dist
			nearestBoss = boss
		end
	end
	
	if not nearestBoss then
		if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
		return
	end
	
	local bossPos = nearestBoss.Position
	local playerPos = rootPart.Position
	local direction = (bossPos - playerPos).Unit
	
	local arrowPos = playerPos + Vector3.new(0, 8, 0)
	local distance = (bossPos - playerPos).Magnitude
	
	if directionArrow and directionArrow.Parent then
		directionArrow.Position = arrowPos
		directionArrow.CFrame = CFrame.lookAt(arrowPos, arrowPos + direction)
		
		local tip = arrowFolder:FindFirstChild("Tip")
		if tip then
			tip.Position = arrowPos + direction * 4
			tip.CFrame = CFrame.lookAt(tip.Position, tip.Position + direction)
		end
		
		if directionLine then
			local midPoint = (playerPos + bossPos) / 2
			local lineLength = distance
			directionLine.Size = Vector3.new(0.5, lineLength, 0.5)
			directionLine.Position = midPoint
			directionLine.CFrame = CFrame.lookAt(midPoint, bossPos)
		end
		
		if directionText then
			local distText = string.format("👑 BOSS: %.0f studs", distance)
			if distance < 50 then
				distText = "👑 BOSS: 🔥 CLOSE! " .. math.floor(distance) .. " studs"
			elseif distance < 100 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs ⬅️"
			elseif distance < 200 then
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🏃"
			else
				distText = "👑 BOSS: " .. math.floor(distance) .. " studs 🚀"
			end
			directionText.Text = distText
			
			if distance < 50 then
				directionText.TextColor3 = Color3.fromRGB(255, 50, 50)
			elseif distance < 100 then
				directionText.TextColor3 = Color3.fromRGB(255, 150, 50)
			else
				directionText.TextColor3 = Color3.fromRGB(255, 200, 100)
			end
		end
	end
	
	local angle = math.deg(math.atan2(direction.X, direction.Z))
	local compass = ""
	if angle > -22.5 and angle <= 22.5 then compass = "⬆️ North"
	elseif angle > 22.5 and angle <= 67.5 then compass = "↗️ Northeast"
	elseif angle > 67.5 and angle <= 112.5 then compass = "➡️ East"
	elseif angle > 112.5 and angle <= 157.5 then compass = "↘️ Southeast"
	elseif angle > 157.5 or angle <= -157.5 then compass = "⬇️ South"
	elseif angle > -157.5 and angle <= -112.5 then compass = "↙️ Southwest"
	elseif angle > -112.5 and angle <= -67.5 then compass = "⬅️ West"
	elseif angle > -67.5 and angle <= -22.5 then compass = "↖️ Northwest"
	end
	
	if not UpdateDirectionGuide.lastPrint or tick() - UpdateDirectionGuide.lastPrint > 5 then
		UpdateDirectionGuide.lastPrint = tick()
		print("🎯 BOSS Direction: " .. compass .. " | Distance: " .. math.floor(distance) .. " studs")
	end
end

-- ============================================
-- AUTO BOSS FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		if not _G.AutoMiniBoss then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local targetRoom = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				targetRoom = boss
			end
		end
		
		if targetRoom then
			local uid = targetRoom.uid
			local roomModel = targetRoom.Model
			local pos = targetRoom.Position
			local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
			if breakZone then pos = breakZone:GetPivot().Position end
			local isInRoom = (rootPart.Position - pos).Magnitude <= 130
			if (not isInRoom) then
				TeleportToRoom(uid)
				task.wait(1)
			else
				local targetBreakable = nil
				local targetType = nil
				local breakablesFolder = workspace:FindFirstChild("__THINGS")
				if breakablesFolder then breakablesFolder = breakablesFolder:FindFirstChild("Breakables") end
				if breakablesFolder then
					local breakables = breakablesFolder:GetChildren()
					local searchRadius = _G.ChestSearchRadius
					for _, b in ipairs(breakables) do
						local bId = b:GetAttribute("BreakableID")
						if bId == "Daydream Mimic Chest2" then
							local bPos = b:GetPivot().Position
							local distance = (bPos - pos).Magnitude
							if distance < searchRadius then
								targetBreakable = b
								targetType = "Chest"
								break
							end
						end
					end
					if not targetBreakable then
						for _, b in ipairs(breakables) do
							local bId = b:GetAttribute("BreakableID")
							if bId == "Daydream Mimic Boss2" then
								local bPos = b:GetPivot().Position
								local distance = (bPos - pos).Magnitude
								if distance < searchRadius then
									targetBreakable = b
									targetType = "Boss"
									break
								end
							end
						end
					end
				end
				if targetBreakable then
					local bUID = targetBreakable:GetAttribute("BreakableUID")
					local bPos = targetBreakable:GetPivot().Position
					local humanoid = character:FindFirstChildOfClass("Humanoid")
					if targetType == "Chest" then
						if humanoid then humanoid:MoveTo(bPos) end
					elseif targetType == "Boss" then
						if humanoid then humanoid:MoveTo(rootPart.Position) end
					end
					Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then pet:SetTarget(targetBreakable) end
					end
				end
			end
		else
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(2)
		if not _G.AutoTPAnomaly then continue end
		if not canDoAction() then continue end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then continue end
		
		local distance = (rootPart.Position - pos).Magnitude
		if distance > 50 then
			print("✨ Auto teleporting to Anomaly (250x Egg)!")
			_G.Teleporting = true
			Network.Fire("RequestStreaming", pos)
			rootPart.Anchored = true
			rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)
			task.delay(1.5, function()
				rootPart.Anchored = false
				_G.Teleporting = false
			end)
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO EGG HATCH LOOP - FAST HATCH SUPPORT (Batch 1000)
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.15)
		if not _G.AutoHatch then continue end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local egg = getNearestEgg(character)
		if egg then
			FastHatchEgg(egg)
		end
	end
end)

-- ============================================
-- AUTO BEST EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPBestEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Best Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO LOCKED EGG LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		if not _G.AutoTPLockedEgg then continue end
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		if not canDoAction() then continue end
		local character = getCharacter()
		if not character then continue end
		local room = getBestLockedEggRoom()
		if room then
			local isInRoom = (character:GetPivot().Position - room.Position).Magnitude <= 40
			if not isInRoom then
				TeleportToRoom(room.uid)
				task.wait(2)
			end
		else
			serverHop("No Locked Egg in this server. hopping...")
			task.wait(5)
		end
	end
end)

-- ============================================
-- AUTO TELEPORT TO MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
			autoMiniInitialized = false
			continue 
		end
		
		if not canDoAction() then continue end
		if #_G.AllMiniChestRooms == 0 then continue end
		
		if _G.AutoTPAnomaly then
			local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
			local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
			if isActive and (type(endsAt) ~= "number" or workspace:GetServerTimeNow() < endsAt) then
				continue
			end
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if autoMiniPhase == "WaitingAfterNearest" then
			local currentTime = tick()
			if currentTime - autoMiniLastActionTime >= _G.MiniChestCooldown then
				autoMiniPhase = "Next"
				print("🔄 Cycle complete! Starting next cycle with Next Mini...")
			else
				continue
			end
		end
		
		local currentTime = tick()
		if autoMiniPhase == "Next" then
			local room, index = GetNextMiniChestRoom()
			if room then
				print("📦 [Phase 1/2] Teleporting to NEXT Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Next")
				autoMiniLastActionTime = currentTime
				autoMiniPhase = "Nearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Next")
				end
				task.wait(1)
				continue
			end
		end
		
		if autoMiniPhase == "Nearest" then
			local timeSinceLastTeleport = tick() - autoMiniLastActionTime
			if timeSinceLastTeleport < 1 then
				continue
			end
			
			local room, index = GetNearestMiniChestRoom()
			if room then
				print("📦 [Phase 2/2] Teleporting to NEAREST Mini Chest #" .. index .. "/" .. #_G.AllMiniChestRooms)
				TeleportToMiniChestAbove(room.uid, index, "Nearest")
				autoMiniLastActionTime = tick()
				autoMiniPhase = "WaitingAfterNearest"
				if _G.UI and _G.UI.UpdateMiniCycle then
					_G.UI.UpdateMiniCycle(index, #_G.AllMiniChestRooms, "Nearest")
				end
				local minutes = math.floor(_G.MiniChestCooldown / 60)
				local seconds = _G.MiniChestCooldown % 60
				if minutes > 0 then
					print("⏱️ Waiting " .. minutes .. "m " .. seconds .. "s before next cycle...")
				else
					print("⏱️ Waiting " .. _G.MiniChestCooldown .. "s before next cycle...")
				end
			end
		end
	end
end)

-- ============================================
-- Direction Guide Update Loop
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- ORIGINAL ANTI AFK METHOD (FROM YOUR ORIGINAL CODE)
-- ============================================
localPlayer.Idled:Connect(function()
	-- ANTI AFK
	Signal.Fire("ResetIdleTimer")
	VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
	task.wait(1)
	VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
end)

-- Also keep the anti-afk loop from original
task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
	end
end)

-- ============================================
-- CREATE UI - WITH MINIMIZE AND RED DOT CLICKER
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 150)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
	mainFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 30)
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 2
	mainFrame.BorderColor3 = Color3.fromRGB(80, 80, 255)
	mainFrame.ClipsDescendants = true
	mainFrame.Parent = screenGui
	
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 26)
	titleBar.Position = UDim2.new(0, 0, 0, 0)
	titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 80)
	titleBar.BackgroundTransparency = 0
	titleBar.BorderSizePixel = 1
	titleBar.BorderColor3 = Color3.fromRGB(100, 100, 255)
	titleBar.ZIndex = 10
	titleBar.Parent = mainFrame
	
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -80, 1, 0)
	title.Position = UDim2.new(0, 4, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "🎮 BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	-- MINIMIZE BUTTON
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "🗕"
	retractButton.TextColor3 = Color3.fromRGB(0, 0, 0)
	retractButton.TextSize = 12
	retractButton.Font = Enum.Font.GothamBold
	retractButton.ZIndex = 11
	retractButton.Parent = titleBar
	
	local isRetracted = false
	
	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 22, 0, 20)
	closeButton.Position = UDim2.new(1, -26, 0, 3)
	closeButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 1
	closeButton.BorderColor3 = Color3.fromRGB(255, 50, 50)
	closeButton.Text = "✕"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
		print("❌ UI Closed")
	end)
	
	closeButton.MouseEnter:Connect(function()
		closeButton.BackgroundTransparency = 0
	end)
	closeButton.MouseLeave:Connect(function()
		closeButton.BackgroundTransparency = 0.2
	end)
	
	local contentFrame = Instance.new("ScrollingFrame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.BorderSizePixel = 0
	contentFrame.ScrollBarThickness = 3
	contentFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	contentFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentFrame.Parent = mainFrame
	
	local UIList = Instance.new("UIListLayout")
	UIList.Parent = contentFrame
	UIList.Padding = UDim.new(0, 2)
	UIList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIList.SortOrder = Enum.SortOrder.LayoutOrder
	
	UIList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		contentFrame.CanvasSize = UDim2.new(0, 0, 0, UIList.AbsoluteContentSize.Y + 10)
	end)
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 22)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
		button.Font = Enum.Font.Gotham
		button.Parent = contentFrame
		
		button.MouseButton1Click:Connect(callback)
		
		button.MouseEnter:Connect(function()
			button.BackgroundTransparency = 0
			button.BackgroundColor3 = Color3.fromRGB(70, 70, 120)
		end)
		button.MouseLeave:Connect(function()
			button.BackgroundTransparency = 0.2
			button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		end)
		
		return button
	end
	
	local function createToggle(text, callback)
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(0, 185, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 125, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 9
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 40, 1, 0)
		toggleButton.Position = UDim2.new(1, -40, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 8
		toggleButton.Font = Enum.Font.GothamBold
		toggleButton.Parent = frame
		
		local state = false
		
		toggleButton.MouseButton1Click:Connect(function()
			state = not state
			if state then
				toggleButton.BackgroundColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(50, 220, 50)
				toggleButton.Text = "ON"
			else
				toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
				toggleButton.Text = "OFF"
			end
			callback(state)
		end)
		
		return toggleButton
	end
	
	-- Status label
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	-- Room count label
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 8
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Center
	roomsLabel.Parent = contentFrame
	
	-- Buttons
	createButton("🔍 Scan", function() Scan() end)
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		local room = getBestEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Free Egg Room found!") end
	end)
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		local room = getBestLockedEggRoom()
		if room then TeleportToRoom(room.uid) else print("❌ No Locked Egg Room found!") end
	end)
	createButton("✨ TP Anomaly (250x)", function()
		if (not canDoAction()) then return end
		TeleportToAnomaly()
	end)
	createButton("🚪 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then print("No Boss Room found!") return end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		local nearestBoss = nil
		local minDist = math.huge
		for _, boss in ipairs(_G.AllBossRooms) do
			local dist = (boss.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestBoss = boss
			end
		end
		if nearestBoss then TeleportToRoom(nearestBoss.uid) end
	end)
	createButton("📦 TP Mini (Next)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNextMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Next") end
	end)
	createButton("📦 TP Mini (Nearest)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then print("No Mini Chest Rooms found!") return end
		local room, index = GetNearestMiniChestRoom()
		if room then TeleportToMiniChestAbove(room.uid, index, "Nearest") end
	end)
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		roomsLabel.Text = "🏠 Rooms: 0 | 👑 Boss: 0 | 📦 Mini: 0"
		print("Cleared all scanned rooms")
	end)
	
	-- Toggles
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
		print("Auto Boss: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		print("Auto Hatch: " .. (value and "ON" or "OFF"))
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
		print("Fast Hatch: " .. (value and "ON" or "OFF"))
		if value then
			print("⚡ Fast Hatch: Hatches in batches of 1000 for maximum speed!")
		end
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
		print("Auto Best Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
		print("Auto Locked Egg: " .. (value and "ON" or "OFF"))
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
		print("Auto Anomaly: " .. (value and "ON" or "OFF"))
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
			print("Auto Mini: ON")
		else
			print("Auto Mini: OFF")
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
		print("Infinite Pet Speed: " .. (value and "ON" or "OFF"))
	end)
	createToggle("🚫 No Hatch Anim", function(value)
		if (not canDoAction()) then return end
		
		-- Check if Eggs or Pets exist in camera
		if workspace.CurrentCamera:FindFirstChild("Eggs") or workspace.CurrentCamera:FindFirstChild("Pets") then
			print("⚠️ Cannot disable hatch animation - Eggs or Pets found in camera")
			return
		end
		
		-- Find the Egg Opening Frontend script
		local scripts = localPlayer:FindFirstChild("PlayerScripts")
		if not scripts then
			print("⚠️ PlayerScripts not found")
			return
		end
		
		local scriptInstance = nil
		for _, descendant in ipairs(scripts:GetDescendants()) do
			if descendant.Name == "Egg Opening Frontend" then
				scriptInstance = descendant
				break
			end
		end
		
		if not scriptInstance then
			print("⚠️ Egg Opening Frontend script not found")
			return
		end
		
		-- Disable or enable the script
		scriptInstance.Enabled = (not value)
		_G.DisableHatchAnimation = value
		print("No Hatch Anim: " .. (value and "ON (Disabled hatch animation)" or "OFF (Enabled hatch animation)"))
	end)
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- Clicker section
	createButton("🖱️ Set Clicker Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			print("📍 Click position set to center of screen")
		end
	end)
	
	createToggle("🖱️ Auto Clicker", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count .. " | 👑 Boss: " .. #_G.AllBossRooms .. " | 📦 Mini: " .. #_G.AllMiniChestRooms
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
	-- RETRACT/MINIMIZE FUNCTIONALITY
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "🎮"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 200, 0, 150)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
			title.Text = "🎮 BR UI"
		end
	end)
	
	-- DRAGGING FUNCTIONALITY
	local dragging = false
	local dragStart, startPos
	titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	
	-- ============================================
	-- RED DOT CLICKER
	-- ============================================
	local screenSize = workspace.CurrentCamera.ViewportSize
	local dotSize = 20
	local dotX = screenSize.X / 2 - dotSize / 2
	local dotY = screenSize.Y / 2 + 50 - dotSize / 2
	
	local redDot = Instance.new("Frame")
	redDot.Name = "RedDot"
	redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
	redDot.Position = UDim2.new(0, dotX, 0, dotY)
	redDot.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	redDot.BackgroundTransparency = 0.3
	redDot.BorderSizePixel = 1.5
	redDot.BorderColor3 = Color3.fromRGB(255, 0, 0)
	redDot.ZIndex = 999999
	redDot.Parent = screenGui
	
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = redDot
	
	local dotGlow = Instance.new("Frame")
	dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
	dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
	dotGlow.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	dotGlow.BackgroundTransparency = 0.1
	dotGlow.BorderSizePixel = 1
	dotGlow.BorderColor3 = Color3.fromRGB(255, 100, 100)
	dotGlow.ZIndex = 999998
	dotGlow.Parent = redDot
	
	local glowCorner = Instance.new("UICorner")
	glowCorner.CornerRadius = UDim.new(1, 0)
	glowCorner.Parent = dotGlow
	
	local dotCenter = Instance.new("Frame")
	dotCenter.Size = UDim2.new(0, 4, 0, 4)
	dotCenter.Position = UDim2.new(0.5, -2, 0.5, -2)
	dotCenter.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.BackgroundTransparency = 0.3
	dotCenter.BorderSizePixel = 1
	dotCenter.BorderColor3 = Color3.fromRGB(255, 255, 255)
	dotCenter.ZIndex = 1000000
	dotCenter.Parent = redDot
	
	local dotCenterCorner = Instance.new("UICorner")
	dotCenterCorner.CornerRadius = UDim.new(1, 0)
	dotCenterCorner.Parent = dotCenter
	
	_G.AutoClickerX = dotX + dotSize / 2
	_G.AutoClickerY = dotY + dotSize / 2
	
	local dotDragging = false
	local dotDragStart, dotStartPos
	
	redDot.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			if dotDragging then
				dotDragging = false
				redDot.BackgroundTransparency = 0.3
			end
		end
	end)
	
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseMovement then
			if dotDragging then
				local delta = input.Position - dotDragStart
				local newX = dotStartPos.X.Offset + delta.X
				local newY = dotStartPos.Y.Offset + delta.Y
				local screenSize = workspace.CurrentCamera.ViewportSize
				newX = math.max(0, math.min(newX, screenSize.X - dotSize))
				newY = math.max(0, math.min(newY, screenSize.Y - dotSize))
				redDot.Position = UDim2.new(0, newX, 0, newY)
				_G.AutoClickerX = newX + dotSize / 2
				_G.AutoClickerY = newY + dotSize / 2
			end
		end
	end)
	
	dotGlow.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or 
		   input.UserInputType == Enum.UserInputType.MouseButton1 then
			dotDragging = true
			dotDragStart = input.Position
			dotStartPos = redDot.Position
			redDot.BackgroundTransparency = 0.1
		end
	end)
	
	redDot.MouseEnter:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.15
			redDot.Size = UDim2.new(0, dotSize + 4, 0, dotSize + 4)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - (dotSize + 4)/2, 0, _G.AutoClickerY - (dotSize + 4)/2)
			dotGlow.Size = UDim2.new(0, dotSize + 10, 0, dotSize + 10)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 10)/2, 0.5, -(dotSize + 10)/2)
		end
	end)
	
	redDot.MouseLeave:Connect(function()
		if not dotDragging then
			redDot.BackgroundTransparency = 0.3
			redDot.Size = UDim2.new(0, dotSize, 0, dotSize)
			redDot.Position = UDim2.new(0, _G.AutoClickerX - dotSize/2, 0, _G.AutoClickerY - dotSize/2)
			dotGlow.Size = UDim2.new(0, dotSize + 6, 0, dotSize + 6)
			dotGlow.Position = UDim2.new(0.5, -(dotSize + 6)/2, 0.5, -(dotSize + 6)/2)
		end
	end)
	
	return screenGui
end

-- ============================================
-- CREATE UI
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("⚡ Infinite Pet Speed: OFF")
print("🚫 No Hatch Animation: OFF")
print("⚡ Fast Hatch: OFF - Hatches in batches of 1000 for maximum speed!")
print("🖱️ Red Dot Clicker: Drag to position")
print("🗕 Click minimize button to retract UI")
print("=========================================")
print("🔒 LOCK DOOR SYSTEM:")
print("   • Auto detects locked rooms")
print("   • Teleports to FRONT of door")
print("   • Uses key to unlock")
print("   • WALKS to target (egg/boss)")
print("   • Even if UNLOCKED, still goes to door front and walks in")
print("=========================================")

task.wait(2)
Scan()
