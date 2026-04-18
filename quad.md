# AC-Advanced-Gamepad-Assist — High-Speed Traffic Cutting Build

> **Base Repo:** https://github.com/adam10603/AC-Advanced-Gamepad-Assist  
> **Version:** 1.5.5 (Dec 14, 2024)  
> **Language:** Lua (LuaJIT, 5.2 compat mode)  
> **Runtime hook:** CSP Gamepad FX — physics thread, `script.update(dt)` ~333Hz  
> **Minimum CSP:** v0.2.0 (v0.2.11+ recommended for blind spot API)  
> **SDK reference:** https://github.com/ac-custom-shaders-patch/acc-lua-sdk  
> **Purpose (repurposed):** High-speed gap threading and traffic cutting assist  
> **License:** MIT

---

## What This Build Is

The original mod replaces AC's controller input system with a physics-aware steering assist. For traffic cutting, those same systems — slip angle targeting, yaw damping, dynamic steering limits, auto-shift — become the foundation for a script that helps a driver (or an agent) move through dense traffic at speed with precision and stability.

The core loop doesn't change. What changes is *what the steering targets*. Instead of targeting the racing line, the system targets gaps. Instead of protecting corner exit, it's protecting lane transitions. The physics machinery is identical.

---

## Correct File Structure

The DeepWiki analysis of the release branch reveals two files that aren't visible from the tree view:

```
Advanced Gamepad Assist/
├── apps/lua/Advanced Gamepad Assist Config/
│   ├── AdvancedGamepadAssistConfig.lua   ← UI app (real filename)
│   └── manifest.ini
└── extension/lua/joypad-assist/Advanced Gamepad Assist/
    ├── assist.lua                         ← Main loop + steering calculation
    ├── extras.lua                         ← Auto-clutch PID, auto-shift, trigger feedback
    ├── AGALib.lua                         ← Math utilities + PID controller class
    ├── CarPerformanceData.lua             ← Reads engine.ini / drivetrain.ini / tyres.ini
    └── manifest.ini
```

`extras.lua` is a real module separate from `assist.lua`. It owns auto-clutch (PID-based), auto-shifting, and trigger feedback. These are dispatched via `extras.update()` from the main loop.

---

## Runtime Entry Points (Correct)

CSP calls two functions per session. Using the `script.*` namespace is the correct modern form:

```lua
function script.update(dt)
    -- Called every physics frame. dt ≈ 0.003s (physics runs ~333Hz, not 60Hz).
    -- Keep this as fast as possible — you're on the physics thread.
end

function script.reset()
    -- Called on session reset, car change, or pit teleport.
    -- MUST clear all smoothed/accumulated state or the next session starts jerky.
end
```

The physics thread update rate (~333Hz) is much faster than the render thread. Any per-frame allocation — creating new `vec3()` objects, table construction — adds up. The original script preallocates:

```lua
-- From assist.lua — avoids vec3 allocation every tick
local storedLocalWheelVel = {[0] = vec3(), vec3(), vec3(), vec3()}
```

Do the same for any new modules.

---

## Known Open Issues (GitHub)

Two issues are currently open on the repo:

**#55** — Bug (opened Apr 24, 2025, by Kozzren) — *Status: Open*  
**#51** — Enhancement request (opened Oct 21, 2024, by Kozzren) — *Status: Open*

Full descriptions weren't publicly visible without login, but the labels and timing align with patterns in the release notes:

- #55 (bug) likely relates to behavior introduced in v1.5.x. The most recent patch (v1.5.5) fixed auto-shift not updating after setup changes — a separate but related area. If this is a calibration or shift-point regression, the fix point is `CarPerformanceData.lua` → `calcOptimalShiftPoints()`.
- #51 (enhancement) predates v1.5.3–v1.5.5 and is still open, suggesting it's a non-trivial feature. Based on community discussions (OverTake thread), likely candidates are per-car preset auto-loading or a more granular cruise mode threshold.

---

## Bugs Fixed in Release History — Relevant to Traffic Build

These are documented fixes from the release changelog that directly affect reliability in a traffic context:

### Auto-Shift Shift-Point Stale After Setup Change
Fixed in v1.5.5. The shift points calculated by `CarPerformanceData.lua` weren't being recalculated when the car setup changed mid-session. In a traffic scenario where the driver might pit and change setup, the shift points would remain wrong.

**Mitigation for your build:** Watch for setup changes and force a recalculate:
```lua
-- In script.update(dt):
if car.setupChanged then  -- check if CSP exposes this; otherwise poll gear ratios
    carPerfData:recalculate(car)
end
```

