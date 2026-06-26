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

local SCAN_HEIGHT_OFFSET = 200
local NORMAL_HEIGHT_OFFSET = 2

local autoMiniLastActionTime = 0
local autoMiniInitialized = false
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
				local doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
				return doorFrontPos, doorFrontPos
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
				local doorFrontPos = doorPosition + (doorFront * 6) + Vector3.new(0, 2, 0)
				return doorFrontPos, doorFrontPos
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

-- VOID PROTECTION - DISABLED DURING SCANNING
task.spawn(function()
	while true do
		task.wait(1)
		
		-- Skip void protection entirely during scanning
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

	-- Get the backrooms folder
	local folder = getGeneratedBackrooms()
	if not folder then
		repeat
			folder = getGeneratedBackrooms()
			task.wait(0.5)
		until folder ~= nil and #folder:GetChildren() > 0
	end

	-- Save spawn position
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
	
	-- Teleport to spawn FIRST to start from a known position
	TPtoSpawn()
	task.wait(2)
	
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

	-- Initial scan to find all existing rooms
	local initialRooms = scanExistingRooms()
	print("Initial scan: " .. #_G.ScannedRooms .. " rooms found")

	local maxLoops = 150
	local loopCount = 0
	local noNewRoomsCount = 0
	local lastRoomCount = #_G.ScannedRooms
	
	-- Get character for movement
	local character = getCharacter()
	if not character then
		_G.IsScanning = false
		_G.IsScanningMode = false
		return
	end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		_G.IsScanning = false
		_G.IsScanningMode = false
		return
	end
	
	while loopCount < maxLoops and #_G.ScannedRooms < 400 do
		loopCount = loopCount + 1
		
		if _G.Teleporting == true then
			task.wait(0.1)
			continue
		end

		-- Find nearest unvisited room
		local targetRoom = nil
		local minDistance = math.huge
		
		for _, r in ipairs(_G.ScannedRooms) do
			if not _G.VistedRooms[r.uid] then
				local dist = (r.Position - rootPart.Position).Magnitude
				if dist < minDistance then
					minDistance = dist
					targetRoom = r
				end
			end
		end

		-- If all rooms visited, reset
		if not targetRoom then
			if #_G.ScannedRooms > 0 then
				_G.VistedRooms = {}
				print("All rooms visited, resetting to find more...")
				targetRoom = _G.ScannedRooms[math.random(1, #_G.ScannedRooms)]
			else
				print("No rooms found!")
				break
			end
		end

		if targetRoom then
			_G.VistedRooms[targetRoom.uid] = true
			
			if not _G.Teleporting then
				_G.Teleporting = true
				local character = getCharacter()
				if character then
					local rootPart = character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						-- Teleport to room position at SCAN_HEIGHT_OFFSET
						local teleportPos = Vector3.new(
							targetRoom.Position.X, 
							SCAN_HEIGHT_OFFSET, 
							targetRoom.Position.Z
						)
						
						Network.Fire("RequestStreaming", teleportPos)
						rootPart.Anchored = true
						rootPart.CFrame = CFrame.new(teleportPos)
						task.wait(0.3)
						rootPart.Anchored = false
					end
				end
				_G.Teleporting = false
			end
			
			-- Wait for rooms to load
			task.wait(0.8)
			RunService.RenderStepped:Wait()
				
			-- Scan for new rooms
			local newRooms = scanExistingRooms()
				
			if newRooms and newRooms > 0 then
				noNewRoomsCount = 0
				print("Found " .. newRooms .. " new rooms! Total: " .. #_G.ScannedRooms)
				print("Boss Rooms: " .. #_G.AllBossRooms .. ", Mini Chests: " .. #_G.AllMiniChestRooms)
			else
				noNewRoomsCount = noNewRoomsCount + 1
			end
				
			-- If no new rooms found for a while, teleport to spawn to refresh
			if noNewRoomsCount > 10 then
				print("No new rooms found, refreshing at spawn...")
				TPtoSpawn()
				task.wait(1.5)
				noNewRoomsCount = 0
				scanExistingRooms()
			end
			
			-- Reset visited rooms periodically to find new ones
			if loopCount % 15 == 0 then
				if #_G.ScannedRooms == lastRoomCount then
					_G.VistedRooms = {}
					print("Reset visited rooms to find new ones...")
				end
				lastRoomCount = #_G.ScannedRooms
			end
		end
		
		if loopCount % 10 == 0 then
			print("Scan progress: " .. #_G.ScannedRooms .. " rooms (" .. loopCount .. "/" .. maxLoops .. ")")
		end
	end

	_G.IsScanning = false
	_G.IsScanningMode = false
	
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

-- UI Creation and other functions remain the same...
-- [UI code continues here - same as before]

local function CreateUI()
	-- [Same UI code as before]
end

local ui = CreateUI()
task.wait(2)
Scan()
