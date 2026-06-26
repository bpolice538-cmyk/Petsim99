if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

if typeof(require) ~= "function" then
	Players.LocalPlayer:Kick("Unsupported")
	return
end

local Network = require(game.ReplicatedStorage.Library.Client.Network)
local PlayerPet = require(game.ReplicatedStorage.Library.Client.PlayerPet)
local InstancingCmds = require(game.ReplicatedStorage.Library.Client.InstancingCmds)
local MiscItem = require(game.ReplicatedStorage.Library.Items.MiscItem)

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
-- KEY CHECK
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

-- ============================================
-- WALK THROUGH HALLWAY / DOOR (FOR LOCKED EGGS)
-- ============================================
local function WalkThroughHallway(startPos, targetPos)
	local character = getCharacter()
	if not character then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return false end
	
	humanoid:MoveTo(targetPos)
	
	local startTime = tick()
	local timeout = 20
	local lastPos = rootPart.Position
	local stuckCount = 0
	
	while tick() - startTime < timeout do
		task.wait(0.1)
		local currentPos = rootPart.Position
		local distToTarget = (currentPos - targetPos).Magnitude
		
		if distToTarget < 5 then
			print("✅ Reached target!")
			return true
		end
		
		if (currentPos - lastPos).Magnitude < 0.3 then
			stuckCount = stuckCount + 1
			if stuckCount > 20 then
				print("⚠️ Stuck! Teleporting to target...")
				rootPart.Anchored = true
				rootPart.CFrame = CFrame.new(targetPos)
				task.wait(0.2)
				rootPart.Anchored = false
				return true
			end
		else
			stuckCount = 0
		end
		
		lastPos = currentPos
	end
	
	print("⚠️ Timeout! Teleporting to target...")
	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(targetPos)
	task.wait(0.2)
	rootPart.Anchored = false
	return true
end

-- ============================================
-- UNLOCK LOCKED EGG ROOM WITH WALKING
-- ============================================
local function UnlockLockedEggRoom(roomUID, targetPosition)
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
		print("⚠️ Room is not locked!")
		return true
	end

	-- Find the lock and door
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
		print("✅ Room already unlocked!")
		return true
	end

	-- Get door position and direction
	local doorPosition = doorPart and doorPart.Position or lockedPart.Position
	local doorCFrame = doorPart and doorPart.CFrame or CFrame.new(doorPosition)
	local doorFront = doorCFrame.LookVector
	
	-- Position in front of door (hallway side)
	local hallwayPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
	local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
	
	print("🚪 Door Position: " .. tostring(doorPosition))
	print("🚪 Hallway Position: " .. tostring(hallwayPos))
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	
	-- Teleport to hallway in front of door
	if rootPart then
		Network.Fire("RequestStreaming", hallwayPos)
		rootPart.Anchored = true
		rootPart.CFrame = CFrame.new(hallwayPos)
		task.wait(0.5)
		rootPart.Anchored = false
	end
	
	print("🔓 Walking to door to unlock...")
	
	-- Walk to door front
	if humanoid then
		humanoid:MoveTo(doorFrontPos)
		task.wait(1.5)
	end
	
	-- Unlock the door
	print("🔓 Unlocking door with key...")
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
	task.wait(1.5)
	
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
	
	-- Walk through to the egg
	local targetPos = targetPosition or roomData.Position + Vector3.new(0, 2, 0)
	print("🚶 Walking through door to egg position: " .. tostring(targetPos))
	
	-- Walk through the door
	if humanoid then
		humanoid:MoveTo(targetPos)
		task.wait(0.5)
	end
	
	-- Walk through hallway to target
	WalkThroughHallway(doorFrontPos, targetPos)
	
	print("✅ Room unlocked and walked to egg!")
	return true
end