### Keyboard Throttle Helper Interfering with Auto-Clutch
Fixed in an earlier release. The keyboard ABS/TCS helpers were writing to the throttle channel in the same tick that auto-clutch was trying to control it. The fix was explicit priority ordering — auto-clutch writes last.

**For traffic build:** If you're injecting agent commands through the keyboard input channel, apply the same rule — clutch control must always be the last write.

### Auto-Shift Forcing Wrong Gear on Toggle
When auto-shift was toggled on or off while the car was moving, it would briefly request the wrong gear. The fix clamped the gear request to `[1, gearCount]` before writing.

```lua
-- Always clamp before calling ac.setGearRequest()
local safeGear = math.clamp(targetGear, 1, car.gearCount)
ac.setGearRequest(safeGear - car.gear)
```

### Low-Speed Assist Fade-In/Out
The assist was fading in and out at low speed in a way that caused jerky behavior during slow maneuvers — relevant if the traffic build includes lane-change at moderate city speeds. The fade logic was reworked in v1.5.3. Use a smooth curve, not a hard threshold:

```lua
local speedBlend = math.smoothstep(0, 20, car.speedKmh)  -- 0 at 0 km/h, 1 at 20+ km/h
steerOut = math.lerp(rawInput, assistedInput, speedBlend)
```

### Third-Party Controller Trigger Vibration
Trigger vibration has a documented blind-fix in v1.5.3. Some third-party controllers don't respond to `ac.setTriggerRumble()` at all regardless of Steam Input status. This isn't fixable in Lua — it's a CSP HID layer issue. Don't depend on trigger feedback as the primary signal in your build.

---

## Core Systems for Traffic Cutting

### 1. Steering Calibration → Gap Feasibility Data

The calibration sweep determines the car's real lock-to-lock range by hijacking inputs for ~1 second. This data gives you the maximum steering angle, from which minimum turning radius at any speed is derived:

```lua
-- r = wheelbase / tan(maxSteerAngleDeg * math.pi / 180)
-- Use this per speed band to determine if a gap is geometrically passable
```

Extend to build a multi-speed lookup table: recalibrate (or interpolate) at 50, 100, 150 km/h bands. The calibration state machine in `assist.lua` is clean — it's a staged state machine with a pre-delay and a timeout fallback. Copy the pattern.

---

### 2. Slip Angle Targeting → Precision Lane Threading

The core physics calculation. Steers to keep front tires at peak lateral grip. For traffic cutting, lower the target to 70–80% of peak — you want predictability over maximum grip.

Real API for slip data:

```lua
local car = ac.getCar(0)

-- Per-wheel lateral slip (FL=0, FR=1, RL=2, RR=3)
car.wheelsSlip[0]   -- front-left
car.wheelsSlip[1]   -- front-right

-- Weighted average (matches how assist.lua does it)
local fWheelWeights = {
    lib.zeroGuard(car.wheels[0].load),
    lib.zeroGuard(car.wheels[1].load)
}
local avgSlip = (car.wheelsSlip[0] * fWheelWeights[1] + car.wheelsSlip[1] * fWheelWeights[2])
              / (fWheelWeights[1] + fWheelWeights[2])
```

---

### 3. Self-Steer / Caster Simulation → Straight-Line Stability Between Cuts

Simulates caster angle return-to-center. After completing a cut, releasing the stick snaps the car back to straight. This is the most critical system for traffic driving per the dev instructions — without it, any overcorrection compounds.

```lua
-- Self-steer + damping (from dev reference)
local selfSteer = -avgFrontSlip * CFG.COUNTERSTEER_GAIN
                -  car.steer    * CFG.COUNTERSTEER_DAMP

-- COUNTERSTEER_DAMP must be at least 60% of COUNTERSTEER_GAIN
-- or the car will tank-slapper
```

The AGALib PID controller (confirmed in DeepWiki architecture) is used for the auto-clutch — consider using the same class for self-steer gain scheduling if you need tighter control over response curves.

---

### 4. Dynamic Steering Limit → Commitment Control

When cutting through a gap, set this high (70–80%). The car should hold its line through the gap even in light oversteer rather than backing off the steering and washing wide into the obstacle.

---

### 5. Auto-Shift (Automatic Mode) → `CarPerformanceData.lua`

Reads `engine.ini`, `drivetrain.ini`, and `tyres.ini` directly at runtime. Integrates the torque curve across each gear's RPM range and picks upshift points where the next gear delivers more power at the current road speed.

