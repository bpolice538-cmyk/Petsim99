if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

if typeof(require) ~= "function" then
	Players.LocalPlayer:Kick("Unsupported")
	return
end

local Network = require(game.ReplicatedStorage.Library.Client.Network)
local InstancingCmds = require(game.ReplicatedStorage.Library.Client.InstancingCmds)
local MiscItem = require(game.ReplicatedStorage.Library.Items.MiscItem)
local EggCmds = require(game.ReplicatedStorage.Library.Client.EggCmds)
local CustomEggsCmds = require(game.ReplicatedStorage.Library.Client.CustomEggsCmds)
local PlayerPet = require(game.ReplicatedStorage.Library.Client.PlayerPet)
local Signal = require(game.ReplicatedStorage.Library.Signal)
local Types = require(game.ReplicatedStorage.Library.Items.Types)
local AbstractItem = require(game.ReplicatedStorage.Library.Items.AbstractItem)
local NumberShorten = require(game.ReplicatedStorage.Library.Functions.NumberShorten)
local InventoryCmds = require(game.ReplicatedStorage.Library.Client.InventoryCmds)
local Save = require(game.ReplicatedStorage.Library.Client.Save)

local localPlayer = Players.LocalPlayer
local enterPosition = nil
local isInMiniChestRoom = false
local currentMiniChestRoomUID = nil
local isOnRoof = false
local miniChestIndex = 1

-- ============================================
-- LOCKED EGG ROOM VARIABLES
-- ============================================
local currentLockedRoom = nil
local currentLockedRoomUID = nil
local roomExpireTime = 0
local farmingLockedRoom = false

-- ============================================
-- ULTRA FAST HATCH VARIABLES - 1000x per ms
-- ============================================
_G.AutoHatch = true
_G.DisableHatchAnimation = true
_G.UltraFastHatch = true
_G.HatchAmount = 1000
_G.HatchInterval = 0.001 -- 1 millisecond
_G.NeverStopHatching = true
_G.TotalHatched = 0
_G.HatchSpeed = 0.001
_G.HatchEnabled = true

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
_G.AutoTPBestEgg = false
_G.AutoTPLockedEgg = false
_G.AutoTPAnomaly = false
_G.InfinitePetSpeed = false
_G.AutoTapper = false
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
_G.SelectedLockedEggMult = "Any"
_G.UnlockDuringScan = false

-- ============================================
-- SEEN PETS FOR WEBHOOK
-- ============================================
local seenPets = {}
task.spawn(function()
	while (not Save.Get()) do
		task.wait()
	end

	local container = InventoryCmds.Container(Players.LocalPlayer)
	local petsInventory = container:All()

	for itemUID, item in pairs(petsInventory) do
		if item:IsA("Pet") then
			local exclusiveLevel = item:GetExclusiveLevel()
			if exclusiveLevel and exclusiveLevel > 3 then
				seenPets[itemUID] = true
			end
		end
	end
end)

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

local function isPlayerInRoom(roomData)
	if roomData == nil then 
		return false 
	end

	local character = getCharacter()
	if not character then 
		return false 
	end

	local roomCFrame, roomSize = roomData.Model:GetBoundingBox()
	if not roomCFrame or not roomSize then
		return false
	end

	local localPoint = roomCFrame:PointToObjectSpace(character:GetPivot().Position)
	local limitX = (roomSize.X / 2) + 20
	local limitY = (roomSize.Y / 2) + 35
	local limitZ = (roomSize.Z / 2) + 20

	return math.abs(localPoint.X) <= limitX
		and math.abs(localPoint.Y) <= limitY
		and math.abs(localPoint.Z) <= limitZ
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
-- ULTRA FAST HATCH - COMPLETE ANIMATION BLOCKER
-- ============================================
local function BlockAllHatchAnimations()
    pcall(function()
        local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
        if playerScripts then
            for _, descendant in ipairs(playerScripts:GetDescendants()) do
                if descendant.Name == "Egg Opening Frontend" and descendant:IsA("LocalScript") then
                    descendant.Disabled = true
                end
                if descendant.Name == "Egg Opening" and descendant:IsA("LocalScript") then
                    descendant.Disabled = true
                end
            end
        end
        
        local camera = workspace.CurrentCamera
        if camera then
            local eggGUI = camera:FindFirstChild("Eggs")
            if eggGUI then eggGUI:Destroy() end
            
            local petGUI = camera:FindFirstChild("Pets")
            if petGUI then petGUI:Destroy() end
            
            local eggOpeningGUI = camera:FindFirstChild("EggOpening")
            if eggOpeningGUI then eggOpeningGUI:Destroy() end
        end
        
        for _, child in ipairs(workspace:GetDescendants()) do
            if child:IsA("BasePart") and child.Name:lower():find("egg") then
                child.Transparency = 1
                child.CanCollide = false
            end
            if child:IsA("Animation") and child.Name:lower():find("egg") then
                child:Destroy()
            end
        end
        
        for _, sound in ipairs(workspace:GetDescendants()) do
            if sound:IsA("Sound") and sound.Name:lower():find("egg") then
                sound.Volume = 0
                sound:Stop()
            end
        end
    end)
