# AGA Traffic-Cutting Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two latent bugs in the AGA v1.5.5 codebase and add traffic-awareness modules (gap scanner, threat classification, blind spot detection, adaptive steering, gap-aware pre-braking) that repurpose the steering assist for high-speed traffic cutting.

**Architecture:** Bug fixes are isolated to `CarPerformanceData.lua`. New traffic logic lives in two new files: `GapScanner.lua` (pure data; no side effects) and `TrafficAssist.lua` (reads gap data, writes to `inputData` and `uiData`). `AGALib.lua` gets one new utility function. `assist.lua` and `extras.lua` each get small integration hooks; the rest of those files is unchanged.

**Tech Stack:** Lua 5.2 (LuaJIT), CSP Gamepad FX (`script.update(dt)` at ~333 Hz), CSP v0.2.11+ for `ac.getCarBlindSpot()`. No external test runner — verification is done in-game via `ac.debug()` values visible in the AC telemetry overlay.

---

## Scope Note

This plan covers two independent subsystems:

1. **Bug fixes** (Tasks 1–2) — self-contained, no new files, safe to ship alone.
2. **Traffic-cutting modules** (Tasks 3–7) — new functionality; depends on fixes being applied first.

If you only want the bug fixes, complete Tasks 1–2 and stop.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `extension/lua/joypad-assist/Advanced Gamepad Assist/CarPerformanceData.lua` | Fix `car.index` → `vehicle.index` and `car.wheels` → `self.vehicle.wheels` |
| Modify | `extension/lua/joypad-assist/Advanced Gamepad Assist/AGALib.lua` | Add `adaptiveSteeringRate()` utility |
| **Create** | `extension/lua/joypad-assist/Advanced Gamepad Assist/GapScanner.lua` | Forward gap scanning, blind spot query, threat classification |
| **Create** | `extension/lua/joypad-assist/Advanced Gamepad Assist/TrafficAssist.lua` | Wires `GapScanner` output into steering/braking/rumble; owns traffic state |
| Modify | `extension/lua/joypad-assist/Advanced Gamepad Assist/assist.lua` | `require` TrafficAssist; swap steering rate call for adaptive version |
| Modify | `extension/lua/joypad-assist/Advanced Gamepad Assist/extras.lua` | Accept gap pre-brake request from TrafficAssist before final brake write |

