if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

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

_G.ScannedRooms = {}
_G.ScannedRoomsMap = {}
_G.VistedRooms = {}
_G.IsScanning = false
_G.Teleporting = false
_G.AutoMiniBoss = false
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

_G.AutoHatch = false
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.InfinitePetSpeed = false
_G.DisableHatchAnimation = false
_G.SelectedLockedEggMult = "Any"
_G.FastHatch = false
_G.IsTeleportingToSpawn = false
_G.IsScanningMode = false

-- Use a moderate height that's invisible but still loads rooms
local SCAN_HEIGHT_OFFSET = 150  -- Reduced from 200 to load rooms better
local NORMAL_HEIGHT_OFFSET = 2

local autoMiniLastActionTime = 0
local autoMiniPhase = "Next"

local oldCalculate = PlayerPet.CalculateSpeedMultiplier
PlayerPet.CalculateSpeedMultiplier = function(self, ...)
	if _G.InfinitePetSpeed then
		return 100000
	end
	return oldCalculate(self, ...)
end

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

local function findHallwayPosition(roomModel)
	if not roomModel then
		return nil, nil
	end
	
	-- Check for LockedDoors first
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if lockedDoors then
		for _, child in ipairs(lockedDoors:GetChildren()) do
			local lock = child:FindFirstChild("Lock")
			if lock and lock.Transparency < 1 then
				local doorCFrame = child.CFrame
				local doorPosition = child.Position
				local doorFront = doorCFrame.LookVector
				local frontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				return frontPos, frontPos
			end
		end
	end
	
	-- Check for regular Doors
	local doors = roomModel:FindFirstChild("Doors")
	if doors then
		for _, door in ipairs(doors:GetChildren()) do
			if door:IsA("BasePart") then
				local doorCFrame = door.CFrame
				local doorPosition = door.Position
				local doorFront = doorCFrame.LookVector
				local frontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
				return frontPos, frontPos
			end
		end
	end
	
	-- Check for HallwayParts
	local hallwayParts = roomModel:FindFirstChild("HallwayParts")
	if hallwayParts then
		for _, part in ipairs(hallwayParts:GetChildren()) do
			if part:IsA("BasePart") then
				return part.Position + Vector3.new(0, 2, 0), nil
			end
		end
	end
	
	-- Check for BREAK_ZONE (boss rooms)
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		return breakZone:GetPivot().Position + Vector3.new(0, 2, 0), nil
	end
	
	-- Fallback: Room center
	local centerCFrame = roomModel:GetBoundingBox()
	return centerCFrame.Position + Vector3.new(0, 2, 0), nil
end

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
		_G.IsTeleportingToSpawn = false
		_G.Teleporting = false
		return
	end

	local heightOffset = _G.IsScanningMode and SCAN_HEIGHT_OFFSET or NORMAL_HEIGHT_OFFSET
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
	
	task.wait(0.5)
	_G.IsTeleportingToSpawn = false
	_G.Teleporting = false
end