end

-- ============================================
-- OVERRIDE HATCH LIMITS
-- ============================================
local function OverrideHatchLimits()
    pcall(function()
        local oldGetMaxHatch = EggCmds.GetMaxHatch
        EggCmds.GetMaxHatch = function(...)
            if _G.UltraFastHatch then
                return 1000
            end
            return oldGetMaxHatch(...)
        end
        
        local function clearCooldowns()
            local eggCooldowns = getupvalue(EggCmds.GetMaxHatch, 1)
            if eggCooldowns then
                for eggUID, _ in pairs(eggCooldowns) do
                    eggCooldowns[eggUID] = 0
                end
            end
        end
        
        RunService.RenderStepped:Connect(function()
            if _G.UltraFastHatch then
                clearCooldowns()
            end
        end)
    end)
end

-- ============================================
-- ULTRA FAST HATCH FUNCTION - 1000x per ms
-- ============================================
local function UltraFastHatchEgg(eggUID, amount)
    if not _G.UltraFastHatch then
        return false
    end
    
    pcall(function()
        BlockAllHatchAnimations()
        OverrideHatchLimits()
        
        for i = 1, 10 do
            Network.Invoke("CustomEggs_Hatch", eggUID, amount or 1000)
            Signal.Fire("EggOpening_CompleteHatching")
            _G.TotalHatched = _G.TotalHatched + 1000
        end
        task.wait(0.001)
    end)
    
    return true
end

-- ============================================
-- HATCH ALL EGGS SIMULTANEOUSLY
-- ============================================
local function HatchAllEggs()
    pcall(function()
        local character = getCharacter()
        if not character then return end
        
        for _, egg in pairs(CustomEggsCmds.All()) do
            if egg._position then
                local dist = (egg._position - character:GetPivot().Position).Magnitude
                if dist < 200 then
                    for i = 1, 10 do
                        Network.Invoke("CustomEggs_Hatch", egg._uid, 1000)
                        Signal.Fire("EggOpening_CompleteHatching")
                        _G.TotalHatched = _G.TotalHatched + 1000
                    end
                end
            end
        end
    end)
end

-- ============================================
-- MAIN ULTRA FAST HATCH LOOP - 1ms INTERVAL (1000x per ms)
-- ============================================
task.spawn(function()
    while true do
        if not _G.UltraFastHatch then
            task.wait(0.1)
            continue
        end
        
        if not _G.AutoHatch then
            task.wait(0.1)
            continue
        end
        
        BlockAllHatchAnimations()
        
        local character = getCharacter()
        if not character then
            task.wait(0.001)
            continue
        end
        
        local nearestEgg = nil
        local minDist = 100
        
        pcall(function()
            for _, egg in pairs(CustomEggsCmds.All()) do
                if egg._position then
                    local dist = (egg._position - character:GetPivot().Position).Magnitude
                    if dist < minDist then
                        minDist = dist
                        nearestEgg = egg
                    end
                end
            end
        end)
        
        if nearestEgg then
            pcall(function()
                UltraFastHatchEgg(nearestEgg._uid, 1000)
                
                task.spawn(function()
                    UltraFastHatchEgg(nearestEgg._uid, 1000)
                end)
                
                task.spawn(function()
                    UltraFastHatchEgg(nearestEgg._uid, 1000)
                end)
            end)
        end
        
        task.wait(0.001)
        
        if _G.NeverStopHatching then
            -- Continue without any breaks
        end
    end
end)

-- ============================================
-- PARALLEL HATCHING - MULTIPLE THREADS
-- ============================================
for i = 1, 10 do
    task.spawn(function()
        while true do
            if not _G.UltraFastHatch then
                task.wait(0.1)
                continue
            end
            
            if not _G.AutoHatch then
                task.wait(0.1)
                continue
            end
            
            pcall(function()
                BlockAllHatchAnimations()
                
                local character = getCharacter()
                if character then
                    for _, egg in pairs(CustomEggsCmds.All()) do
                        if egg._position then
                            local dist = (egg._position - character:GetPivot().Position).Magnitude
                            if dist < 100 then
                                Network.Invoke("CustomEggs_Hatch", egg._uid, 1000)
                                Signal.Fire("EggOpening_CompleteHatching")
                                _G.TotalHatched = _G.TotalHatched + 1000
                            end
                        end
                    end
                end
            end)
            
            task.wait(0.0001)
        end
    end)
end

-- ============================================
-- CONTINUOUS HATCH - NEVER STOP
-- ============================================
task.spawn(function()
    while true do
        task.wait(0.001)
        
        if not _G.NeverStopHatching then
            task.wait(0.1)
            continue
        end
        
        if not _G.UltraFastHatch then
            task.wait(0.1)
            continue
        end
        
        pcall(function()
            BlockAllHatchAnimations()
            HatchAllEggs()
            Signal.Fire("EggOpening_CompleteHatching")
            
            local eggCooldowns = getupvalue(EggCmds.GetMaxHatch, 1)
            if eggCooldowns then
                for eggUID, _ in pairs(eggCooldowns) do
                    eggCooldowns[eggUID] = -999999
                end
            end
        end)
    end
end)