-- ============================================
-- TELEPORT TO CENTER OF ROOF OF MINI CHEST ROOM
-- ============================================
local function TeleportToMiniChestRoof(roomUID)
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
	local pos = roomData.Position

	-- Find the CENTER highest point in the room for roof position
	local centerX = pos.X
	local centerZ = pos.Z
	local highestPoint = pos.Y + 30
	
	local roomParts = roomModel:GetDescendants()
	for _, part in ipairs(roomParts) do
		if part:IsA("BasePart") then
			local partPos = part.Position
			local distFromCenter = math.sqrt((partPos.X - centerX)^2 + (partPos.Z - centerZ)^2)
			if distFromCenter < 30 and partPos.Y > highestPoint then
				highestPoint = partPos.Y + 15
			end
		end
	end
	
	-- Center roof position
	local roofPos = Vector3.new(centerX, highestPoint, centerZ)
	
	-- Force streaming for both positions
	Network.Fire("RequestStreaming", pos)
	Network.Fire("RequestStreaming", roofPos)

	-- Clear any existing forces
	rootPart.Anchored = true
	rootPart.Velocity = Vector3.new(0, 0, 0)
	rootPart.RotVelocity = Vector3.new(0, 0, 0)
	
	-- Teleport to roof position
	rootPart.CFrame = CFrame.new(roofPos)
	
	-- Wait for server to sync
	task.wait(0.5)
	
	-- Unanchor
	rootPart.Anchored = false

	_G.Teleporting = false
	
	isOnRoof = true
	
	-- Check if this is actually a mini chest room
	if roomData.Id and string.match(roomData.Id, "DeepChestRoom") ~= nil then
		isInMiniChestRoom = true
		currentMiniChestRoomUID = roomUID
		print("✅ Now on CENTER roof of Mini Chest Room! Pets will auto-break chests below.")
	else
		print("⚠️ Not a mini chest room, returning to spawn...")
		isInMiniChestRoom = false
		isOnRoof = false
		TPtoSpawn()
	end
end

-- ============================================
-- TELEPORT TO BOSS ROOM - 200 studs outside
-- ============================================
local function TeleportToBossOutside(roomUID)
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
	local pos = roomData.Position

	local roomCenter = pos
	local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomCenter = breakZone:GetPivot().Position
	end
	
	local distance = 200
	local angle = math.random(0, 360)
	local radAngle = math.rad(angle)
	
	local outsidePos = roomCenter + Vector3.new(
		math.sin(radAngle) * distance,
		3,
		math.cos(radAngle) * distance
	)

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	rootPart.CFrame = CFrame.new(outsidePos)

	task.delay(1.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end
		rootPart.Anchored = false
	end)

	_G.Teleporting = false
	print("🚪 Teleported 200 studs outside Boss Room!")
end

-- ============================================
-- TELEPORT TO ROOM (HANDLES LOCKED EGG ROOMS)
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

	-- Check if it's a locked egg room
	if roomId == "DeepLockedEggRoom" then
		-- Use the unlock and walk method
		local targetPos = nil
		local eggObj = roomModel:FindFirstChild("Backrooms Egg")
		if eggObj then
			targetPos = eggObj.Position + Vector3.new(0, 2, 0)
		else
			targetPos = roomData.Position + Vector3.new(0, 2, 0)
		end
		
		_G.Teleporting = false
		local success = UnlockLockedEggRoom(roomUID, targetPos)
		return
	end

	-- For free egg rooms, teleport directly
	local targetPos = roomData.Position + Vector3.new(0, 3, 0)
	
	-- Check for egg object in free egg room
	local eggObj = roomModel:FindFirstChild("Backrooms Egg")
	if eggObj then
		targetPos = eggObj.Position + Vector3.new(0, 2, 0)
	end

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
	print("✅ Teleported to room!")
end