All paths are relative to `C:\Users\Tom\Videos\Advanced Gamepad Assist v1.5.5\Advanced Gamepad Assist\`.

---

## Task 1: Fix `car.index` in CarPerformanceData.lua

**Files:**
- Modify: `extension/lua/joypad-assist/Advanced Gamepad Assist/CarPerformanceData.lua:93`

The constructor reads `tyres.ini` using the global `car.index` instead of the `vehicle` parameter passed in. On multi-car sessions this silently reads the wrong car's tyre data.

- [ ] **Step 1: Open the file and locate the bug**

In `CarPerformanceData.lua`, find line 93:

```lua
local tiresINI = ac.INIConfig.carData(car.index, "tyres.ini")
```

- [ ] **Step 2: Verify the correct identifier**

The constructor signature is `function M:new(vehicle)` (line 7). The local should use `vehicle.index`, consistent with the engine and drivetrain reads directly above it (lines 16 and 80 both use `vehicle.index`).

- [ ] **Step 3: Apply the fix**

Change line 93 from:

```lua
local tiresINI = ac.INIConfig.carData(car.index, "tyres.ini")
```

to:

```lua
local tiresINI = ac.INIConfig.carData(vehicle.index, "tyres.ini")
```

- [ ] **Step 4: In-game verification**

Launch AC with any car. In the AGA telemetry overlay (`ac.debug` values), confirm `C) Target front slip angle` is non-zero and plausible (6–11°) within a few seconds of driving. If it was reading a wrong car index the value would be stuck at 0 or at the fallback 7.0 even for v10-tyre cars.

- [ ] **Step 5: Commit**

```bash
git add "extension/lua/joypad-assist/Advanced Gamepad Assist/CarPerformanceData.lua"
git commit -m "fix: use vehicle.index for tyres.ini, not global car.index"
```

---

## Task 2: Fix `car.wheels` in `getInitialTargetSlipEstimate`

**Files:**
- Modify: `extension/lua/joypad-assist/Advanced Gamepad Assist/CarPerformanceData.lua:293-294`

Two lines in `getInitialTargetSlipEstimate()` reference the global `car.wheels` instead of `self.vehicle.wheels`. Same silent multi-car bug as Task 1; also risks a nil-dereference on the first frame if `car` is not yet available.

- [ ] **Step 1: Locate the lines**

In `CarPerformanceData.lua`, find lines 293–294 inside `getInitialTargetSlipEstimate()`:

```lua
local pressureFlexGain0 = pressureDiff0 * pressureFlexGainMult - math.abs(pressureDiff0 * dGainPressureMult0) * pressureDGain * 1.7 - 0.005 * math.abs(car.wheels[0].tyreCoreTemperature - car.wheels[0].tyreOptimumTemperature)
local pressureFlexGain1 = pressureDiff1 * pressureFlexGainMult - math.abs(pressureDiff1 * dGainPressureMult1) * pressureDGain * 1.7 - 0.005 * math.abs(car.wheels[1].tyreCoreTemperature - car.wheels[1].tyreOptimumTemperature)
```

- [ ] **Step 2: Apply the fix**

Replace both lines with:

```lua
local pressureFlexGain0 = pressureDiff0 * pressureFlexGainMult - math.abs(pressureDiff0 * dGainPressureMult0) * pressureDGain * 1.7 - 0.005 * math.abs(self.vehicle.wheels[0].tyreCoreTemperature - self.vehicle.wheels[0].tyreOptimumTemperature)
local pressureFlexGain1 = pressureDiff1 * pressureFlexGainMult - math.abs(pressureDiff1 * dGainPressureMult1) * pressureDGain * 1.7 - 0.005 * math.abs(self.vehicle.wheels[1].tyreCoreTemperature - self.vehicle.wheels[1].tyreOptimumTemperature)
```

- [ ] **Step 3: In-game verification**

Launch AC. Drive a car with v10 tyres. Confirm `C) Target front slip angle` in the debug overlay starts at a non-zero estimate (6–11°) and adapts over the first 30 seconds of cornering. No Lua error in the CSP log.

- [ ] **Step 4: Commit**

```bash
git add "extension/lua/joypad-assist/Advanced Gamepad Assist/CarPerformanceData.lua"
git commit -m "fix: use self.vehicle.wheels in getInitialTargetSlipEstimate, not global car"
```

---

## Task 3: Add `adaptiveSteeringRate()` to AGALib.lua

**Files:**
- Modify: `extension/lua/joypad-assist/Advanced Gamepad Assist/AGALib.lua` (append before `return M`)

This utility scales the steering rate smoothly from full at low speed to 35% at 200 km/h. It is consumed by Task 6.

- [ ] **Step 1: Add the function**

In `AGALib.lua`, insert before the final `return M` line:

```lua
-- Returns a speed-scaled steering rate multiplier.
-- Full rate below 60 km/h, decaying to ~35% at 200 km/h.
-- baseRate should be the uiData.steeringRate value (0-1 range).
-- dt-normalization is handled by the SmoothTowards caller, not here.
function M.adaptiveSteeringRate(baseRate, speedKmh)
    local t = math.clamp((speedKmh - 60) / 140, 0, 1)
    return baseRate * (1.0 - t * 0.65)
