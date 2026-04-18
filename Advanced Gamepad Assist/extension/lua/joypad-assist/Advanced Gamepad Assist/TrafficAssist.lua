local lib        = require "AGALib"
local GapScanner = require "GapScanner"

local M = {}

-- Minimum lateral clearance (metres) to each side before a cut is attempted.
local MIN_CLEARANCE = 0.4

-- Dynamic limit values per threat level (normalised 0-1, maps to steering limit).
local LIMIT_BY_THREAT = {
    [GapScanner.ThreatLevel.CLEAR]    = 0.55,
    [GapScanner.ThreatLevel.MONITOR]  = 0.60,
    [GapScanner.ThreatLevel.EVADE]    = 0.75,
    [GapScanner.ThreatLevel.CRITICAL] = 0.90,
}

-- State
local prevThreat        = GapScanner.ThreatLevel.CLEAR
local threatHoldTimer   = 0.0  -- Don't drop threat level instantly
local gapBrakeRequest   = 0.0  -- Written here, read by extras.lua

-- Read-only accessor so extras.lua can get the brake request each tick.
function M.getGapBrakeRequest()
    return gapBrakeRequest
end

-- Main update. Call from assist.lua after getVehicleData, before calcCorrectedSteering.
-- vData      : vehicle data table from assist.lua
-- uiData     : shared config struct
-- carWidth   : half-width of player car in metres (pass ~1.0)
-- dt         : frame delta
function M.update(vData, uiData, carWidth, dt)
    local player = vData.vehicle

    local _, bestGap, blindSpot = GapScanner.scan(player, 80, carWidth)

    -- Determine worst current threat
    local threat = GapScanner.ThreatLevel.CLEAR
    if bestGap then
        threat = bestGap.threat
    end

    -- Hysteresis: threat level can only drop after 0.4s at the lower level
    if threat < prevThreat then
        threatHoldTimer = threatHoldTimer + dt
        if threatHoldTimer < 0.4 then
            threat = prevThreat
        else
            threatHoldTimer = 0.0
        end
    else
        threatHoldTimer = 0.0
    end
    prevThreat = threat

    -- Map threat to dynamic limit (stored * 10 for legacy reasons, same as AGA convention)
    local targetLimit = LIMIT_BY_THREAT[threat] * 10.0
    uiData.maxDynamicLimitReduction = math.lerp(uiData.maxDynamicLimitReduction, targetLimit, math.clamp(dt / 0.15, 0, 1))

    -- Gap-aware pre-braking: if the best gap needs lower entry speed, request gentle decel
    gapBrakeRequest = 0.0
    if bestGap and bestGap.ttc < 3.0 and player.speedKmh > 40 then
        local requiredSpeedFraction = math.clamp(bestGap.ttc / 3.0, 0, 1)
        gapBrakeRequest = (1.0 - requiredSpeedFraction) * 0.4
    end

    -- Blind spot rumble warning on CRITICAL (left motor = left blind spot, right = right)
    if threat == GapScanner.ThreatLevel.CRITICAL then
        local lRumble = (blindSpot.left  < 4.0) and 0.6 or 0.0
        local rRumble = (blindSpot.right < 4.0) and 0.6 or 0.0
        if lRumble > 0 or rRumble > 0 then
            ac.setControllerRumble(lRumble, rRumble, dt * 2.0)
        end
    end

    -- Debug telemetry
    ac.debug("TA_threat",       threat)
    ac.debug("TA_dynLimit",     uiData.maxDynamicLimitReduction)
    ac.debug("TA_brakeReq",     gapBrakeRequest)
    ac.debug("TA_blindL",       blindSpot.left  == math.huge and 99 or blindSpot.left)
    ac.debug("TA_blindR",       blindSpot.right == math.huge and 99 or blindSpot.right)
end

function M.reset()
    prevThreat      = GapScanner.ThreatLevel.CLEAR
    threatHoldTimer = 0.0
    gapBrakeRequest = 0.0
end

return M