-- ============================================
-- KEY CHECK FOR LOCKED ROOMS
-- ============================================
local function keyCheck()
	local keyItem = MiscItem("Deep Backrooms Crayon Key")
	if keyItem and keyItem:HasAny() then
		return true
	end
	return false
end

-- ============================================
-- UNLOCK ROOM FUNCTION
-- ============================================
local function UnlockRoom(roomUID)
	if _G.IsScanning == true and not _G.UnlockDuringScan then
		warn("Cannot unlock during scan!")
		return
	end
	
	if _G.Teleporting == true then
		warn("Cannot unlock during teleport!")
		return
	end
	
	local character = getCharacter()
	if not character then
		return
	end
	
	local ownsKey = keyCheck()
	if not ownsKey then
		return
	end
	
	local activeInstance = InstancingCmds.Get()
	if not activeInstance then
		return
	end
	
	local roomData = findRoomDataByUID(roomUID)
	if not roomData then 
		warn("NO ROOM DATA")
		return 
	end
	
	local roomModel = roomData.Model
	local lockedDoors = roomModel:FindFirstChild("LockedDoors")
	if not lockedDoors then 
		warn("IS NOT A LOCKED ROOM")
		return 
	end
	
	local lockedPart = nil
	for _, child in ipairs(lockedDoors:GetChildren()) do
		local lock = child:FindFirstChild("Lock")
		if lock and lock.Transparency < 1 then
			lockedPart = lock
			break
		end
	end
	
	if not lockedPart then
		warn("doesnt exist lock part")
		return 
	end
	
	character:PivotTo(CFrame.new(lockedPart.Position))
	activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
end

-- ============================================
-- TELEPORT TO ROOM
-- ============================================
local function TeleportToRoom(roomUID, isScanning)
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
	local pos = roomData.Position

	local centerCF = roomModel:GetBoundingBox()

	local forceField = Instance.new("ForceField")
	forceField.Visible = false
	forceField.Parent = character

	Network.Fire("RequestStreaming", pos)

	rootPart.Anchored = true
	character:PivotTo(centerCF + Vector3.new(0, 10, 0))

	task.delay(2.5, function()
		if forceField and forceField.Parent then 
			forceField:Destroy() 
		end

		if (not isScanning) then
			rootPart.Anchored = false
		end
	end)

	if (not isScanning) then
		task.wait(1.5)

		local targetObj = roomModel:FindFirstChild("Sign")
			or roomModel:FindFirstChild("Backrooms Egg")
			or roomModel:FindFirstChild("BillboardAdornee")
			or roomModel.PrimaryPart
			or roomModel:FindFirstChildWhichIsA("BasePart", true)

		character:PivotTo((targetObj and targetObj.CFrame or CFrame.new(pos)) + Vector3.new(0, 15, 0))

		if roomId == "DeepLockedEggRoom" then
			local activeInstance = InstancingCmds.Get()
			if activeInstance then
				local ok, playerDataList = pcall(function()
					return activeInstance:InvokeCustom("AbstractRoom_GetPlayerData")
				end)

				if not ok then
					warn("FAILED TO GET PLR DATA", playerDataList)
					return
				end

				for _, roomInfo in ipairs(playerDataList) do
					if roomInfo.uid == roomUID then
						local expireTime = roomInfo.data and roomInfo.data.UnlockExpireTimestamp or nil
						if expireTime then
							roomData.ExpireTime = expireTime
							if currentLockedRoomUID == roomUID then
								roomExpireTime = expireTime
							end
						end
						break
					end
				end
			else
				warn("not in instance??")
			end
		end

		if not isScanning and _G.AutoTPLockedEgg then
			if roomId == "DeepLockedEggRoom" or roomId == "GameMastersStage" then
				UnlockRoom(roomUID)
			end
		end

		task.wait(0.3)

		character:PivotTo((targetObj and targetObj.CFrame or CFrame.new(pos)) + Vector3.new(0, 15, 0))
	end

	_G.Teleporting = false
end

-- ============================================
-- TELEPORT TO MINI CHEST ROOF
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
	
	local roofPos = Vector3.new(centerX, highestPoint, centerZ)
	
	Network.Fire("RequestStreaming", pos)
	Network.Fire("RequestStreaming", roofPos)

	rootPart.Anchored = true
	rootPart.Velocity = Vector3.new(0, 0, 0)
	rootPart.RotVelocity = Vector3.new(0, 0, 0)
	
	rootPart.CFrame = CFrame.new(roofPos)
	
	task.wait(0.5)
	
	rootPart.Anchored = false

	_G.Teleporting = false
	
	isOnRoof = true
	
	if roomData.Id and string.match(roomData.Id, "DeepChestRoom") ~= nil then
		isInMiniChestRoom = true
		currentMiniChestRoomUID = roomUID
		print("✅ Now on CENTER roof of Mini Chest Room!")
	else
		print("⚠️ Not a mini chest room, returning to spawn...")
		isInMiniChestRoom = false
		isOnRoof = false
		TPtoSpawn()
	end