Known edge case: cars with non-standard gearbox configs (e.g., VRC Beamer V12 style) can cause incorrect gear engagement. The fix is to clamp gear requests and validate with `car.gearCount` before writing. This is especially important in traffic — wrong-gear downshifts at 160 km/h are catastrophic.

---

## Configuration — Three-Tier Storage System

Settings live in three layers. Knowing which layer does what matters when building a traffic profile system:

| Tier | Mechanism | What It Stores | Persistence |
|---|---|---|---|
| Persistent | `ac.storage` with `AGA_*` prefix | 27 user settings | Across sessions |
| Shared memory | `ac.connect("AGAData")` | Real-time bidirectional UI ↔ assist sync | Runtime only |
| Game settings | `controls.ini` (throttled writes) | Gamma, deadzone, rumble | Written with rate limit |

Presets are stored as JSON in `ac.storage` using `AGA_PRESETS_*` keys. To add a "traffic cutting" factory preset, add a new entry under that prefix with the configuration table from the tuning section below.

---

## Expansion: Making It Smarter

### `ac.getCarBlindSpot()` — The Right API for Traffic Awareness

CSP 0.2.11+ added this specifically for detecting nearby cars in blind zones. This is the correct API for traffic scanning — not iterating all cars manually:

```lua
-- Returns distance to the nearest car in the left/right blind spot zones
-- Available from CSP v0.2.11+
local blindSpot = ac.getCarBlindSpot()
-- blindSpot.left  = distance to nearest car on left  (math.huge if clear)
-- blindSpot.right = distance to nearest car on right (math.huge if clear)

-- Use before committing to a cut:
local leftClear  = blindSpot.left  > minClearance
local rightClear = blindSpot.right > minClearance
```

This saves building a full `GapScanner` from scratch for the most common case. For forward-facing gap detection you still need `ac.getCar(i)` iteration, but blind spot checks during a cut are covered natively.

---

### Forward Gap Scanner (`GapScanner.lua`)

For forward traffic — the gaps you're driving into:

```lua
GapScanner = {}

function GapScanner:scan(trafficCount)
    local car  = ac.getCar(0)
    local gaps = {}

    for i = 1, trafficCount do
        local other = ac.getCar(i)
        if not other then goto continue end

        local relPos   = other.transform.position - car.transform.position
        local forward  = relPos:dot(car.transform.look)
        local lateral  = relPos:dot(car.transform.side)
        local closing  = (other.localVelocity.z - car.localVelocity.z)  -- +ve = closing

        if forward > 0 and forward < 80 then
            table.insert(gaps, {
                forward  = forward,
                lateral  = lateral,
                closing  = closing,
                carIndex = i,
            })
        end
        ::continue::
    end

    -- Sort by forward distance
    table.sort(gaps, function(a, b) return a.forward < b.forward end)
    return gaps
end
```

**Note:** `ac.getCarsCount()` gives you the count. Iterate `1` to `count - 1` for traffic (0 is the player).

---

### Time-to-Contact Scoring (not distance-based)

Replace all distance thresholds with time-to-contact. A 40m gap at 30 m/s closing rate is 1.3 seconds — less safe than a 20m gap that's opening:

```lua
function timeToContact(forwardDist, closingRate)
    if closingRate <= 0 then return math.huge end  -- gap opening
    return forwardDist / closingRate
end

function scoreGap(gap, carWidth, gapWidth)
    local ttc        = timeToContact(gap.forward, gap.closing)
    local clearance  = gapWidth - carWidth
    local score = clearance + (ttc * 0.3) - (math.max(0, gap.closing) * 0.5)
    return score
end
```

---

### Speed-Adaptive Steering Rate (extend `AGALib.lua`)

The existing steering rate is a fixed setting. Make it a function of speed:

```lua
function adaptiveSteeringRate(baseRate, speedKmh)
    -- dt-normalized exponential decay
    -- Full rate near 0 km/h, ~35% at 200 km/h
    local t = math.clamp((speedKmh - 60) / 120, 0, 1)
    return baseRate * math.lerp(1.0, 0.35, t)
end
```

Wire into `SmoothTowards` rate parameter every tick. Never apply a fixed lerp constant — normalize against `dt` or behavior will differ across frame rates:

```lua
-- WRONG: steerOut = math.lerp(steerOut, target, 0.12)
-- RIGHT:
steerOut = math.lerp(steerOut, target, math.clamp(dt / CFG.STEER_SMOOTH, 0, 1))
```

---

### Threat Classification

