FPP = FPP or {}
local plyMeta = FindMetaTable("Player")
local entMeta = FindMetaTable("Entity")

local rawget = rawget
local rawset = rawset
local pairs = pairs
local IsValid = IsValid

local stringLower = string.lower
local stringUpper = string.upper

local tableInsert = table.insert
local tableHasValue = table.HasValue

local bitBor = bit.bor
local bitBand = bit.band
local bitLShift = bit.lshift

local netWriteUInt = net.WriteUInt
local netStart = net.Start
local netSend = net.Send

local timerExists = timer.Exists
local timerCreate = timer.Create
local timerRemove = timer.Remove

local GetAllConstrainedEntities = constraint.GetAllConstrainedEntities


local EFL_SERVER_ONLY = EFL_SERVER_ONLY

---------------------------------------------------------------------------
-- Entity data explanation.
-- Every ent has a field FPPCanTouch. This is a table with one entry per player.
-- Every bit in FPPCanTouch represents a type.
--     The first bit says whether the player can physgun the ent
--     The second bit whether the player can use gravun on the ent
--     etc.
--
-- Then there is the FPPCanTouchWhy var This var follows the same idea as FPPCanTouch
-- except there are five bits for each type. These 4 bits represent a number that shows the reason
-- why a player can or cannot touch a prop.
---------------------------------------------------------------------------

local touchTypes = {
    Physgun = 1,
    Gravgun = 2,
    Toolgun = 4,
    PlayerUse = 8,
    EntityDamage = 16
}

local touchTypeNumbers = {
    [1] = "Physgun",
    [2] = "Gravgun",
    [4] = "Toolgun",
    [8] = "PlayerUse",
    [16] = "EntityDamage"
}

local reasonSize = 4 -- bits

local reasonNumbers = {
    ["owner"] = 1,
    ["world"] = 2,
    ["disconnected"] = 3,
    ["blocked"] = 4,
    ["constrained"] = 5,
    ["buddy"] = 6,
    ["shared"] = 7,
    ["player"] = 8,
}

---------------------------------------------------------------------------
-- Utility functions
---------------------------------------------------------------------------
local function getPlySetting(ply, settingName)
    return (ply[settingName] or ply:GetInfo(settingName)) == "1"
end

local function getSetting(touchType)
    return touchType .. "1", stringUpper("FPP_" .. touchType .. "1")
end

local constraints = { -- These little buggers think they're not constraints, but they are
    ["phys_spring"] = true,
}
local function isConstraint(ent)
    return ent:IsConstraint() or rawget( constraints, ent:GetClass() ) or false
end