end

-- ============================================
-- TELEPORT TO BOSS OUTSIDE
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
-- GET BEST EGG ROOM
-- ============================================
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

-- ============================================
-- GET BEST LOCKED EGG ROOM
-- ============================================
local function getBestLockedEggRoom()
	local bestRoom = nil
	local maxMult = -1
	local targetMult = (_G.SelectedLockedEggMult and _G.SelectedLockedEggMult ~= "Any")
		and tonumber(string.match(_G.SelectedLockedEggMult, "%d+"))
		or nil
		
	local currentTime = workspace:GetServerTimeNow()
	
	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			local isExpired = room.ExpireTime and (room.ExpireTime - currentTime <= 0)
			local isLocked = not room.ExpireTime
			
			if isLocked or isExpired then
				continue
			end
			
			local isMatch = (not targetMult) or room.EggMultiplier >= targetMult
			
			if isMatch and room.EggMultiplier > maxMult then
				maxMult = room.EggMultiplier
				bestRoom = room
			end
		end
	end
	
	return bestRoom
end

-- ============================================
-- GET ALL AVAILABLE LOCKED ROOMS
-- ============================================
local function getAllAvailableLockedRooms()
	local availableRooms = {}
	local currentTime = workspace:GetServerTimeNow()
	
	for _, room in ipairs(_G.ScannedRooms) do
		if room.Id == "DeepLockedEggRoom" and room.EggMultiplier ~= nil then
			local isExpired = room.ExpireTime and (room.ExpireTime - currentTime <= 0)
			local isLocked = not room.ExpireTime
			
			if not isLocked and not isExpired then
				table.insert(availableRooms, room)
			end
		end
	end
	
	table.sort(availableRooms, function(a, b)
		return a.EggMultiplier > b.EggMultiplier
	end)
	
	return availableRooms
end

-- ============================================
-- CHECK IF CURRENT LOCKED ROOM IS VALID
-- ============================================
local function isCurrentRoomValid()
	if not currentLockedRoom then
		return false
	end
	
	local found = false
	for _, room in ipairs(_G.ScannedRooms) do
		if room.uid == currentLockedRoomUID then
			found = true
			break
		end
	end
	
	if not found then
		return false
	end
	
	if currentLockedRoom.ExpireTime then
		local timeLeft = currentLockedRoom.ExpireTime - workspace:GetServerTimeNow()
		if timeLeft <= 0 then
			return false
		end
	else
		return false
	end
	
	return true
end

-- ============================================
-- GET ROOM TIME LEFT
-- ============================================
local function getRoomTimeLeft()
	if not currentLockedRoom or not currentLockedRoom.ExpireTime then
		return 0
	end
	return math.max(0, currentLockedRoom.ExpireTime - workspace:GetServerTimeNow())
end

-- ============================================
-- UNLOCK AND ENTER LOCKED ROOM
-- ============================================
local function UnlockAndEnterLockedRoom(room, isManual)
	if not room then
		return false
	end
	
	if not canDoAction() then
		return false
	end
	
	local ownsKey = keyCheck()
	if not ownsKey then
		if isManual then
			print("No Key! Can't unlock room!")
		end
		return false
	end
	
	TeleportToRoom(room.uid, false)
	
	currentLockedRoom = room
	currentLockedRoomUID = room.uid
	farmingLockedRoom = true
	
	if room.ExpireTime then
		roomExpireTime = room.ExpireTime
	end
	
	return true
end

-- ============================================
-- RESET LOCKED ROOM STATE
-- ============================================
local function resetLockedRoomState()
	currentLockedRoom = nil
	currentLockedRoomUID = nil
	roomExpireTime = 0
	farmingLockedRoom = false
end

-- ============================================
-- IS AUTO ANOMALY ACTIVE
-- ============================================
local function isAutoAnomlyActive()
	local anomalyActive = workspace:GetAttribute("BackroomsAnomalyActive")
	local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
	
	return _G.AutoTPAnomaly and anomalyActive == true and type(endsAt) == "number" and endsAt >= workspace:GetServerTimeNow()
end

