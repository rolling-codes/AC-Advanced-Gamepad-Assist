# Advanced Gamepad Assist — Traffic Cutting Build
## Install Guide

This is a modified version of [Advanced Gamepad Assist v1.5.5](https://github.com/adam10603/AC-Advanced-Gamepad-Assist) by adam10603, repurposed for high-speed traffic threading. The steering, self-steer, and yaw-damping systems are unchanged. What is added is a live traffic scanner that adjusts the dynamic steering limit and applies gentle pre-braking based on gap threat level.

---

## Requirements

| | Minimum | Recommended |
|---|---|---|
| Assetto Corsa | any | any |
| Custom Shaders Patch | 0.2.0 | 0.2.11+ |
| Content Manager | free | full / paid |
| Controller | any Xbox-compatible gamepad | Xbox Series / DualSense |

CSP 0.2.11 or newer unlocks the blind-spot API used for the haptic warning. The script runs on earlier versions but the blind-spot rumble will be silently skipped.

---

## Step 1 — Copy the files

Inside this folder you have:

```
Advanced Gamepad Assist/
├── apps/
└── extension/
```

Copy **both** of those folders into your main `assettocorsa` game folder. On a default Steam install that is:

```
C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\
```

If prompted to merge folders, choose **Yes**. No existing files will be overwritten — the mod lives in its own subfolder.

> **Content Manager users:** If you prefer using the CM mods folder, drop the `Advanced Gamepad Assist` folder (the one containing `apps/` and `extension/`) into `Documents\Assetto Corsa\mods\` and enable it from CM's mod manager.

---

## Step 2 — Activate the script in CSP

1. Open Content Manager.
2. Top-right → **Settings** → top-left → **Custom Shaders Patch** → left panel → **Gamepad FX**.
3. Under **Gamepad Script**, check **Active** and select **Advanced Gamepad Assist** from the dropdown.

---

## Step 3 — Set input method to Gamepad

1. In Content Manager, **Settings** → **Assetto Corsa** → **Controls**.
2. Set **Input Method** to **Gamepad**.

---

## Step 4 — Verify the UI app is available (optional but useful)

The in-game config app lets you tune all steering parameters in real time. Add it from the sidebar when in a session:

- App name: **Advanced Gamepad Assist Config**

The app shows live graphs for front/rear slip, self-steer strength, and the steering limit reduction. During traffic driving the `TA_threat` and `TA_dynLimit` debug values visible in the CSP debug overlay (if enabled) will confirm the traffic scanner is active.

---

## What this build adds

On top of the standard AGA steering assist, the traffic build includes:

| Feature | Behaviour |
|---|---|
| **Gap Scanner** | Scans cars up to 80 m ahead every physics frame, scores gaps by time-to-contact and lateral clearance |
| **Threat levels** | CLEAR / MONITOR / EVADE / CRITICAL — escalates instantly, drops after 0.4 s hysteresis to prevent flicker |
| **Dynamic steering limit** | Rises from 55 % (clear road) to 90 % (critical threat) to keep the car committed through gaps |
| **Adaptive steering rate** | Steering response scales down smoothly above 60 km/h — full rate at standstill, ~35 % at 200 km/h |
| **Gap pre-braking** | When TTC drops below 3 s the script requests up to 40 % brake input as a floor — your own braking always wins |
| **Blind-spot rumble** | Left/right motor pulses when a car enters the blind zone during a CRITICAL threat (CSP 0.2.11+ only) |

---

## Recommended starting settings

Open the **Advanced Gamepad Assist Config** app in-game and set:

| Setting | Value |
|---|---|
| Steering rate | 45 % |
| Filter | 60 % |
| Self-steer response | High |
| Countersteer response | 25 % |
| Shifting mode | Automatic |
| Brake assist | On |

These can be adjusted per-car using the preset system built into the app.

---

## Uninstall

Delete the two folders that were copied in Step 1:

```
assettocorsa/apps/lua/Advanced Gamepad Assist Config/
assettocorsa/extension/lua/joypad-assist/Advanced Gamepad Assist/
```

In CSP Gamepad FX settings, deactivate or change the selected script.

---

## Known limitations

- **Gap pre-braking only activates when Auto Clutch is enabled.** If you use manual clutch, the pre-braking floor will not apply.
- **Blind-spot rumble requires CSP 0.2.11+.** On earlier versions the feature is silently skipped; all other features work normally.
- **Third-party controllers.** Some non-Xbox controllers do not respond to `ac.setTriggerRumble()` regardless of Steam Input settings — this is a CSP HID layer limitation.

---

## Credits

Base mod: [Advanced Gamepad Assist v1.5.5](https://github.com/adam10603/AC-Advanced-Gamepad-Assist) by adam10603 (MIT licence).