---------------------------------------------------------------------------
-- Touch calculations
---------------------------------------------------------------------------
local hardWhiteListed = { -- things that mess up when not allowed
    ["worldspawn"] = true, -- constraints with the world
    ["gmod_anchor"] = true -- used in slider constraints with world
}
local function calculateCanTouchForType(ply, ent, touchType)
    if not IsValid( ent ) then return false, 0 end

    ply.FPP_Privileges = ply.FPP_Privileges or {}
    local privileges = ply.FPP_Privileges

    local class = ent:GetClass()
    local setting, tablename = getSetting(touchType)

    local settings = rawget( FPP, "Settings" )
    local FPPSettings = rawget( settings, tablename )

    -- hard white list
    if rawget( hardWhiteListed, class ) then
        return true, rawget( reasonNumbers, "world" )
    end

    -- picking up players
    if touchType == "Physgun" and ent:IsPlayer() and not getPlySetting(ply, "cl_pickupplayers") then
        return false, rawget( reasonNumbers, "player" )
    end

    -- blocked entity
    local whitelist = rawget( FPPSettings, "iswhitelist" ) ~= 0

    local blocked = rawget( FPP, "Blocked" )
    local blockedSetting = rawget( blocked, setting )
    local isInList = rawget( blockedSetting, stringLower( class ) ) or false

    local isAdmin = rawget( privileges, "FPP_TouchOtherPlayersProps" )
    local isBlocked = whitelist ~= isInList -- XOR

    if isBlocked then
        local adminsCanTouchBlocked = rawget( FPPSettings, "admincanblocked" ) ~= 0
        local playersCanBlocked = rawget( FPPSettings, "canblocked" ) ~= 0

        local canSpawnBlocked = playersCanBlocked or ( isAdmin and adminsCanTouchBlocked )
        local shouldBlock = canSpawnBlocked and not getPlySetting( ply, "FPP_PrivateSettings_BlockedProps" )
        return shouldBlock, rawget( reasonNumbers, "blocked" )
    end

    -- touch own props
    local owner = ent.FPPOwner -- Circumvent CPPI for micro-optimisation
    if owner == ply then
        return not getPlySetting(ply, "FPP_PrivateSettings_OwnProps"), rawget( reasonNumbers, "owner" )
    end

    local noTouchOtherPlayerProps = getPlySetting(ply, "FPP_PrivateSettings_OtherPlayerProps")

    -- Shared entity
    -- TODO: Make allowedPlayers a [ent] = true lookup table
    if ent.AllowedPlayers and tableHasValue(ent.AllowedPlayers, ply) then
        return not noTouchOtherPlayerProps, rawget( reasonNumbers, "shared" )
    end
    if ent["Share" .. setting] then return not noTouchOtherPlayerProps, rawget( reasonNumbers, "shared" ) end

    if IsValid(owner) then
        -- Player is buddies with the owner of the entity
        local buddies = owner.Buddies
        local buddyData = buddies and rawget( buddies, ply )
        local buddyCanTouch = buddyData and rawget( buddyData, touchType )
        if buddyCanTouch then return
            not noTouchOtherPlayerProps, rawget( reasonNumbers, "buddy" )
        end

        -- Someone else's prop
        local adminProps = rawget( FPPSettings, "adminall" ) ~= 0
        return isAdmin and adminProps and not noTouchOtherPlayerProps, rawget( reasonNumbers, "owner" )
    end

    -- World props and disconnected players' props
    local adminWorldProps = rawget( FPPSettings, "adminworldprops" ) ~= 0
    local peopleWorldProps = rawget( FPPSettings, "worldprops" ) ~= 0
    local restrictWorld = getPlySetting(ply, "FPP_PrivateSettings_WorldProps")

    return not restrictWorld and (peopleWorldProps or (isAdmin and adminWorldProps)),
           owner == nil and rawget( reasonNumbers, "world" ) or rawget( reasonNumbers, "disconnected" )
end

local blockedEnts = {
    ["ai_network"] = true,
    ["network"] = true, -- alternative name for ai_network
    ["ambient_generic"] = true,
    ["beam"] = true,
    ["bodyque"] = true,
    ["env_soundscape"] = true,
    ["env_sprite"] = true,
    ["env_sun"] = true,
    ["env_tonemap_controller"] = true,
    ["func_useableladder"] = true,
    ["gmod_hands"] = true,
    ["info_ladder_dismount"] = true,
    ["info_player_start"] = true,
    ["info_player_terrorist"] = true,
    ["light_environment"] = true,
    ["light_spot"] = true,
    ["physgun_beam"] = true,
    ["player_manager"] = true,
    ["point_spotlight"] = true,
    ["predicted_viewmodel"] = true,
    ["scene_manager"] = true,
    ["shadow_control"] = true,
    ["soundent"] = true,
    ["spotlight_end"] = true,
    ["water_lod_control"] = true,
    ["gmod_gamerules"] = true,
    ["bodyqueue"] = true,
    ["phys_bone_follower"] = true,
}
function FPP.calculateCanTouch(ply, ent)
    local canTouch = 0

    local reasons = 0
    local i = 0

    for Bit, touchType in pairs(touchTypeNumbers) do
        local canTouchType, why = calculateCanTouchForType(ply, ent, touchType)
        if canTouchType then
            canTouch = bitBor( canTouch, Bit )
        end

        reasons = bitBor( reasons, bitLShift(why, i * reasonSize) )

        i = i + 1
    end

    ent.FPPCanTouch = ent.FPPCanTouch or {}
    ent.FPPCanTouchWhy = ent.FPPCanTouchWhy or {}

    local changed = rawget( ent.FPPCanTouch, ply ) ~= canTouch or rawget( ent.FPPCanTouchWhy, ply ) ~= reasons or ent.FPPOwnerChanged
    rawset( ent.FPPCanTouch, ply, canTouch )
    rawset( ent.FPPCanTouchWhy, ply, reasons )

    return changed