-- ============================================
-- SCAN FUNCTION
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
	miniChestIndex = 1
	
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
							_G.UI.UpdateStatus("Scanned " .. #_G.ScannedRooms .. " rooms")
							_G.UI.UpdateRooms(#_G.ScannedRooms)
						end

						if string.match(roomId, "GameMastersStage") ~= nil then
							table.insert(_G.AllBossRooms, roomData)
							print("🏠 Found Boss Room #" .. #_G.AllBossRooms)
						end
						
						if string.match(roomId, "DeepChestRoom") ~= nil then
							table.insert(_G.AllMiniChestRooms, roomData)
							print("📦 Found Mini Chest Room #" .. #_G.AllMiniChestRooms)
						end
						
						if string.match(roomId, "DeepFreeEggRoom") ~= nil then
							print("🥚 Found Free Egg Room #" .. #_G.ScannedRooms)
						end
						
						if string.match(roomId, "DeepLockedEggRoom") ~= nil then
							print("🔒 Found Locked Egg Room #" .. #_G.ScannedRooms)
						end
					end
				end
			end
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
			
			if room.Id and string.match(room.Id, "DeepChestRoom") ~= nil then
				TeleportToMiniChestRoof(room.uid)
			else
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
-- AUTO BREAK MINI CHEST - LOOP THROUGH ALL MINI CHESTS
-- ============================================
local function AutoBreakMiniChestRoom()
	if not _G.AutoBreakMiniChest then
		return
	end

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

	if #_G.AllMiniChestRooms == 0 then
		print("📦 No Mini Chest Rooms found!")
		return
	end

	if isInMiniChestRoom and currentMiniChestRoomUID then
		local roomData = findRoomDataByUID(currentMiniChestRoomUID)
		if not roomData then
			isInMiniChestRoom = false
			currentMiniChestRoomUID = nil
			isOnRoof = false
		end
	end

	if not isInMiniChestRoom then
		local targetRoom = _G.AllMiniChestRooms[miniChestIndex]
		
		if not targetRoom then
			miniChestIndex = 1
			targetRoom = _G.AllMiniChestRooms[miniChestIndex]
		end
		
		if targetRoom then
			print("📦 Teleporting to Mini Chest Room #" .. miniChestIndex .. " of " .. #_G.AllMiniChestRooms)
			TeleportToMiniChestRoof(targetRoom.uid)
			task.wait(1.5)
		end
		return
	end

	local roomData = findRoomDataByUID(currentMiniChestRoomUID)
	if not roomData then
		isInMiniChestRoom = false
		isOnRoof = false
		return
	end
	
	local roomPos = roomData.Position
	local breakZone = roomData.Model:FindFirstChild("BREAK_ZONE")
	if breakZone then
		roomPos = breakZone:GetPivot().Position
	end
	
	local breakablesFolder = workspace:FindFirstChild("__THINGS")
	if breakablesFolder then
		breakablesFolder = breakablesFolder:FindFirstChild("Breakables")
	end
	
	local foundBreakable = false
	
	if breakablesFolder then
		local breakables = breakablesFolder:GetChildren()
		
		for _, b in ipairs(breakables) do
			local bPos = b:GetPivot().Position
			local distance = (bPos - roomPos).Magnitude
			
			if distance < 80 then
				local bUID = b:GetAttribute("BreakableUID")
				if bUID then
					local activePets = PlayerPet.GetByPlayer(localPlayer)
					for _, pet in pairs(activePets) do
						if pet.cpet then
							pcall(function()
								pet:SetTarget(b)
							end)
						end
					end
					
					pcall(function()
						Network.UnreliableFire("Breakables_PlayerDealDamage", bUID)
					end)
					
					foundBreakable = true
					print("💥 Attacking breakable in mini chest room")
				end
			end
		end
	end
	
	if foundBreakable then
		task.wait(0.5)
	else
		print("📦 No breakables left in this room, moving to next...")
		isInMiniChestRoom = false
		isOnRoof = false
		miniChestIndex = miniChestIndex + 1
		
		if miniChestIndex > #_G.AllMiniChestRooms then
			miniChestIndex = 1
			print("🔄 Looped back to first mini chest room")
		end
		
		task.wait(0.5)
		
		local nextRoom = _G.AllMiniChestRooms[miniChestIndex]
		if nextRoom then
			print("📦 Moving to next mini chest room #" .. miniChestIndex)
			TeleportToMiniChestRoof(nextRoom.uid)
			task.wait(1)
		end
	end
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
-- DIRECTION GUIDE FOR BOSS (3D Arrow)
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
-- ANTI AFK
-- ============================================
local function antiAFK()
	local character = getCharacter()
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid:Jump()
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		local currentPos = rootPart.Position
		rootPart.CFrame = CFrame.new(currentPos + Vector3.new(0, 0.1, 0))
		task.wait(0.05)
		rootPart.CFrame = CFrame.new(currentPos)
	end
end

task.spawn(function()
	while true do
		task.wait(30)
		if not _G.AntiAFK then continue end
		pcall(antiAFK)
		pcall(function()
			VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
			task.wait(0.1)
			VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
		end)
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
			print("🔍 No Boss Rooms found.")
			task.wait(5)
		end
	end
end)

-- Auto Break MINI CHEST Loop
task.spawn(function()
	while true do
		task.wait(0.3)
		if not _G.AutoBreakMiniChest then continue end
		AutoBreakMiniChestRoom()
	end
end)

-- Direction Guide Update Loop
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

-- ============================================
-- CREATE UI - RETRACTABLE TO ICON
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 170)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -85)
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
	
	local contentFrame = Instance.new("Frame")
	contentFrame.Size = UDim2.new(1, 0, 1, -26)
	contentFrame.Position = UDim2.new(0, 0, 0, 26)
	contentFrame.BackgroundTransparency = 1
	contentFrame.Parent = mainFrame
	
	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Size = UDim2.new(1, 0, 1, 0)
	scrollFrame.Position = UDim2.new(0, 0, 0, 0)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 3
	scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.Parent = contentFrame
	
	local scrollList = Instance.new("UIListLayout")
	scrollList.Parent = scrollFrame
	scrollList.Padding = UDim.new(0, 1)
	scrollList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	scrollList.SortOrder = Enum.SortOrder.LayoutOrder
	
	scrollList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		scrollFrame.CanvasSize = UDim2.new(0, 0, 0, scrollList.AbsoluteContentSize.Y + 10)
		scrollFrame.CanvasPosition = Vector2.new(0, scrollFrame.CanvasSize.Y.Offset)
	end)
	
	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(0, 185, 0, 14)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = "📊 Ready"
	statusLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	statusLabel.TextSize = 9
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Parent = scrollFrame
	
	local roomsLabel = Instance.new("TextLabel")
	roomsLabel.Size = UDim2.new(0, 185, 0, 14)
	roomsLabel.BackgroundTransparency = 1
	roomsLabel.Text = "🏠 Rooms: 0"
	roomsLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
	roomsLabel.TextSize = 9
	roomsLabel.Font = Enum.Font.Gotham
	roomsLabel.TextXAlignment = Enum.TextXAlignment.Left
	roomsLabel.Parent = scrollFrame
	
	local bossLabel = Instance.new("TextLabel")
	bossLabel.Size = UDim2.new(0, 185, 0, 14)
	bossLabel.BackgroundTransparency = 1
	bossLabel.Text = "👑 Boss: 0"
	bossLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
	bossLabel.TextSize = 9
	bossLabel.Font = Enum.Font.Gotham
	bossLabel.TextXAlignment = Enum.TextXAlignment.Left
	bossLabel.Parent = scrollFrame
	
	local miniLabel = Instance.new("TextLabel")
	miniLabel.Size = UDim2.new(0, 185, 0, 14)
	miniLabel.BackgroundTransparency = 1
	miniLabel.Text = "📦 Mini: 0"
	miniLabel.TextColor3 = Color3.fromRGB(100, 200, 255)
	miniLabel.TextSize = 9
	miniLabel.Font = Enum.Font.Gotham
	miniLabel.TextXAlignment = Enum.TextXAlignment.Left
	miniLabel.Parent = scrollFrame
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 185, 0, 18)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 9
		button.Font = Enum.Font.Gotham
		button.Parent = scrollFrame
		
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
		frame.Size = UDim2.new(0, 185, 0, 18)
		frame.BackgroundTransparency = 1
		frame.Parent = scrollFrame
		
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
	
	local function createDivider()
		local divider = Instance.new("Frame")
		divider.Size = UDim2.new(0, 160, 0, 1)
		divider.BackgroundColor3 = Color3.fromRGB(80, 80, 200)
		divider.BackgroundTransparency = 0.5
		divider.Parent = scrollFrame
		return divider
	end
	
	createButton("🔍 Scan", function() 
		Scan()
	end)
	
	createButton("🥚 TP Best Free Egg", function()
		if (not canDoAction()) then return end
		if #_G.ScannedRooms == 0 then
			print("⚠️ Scan first!")
			return
		end
		local bestRoom = nil
		local bestMult = -1
		for _, room in ipairs(_G.ScannedRooms) do
			if string.match(room.Id, "DeepFreeEggRoom") ~= nil and room.EggMultiplier and room.EggMultiplier > bestMult then
				bestMult = room.EggMultiplier
				bestRoom = room
			end
		end
		if bestRoom then
			print("🥚 Teleporting to Best Free Egg Room with " .. bestMult .. "x multiplier")
			TeleportToRoom(bestRoom.uid)
		else
			print("❌ No Free Egg Room found!")
		end
	end)
	
	createButton("🔒 TP Best Locked Egg", function()
		if (not canDoAction()) then return end
		if #_G.ScannedRooms == 0 then
			print("⚠️ Scan first!")
			return
		end
		local bestRoom = nil
		local bestMult = -1
		for _, room in ipairs(_G.ScannedRooms) do
			if room.Id == "DeepLockedEggRoom" and room.EggMultiplier and room.EggMultiplier > bestMult then
				bestMult = room.EggMultiplier
				bestRoom = room
			end
		end
		if bestRoom then
			print("🔒 Teleporting to Best Locked Egg Room with " .. bestMult .. "x multiplier")
			TeleportToRoom(bestRoom.uid)
		else
			print("❌ No Locked Egg Room found!")
		end
	end)
	
	createButton("🚪 TP Boss (200 studs)", function()
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
			print("🚪 Teleporting 200 studs away from Boss Room")
			TeleportToBossOutside(nearestBoss.uid)
		end
	end)
	
	createButton("📦 TP Mini (Roof)", function()
		if (not canDoAction()) then return end
		if #_G.AllMiniChestRooms == 0 then
			print("No Mini Chest Room found! Scan first!")
			return
		end
		local character = getCharacter()
		if not character then return end
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not rootPart then return end
		
		local nearestMini = nil
		local minDist = math.huge
		for _, mini in ipairs(_G.AllMiniChestRooms) do
			local dist = (mini.Position - rootPart.Position).Magnitude
			if dist < minDist then
				minDist = dist
				nearestMini = mini
			end
		end
		
		if nearestMini then
			print("📦 Teleporting to CENTER roof of Mini Chest...")
			TeleportToMiniChestRoof(nearestMini.uid)
		end
	end)
	
	createButton("🏠 Spawn", function() TPtoSpawn() end)
	
	createButton("🗑️ Clear", function()
		_G.ScannedRooms = {}
		_G.ScannedRoomsMap = {}
		_G.VistedRooms = {}
		_G.AllBossRooms = {}
		_G.AllMiniChestRooms = {}
		miniChestIndex = 1
		if _G.UI then _G.UI.UpdateRooms(0); _G.UI.UpdateStatus("Cleared") end
		if bossLabel then bossLabel.Text = "👑 Boss: 0" end
		if miniLabel then miniLabel.Text = "📦 Mini: 0" end
		if roomsLabel then roomsLabel.Text = "🏠 Rooms: 0" end
		print("Cleared all scanned rooms")
	end)
	
	createDivider()
	
	createToggle("🤖 Boss", function(value)
		if (not canDoAction()) then return end
		_G.AutoMiniBoss = value
		if value then
			_G.AutoBreakMiniChest = false
			if _G.UI then _G.UI.UpdateStatus("Auto Boss") end
			print("Auto Farm Boss: ON")
		else
			if _G.UI then _G.UI.UpdateStatus("Idle") end
			print("Auto Farm Boss: OFF")
		end
	end)
	
	createToggle("🐾 Mini (Loop)", function(value)
		if (not canDoAction()) then return end
		_G.AutoBreakMiniChest = value
		if value then
			_G.AutoMiniBoss = false
			miniChestIndex = 1
			if _G.UI then _G.UI.UpdateStatus("Mini Chest Loop") end
			print("Auto Break Mini Chest: ON - Will loop through all mini chests")
		else
			isInMiniChestRoom = false
			currentMiniChestRoomUID = nil
			isOnRoof = false
			if _G.UI then _G.UI.UpdateStatus("Idle") end
			print("Auto Break Mini Chest: OFF")
		end
	end)
	
	createDivider()
	
	createToggle("🧭 Direction", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	createDivider()
	
	local clickerLabel = Instance.new("TextLabel")
	clickerLabel.Size = UDim2.new(0, 185, 0, 12)
	clickerLabel.BackgroundTransparency = 1
	clickerLabel.Text = "🖱️ Clicker"
	clickerLabel.TextColor3 = Color3.fromRGB(255, 200, 100)
	clickerLabel.TextSize = 9
	clickerLabel.Font = Enum.Font.GothamBold
	clickerLabel.TextXAlignment = Enum.TextXAlignment.Left
	clickerLabel.Parent = scrollFrame
	
	createToggle("🖱️ Auto", function(value)
		_G.AutoClickerEnabled = value
		print("Auto Clicker: " .. (value and "ON" or "OFF"))
	end)
	
	local clickerPosLabel = Instance.new("TextLabel")
	clickerPosLabel.Size = UDim2.new(0, 185, 0, 12)
	clickerPosLabel.BackgroundTransparency = 1
	clickerPosLabel.Text = "📍 0,0"
	clickerPosLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
	clickerPosLabel.TextSize = 8
	clickerPosLabel.Font = Enum.Font.Gotham
	clickerPosLabel.TextXAlignment = Enum.TextXAlignment.Left
	clickerPosLabel.Parent = scrollFrame
	
	createButton("📍 Set Pos", function()
		local camera = workspace.CurrentCamera
		if camera then
			local viewport = camera.ViewportSize
			_G.AutoClickerX = viewport.X / 2
			_G.AutoClickerY = viewport.Y / 2 + 50
			clickerPosLabel.Text = "📍 " .. math.floor(_G.AutoClickerX) .. "," .. math.floor(_G.AutoClickerY)
			print("📍 Click position set to center of screen")
		end
	end)
	
	task.spawn(function()
		while true do
			task.wait(0.5)
			if bossLabel then
				bossLabel.Text = "👑 Boss: " .. #_G.AllBossRooms
			end
			if miniLabel then
				miniLabel.Text = "📦 Mini: " .. #_G.AllMiniChestRooms
			end
			if roomsLabel then
				roomsLabel.Text = "🏠 Rooms: " .. #_G.ScannedRooms
			end
		end
	end)
	
	local function updateStatus(text)
		statusLabel.Text = "📊 " .. text
	end
	
	local function updateRooms(count)
		roomsLabel.Text = "🏠 Rooms: " .. count
	end
	
	_G.UI = {
		UpdateStatus = updateStatus,
		UpdateRooms = updateRooms
	}
	
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
			mainFrame.Size = UDim2.new(0, 200, 0, 170)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -85)
			title.Text = "🎮 BR UI"
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
				clickerPosLabel.Text = "📍 " .. math.floor(_G.AutoClickerX) .. "," .. math.floor(_G.AutoClickerY)
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

-- Create UI
local ui = CreateUI()
print("Backroom UI loaded!")
print("🔍 FAST SCAN ACTIVATED")
print("👑 Boss Rooms found: 0")
print("📦 Mini Chest Rooms found: 0")
print("🥚 Free Egg Rooms: 0")
print("🔒 Locked Egg Rooms: 0")
print("🚪 TP Boss (200 studs) - Teleports 200 studs away from boss")
print("📦 TP Mini (Roof) - Teleports to CENTER roof of mini chest")
print("🐾 Mini (Loop) - Will loop through ALL mini chest rooms")
print("🧭 Direction - Shows 3D arrow pointing to nearest boss with distance")
print("🗕 Click to retract to icon")

task.wait(2)
Scan()