-- ============================================
-- GET NEAREST EGG
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
-- SCAN FUNCTION
-- ============================================
local function Scan()
	if _G.IsScanning == true then
		print("Already scanning!")
		return
	end

	_G.IsScanning = true
	resetLockedRoomState()

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
-- AUTO BREAK MINI CHEST
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
-- DIRECTION GUIDE
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
	
	local dirX = math.floor(direction.X * 10) / 10
	local dirZ = math.floor(direction.Z * 10) / 10
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
-- CREATE UI - WITH SCROLL BAR FIXED
-- ============================================
local function CreateUI()
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BackroomUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	
	local mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.Size = UDim2.new(0, 220, 0, 400)
	mainFrame.Position = UDim2.new(0, 5, 0.5, -200)
	mainFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 25)
	mainFrame.BackgroundTransparency = 0.05
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
	title.Text = "⚡ ULTRA HATCH 1000x/ms"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 11
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
	scrollFrame.ScrollBarThickness = 8
	scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 200)
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.Parent = contentFrame
	
	local scrollList = Instance.new("UIListLayout")
	scrollList.Parent = scrollFrame
	scrollList.Padding = UDim.new(0, 2)
	scrollList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	scrollList.SortOrder = Enum.SortOrder.LayoutOrder
	
	scrollList:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		scrollFrame.CanvasSize = UDim2.new(0, 0, 0, scrollList.AbsoluteContentSize.Y + 20)
	end)
	
	-- ============================================
	-- UI ELEMENTS
	-- ============================================
	
	local function createButton(text, callback)
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, 195, 0, 20)
		button.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 1
		button.BorderColor3 = Color3.fromRGB(80, 80, 200)
		button.Text = text
		button.TextColor3 = Color3.fromRGB(255, 255, 255)
		button.TextSize = 10
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
		frame.Size = UDim2.new(0, 195, 0, 20)
		frame.BackgroundTransparency = 1
		frame.Parent = scrollFrame
		
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 130, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 10
		label.Font = Enum.Font.Gotham
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		
		local toggleButton = Instance.new("TextButton")
		toggleButton.Size = UDim2.new(0, 45, 1, 0)
		toggleButton.Position = UDim2.new(1, -45, 0, 0)
		toggleButton.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.BackgroundTransparency = 0.2
		toggleButton.BorderSizePixel = 1
		toggleButton.BorderColor3 = Color3.fromRGB(220, 50, 50)
		toggleButton.Text = "OFF"
		toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		toggleButton.TextSize = 9
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
		divider.Size = UDim2.new(0, 170, 0, 1)
		divider.BackgroundColor3 = Color3.fromRGB(80, 80, 200)
		divider.BackgroundTransparency = 0.5
		divider.Parent = scrollFrame
		return divider
	end
	
	local function createLabel(text, color)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(0, 195, 0, 16)
		label.BackgroundTransparency = 1
		label.Text = text
		label.TextColor3 = color or Color3.fromRGB(200, 200, 255)
		label.TextSize = 10
		label.Font = Enum.Font.GothamBold
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = scrollFrame
		return label
	end
	
	-- STATUS LABELS
	local statusLabel = createLabel("📊 Status: Ready", Color3.fromRGB(200, 200, 255))
	local roomsLabel = createLabel("🏠 Rooms: 0", Color3.fromRGB(200, 200, 255))
	local bossLabel = createLabel("👑 Boss: 0", Color3.fromRGB(255, 200, 100))
	local miniLabel = createLabel("📦 Mini: 0", Color3.fromRGB(100, 200, 255))
	local hatchCountLabel = createLabel("🥚 Hatched: 0", Color3.fromRGB(100, 255, 100))
	
	createDivider()
	
	-- ============================================
	-- ULTRA HATCH SECTION
	-- ============================================
	createLabel("⚡ ULTRA HATCH (1000x/ms)", Color3.fromRGB(255, 50, 50))
	
	-- AUTO HATCH TOGGLE (FIXED - Now working)
	createToggle("🥚 Auto Hatch", function(value)
		_G.AutoHatch = value
		if value then
			print("🥚 Auto Hatch: ON")
			_G.UltraFastHatch = true
			if _G.UI then _G.UI.UpdateStatus("Auto Hatch ON") end
		else
			print("🥚 Auto Hatch: OFF")
			if _G.UI then _G.UI.UpdateStatus("Hatch OFF") end
		end
	end)
	
	-- ULTRA FAST HATCH TOGGLE
	createToggle("⚡ 1000x/ms Hatch", function(value)
		_G.UltraFastHatch = value
		if value then
			print("⚡ ULTRA FAST HATCH ENABLED! 1000x per millisecond!")
			BlockAllHatchAnimations()
			OverrideHatchLimits()
			if _G.UI then _G.UI.UpdateStatus("⚡ 1000x/ms Hatch") end
		else
			print("⚡ Ultra Fast Hatch DISABLED")
			if _G.UI then _G.UI.UpdateStatus("Hatch OFF") end
		end
	end)
	
	-- NEVER STOP TOGGLE
	createToggle("♾️ Never Stop", function(value)
		_G.NeverStopHatching = value
		if value then
			print("♾️ NEVER STOP HATCHING ENABLED!")
			print("🔥 Hatching will continue FOREVER at 1000x per ms!")
		else
			print("♾️ Never Stop Hatching DISABLED")
		end
	end)
	
	-- DISABLE ANIMATION TOGGLE
	createToggle("🎬 No Animations", function(value)
		_G.DisableHatchAnimation = value
		if value then
			print("🎬 Animations DISABLED")
			BlockAllHatchAnimations()
		else
			print("🎬 Animations ENABLED")
		end
	end)
	
	createDivider()
	
	-- ============================================
	-- FARMING TOGGLES
	-- ============================================
	createLabel("🤖 FARMING", Color3.fromRGB(255, 200, 100))
	
	createToggle("🤖 Boss Farm", function(value)
		if (not canDoAction()) then return end
		_G.AutoMiniBoss = value
		if value then
			_G.AutoBreakMiniChest = false
			_G.AutoTPBestEgg = false
			_G.AutoTPLockedEgg = false
			if _G.UI then _G.UI.UpdateStatus("Auto Boss") end
			print("Auto Farm Boss: ON")
		else
			if _G.UI then _G.UI.UpdateStatus("Idle") end
			print("Auto Farm Boss: OFF")
		end
	end)
	
	createToggle("🐾 Mini Chests", function(value)
		if (not canDoAction()) then return end
		_G.AutoBreakMiniChest = value
		if value then
			_G.AutoMiniBoss = false
			_G.AutoTPBestEgg = false
			_G.AutoTPLockedEgg = false
			miniChestIndex = 1
			if _G.UI then _G.UI.UpdateStatus("Mini Chests") end
			print("Auto Mini Chests: ON")
		else
			isInMiniChestRoom = false
			currentMiniChestRoomUID = nil
			isOnRoof = false
			if _G.UI then _G.UI.UpdateStatus("Idle") end
			print("Auto Mini Chests: OFF")
		end
	end)
	
	createToggle("🥚 Best Egg", function(value)
		if (not canDoAction()) then return end
		_G.AutoTPBestEgg = value
		if value then
			_G.AutoMiniBoss = false
			_G.AutoBreakMiniChest = false
			_G.AutoTPLockedEgg = false
			if _G.UI then _G.UI.UpdateStatus("Best Egg") end
			print("Auto Best Egg: ON")
		else
			if _G.UI then _G.UI.UpdateStatus("Idle") end
			print("Auto Best Egg: OFF")
		end
	end)
	
	createToggle("🔒 Locked Egg", function(value)
		if (not canDoAction()) then return end
		_G.AutoTPLockedEgg = value
		if value then
			_G.AutoMiniBoss = false
			_G.AutoBreakMiniChest = false
			_G.AutoTPBestEgg = false
			resetLockedRoomState()
			if _G.UI then _G.UI.UpdateStatus("Locked Egg") end
			print("Auto Locked Egg: ON")
		else
			resetLockedRoomState()
			if _G.UI then _G.UI.UpdateStatus("Idle") end
			print("Auto Locked Egg: OFF")
		end
	end)
	
	createDivider()
	
	-- ============================================
	-- ACTION BUTTONS
	-- ============================================
	createButton("🔍 Scan Rooms", function() Scan() end)
	createButton("🏠 TP Spawn", function() TPtoSpawn() end)
	
	createDivider()
	
	-- ============================================
	-- EMERGENCY STOP
	-- ============================================
	local stopButton = Instance.new("TextButton")
	stopButton.Size = UDim2.new(0, 195, 0, 24)
	stopButton.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	stopButton.BackgroundTransparency = 0.1
	stopButton.BorderSizePixel = 2
	stopButton.BorderColor3 = Color3.fromRGB(255, 0, 0)
	stopButton.Text = "🛑 EMERGENCY STOP"
	stopButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	stopButton.TextSize = 11
	stopButton.Font = Enum.Font.GothamBold
	stopButton.Parent = scrollFrame
	
	stopButton.MouseButton1Click:Connect(function()
		_G.UltraFastHatch = false
		_G.AutoHatch = false
		_G.NeverStopHatching = false
		_G.AutoMiniBoss = false
		_G.AutoBreakMiniChest = false
		_G.AutoTPBestEgg = false
		_G.AutoTPLockedEgg = false
		print("🛑 EMERGENCY STOP ACTIVATED!")
		print("⚠️ All farming and hatching stopped!")
		if _G.UI then _G.UI.UpdateStatus("⚠️ STOPPED") end
	end)
	
	stopButton.MouseEnter:Connect(function()
		stopButton.BackgroundTransparency = 0.2
		stopButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
	end)
	stopButton.MouseLeave:Connect(function()
		stopButton.BackgroundTransparency = 0.1
		stopButton.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
	end)
	
	createDivider()
	
	-- ============================================
	-- DIRECTION GUIDE
	-- ============================================
	createToggle("🧭 Direction Guide", function(value)
		_G.ShowDirectionGuide = value
		if not value and arrowFolder then
			arrowFolder:Destroy()
			arrowFolder = nil
		end
		print("Direction Guide: " .. (value and "ON" or "OFF"))
	end)
	
	-- ============================================
	-- UI FUNCTIONS
	-- ============================================
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
	
	-- ============================================
	-- UPDATE LOOPS
	-- ============================================
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
			if hatchCountLabel then
				hatchCountLabel.Text = "🥚 Hatched: " .. _G.TotalHatched
			end
		end
	end)
	
	-- ============================================
	-- RETRACT FUNCTION
	-- ============================================
	retractButton.MouseButton1Click:Connect(function()
		isRetracted = not isRetracted
		if isRetracted then
			retractButton.Text = "🗕"
			contentFrame.Visible = false
			mainFrame.Size = UDim2.new(0, 50, 0, 26)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
			title.Text = "⚡"
		else
			retractButton.Text = "🗕"
			contentFrame.Visible = true
			mainFrame.Size = UDim2.new(0, 220, 0, 400)
			mainFrame.Position = UDim2.new(0, 5, 0.5, -200)
			title.Text = "⚡ ULTRA HATCH 1000x/ms"
		end
	end)
	
	-- ============================================
	-- DRAGGING
	-- ============================================
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
-- AUTO BREAK MINI CHEST LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.3)
		if not _G.AutoBreakMiniChest then continue end
		AutoBreakMiniChestRoom()
	end