end

-- try not to call this with both player.GetAll() and ents.GetAll()
local function recalculateCanTouch(players, entities)
    local playersCount = #players

    local removeIfNeeded = function( i, v )
        if not IsValid(v) then
            rawset( entities, i, nil )
            return
        end

        if v:IsEFlagSet(EFL_SERVER_ONLY) then
            rawset( entities, i, nil )
            return
        end

        if rawget( blockedEnts, v:GetClass() ) then
            rawset( entities, i, nil )
            return
        end

        if v:IsWeapon() and IsValid(v.Owner) then
            rawset( entities, i, nil )
            return
        end
    end

    local entsCount = #entities

    for i = 1, entsCount do
        local v = rawget( entities, i )
        removeIfNeeded( i, v )
    end

    local calculateCanTouch = FPP.calculateCanTouch

    for p = 1, playersCount do
        local ply = rawget( players, p )

        if IsValid( ply ) then
            ply.FPPIsAdmin = ply.FPP_Privileges.FPP_TouchOtherPlayersProps
            ply.FPP_PrivateSettings_OtherPlayerProps = ply:GetInfo("FPP_PrivateSettings_OtherPlayerProps")
            ply.cl_pickupplayers = ply:GetInfo("cl_pickupplayers")
            ply.FPP_PrivateSettings_BlockedProps = ply:GetInfo("FPP_PrivateSettings_BlockedProps")
            ply.FPP_PrivateSettings_OwnProps = ply:GetInfo("FPP_PrivateSettings_OwnProps")
            ply.FPP_PrivateSettings_WorldProps = ply:GetInfo("FPP_PrivateSettings_WorldProps")
            local changed = {}

            for i = 1, entsCount do
                local ent = rawget( entities, i )

                -- May have been removed for being ineligible
                if ent then
                    local hasChanged = calculateCanTouch( ply, ent )
                    if hasChanged then tableInsert( changed, ent ) end
                end
            end

            FPP.plySendTouchData( ply, changed )

            ply.FPP_PrivateSettings_OtherPlayerProps = nil
            ply.cl_pickupplayers = nil
            ply.FPP_PrivateSettings_BlockedProps = nil
            ply.FPP_PrivateSettings_OwnProps = nil
            ply.FPP_PrivateSettings_WorldProps = nil
            ply.FPPIsAdmin = nil
        end
    end
end

function FPP.recalculateCanTouch(plys, ens)
    FPP.calculatePlayerPrivilege("FPP_TouchOtherPlayersProps", function() recalculateCanTouch(plys, ens) end)
end

---------------------------------------------------------------------------
-- Touch interface
---------------------------------------------------------------------------
function FPP.plyCanTouchEnt(ply, ent, touchType)
    ent.FPPCanTouch = ent.FPPCanTouch or {}
    rawset( ent.FPPCanTouch, ply, rawget( ent.FPPCanTouch, ply ) or 0 )
    ent.AllowedPlayers = ent.AllowedPlayers or {}

    local canTouch = rawget( ent.FPPCanTouch, ply )

    -- if an entity is constrained, return the least of the rights
    local restrictConstraint = ent.FPPRestrictConstraint
    local plyConstraint = restrictConstraint and rawget( restrictConstraint, ply )

    if plyConstraint then
        canTouch = bitBand( plyConstraint, rawget( ent.FPPCanTouch, ply  ) )
    end

    -- return the answer for every touch type if parameter is empty
    if not touchType then return canTouch end

    return bitBor( canTouch, rawget( touchTypes, touchType ) ) == canTouch
end

function FPP.entGetOwner(ent)
    return ent.FPPOwner
end