-- Void protection - disabled during scanning
task.spawn(function()
	while true do
		task.wait(1)
		
		if _G.IsScanningMode or _G.IsScanning then
			continue
		end
		
		local character = getCharacter()
		if not character then continue end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then continue end
		
		if rootPart.Position.Y < -50 then
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
	
	return true
end

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
			end
		else
			Network.Invoke("CustomEggs_Hatch", egg._uid, maxHatch)
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

local function TeleportToAnomaly()
	if _G.Teleporting then
		return
	end

	local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")

	if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
		return false
	end

	local pos = workspace:GetAttribute("BackroomsAnomalyPos")
	if not pos then
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
	
	local hallwayPos = roomData.HallwayPos
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
		
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	else
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(targetPos)
		task.wait(0.3)
		rootPart.Anchored = false
	end
	
	_G.Teleporting = false
end

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

local function DebugHallwayPositions()
	print("=== HALLWAY POSITIONS FOUND ===")
	local foundCount = 0
	local missingCount = 0
	
	for _, room in ipairs(_G.ScannedRooms) do
		if room.HallwayPos then
			foundCount = foundCount + 1
			print("✅ Room: " .. (room.Id or "Unknown") .. " | Hallway: " .. tostring(room.HallwayPos))
		else
			missingCount = missingCount + 1
			print("❌ Room: " .. (room.Id or "Unknown") .. " | NO HALLWAY FOUND")
		end
	end
	
	print("==================================")
	print("Found: " .. foundCount .. " | Missing: " .. missingCount)
	print("==================================")
end

-- Teleport and wait for rooms to load
local function TeleportAndLoad(targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	_G.Teleporting = true
	
	-- Teleport to position
	Network.Fire("RequestStreaming", targetPos)
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(targetPos)
	task.wait(0.3)
	rootPart.Anchored = false
	
	-- Wait for rooms to load
	task.wait(1.5)
	
	_G.Teleporting = false
	return true
end

local function Scan()
	if _G.IsScanning == true then
		return
	end

	_G.IsScanning = true
	_G.IsScanningMode = true

	local message = createMessage("Exploring the backrooms...")
	
	if _G.UI then
		_G.UI.UpdateStatus("Scanning...")
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
			print("Spawn position saved at: " .. tostring(enterPosition))
		end
	end
	
	_G.AllBossRooms = {}
	_G.AllMiniChestRooms = {}
	_G.MiniChestCycleIndex = 1
	_G.VistedRooms = {}
	
	local function scanExistingRooms()
		local folder = getGeneratedBackrooms()
		if not folder then
			return 0
		end

		local newRoomsFound = 0

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
						newRoomsFound = newRoomsFound + 1
						
						if _G.UI then
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms")
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
		
		return newRoomsFound
	end

	-- Teleport to spawn first
	TPtoSpawn()
	task.wait(2)
	
	scanExistingRooms()
	print("Initial scan: " .. #_G.ScannedRooms .. " rooms found")

	local maxLoops = 300
	local loopCount = 0
	local noNewRoomsCount = 0
	local consecutiveSameRoom = 0
	local lastRoomUID = nil
	local visitedCount = 0
	
	while loopCount < maxLoops and #_G.ScannedRooms < 500 do
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

		-- Find nearest UNVISITED room
		local targetRoom = nil
		local minDistance = math.huge
		local unvisitedCount = 0
		
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				unvisitedCount = unvisitedCount + 1
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					targetRoom = r
				end
			end
		end

		-- If no unvisited rooms found, reset
		if not targetRoom then
			if #_G.ScannedRooms > 0 then
				print("No unvisited rooms! Resetting visited list...")
				_G.VistedRooms = {}
				targetRoom = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
			else
				print("No rooms found!")
				break
			end
		end

		-- Check if we're about to visit the same room again
		if targetRoom.uid == lastRoomUID then
			consecutiveSameRoom = consecutiveSameRoom + 1
			if consecutiveSameRoom > 3 then
				print("⚠️ Stuck on same room! Marking as visited...")
				_G.VistedRooms[targetRoom.uid] = true
				consecutiveSameRoom = 0
				continue
			end
		else
			consecutiveSameRoom = 0
			lastRoomUID = targetRoom.uid
		end

		-- Mark room as visited
		_G.VistedRooms[targetRoom.uid] = true
		visitedCount = visitedCount + 1
		
		-- Teleport to position above the room (invisible but loads rooms)
		local teleportPos = Vector3.new(
			targetRoom.Position.X,
			SCAN_HEIGHT_OFFSET,
			targetRoom.Position.Z
		)
		
		print("📍 Scanning room: " .. (targetRoom.Id or "Unknown") .. " (" .. visitedCount .. "/" .. #_G.ScannedRooms .. " visited)")
		print("   Position: " .. tostring(teleportPos))
		
		-- Teleport and wait for rooms to load
		local success = TeleportAndLoad(teleportPos)
		
		if not success then
			print("⚠️ Teleport failed, trying again...")
			task.wait(1)
			continue
		end
		
		-- Scan for new rooms
		local newRooms = scanExistingRooms()
		
		if newRooms and newRooms > 0 then
			noNewRoomsCount = 0
			print("✅ Found " .. newRooms .. " new rooms! Total: " .. #_G.ScannedRooms)
			print("   Boss Rooms: " .. #_G.AllBossRooms .. " | Mini Chests: " .. #_G.AllMiniChestRooms)
		else
			noNewRoomsCount = noNewRoomsCount + 1
		end
		
		-- If no new rooms found for a while, teleport to spawn to refresh
		if noNewRoomsCount > 10 then
			print("🔄 No new rooms found. Refreshing at spawn...")
			TPtoSpawn()
			task.wait(2)
			noNewRoomsCount = 0
			scanExistingRooms()
		end
		
		-- Progress report every 10 loops
		if loopCount % 10 == 0 then
			print("📊 Progress: " .. #_G.ScannedRooms .. " rooms (" .. loopCount .. "/" .. maxLoops .. ")")
			print("   Visited: " .. visitedCount .. " | Unvisited: " .. (#_G.ScannedRooms - visitedCount))
		end
	end

	_G.IsScanning = false
	_G.IsScanningMode = false
	
	DebugHallwayPositions()
	
	if _G.UI then
		_G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
		_G.UI.UpdateRooms(#_G.ScannedRooms)
	end
	
	game.Debris:AddItem(message, 0)
	TPtoSpawn()
	
	print("=== SCAN COMPLETE ===")
	print("Total rooms scanned: " .. #_G.ScannedRooms)
	print("Boss Rooms: " .. #_G.AllBossRooms)
	print("Mini Chest Rooms: " .. #_G.AllMiniChestRooms)
	print("Rooms visited: " .. visitedCount)
	print("=====================")
end

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

-- UI Creation
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 220, 0, 180)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -90)
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
	title.Text = "BR UI"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 12
	title.Font = Enum.Font.GothamBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 11
	title.Parent = titleBar
	
	local retractButton = Instance.new("TextButton")
	retractButton.Size = UDim2.new(0, 22, 0, 20)
	retractButton.Position = UDim2.new(1, -52, 0, 3)
	retractButton.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	retractButton.BackgroundTransparency = 0
	retractButton.BorderSizePixel = 1
	retractButton.BorderColor3 = Color3.fromRGB(255, 255, 255)
	retractButton.Text = "-"
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
	closeButton.Text = "X"
	closeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeButton.TextSize = 12
	closeButton.Font = Enum.Font.GothamBold
	closeButton.ZIndex = 11
	closeButton.Parent = titleBar
	
	closeButton.MouseButton1Click:Connect(function()
		mainFrame:Destroy()
		screenGui:Destroy()
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
		button.Size = UDim2.new(0, 200, 0, 22)
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
		frame.Size = UDim2.new(0, 200, 0, 22)
		frame.BackgroundTransparency = 1
		frame.Parent = contentFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 130, 1, 0)
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
	statusLabel.Size = UDim2.new(0, 200, 0, 16)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.Parent = contentFrame
	
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 200, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "Rooms: 0 | Boss: 0 | Mini: 0"
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
	createButton("👑 TP Boss", function()
		if (not canDoAction()) then return end
		if #_G.AllBossRooms == 0 then 
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
		roomsLabel.Text = "Rooms: 0 | Boss: 0 | Mini: 0"
	end)
	
	createToggle("🤖 Auto Boss", function(value)
		_G.AutoMiniBoss = value
	end)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
	end)
	createToggle("⚡ Fast Hatch", function(value)
		_G.FastHatch = value
	end)
	createToggle("🥚 Auto Best Egg", function(value)
		_G.AutoTPBestEgg = value
	end)
	createToggle("🔒 Auto Locked Egg", function(value)
		_G.AutoTPLockedEgg = value
	end)
	createToggle("✨ Auto Anomaly", function(value)
		_G.AutoTPAnomaly = value
	end)
	createToggle("📦 Auto Mini", function(value)
		_G.AutoTeleportMiniChest = value
		if value then
			_G.MiniChestCycleIndex = 1
			autoMiniPhase = "Next"
			autoMiniLastActionTime = 0
		end
	end)
	createToggle("⚡ Infinite Pet Speed", function(value)
		_G.InfinitePetSpeed = value
	end)
	createToggle("🧭 Direction Guide", function(value)
		_G.ShowDirectionGuide = value
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
	
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "+"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "BR"
		else
			retractButton.Text = "-"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 220, 0, 180)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -90)
			title.Text = "BR UI"
		end
	end)
	
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
	
	return screenGui
end

-- Auto Boss Loop
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

task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTeleportMiniChest then 
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
			end
		end
	end
end)

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

local ui = CreateUI()
print("✅ UI Created!")

task.wait(2)
Scan()
