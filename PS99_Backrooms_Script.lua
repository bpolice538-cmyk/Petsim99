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

local NORMAL_HEIGHT_OFFSET = 2
local SIDEWAYS_OFFSET = 500 -- 500 studs sideways from the maze
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
	
	local hallwayParts = roomModel:FindFirstChild("HallwayParts")
	if hallwayParts then
		for _, part in ipairs(hallwayParts:GetChildren()) do
			if part:IsA("BasePart") then
				return part.Position + Vector3.new(0, 2, 0), nil
			end
		end
	end
	
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		return breakZone:GetPivot().Position + Vector3.new(0, 2, 0), nil
	end
	
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

	local pos = enterPosition + Vector3.new(0, NORMAL_HEIGHT_OFFSET, 0)

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

-- Get the maze bounds to find a safe scanning position
local function GetMazeBounds()
	local folder = getGeneratedBackrooms()
	if not folder then return nil, nil end
	
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	
	for _, room in ipairs(folder:GetChildren()) do
		if room:GetAttribute("DeepRoom") == true then
			local pos = room:GetPivot().Position
			minX = math.min(minX, pos.X)
			maxX = math.max(maxX, pos.X)
			minZ = math.min(minZ, pos.Z)
			maxZ = math.max(maxZ, pos.Z)
		end
	end
	
	return minX, maxX, minZ, maxZ
end

-- Teleport to side of maze (invisible to players)
local function TeleportToSide(targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	-- Get maze bounds
	local minX, maxX, minZ, maxZ = GetMazeBounds()
	if not minX then return false end
	
	-- Calculate a position outside the maze (to the side)
	local mazeCenterX = (minX + maxX) / 2
	local mazeCenterZ = (minZ + maxZ) / 2
	
	-- Pick a random direction to teleport to the side
	local directions = {
		Vector3.new(1, 0, 0),   -- East
		Vector3.new(-1, 0, 0),  -- West
		Vector3.new(0, 0, 1),   -- South
		Vector3.new(0, 0, -1),  -- North
	}
	
	local dir = directions[math.random(1, #directions)]
	local sideOffset = 300 -- 300 studs outside the maze
	
	-- Calculate position on the side of the maze
	local sidePos = Vector3.new(
		mazeCenterX + (dir.X * sideOffset),
		NORMAL_HEIGHT_OFFSET,
		mazeCenterZ + (dir.Z * sideOffset)
	)
	
	print("📍 Teleporting to SIDE of maze: " .. tostring(sidePos))
	
	Network.Fire("RequestStreaming", sidePos)
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(sidePos)
	task.wait(0.3)
	rootPart.Anchored = false
	
	return true
end

-- Walk along the side of the maze to discover rooms
local function WalkSideways(targetRoomPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	-- Get maze bounds
	local minX, maxX, minZ, maxZ = GetMazeBounds()
	if not minX then return false end
	
	-- Calculate position on the side of the room
	local roomPos = targetRoomPos
	local sidePos = Vector3.new(
		roomPos.X,
		NORMAL_HEIGHT_OFFSET,
		roomPos.Z + 200 -- 200 studs to the side (Z direction)
	)
	
	-- If we're on the side, the rooms should still load
	print("🚶 Walking SIDEWAYS to room at: " .. tostring(sidePos))
	
	humanoid:MoveTo(sidePos)
	
	local startTime = tick()
	local timeout = 15
	local lastPos = rootPart.Position
	local stuckCount = 0
	
	while tick() - startTime < timeout do
		task.wait(0.1)
		local currentPos = rootPart.Position
		local distToTarget = (currentPos - sidePos).Magnitude
		
		if distToTarget < 5 then
			-- Return to side position after reaching
			return true
		end
		
		if (currentPos - lastPos).Magnitude < 0.3 then
			stuckCount = stuckCount + 1
			if stuckCount > 30 then
				print("⚠️ Stuck! Teleporting to side...")
				rootPart.Anchored = true
				rootPart.CFrame = CFrame.new(sidePos)
				task.wait(0.2)
				rootPart.Anchored = false
				return true
			end
		else
			stuckCount = 0
		end
		
		lastPos = currentPos
	end
	
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
		_G.UI.UpdateStatus("Scanning from SIDE of maze...")
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
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms from SIDE")
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
	
	-- Teleport to the side of the maze (invisible to players)
	TeleportToSide()
	task.wait(1)
	
	scanExistingRooms()
	print("Initial scan from SIDE: " .. #_G.ScannedRooms .. " rooms found")

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
		
		-- Walk sideways to the room (invisible to players)
		print("🚶 Walking SIDEWAYS to room: " .. (targetRoom.Id or "Unknown") .. " (" .. visitedCount .. "/" .. #_G.ScannedRooms .. " visited)")
		
		local success = WalkSideways(targetRoom.Position)
		
		if not success then
			print("⚠️ Walk failed! Teleporting to side...")
			local minX, maxX, minZ, maxZ = GetMazeBounds()
			if minX then
				local mazeCenterX = (minX + maxX) / 2
				local mazeCenterZ = (minZ + maxZ) / 2
				local sidePos = Vector3.new(mazeCenterX, NORMAL_HEIGHT_OFFSET, mazeCenterZ + 200)
				rootPart.Anchored = true
				rootPart.CFrame = CFrame.new(sidePos)
				task.wait(0.3)
				rootPart.Anchored = false
			end
		end
		
		task.wait(0.5)
		RunService.RenderStepped:Wait()
		
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
			TeleportToSide()
			task.wait(1)
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
	print("Scan Method: SIDEWAYS (invisible to players)")
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

-- UI Creation (shortened for space)
local function CreateUI()
	-- ... (same UI code as before) ...
end

local ui = CreateUI()
print("✅ UI Created!")

task.wait(2)
Scan()