---------------------------------------------------------------------------
-- Networking
---------------------------------------------------------------------------
util.AddNetworkString("FPP_TouchabilityData")
local function netWriteEntData(ply, ent)
    -- EntIndex for when it's out of the PVS of the player
    netWriteUInt(ent:EntIndex(), 32)

    local owner = ent:CPPIGetOwner()
    netWriteUInt(IsValid(owner) and owner:EntIndex() or -1, 32)
    netWriteUInt( ent.FPPRestrictConstraint and rawget( ent.FPPRestrictConstraint, ply ) or rawget( ent.FPPCanTouch, ply ), 5 ) -- touchability information
    netWriteUInt( ent.FPPConstraintReasons and rawget( ent.FPPConstraintReasons, ply ) or rawget( ent.FPPCanTouchWhy, ply ), 20 ) -- reasons
end

function FPP.plySendTouchData(ply, entities)
    local count = #entities
    if count == 0 then return end

    netStart( "FPP_TouchabilityData" )
        for i = 1, count do
            netWriteEntData( ply, rawget( entities, i ) )
            net.WriteBit( i == count )
        end
    netSend( ply )
end

---------------------------------------------------------------------------
-- Events that trigger recalculation
---------------------------------------------------------------------------
local function handleConstraintCreation(ent)
    local ent1, ent2 = ent:GetConstrainedEntities()
    ent1, ent2 = ent1 or ent.Ent1, ent2 or ent.Ent2

    if not ent1 then return end
    if not ent2 then return end
    if not ent1.FPPCanTouch  then return end
    if not ent2.FPPCanTouch then return end

    local reason = 0
    local i = 0
    local constrainedReason = rawget( reasonNumbers, "constrained" )

    for Bit, touchType in pairs(touchTypeNumbers) do
        reason = bitBor( reason, bitLShift(constrainedReason, i * reasonSize ) )
        i = i + 1
    end

    local allPlayers = player.GetAll()
    local playersCount = #allPlayers

    local plyCanTouchEnt = rawget( FPP, "plyCanTouchEnt" )
    for i = 1, playersCount do
        local ply = rawget( allPlayers, i )
        local touch1, touch2 = plyCanTouchEnt(ply, ent1), plyCanTouchEnt(ply, ent2)

        -- As long as the constrained entities have the same touching rights.
        if touch1 ~= touch2 then
            local restrictedAccess = bitBand( touch1, touch2 )

            local send = {}

            local constrainedEntities = GetAllConstrainedEntities( ent1 ) or {}
            local constrainedEntitiesCount = #constrainedEntities

            for i = 1, constrainedEntitiesCount do
                local e = rawget( constrainedEntities, i )

                if IsValid( e ) then
                    if plyCanTouchEnt(ply, e) ~= restrictedAccess then
                        e.FPPRestrictConstraint = e.FPPRestrictConstraint or {}
                        e.FPPConstraintReasons = e.FPPConstraintReasons or {}
                        e.FPPRestrictConstraint[ply] = restrictedAccess
                        e.FPPConstraintReasons[ply] = reason

                        tableInsert(send, e)
                    end
                end
            end

            FPP.plySendTouchData(ply, send)
        end
    end

end

---------------------------------------------------------------------------
-- On entity created
---------------------------------------------------------------------------
local function onEntitiesCreated(entities)
    local entitiesCount = #entities
    local send = {}

    local allPlayers = player.GetAll()
    local playersCount = #allPlayers

    local function handleEnt( ent )
        if not IsValid( ent ) then return end

        if isConstraint( ent ) then
            handleConstraintCreation( ent )
            return
        end

        -- Don't send information about server only entities to the clients
        if ent:GetSolid() == 0 or ent:IsEFlagSet( EFL_SERVER_ONLY ) then
            return
        end

        if rawget( blockedEnts, ent:GetClass() ) then return end

        for i = 1, playersCount do
            local ply = rawget( allPlayers, i )
            FPP.calculateCanTouch( ply, ent )
        end

        tableInsert( send, ent )
    end

    for i = 1, entitiesCount do
        local ent = rawget( entities, i )
        handleEnt( ent )
    end

    for i = 1, playersCount do
        local ply = rawget( allPlayers, i )
        FPP.plySendTouchData( ply, send )
    end