end
```

- [ ] **Step 2: In-game verification (pre-integration smoke test)**

Temporarily add this to `assist.lua` inside `script.update(dt)`, just after `getVehicleData`:

```lua
ac.debug("Z_adaptiveRate", lib.adaptiveSteeringRate(uiData.steeringRate, vData.vehicle.speedKmh))
```

At 0 km/h the debug value should equal `uiData.steeringRate`. At 200 km/h it should be ~35% of that value. Remove the debug line after confirming.

- [ ] **Step 3: Commit**

```bash
git add "extension/lua/joypad-assist/Advanced Gamepad Assist/AGALib.lua"
git commit -m "feat: add adaptiveSteeringRate utility to AGALib"
```

---

## Task 4: Create GapScanner.lua

**Files:**
- Create: `extension/lua/joypad-assist/Advanced Gamepad Assist/GapScanner.lua`

Pure data module. No side effects. Returns a sorted gap list and a threat level for the best gap. Designed to be called once per `script.update` tick from `TrafficAssist`.

- [ ] **Step 1: Create the file**

```lua
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
```

- [ ] **Step 2: Smoke-test in assist.lua**

Temporarily add to `assist.lua` at the top with the other `require` lines:

```lua
local GapScanner = require "GapScanner"
```

And inside `script.update(dt)`, after `getVehicleData`, add:

```lua
local _, bestGap, blindSpot = GapScanner.scan(vData.vehicle, 80, 1.0)
ac.debug("Z_gapFwd",   bestGap and bestGap.forward or -1)
ac.debug("Z_gapTTC",   bestGap and (bestGap.ttc == math.huge and 99 or bestGap.ttc) or -1)
ac.debug("Z_blindL",   blindSpot.left  == math.huge and 99 or blindSpot.left)
ac.debug("Z_blindR",   blindSpot.right == math.huge and 99 or blindSpot.right)
```

Load AC with traffic. Confirm gap forward distance and TTC look plausible. Remove temp lines and the temp `require` after confirming.

- [ ] **Step 3: Commit**

```bash
git add "extension/lua/joypad-assist/Advanced Gamepad Assist/GapScanner.lua"
git commit -m "feat: add GapScanner module with gap scoring and threat classification"
```

---

## Task 5: Create TrafficAssist.lua

**Files:**
- Create: `extension/lua/joypad-assist/Advanced Gamepad Assist/TrafficAssist.lua`

Owns all traffic-cutting state. Called once per tick from `assist.lua`. Reads gap data, adjusts `uiData.maxDynamicLimitReduction` based on threat level, sets a `gapBrakeRequest` field that `extras.lua` reads, and pulses rumble on CRITICAL threats.

- [ ] **Step 1: Create the file**

```lua
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
```

- [ ] **Step 2: Verify it loads without errors**

Add to `assist.lua` at the top (with other requires):

```lua
local TrafficAssist = require "TrafficAssist"
```

Launch AC. If the CSP log shows no Lua errors and the `TA_threat` debug key appears in the telemetry overlay (value 0 on an empty track), the module is loading correctly.

- [ ] **Step 3: Commit**

```bash
git add "extension/lua/joypad-assist/Advanced Gamepad Assist/TrafficAssist.lua"
git commit -m "feat: add TrafficAssist module for threat-based limit and pre-braking"
```

---

## Task 6: Wire TrafficAssist into assist.lua

**Files:**
- Modify: `extension/lua/joypad-assist/Advanced Gamepad Assist/assist.lua`

Two changes:
1. Add `require "TrafficAssist"` at the top.
2. Call `TrafficAssist.update()` each tick and use `lib.adaptiveSteeringRate()` for the steering rate.

- [ ] **Step 1: Add require**

At the top of `assist.lua`, after the existing requires (around line 12):

```lua
local TrafficAssist = require "TrafficAssist"
```

- [ ] **Step 2: Call TrafficAssist.update each tick**

Inside `script.update(dt)`, after the line:

```lua
vData.perfData:updateTargetFrontSlipAngle(vData, initialSteering, dt)
```

Add:

```lua
TrafficAssist.update(vData, uiData, 1.0, dt)
```

- [ ] **Step 3: Replace fixed steering rate with adaptive version**

Find the line in `script.update(dt)` (inside the `if uiData.assistEnabled then` block):

```lua
local steeringRateMult = calcSteeringRateMult(vData.localHVelLen, vData.steeringLockDeg)
```

`calcSteeringRateMult` returns a rate multiplier. Wrap its result with the adaptive scaler:

```lua
local steeringRateMult = calcSteeringRateMult(vData.localHVelLen, vData.steeringLockDeg)
steeringRateMult = lib.adaptiveSteeringRate(steeringRateMult, vData.vehicle.speedKmh)
```

- [ ] **Step 4: Add reset call**

Inside `script.reset()` — if it doesn't exist yet, add it — call:

```lua
TrafficAssist.reset()
```

If `script.reset` is not defined in `assist.lua`, add it:

```lua
function script.reset()
    TrafficAssist.reset()
