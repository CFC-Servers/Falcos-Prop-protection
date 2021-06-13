FPP = FPP or {}

local Entity = Entity
local IsValid = IsValid
local isnumber = isnumber

local rawget = rawget
local rawset = rawset

local netReadUInt = net.ReadUInt
local netReadBit = net.ReadBit

local bitBor = bit.bor
local bitBand = bit.band
local bitLShift = bit.lshift
local bitRShift = bit.rshift

FPP.entOwners       = FPP.entOwners or {}
FPP.entTouchability = FPP.entTouchability or {}
FPP.entTouchReasons = FPP.entTouchReasons or {}

local touchTypes = {
    Physgun = 1,
    Gravgun = 2,
    Toolgun = 4,
    PlayerUse = 8,
    EntityDamage = 16
}

local reasonSize = 4 -- bits
local reasons = {
    [1] = "owner", -- you can't touch other people's props
    [2] = "world",
    [3] = "disconnected",
    [4] = "blocked",
    [5] = "constrained",
    [6] = "buddy",
    [7] = "shared",
    [8] = "player", -- you can't pick up players
}

local function receiveTouchData(len)
    repeat
        local entIndex = netReadUInt(32)
        local ownerIndex = netReadUInt(32)
        local touchability = netReadUInt(5)
        local reason = netReadUInt(20)

        rawset( rawget( FPP, "entOwners" ), entIndex, ownerIndex )
        rawset( rawget( FPP, "entTouchability" ), entIndex, touchability )
        rawset( rawget( FPP, "entTouchReasons" ), entIndex, reason )
    until netReadBit() == 1
end
net.Receive("FPP_TouchabilityData", receiveTouchData)

function FPP.entGetOwner(ent)
    local idx = rawget( rawget( FPP, "entOwners" ), ent:EntIndex() )
    ent.FPPOwner = idx and Entity(idx) or nil

    return ent.FPPOwner
end

function FPP.canTouchEnt(ent, touchType)
    ent.FPPCanTouch = rawget( rawget( FPP, "entTouchability" ), ent:EntIndex() )
    if not touchType or not ent.FPPCanTouch then
        return ent.FPPCanTouch
    end

    return bitBor(ent.FPPCanTouch, rawget( touchTypes, touchType ) ) == ent.FPPCanTouch
end


local touchTypeMultiplier = {
    ["Physgun"] = 0,
    ["Gravgun"] = 1,
    ["Toolgun"] = 2,
    ["PlayerUse"] = 3,
    ["EntityDamage"] = 4
}

function FPP.entGetTouchReason(ent, touchType)
    local idx = rawget( rawget( FPP, "entTouchReasons" ), ent:EntIndex() ) or 0
    ent.FPPCanTouchWhy = idx

    if not touchType then return idx end

    local touchMult = rawget( touchTypeMultiplier, touchType )

    local maxReasonValue = 15
    -- 1111 shifted to the right touch type
    local touchTypeMask = bitLShift(maxReasonValue, reasonSize * touchMult)
    -- Extract reason for touch type from reason number
    local touchTypeReason = bitBand(idx, touchTypeMask)
    -- Shift it back to the right
    local reasonNr = bitRShift(touchTypeReason, reasonSize * touchMult)

    local reason = rawget( reasons, reasonNr )
    local owner = ent:CPPIGetOwner()

    if reasonNr == 1 then -- convert owner to the actual player
        return not isnumber(owner) and IsValid(owner) and owner:Nick() or "Unknown player"
    elseif reasonNr == 6 then
        return "Buddy (" .. (IsValid(owner) and owner:Nick() or "Unknown player") .. ")"
    end

    return reason
end