end


-- Make a queue of entities created per frame, so the server will send out a maximum-
-- of one message per player per frame
local entQueue = {}

local clearQueue = function()
    local queueCount = #entQueue
    for i = 1, queueCount do
        rawset( entQueue, i, nil )
    end
end

local timerFunc = function()
    onEntitiesCreated( entQueue )
    clearQueue()
    timerRemove( "FPP_OnEntityCreatedTimer" )
end

hook.Add("OnEntityCreated", "FPP_EntityCreated", function(ent)
    tableInsert( entQueue, ent )

    if timerExists( "FPP_OnEntityCreatedTimer" ) then return end
    timerCreate( "FPP_OnEntityCreatedTimer", 0, 1, timerFunc )
end)


---------------------------------------------------------------------------
-- On entity removed
---------------------------------------------------------------------------
-- Recalculates touchability information for constrained entities
-- Note: Assumes normal touchability information is up to date!
-- Update constraints, O(players * (entities + constraints))
function FPP.RecalculateConstrainedEntities( players, entities )
    local playersCount = #players
    local entitiesCount = #entities

    local function handleEnt( i, ent )
        if not IsValid( ent ) then
            rawset( entities, i, nil )
            return
        end

        if ent:IsEFlagSet(EFL_SERVER_ONLY) then
            rawset( entities, i, nil )
            return
        end

        if rawget( blockedEnts, ent:GetClass() ) then
            rawset( entities, i, nil )
            return
        end

        ent.FPPRestrictConstraint = ent.FPPRestrictConstraint or {}
        ent.FPPConstraintReasons = ent.FPPConstraintReasons or {}
    end

    for i = 1, entitiesCount do
        local ent = rawget( entities, i )
        handleEnt( i, ent )
    end

    entitiesCount = #entities

    local plyCanTouchEnt = rawget( FPP, "plyCanTouchEnt" )
    local plySendTouchData = rawget( FPP, "plySendTouchData" )

    -- constrained entities form a graph.
    for p = 1, playersCount do
        local ply = rawget( players, p )
        local discovered = {}
        -- BFS vars
        local BFSQueue = {}
        local black, gray = {}, {} -- black = fully discovered, gray = seen, but discovery from this point is needed
        local value -- used as key and value of the BFSQueue

        local function handleEnt( ent )
            if rawget( discovered, ent ) then return end -- We've seen this ent in a graph
            ent.FPPCanTouch = ent.FPPCanTouch or {}
            rawset( ent.FPPCanTouch, ply, rawget( ent.FPPCanTouch, ply ) or 0 )

            local left, right = 1, 2
            rawset( BFSQueue, left, ent )

            local FPP_CanTouch = rawget( ent.FPPCanTouch, ply ) -- Find out the canTouch state
            while rawget( BFSQueue, left ) do
                value = rawget( BFSQueue, left )
                rawset( BFSQueue, left, nil )
                left = left + 1

                local constraints = value.Constraints or {}
                local constraintsCount = #constraints
                for i = 1, constraintsCount do
                    local constr = rawget( constraints, i )
                    local otherEnt = constr.Ent1 == value and constr.Ent2 or constr.Ent1

                    if IsValid( otherEnt ) and ( rawget( gray, otherEnt ) == nil ) and ( rawget( black, otherEnt ) == nil ) then
                        rawset( gray, otherEnt, true )
                        rawset( BFSQueue, right, otherEnt )
                        right = right + 1
                    end
                end

                rawset( black, value, true )
                rawset( discovered, value, true )

                -- The entity doesn't necessarily have CanTouch data at this point
                value.FPPCanTouch = value.FPPCanTouch or {}
                rawset( value.FPPCanTouch, ply, rawget( value.FPPCanTouch, ply ) or 0 )
                FPP_CanTouch = bitBand( FPP_CanTouch or 0, rawget( value.FPPCanTouch, ply ) )
            end

            -- now update the ents to the client
            local updated = {}
            for e in pairs(black) do
                if plyCanTouchEnt( ply, e ) ~= FPP_CanTouch then
                    e.FPPRestrictConstraint = e.FPPRestrictConstraint or {}
                    rawset( e.FPPRestrictConstraint, ply, rawget( e.FPPCanTouch, ply ) ~= FPP_CanTouch and FPP_CanTouch or nil )
                    tableInsert( updated, e )
                end
            end
            plySendTouchData( ply, updated )

            -- reset BFS information for next BFS round
            black = {}
            gray = {}
        end

        for i = 1, entitiesCount do
            local ent = rawget( entities, i )
            handleEnt( ent )
        end
    end