end
```

- [ ] **Step 5: In-game verification**

Launch AC on a track with traffic. Observe the telemetry overlay:
- `TA_threat` should be 0 (CLEAR) on empty road, rising to 2–3 (EVADE/CRITICAL) when a car is close ahead and closing.
- `TA_dynLimit` should smoothly increase (toward 9.0) as threat rises.
- Steering should feel notably calmer at 150+ km/h than before.

- [ ] **Step 6: Commit**

```bash
git add "extension/lua/joypad-assist/Advanced Gamepad Assist/assist.lua"
git commit -m "feat: integrate TrafficAssist and adaptive steering rate into main loop"
```

---

## Task 7: Wire gap pre-braking into extras.lua

**Files:**
- Modify: `extension/lua/joypad-assist/Advanced Gamepad Assist/extras.lua`

`TrafficAssist` sets a `gapBrakeRequest` (0–0.4). `extras.lua` should blend this in as a floor on the brake input, applied *after* the ABS sim but *before* the final write, so it can't override harder driver braking.

- [ ] **Step 1: Add require**

At the top of `extras.lua` (after `local lib = require "AGALib"`):

```lua
local TrafficAssist = require "TrafficAssist"
```

- [ ] **Step 2: Apply the gap brake request**

In `extras.lua`, find the section at the end of `M.update` where `vData.inputData.brake` is last set (around the auto-clutch handbrake block). After all clutch and brake writes, add:

```lua
-- Gap-aware pre-braking from TrafficAssist (gentle decel floor, can't override driver)
local gapBrake = TrafficAssist.getGapBrakeRequest()
if gapBrake > 0.001 then
    vData.inputData.brake = math.max(vData.inputData.brake, gapBrake)
end
```

The exact location is after line 384 (`vData.inputData.clutch = math.min(vData.inputData.clutch, autoClutchVal)`) and before the auto-shifting block.

- [ ] **Step 3: In-game verification**

With traffic, approach a slow car from behind at speed (100+ km/h). With no driver brake input, observe that:
- `TA_brakeReq` in the debug overlay becomes non-zero when TTC drops below 3s.
- The car gently decelerates — the `brake` input should be visibly non-zero in the telemetry — without the driver touching the brake pedal.
- Pressing the brake yourself still overrides (the `math.max` can only add, not reduce).

- [ ] **Step 4: Commit**

```bash
git add "extension/lua/joypad-assist/Advanced Gamepad Assist/extras.lua"
git commit -m "feat: apply gap-aware pre-braking floor from TrafficAssist in extras"
```

---

## Self-Review

### Spec coverage

| quad.md requirement | Task |
|---------------------|------|
| `car.index` bug fix | Task 1 |
| `car.wheels` bug fix | Task 2 |
| Adaptive steering rate | Task 3, 6 |
| `GapScanner` with forward scan | Task 4 |
| Time-to-contact scoring | Task 4 |
| Threat classification | Task 4, 5 |
| `ac.getCarBlindSpot()` integration | Task 4, 5 |
| Predictive lateral position | Task 4 |
| Gap-aware pre-braking | Task 5, 7 |
| Blind spot rumble warning | Task 5 |
| Dynamic steering limit by threat | Task 5, 6 |
| `script.reset()` clears traffic state | Task 6 |
| dt-normalized smoothing | All smoothers use `SmoothTowards`; new lerp calls use `dt / time` |

### Gaps identified

- **Speed profile learning** (`ac.storage` per-track success rate) — omitted intentionally: it requires enough run data to be useful and adds persistent storage complexity. Add as a follow-up task.
- **Per-car preset auto-loading** (issue #51) — not in scope for this plan; enhancement request, separate plan needed.
- **Gear clamp on setup change** (`car.setupChanged`) — already handled by `updateGearSetHash()` in `assist.lua`. No change needed.

### Placeholder scan

No TBD/TODO/placeholder phrases present. All code blocks are complete.

### Type consistency

- `GapScanner.scan()` returns `(gaps, bestGap, blindSpot)` — consumed correctly in `TrafficAssist.update()`.
- `TrafficAssist.getGapBrakeRequest()` returns a number — consumed correctly in `extras.lua`.
- `lib.adaptiveSteeringRate(baseRate, speedKmh)` — called with correct args in `assist.lua` Task 6.
- `uiData.maxDynamicLimitReduction` stores `* 10` (legacy AGA convention) — multiplied by 10 in `TrafficAssist` correctly.
