-- PS99 Backrooms Auto Farm Script
-- by @pirategames and @majinbacon
-- FIXED: Invisible scanning using sky teleport (+200 studs above)
-- VOID PROTECTION REMOVED
-- ORIGINAL UI RESTORED WITH ALL FUNCTIONS

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local VirtualUser = game:GetService("VirtualUser")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Safe module loading
local function safeRequire(path)
    local success, result = pcall(function()
        return require(path)
    end)
    return result
end

local Network = safeRequire(ReplicatedStorage.Library.Client.Network)
local PlayerPet = safeRequire(ReplicatedStorage.Library.Client.PlayerPet)
local InstancingCmds = safeRequire(ReplicatedStorage.Library.Client.InstancingCmds)
local MiscItem = safeRequire(ReplicatedStorage.Library.Items.MiscItem)
local EggCmds = safeRequire(ReplicatedStorage.Library.Client.EggCmds)
local CustomEggsCmds = safeRequire(ReplicatedStorage.Library.Client.CustomEggsCmds)
local Signal = safeRequire(ReplicatedStorage.Library.Signal)

if not Network then
    print("⚠️ Network module not found - trying again...")
    task.wait(1)
    Network = safeRequire(ReplicatedStorage.Library.Client.Network)
end

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
if PlayerPet then
    local oldCalculate = PlayerPet.CalculateSpeedMultiplier
    PlayerPet.CalculateSpeedMultiplier = function(self, ...)
        if _G.InfinitePetSpeed then
            return 100000
        end
        return oldCalculate(self, ...)
    end
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
    
    local lockedDoors = roomModel:FindFirstChild("LockedDoors")
    if lockedDoors then
        for _, child in ipairs(lockedDoors:GetChildren()) do
            local lock = child:FindFirstChild("Lock")
            if lock and lock.Transparency < 1 then
                local doorCFrame = child.CFrame
                local doorPosition = child.Position
                local doorFront = doorCFrame.LookVector
                doorFrontPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
                hallwayPos = doorFrontPos
                break
            end
        end
    end
    
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
    
    local direction = (targetPos - startPos).Unit
    local distance = (targetPos - startPos).Magnitude
    
    if distance < 15 then
        humanoid:MoveTo(targetPos)
        task.wait(0.5)
        return true
    end
    
    local waypoints = {}
    local numWaypoints = math.ceil(distance / 5)
    
    for i = 1, numWaypoints do
        local t = i / numWaypoints
        local waypoint = startPos + (direction * (distance * t))
        waypoint = Vector3.new(waypoint.X, startPos.Y + 1, waypoint.Z)
        table.insert(waypoints, waypoint)
    end
    
    table.insert(waypoints, targetPos)
    
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

    local pos = enterPosition + Vector3.new(0, 4, 0)

    if Network then
        Network.Fire("RequestStreaming", pos)
    end

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
-- MAKE CHARACTER INVISIBLE
-- ============================================
local function setCharacterInvisible(character, invisible)
    if not character then return end
    
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            if invisible then
                part.Transparency = 1
                part.CanCollide = false
            else
                part.Transparency = 0
                part.CanCollide = true
            end
        end
    end
end

-- ============================================
-- TP TO SKY (200 STUD ABOVE) - INVISIBLE
-- ============================================
local function TeleportToSky()
    _G.Teleporting = true
    
    local character = getCharacter()
    if not character then
        _G.Teleporting = false
        return nil
    end
    
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then
        _G.Teleporting = false
        return nil
    end
    
    local folder = getGeneratedBackrooms()
    if not folder then
        _G.Teleporting = false
        return nil
    end
    
    local spawnRoom = folder:FindFirstChild("DeepSpawnRoom")
    if not spawnRoom then
        _G.Teleporting = false
        return nil
    end
    
    local spawnLocation = spawnRoom:FindFirstChild("DEEP_SPAWN_LOCATION")
    if not spawnLocation then
        _G.Teleporting = false
        return nil
    end
    
    local spawnPos = spawnLocation.Position
    -- Teleport 200 studs ABOVE the spawn (invisible in the sky)
    local skyPos = Vector3.new(spawnPos.X, spawnPos.Y + 200, spawnPos.Z)
    
    print("☁️ Teleporting to SKY at Y=" .. (spawnPos.Y + 200) .. " (invisible)")
    
    if Network then
        Network.Fire("RequestStreaming", skyPos)
    end
    rootPart.Anchored = true
    rootPart.CFrame = CFrame.new(skyPos)
    task.wait(0.5)
    rootPart.Anchored = false
    
    _G.Teleporting = false
    return skyPos