end

local entMem = {}
local function constraintRemovedTimer(ent1, ent2, constrainedEnts)
    if not IsValid(ent1) and not IsValid(ent2) or not constrainedEnts then return end

    FPP.RecalculateConstrainedEntities(player.GetAll(), constrainedEnts)
    entMem = {}
end

local function handleConstraintRemoved(ent)
    local ent1, ent2 = ent:GetConstrainedEntities()
    ent1, ent2 = ent1 or ent.Ent1, ent2 or ent.Ent2

    if not IsValid(ent1) or not IsValid(ent2) then return end
    -- prevent the function from being called too often when many constraints are removed at once
    if rawget( entMem, ent1 ) or rawget( entMem, ent2 ) then return end
    rawset( entMem, ent1, true )
    rawset( entMem, ent2, true )

    -- the constraint is still there, so this includes ent2's constraints
    local constrainedEnts = GetAllConstrainedEntities( ent1 )

    timer.Create( "FPP_ConstraintRemovedTimer", 0, 1, function()
        constraintRemovedTimer( ent1, ent2, constrainedEnts )
    end )
end

local function onEntityRemoved(ent)
    if isConstraint( ent ) then handleConstraintRemoved( ent ) end
end

hook.Add("EntityRemoved", "FPP_OnEntityRemoved", onEntityRemoved)

---------------------------------------------------------------------------
-- Player disconnected
---------------------------------------------------------------------------
local function playerDisconnected(ply)
    local ownedEnts = {}

    local allEnts = ents.GetAll()
    local entsCount = #allEnts

    for i = 1, entsCount do
        local ent = rawget( allEnts, i )
        if ent:CPPIGetOwner() == ply then
            tableInsert( ownedEnts, ent )
        end
    end

    timer.Simple( 0, function() FPP.recalculateCanTouch( player.GetAll(), ownedEnts ) end)
end
hook.Add("PlayerDisconnected", "FPP_PlayerDisconnected", playerDisconnected)

---------------------------------------------------------------------------
-- Usergroup changed
---------------------------------------------------------------------------
local function userGroupRecalculate(ply)
    if not IsValid(ply) or not ply:IsPlayer() then return end

    timer.Create( "FPP_recalculate_cantouch_" .. ply:UserID(), 0, 1, function()
        FPP.recalculateCanTouch({ply}, ents.GetAll())
    end )
end

FPP.oldSetUserGroup = FPP.oldSetUserGroup or plyMeta.SetUserGroup
local oldSetUserGroup = FPP.oldSetUserGroup
function plyMeta:SetUserGroup( group )
    userGroupRecalculate( self )

    return oldSetUserGroup( self, group )
end

FPP.oldSetNWString = FPP.oldSetNWString or entMeta.SetNWString
local oldSetNWString = FPP.oldSetNWString
function entMeta:SetNWString(str, val)
    if str ~= "usergroup" then return oldSetNWString( self, str, val ) end

    userGroupRecalculate( self )
    return oldSetNWString( self, str, val )
end

FPP.oldSetNetworkedString = FPP.oldSetNetworkedString or entMeta.SetNetworkedString
local oldSetNetworkedString = FPP.oldSetNetworkedString
function entMeta:SetNetworkedString(str, val)
    if str ~= "usergroup" then return oldSetNetworkedString( self, str, val ) end

    userGroupRecalculate( self )
    return oldSetNetworkedString( self, str, val )
end