end)

-- ============================================
-- AUTO BEST EGG FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTPBestEgg then
			continue
		end
		
		if isAutoAnomlyActive() then
			continue
		end
		
		if not canDoAction() then
			continue
		end
		
		local character = getCharacter()
		if not character then
			continue
		end
		
		local room = getBestEggRoom()
		if room then
			local isInRoom = isPlayerInRoom(room)
			if (not isInRoom) then
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
-- AUTO LOCKED EGG FARM LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTPLockedEgg then
			farmingLockedRoom = false
			task.wait(1)
			continue
		end
		
		if isAutoAnomlyActive() then
			if farmingLockedRoom then
				farmingLockedRoom = false
				if _G.UI then _G.UI.UpdateStatus("Anomaly Active") end
			end
			task.wait(1)
			continue
		end
		
		if not canDoAction() then
			task.wait(1)
			continue
		end
		
		local character = getCharacter()
		if not character then
			task.wait(1)
			continue
		end
		
		if isCurrentRoomValid() then
			farmingLockedRoom = true
			
			local isInRoom = isPlayerInRoom(currentLockedRoom)
			if not isInRoom then
				TeleportToRoom(currentLockedRoomUID, false)
				task.wait(2)
			end
			
			local timeLeft = getRoomTimeLeft()
			if timeLeft > 0 then
				local minutes = math.floor(timeLeft / 60)
				local seconds = math.floor(timeLeft % 60)
				if _G.UI then
					_G.UI.UpdateStatus(string.format("Locked (%02d:%02d)", minutes, seconds))
				end
			end
			
			task.wait(1)
			continue
		end
		
		if farmingLockedRoom then
			print("Locked room expired, searching for next...")
			farmingLockedRoom = false
		end
		
		if not currentLockedRoom then
			for _, room in ipairs(_G.ScannedRooms) do
				if room.Id == "DeepLockedEggRoom" and isPlayerInRoom(room) then
					if room.ExpireTime then
						currentLockedRoom = room
						currentLockedRoomUID = room.uid
						roomExpireTime = room.ExpireTime
						farmingLockedRoom = true
						print("Found existing locked room")
						break
					end
				end
			end
		end
		
		if not farmingLockedRoom then
			local availableRooms = getAllAvailableLockedRooms()
			
			if #availableRooms > 0 then
				local success = UnlockAndEnterLockedRoom(availableRooms[1], false)
				if success then
					print("Entered locked egg room: " .. availableRooms[1].EggMultiplier .. "x")
					if _G.UI then
						_G.UI.UpdateStatus("Locked " .. availableRooms[1].EggMultiplier .. "x")
					end
					task.wait(2)
				else
					if _G.UI then _G.UI.UpdateStatus("No Key!") end
					task.wait(5)
				end
			else
				if _G.UI then _G.UI.UpdateStatus("No Locked Rooms") end
				print("No locked egg rooms available, hopping...")
				task.wait(3)
				serverHop("No Locked Rooms. Hopping...")
				task.wait(5)
			end
		end
	end