```lua
ThreatLevel = {
    CLEAR    = 0,  -- no action needed
    MONITOR  = 1,  -- in scan range, stable
    EVADE    = 2,  -- closing fast, lateral overlap likely
    CRITICAL = 3,  -- immediate collision course
}

function classifyThreat(gap, carSpeed)
    local ttc = timeToContact(gap.forward, gap.closing)
    if ttc == math.huge     then return ThreatLevel.CLEAR    end
    if ttc > 4.0            then return ThreatLevel.MONITOR  end
    if ttc > 1.5            then return ThreatLevel.EVADE    end
    return ThreatLevel.CRITICAL
end
```

Map threat level to dynamic steering limit:
- `CLEAR` → 55% (relaxed cuts, full driver authority)
- `EVADE` → 75% (committed, assisted through the gap)
- `CRITICAL` → 90% + damping increase (stability over everything)

---

### Predictive Lateral Position

Traffic cars move. Project where they'll be when you arrive:

```lua
function predictedLateral(other, car, lookaheadTime)
    local futurePos = other.transform.position + other.velocity * lookaheadTime
    return (futurePos - car.transform.position):dot(car.transform.side)
end

-- Use timeToContact() as the lookaheadTime
-- If predicted lateral position closes the gap, drop it from scoring
```

---

### Gap-Aware Pre-Braking (extend `extras.lua`)

Extend the existing brake assist with look-ahead deceleration. If the best available gap requires lower entry speed, begin gentle deceleration before the gap reaches you:

```lua
-- In extras.update(), after gap scoring:
if bestGap and bestGap.requiredSpeed < car.speedKmh then
    local brakeFactor = (car.speedKmh - bestGap.requiredSpeed) / car.speedKmh
    -- Gentle — don't override hard braking the driver is already doing
    inputData.brake = math.max(inputData.brake, brakeFactor * 0.5)
end
```

The existing ABS sim in extras already handles lockup prevention — this rides on top of it.

---

### Persistent Speed Profile (learning)

`ac.storage` supports arbitrary key-value persistence. After enough runs, log successful gap threads by speed and gap width:

```lua
local key = string.format("AGA_TC_%s_%d_%d",
    ac.getTrackName(),          -- map-specific
    math.floor(car.speedKmh / 20) * 20,   -- 20 km/h buckets
    math.floor(gapWidth * 10)   -- gap width in 0.1m steps
)
local prev = ac.storage(key) and json.parse(ac.storage(key)) or {ok=0, fail=0}
prev.ok = prev.ok + 1
ac.storage(key, json.stringify(prev))
```

Query success rate when scoring gaps to bias toward historically safe parameters on that map.

---

## Known Implementation Pitfalls

These are documented in both the dev instructions and the release history. Ignore them and you will hit them.

**Frame-rate dependent smoothing.** The physics thread runs at ~333Hz. A raw lerp constant will behave wildly differently at different physics rates. Always normalize:
```lua
-- Correct dt-normalized lerp
local t = math.clamp(dt / CFG.SMOOTH_TIME, 0, 1)
steerOut = math.lerp(steerOut, target, t)
```

**`ac.getCar(0)` returns nil on the first frame.** Always nil-guard before reading any car property. The script will silently stop running if it throws on frame 1.

**`script.reset()` must zero all state.** Any accumulated smoother or integral value left from the previous session causes a jerk at session start. The PID in `extras.lua` for auto-clutch has its own reset — if you add a PID for gap targeting, give it one too.

**Axis index drift.** `ac.getGamepad(0).axes[N]` indices are not guaranteed across controller models. Log all axes at startup with `ac.log()` and validate before coding around them.

**Self-steer oscillation.** `COUNTERSTEER_DAMP` must be at least 60% of `COUNTERSTEER_GAIN` or the car develops a tank-slapper at the limit. If the car wobbles after a cut, raise damping before lowering gain.

**Mod cars with non-standard gearboxes.** `CarPerformanceData.lua` has a guard for `gearCount < 1` and missing gear ratios, but some mod cars configure these in unexpected ways (documented in community reports for the VRC Beamer V12). Always clamp `ac.setGearRequest()` output to `[1, car.gearCount]`.

**Trigger vibration on third-party controllers.** `ac.setTriggerRumble()` has a known blind-fix in v1.5.3 for controllers that don't respond. Don't use trigger feedback as the primary alert signal for collision threats — it may silently do nothing.

---

## Full CSP API Reference for This Build