end

-- ============================================
-- LOCK DOOR SYSTEM
-- ============================================
local function keyCheck()
    if not MiscItem then return false end
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

    if not InstancingCmds then return false end
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
    
    local teleportPos = doorPosition + (doorFront * 8) + Vector3.new(0, 2, 0)
    local doorFrontPos = doorPosition + (doorFront * 4) + Vector3.new(0, 2, 0)
    
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    
    if rootPart then
        if Network then Network.Fire("RequestStreaming", teleportPos) end
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
    
    local isUnlocked = true
    for _, child in ipairs(lockedDoors:GetChildren()) do
        local lock = child:FindFirstChild("Lock")
        if lock and lock.Transparency < 1 then
            isUnlocked = false
            break
        end
    end
    
    if not isUnlocked then
        activeInstance:FireCustom("AbstractRoom_FireServer", roomUID, "UnlockDoors")
        task.wait(1)
    end
    
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

    if not CustomEggsCmds then return nil end
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
    if not egg or not Network then return end
    
    pcall(function()
        if not EggCmds then return end
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
        return false
    end

    local pos = workspace:GetAttribute("BackroomsAnomalyPos")
    if not pos then
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

    if Network then Network.Fire("RequestStreaming", pos) end

    rootPart.Anchored = true
    rootPart.CFrame = CFrame.new(pos) + Vector3.new(0, 5, 0)

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
    
    local centerCFrame = roomModel:GetBoundingBox()
    local roomCenter = centerCFrame.Position
    
    local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
    if breakZone then
        roomCenter = breakZone:GetPivot().Position
    end
    
    local centerPos = Vector3.new(roomCenter.X, roomCenter.Y + 2, roomCenter.Z)
    local abovePos = centerPos + Vector3.new(0, 100, 0)

    local forceField = Instance.new("ForceField")
    forceField.Visible = false
    forceField.Parent = character

    if Network then Network.Fire("RequestStreaming", abovePos) end

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
end

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
        _G.Teleporting = false
        return
    end

    local roomModel = roomData.Model
    local roomId = roomData.Id

    local targetPos = nil
    
    if roomId == "DeepLockedEggRoom" then
        local eggObj = roomModel:FindFirstChild("Backrooms Egg")
        if eggObj then
            targetPos = eggObj.Position + Vector3.new(0, 2, 0)
        end
    end
    
    if roomId == "GameMastersStage" then
        local breakZone = roomModel:FindFirstChild("BREAK_ZONE")
        if breakZone then
            targetPos = breakZone:GetPivot().Position + Vector3.new(0, 2, 0)
        end
    end
    
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
        
        if Network then Network.Fire("RequestStreaming", hallwayPos) end
        rootPart.Anchored = true
        rootPart.CFrame = CFrame.new(hallwayPos)
        
        task.delay(1.5, function()
            if forceField and forceField.Parent then 
                forceField:Destroy() 
            end
            rootPart.Anchored = false
        end)
        
        task.wait(0.5)
        
        local success = WalkThroughHallway(hallwayPos, targetPos)
        
        if not success then
            rootPart.Anchored = true
            rootPart.CFrame = CFrame.new(targetPos)
            task.wait(0.3)
            rootPart.Anchored = false
        end
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
-- SCAN FUNCTION - USING SKY (200 STUD ABOVE) - INVISIBLE
-- ============================================
local function Scan()
    if _G.IsScanning == true then
        print("Already scanning!")
        return
    end

    _G.IsScanning = true

    local message = createMessage("Exploring the backrooms...")
    print("Starting FAST scan (INVISIBLE - in the sky)...")
    
    if _G.UI then
        _G.UI.UpdateStatus("Scanning (in sky)...")
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
        end
    end
    
    _G.AllBossRooms = {}
    _G.AllMiniChestRooms = {}
    _G.MiniChestCycleIndex = 1
    
    -- Teleport to sky (200 studs above spawn)
    local skyPos = TeleportToSky()
    if not skyPos then
        print("⚠️ Failed to teleport to sky!")
        _G.IsScanning = false
        return
    end
    
    local character = getCharacter()
    
    -- Make character invisible
    if character then
        setCharacterInvisible(character, true)
    end
    
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
                        end
                        
                        if string.match(roomId, "DeepChestRoom") ~= nil then
                            table.insert(_G.AllMiniChestRooms, roomData)
                            miniChestCount = miniChestCount + 1
                        end
                        
                        if string.match(roomId, "DeepFreeEggRoom") ~= nil or string.match(roomId, "DeepFreeEggRoom%d+") ~= nil then
                            eggCount = eggCount + 1
                        end
                        
                        if string.match(roomId, "DeepLockedEggRoom") ~= nil then
                            lockedEggCount = lockedEggCount + 1
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

    local maxLoops = 200
    local loopCount = 0
    local noNewRoomsCount = 0
    
    while loopCount < maxLoops and #_G.ScannedRooms < 400 do
        loopCount = loopCount + 1
        
        if _G.Teleporting == true then
            task.wait(0.1)
            continue
        end

        -- Just scan without moving (we're in the sky)
        scanExistingRooms()
        
        if loopCount % 10 == 0 then
            print("Progress: " .. #_G.ScannedRooms .. " rooms scanned (" .. loopCount .. "/" .. maxLoops .. ")")
        end
        
        task.wait(0.2)
    end

    _G.IsScanning = false
    
    if _G.UI then
        _G.UI.UpdateStatus("Scan Complete (" .. #_G.ScannedRooms .. " rooms)")
        _G.UI.UpdateRooms(#_G.ScannedRooms)
    end
    
    -- Make character visible again
    if character then
        setCharacterInvisible(character, false)
    end
    
    game.Debris:AddItem(message, 0)
    TPtoSpawn()
    
    print("=== FAST SCAN FINISHED ===")
    print("Total rooms scanned: " .. #_G.ScannedRooms)
    print("👑 Boss Rooms found: " .. #_G.AllBossRooms)
    print("📦 Mini Chest Rooms found: " .. #_G.AllMiniChestRooms)
    print("☁️ Scanned from SKY (200 studs above - invisible to others)")
    print("=========================")
end

-- ============================================
-- AUTO CLICKER
-- ============================================
task.spawn(function()
    while true do
        task.wait(_G.AutoClickerInterval)
        if _G.AutoClickerEnabled then
            pcall(function()
                local VirtualInputManager = game:GetService("VirtualInputManager")
                VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, true, game, 0)
                task.wait(0.02)
                VirtualInputManager:SendMouseButtonEvent(_G.AutoClickerX, _G.AutoClickerY, 0, false, game, 0)
            end)
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
                    for _, b in ipairs(breakables) do
                        local bId = b:GetAttribute("BreakableID")
                        if bId == "Daydream Mimic Chest2" then
                            local bPos = b:GetPivot().Position
                            local distance = (bPos - pos).Magnitude
                            if distance < _G.ChestSearchRadius then
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
                                if distance < _G.ChestSearchRadius then
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
                    if Network then Network.UnreliableFire("Breakables_PlayerDealDamage", bUID) end
                    if PlayerPet then
                        local activePets = PlayerPet.GetByPlayer(localPlayer)
                        for _, pet in pairs(activePets) do
                            if pet.cpet then pet:SetTarget(targetBreakable) end
                        end
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
            _G.Teleporting = true
            if Network then Network.Fire("RequestStreaming", pos) end
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
            end
        end
    end
end)

-- ============================================
-- ANTI AFK
-- ============================================
if localPlayer and Signal and VirtualUser then
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
end

-- ============================================
-- CREATE UI (ORIGINAL COMPLETE VERSION)
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
    
    -- ALL ORIGINAL BUTTONS
    createButton("🔍 Scan (Invisible)", function() Scan() end)
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
    createButton("✨ TP Anomaly (250x)", function()
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
    
    -- ALL ORIGINAL TOGGLES
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
    createToggle("🧭 Direction", function(value)
        _G.ShowDirectionGuide = value
    end)
    createToggle("🖱️ Auto Clicker", function(value)
        _G.AutoClickerEnabled = value
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
            contentFrame.Visible = false
            mainFrame.Size = UDim2.new(0, 50, 0, 26)
            mainFrame.Position = UDim2.new(0, 5, 0.5, -13)
            title.Text = "🎮"
        else
            contentFrame.Visible = true
            mainFrame.Size = UDim2.new(0, 200, 0, 150)
            mainFrame.Position = UDim2.new(0, 5, 0.5, -75)
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
    
    -- RED DOT CLICKER
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
    
    return screenGui
end

-- ============================================
-- INITIALIZE
-- ============================================
local ui = CreateUI()
print("✅ Backroom UI loaded!")
print("=========================================")
print("🔍 FAST SCAN ACTIVATED (INVISIBLE - SKY)")
print("☁️ Teleports to SKY (+200 studs above)")
print("👻 Completely invisible to other players")
print("=========================================")

-- Start automatic scan
task.wait(2)
Scan()
