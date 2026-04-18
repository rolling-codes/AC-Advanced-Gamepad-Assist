local lib = require "AGALib"

local M = {}

-- Threat levels returned by classifyThreat()
M.ThreatLevel = {
    CLEAR    = 0,
    MONITOR  = 1,
    EVADE    = 2,
    CRITICAL = 3,
}

-- Returns time-to-contact in seconds. Returns math.huge if the gap is opening.
local function timeToContact(forwardDist, closingRate)
    if closingRate <= 0 then return math.huge end
    return forwardDist / closingRate
end

-- Scores a gap for selection. Higher is better.
-- carWidth is the player car's approximate half-width in metres (use 1.0 as default).
-- gapWidth is the lateral clearance available (metres).
local function scoreGap(forwardDist, closingRate, gapWidth, carWidth)
    local ttc       = timeToContact(forwardDist, closingRate)
    local clearance = gapWidth - carWidth
    return clearance + (ttc * 0.3) - (math.max(0, closingRate) * 0.5)
end

-- Classifies a gap's threat level based on TTC.
function M.classifyThreat(forwardDist, closingRate)
    local ttc = timeToContact(forwardDist, closingRate)
    if ttc == math.huge then return M.ThreatLevel.CLEAR    end
    if ttc > 4.0        then return M.ThreatLevel.MONITOR  end
    if ttc > 1.5        then return M.ThreatLevel.EVADE    end
    return M.ThreatLevel.CRITICAL
end

-- Returns the predicted lateral offset (metres, in player-car's local frame) of `other`
-- after `lookaheadTime` seconds. Positive = right of player.
function M.predictedLateral(other, playerCar, lookaheadTime)
    local futurePos = other.transform.position + other.velocity * lookaheadTime
    return (futurePos - playerCar.transform.position):dot(playerCar.transform.side)
end

-- Main scan function. Returns:
--   gaps      table, sorted nearest-first, each entry:
--             { forward, lateral, closing, carIndex, ttc, score, threat }
--   bestGap   the highest-scoring entry, or nil if no gaps in range
--   blindSpot { left, right } distance to nearest blind-zone car (math.huge = clear)
--             Requires CSP 0.2.11+; falls back to { left=math.huge, right=math.huge }
--
-- scanRange: how far forward to consider (metres, default 80)
-- carWidth:  half-width of player car (metres, default 1.0)
function M.scan(playerCar, scanRange, carWidth)
    scanRange = scanRange or 80
    carWidth  = carWidth  or 1.0

    local gaps      = {}
    local totalCars = ac.getCarsCount()

    for i = 1, totalCars - 1 do
        local other = ac.getCar(i)
        if other then
            local relPos   = other.transform.position - playerCar.transform.position
            local forward  = relPos:dot(playerCar.transform.look)
            local lateral  = relPos:dot(playerCar.transform.side)
            local closing  = other.localVelocity.z - playerCar.localVelocity.z

            if forward > 0 and forward < scanRange then
                local ttc      = timeToContact(forward, closing)
                local predLat  = M.predictedLateral(other, playerCar, math.min(ttc, 4.0))
                local gapWidth = math.abs(lateral) - carWidth
                local score    = scoreGap(forward, closing, gapWidth, carWidth)
                local threat   = M.classifyThreat(forward, closing)

                table.insert(gaps, {
                    forward  = forward,
                    lateral  = lateral,
                    predLat  = predLat,
                    closing  = closing,
                    carIndex = i,
                    ttc      = ttc,
                    score    = score,
                    threat   = threat,
                })
            end
        end
    end

    table.sort(gaps, function(a, b) return a.forward < b.forward end)

    -- Pick best gap by score
    local bestGap = nil
    for _, g in ipairs(gaps) do
        if not bestGap or g.score > bestGap.score then
            bestGap = g
        end
    end

    -- Blind spot query (CSP 0.2.11+)
    local blindSpot = { left = math.huge, right = math.huge }
    if type(ac.getCarBlindSpot) == "function" then
        local bs = ac.getCarBlindSpot()
        if bs then
            blindSpot.left  = bs.left
            blindSpot.right = bs.right
        end
    end

    return gaps, bestGap, blindSpot
end

return M