```lua
-- ── Entry points ──────────────────────────────────────────────
function script.update(dt) end   -- physics thread, dt ≈ 0.003s (~333Hz)
function script.reset()    end   -- on session reset / car change

-- ── Car state ────────────────────────────────────────────────
local car = ac.getCar(0)         -- nil-guard: can be nil on frame 1
-- ac.getCar(i) for traffic, i = 1..ac.getCarsCount()-1

car.speedKmh                     -- speed in km/h
car.localVelocity                -- vec3: velocity in car-local space (z = forward)
car.steer                        -- current steering, normalized [-1, 1]
car.gas / car.brake / car.clutch -- current applied inputs [0, 1]
car.gear                         -- 0=R, 1=N, 2=1st, ...
car.rpm / car.rpmLimiter         -- engine RPM
car.wheelsSlip[0..3]             -- lateral slip per wheel (FL, FR, RL, RR)
car.tyreSlip[0..3]               -- combined slip per wheel
car.wheelAngularSpeed[0..3]      -- wheel angular velocity
car.isGrounded[0..3]             -- bool: wheel contact
car.wheels[n].load               -- vertical load on wheel n
car.wheels[n].localVelocity      -- wheel local velocity (for slip calc)
car.transform.position           -- world position (vec3)
car.transform.look               -- forward vector
car.transform.side               -- lateral vector (right)
car.transform:inverse()          -- inverse transform (for local-space projection)

-- ── Traffic ──────────────────────────────────────────────────
ac.getCarsCount()                -- total cars in session
ac.getCarBlindSpot()             -- CSP 0.2.11+ — {left, right}: dist to nearest blind-zone car

-- ── Collision geometry ───────────────────────────────────────
ac.areShapesColliding(s1, s2)    -- CSP 0.2.11+ — quick intersection check

-- ── Input ────────────────────────────────────────────────────
local gp = ac.getGamepad(0)
gp.axes[1]   -- left stick X: steering  [-1, 1]
gp.axes[3]   -- right trigger: throttle  [0, 1]
gp.axes[4]   -- left trigger: brake      [0, 1]
-- Validate axis indices at startup — not guaranteed across controllers

-- ── Output ───────────────────────────────────────────────────
ac.setSteer(v)           -- [-1, 1]
ac.setGas(v)             -- [0, 1]
ac.setBrake(v)           -- [0, 1]
ac.setClutch(v)          -- [0, 1]  (0 = fully engaged)
ac.setGearRequest(delta) -- int: +1 upshift, -1 downshift, 0 hold

-- ── Haptics ──────────────────────────────────────────────────
ac.setControllerRumble(left, right, duration)  -- main motors [0,1]
ac.setTriggerRumble(left, right)               -- trigger motors [0,1], CSP 0.2.0+
                                               -- unreliable on third-party controllers

-- ── Storage & comms ──────────────────────────────────────────
ac.storage(key)           -- read persistent value
ac.storage(key, value)    -- write persistent value
ac.connect("AGAData")     -- shared memory struct (UI ↔ assist bidirectional)
ac.log("message")         -- CSP log
ac.setMessage("T", "B")   -- in-game toast

-- ── Session info ─────────────────────────────────────────────
ac.getTrackName()         -- current track identifier (for per-map learning)
ac.getSim()               -- sim-wide state (time, session type, etc.)
```

---

## SDK and Documentation Links

| Resource | URL |
|---|---|
| CSP Lua SDK (full API) | https://github.com/ac-custom-shaders-patch/acc-lua-sdk |
| CSP internal gamepad scripts | https://github.com/ac-custom-shaders-patch/acc-lua-internal |
| AC-Gamepad-FX dev instructions | https://github.com/rolling-codes/AC-Gamepad-FX/blob/master/AC_GamepadFX_Dev_Instructions.md |
| DeepWiki architecture analysis | https://deepwiki.com/adam10603/AC-Advanced-Gamepad-Assist |
| Local full API docs (shipped with CSP) | `assettocorsa/extension/internal/lua-sdk/` |

---

## Traffic Cutting Configuration Profile

Starting point:

| Setting | Value | Reason |
|---|---|---|
| Steering rate | 40–50% | Responsive without being twitchy at speed |
| Steering rate at speed | -20% | Calmer inputs as speed increases |
| Target slip angle | 75–85% | Predictability over maximum grip |
| Countersteer response | 25–35% | Recovery without overcorrection risk |
| Dynamic steering limit | 65–75% | Committed cuts, tolerates light oversteer |
| Self-steer response | High | Fast re-centering between cuts |
| Self-steer max angle | 90° | Full recovery authority |
| Damping | ≥60% of response value | No oscillation between moves |
| Shifting mode | Automatic | Attention stays on traffic |
| Brake assist | On (brake help) | Threshold braking without lockup |
