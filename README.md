# TrueSpeed

A lightweight World of Warcraft addon that measures your character's **actual** movement speed from map coordinates, rather than reading the game's reported speed. This means it works correctly in situations where the API lies — most notably **flight paths**, where `GetUnitSpeed("player")` returns 0.

## Features

- Real-time speed display in **yards/sec**, **% of base run speed**, and optionally **knots**
- Works on **flight paths**, taxis, vehicles, and anywhere the standard speed API fails
- Side-by-side comparison with the game's API-reported speed (toggleable)
- Color-coded readout so you can tell mount tiers apart at a glance
- Movable, scalable frame with a right-click options menu
- Auto-hides inside instances (raids, dungeons, battlegrounds)
- Optional **ElvUI DataText** so the reading can live in any ElvUI panel
- Configurable sampling rate and smoothing window for the trade-off between responsiveness and stability

## Installation

1. Download `TrueSpeed.zip` from the [latest release](https://github.com/NigelStruble/TrueSpeed/releases/latest).
2. Extract the `TrueSpeed` folder into your WoW `Interface\AddOns` directory, e.g.:
   ```
   World of Warcraft\_classic_\Interface\AddOns\TrueSpeed\
   ```
3. Restart WoW (or `/reload` if already in-game) and enable **TrueSpeed** in the AddOns list.

The `.toc` lists multiple interface versions (Classic Era, TBC Classic, a Classic expansion, and Retail), so the addon should load on any of those without needing "Load out of date AddOns" enabled. If your client still reports it out of date, enable that option in the character select AddOns menu.

## Usage

Type `/ts` (or `/truespeed`) for the full command list. The frame also responds to **right-click** for a graphical options menu.

### Slash commands

| Command | Effect |
| --- | --- |
| `/ts lock` / `/ts unlock` | Lock or unlock the frame for dragging |
| `/ts reset` | Reset the frame's position to the screen center |
| `/ts title` | Toggle the "TrueSpeed" title line |
| `/ts yards` | Toggle the yards/sec readout |
| `/ts percent` | Toggle the % readout |
| `/ts knots` | Toggle the knots readout |
| `/ts api` | Toggle the secondary API-reported % line |
| `/ts scale <0.5–3.0>` | Set frame scale |
| `/ts interval <0.01–1.0>` | Set sample interval in seconds |
| `/ts window <2–50>` | Set how many samples to average over |
| `/ts hide` / `/ts show` | Hide or restore the frame |

### Color coding

The main speed line is colored by speed tier:

| Color | Range | Typical source |
| --- | --- | --- |
| Grey | < 1% | Stationary |
| White | 1–100% | Walking / running |
| Green | 101–200% | Ground mount |
| Blue | 201–400% | Fast mount / flight form |
| Orange | > 400% | Flight path / very fast travel |

## ElvUI integration

If [ElvUI](https://www.tukui.org/) is installed, TrueSpeed registers a **DataText** named `TrueSpeed` in the **Information** category. Add it to any ElvUI panel via *ElvUI &rarr; DataTexts &rarr; Panels* and pick `TrueSpeed` from the dropdown for whichever slot you want it in.

- The label shows percent of base run speed, colored by the same tier rules as the floating frame.
- Hovering reveals the full breakdown (yd/s, percent, knots, and the API-reported speed for comparison).
- Left-clicking the datatext prints the slash-command help.

The integration is purely optional — if ElvUI isn't loaded, `TrueSpeed_ElvUI.lua` returns immediately and has no effect. Sampling continues even when the floating frame is hidden, so the datatext stays live whether you keep the frame visible or not.

## How it works

Every `updateInterval` seconds (default 0.1s) the addon samples your world position via `C_Map.GetPlayerMapPosition` and converts it to world coordinates with `C_Map.GetWorldPosFromMapPos`. Speed is then computed as the distance between the oldest and newest samples in the smoothing window, divided by the elapsed time. Switching maps invalidates the buffer so cross-zone deltas don't produce nonsense readings.

This approach is independent of `GetUnitSpeed`, which is why it keeps working on flight paths and other vehicle states where the API returns 0.

## License

[MIT](LICENSE) — © 2026 Nigel Struble