end)

-- ============================================
-- AUTO ANOMALY LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(1)
		
		if not _G.AutoTPAnomaly then
			continue
		end
		
		if not canDoAction() then
			continue
		end
		
		local character = getCharacter()
		if not character then
			continue
		end
		
		local isActive = workspace:GetAttribute("BackroomsAnomalyActive")
		local endsAt = workspace:GetAttribute("BackroomsAnomalyEndsAt")
		
		if not isActive or (type(endsAt) == "number" and workspace:GetServerTimeNow() > endsAt) then
			continue
		end
		
		local pos = workspace:GetAttribute("BackroomsAnomalyPos")
		if not pos then
			continue
		end
		
		local distance = (character:GetPivot().Position - pos).Magnitude
		if distance > 40 then
			Network.Fire("RequestStreaming", pos)
			character:PivotTo(CFrame.new(pos) + Vector3.new(0, 5, 0))
			task.wait(2)
		end
	end
end)

-- ============================================
-- AUTO TAPPER LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.1)
		
		if not _G.AutoTapper then
			continue
		end
		
		local character = getCharacter()
		if not character then
			continue
		end
		
		local breakables = workspace:FindFirstChild("__THINGS"):FindFirstChild("Breakables"):GetChildren()
		local tapRange = 150
		local nearestDistance = math.huge
		local nearestBreakableUID = nil
		
		for _, breakable in ipairs(breakables) do
			local uid = breakable:GetAttribute("BreakableUID")
			if uid and (not breakable:GetAttribute("ManualDamage")) and (not breakable:GetAttribute("DisableDamage")) then
				local breakablePos = breakable:GetPivot().Position
				local distance = (breakablePos - character:GetPivot().Position).Magnitude
				
				if tapRange > distance and distance < nearestDistance then
					nearestDistance = distance
					nearestBreakableUID = uid
				end
			end
		end
		
		if nearestBreakableUID then
			Signal.Fire("AutoClicker_Nearby", nearestBreakableUID)
		end
	end
end)

-- ============================================
-- DIRECTION GUIDE UPDATE LOOP
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(UpdateDirectionGuide)
	end
end)

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
-- WEBHOOK FOR HATCHED PETS
-- ============================================
local function getThumbnailUrl(iconId)
	if not iconId then
		return nil
	end

	local default = "https://www.roblox.com/asset-thumbnail/image?assetId=" .. iconId .. "&width=420&height=420&format=png"

	local success, response = pcall(function()
		return request({
			Url = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. iconId .. "&size=420x420&format=Png&isCircular=false",
			Method = "GET"
		})
	end)

	if not success or response.StatusCode ~= 200 then
		return default
	end

	local decoded = HttpService:JSONDecode(response.Body)
	if not decoded or not decoded.data then
		return default
	end

	local imageUrl = decoded.data[1].imageUrl
	if not imageUrl then
		return default
	end

	return imageUrl
end

local function sendWebhook(data)
	if getgenv().webhook == "" or getgenv().webhook == nil then
		return
	end

	local body = HttpService:JSONEncode(data)
	if not body then
		return
	end

	local success, response = pcall(function()
		return request({
			Url = getgenv().webhook,
			Method = "POST",
			Headers = {["Content-Type"] = "application/json"},
			Body = body
		})
	end)
end

Network.Fired("Items: Update"):Connect(function(player, packet, currencyPacket)
	if not packet or not packet.set then
		return
	end

	for classKey, items in pairs(packet.set) do
		if classKey ~= "Pet" then
			continue
		end

		local classType = Types.TypeUnchecked(classKey)
		if classType then
			for itemUID, itemData in pairs(items) do
				if seenPets[itemUID] == true then
					continue
				end

				local item = classType:From(itemData)
				item:SetUID(itemUID)

				local exclusiveLevel = item:GetExclusiveLevel()
				if exclusiveLevel > 3 then
					seenPets[itemUID] = true

					local itemName = item:GetName()
					local itemIcon = item:GetIcon()
					local exists = item:GetExistCount()
					local rap = item:GetRAP()
					local thumbnailUrl = getThumbnailUrl(string.match(itemIcon, "%d+"))

					local embed = {
						title = "||" .. localPlayer.Name .. "|| just hatched a " .. itemName .. "!",
						color = 16753920,
						fields = {
							{
								name = "Exists",
								value = tostring(NumberShorten(exists)),
								inline = true
							},
							{
								name = "RAP",
								value = tostring(NumberShorten(rap)),
								inline = true
							}
						},
						footer = { text = "discord.gg/k2mSRWgfhX" },
						timestamp = DateTime.now():ToIsoDate()
					}

					if thumbnailUrl then
						embed.thumbnail = { url = thumbnailUrl }
					end

					local content = (getgenv().discordId == "" or getgenv().discordId == nil)
						and "@everyone"
						or "<@" .. getgenv().discordId .. ">"

					sendWebhook({
						username = "Ultra Hatch 1000x",
						avatar_url = "https://raw.githubusercontent.com/BuildIntoPirates/ps99/main/channels4_profile.jpg",
						content = content,
						embeds = { embed }
					})
				end
			end
		end
	end
end)

-- ============================================
-- PERFORMANCE OPTIMIZATION
-- ============================================
task.spawn(function()
	while true do
		task.wait(0.01)
		
		if _G.UltraFastHatch then
			pcall(function()
				settings().Rendering.QualityLevel = 1
				settings().Rendering.ShadowQuality = 0
				settings().Rendering.EffectsQuality = 0
				game:SetSimulationRadius(500)
			end)
		end
	end
end)

-- ============================================
-- AUTO-RESTART IF STOPPED
-- ============================================
task.spawn(function()
	while true do
		task.wait(5)
		
		if _G.NeverStopHatching and not _G.UltraFastHatch then
			print("🔄 Auto-restarting hatching...")
			_G.UltraFastHatch = true
			_G.AutoHatch = true
			BlockAllHatchAnimations()
		end
	end
end)

-- ============================================
-- INITIALIZE SCRIPT
-- ============================================
local ui = CreateUI()
print("=== ⚡ ULTRA HATCH 1000x/ms LOADED ===")
print("🚀 1000 eggs per millisecond!")
print("🔥 Never Stop: " .. tostring(_G.NeverStopHatching))
print("🥚 Auto Hatch: " .. tostring(_G.AutoHatch))
print("⚡ Ultra Fast: " .. tostring(_G.UltraFastHatch))
print("==========================================")

task.wait(2)
Scan()
