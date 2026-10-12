# Memory (oomd) for Omarchy

A fork of [egoist/omarchy-memory-usage](https://github.com/egoist/omarchy-memory-usage), the iStat Menus-style memory widget for the Omarchy bar. Credit for the widget, the rings, the process list and the overall design goes to EGOIST. This fork keeps all of that and makes the widget aware of systemd-oomd, the daemon that kills apps on Omarchy when memory runs short.

![Memory (oomd) preview: the bar chip in normal, warn and critical, and the popup in normal and warn](preview.png)

The preview uses mock data. It shows the bar chip at three levels (normal, warn, critical) above the popup in the normal state and in the warn state.

## What it adds over upstream

- **oomd-aware levels.** The widget judges memory as normal, warn or critical by how close the machine is to an oomd kill, not by RAM used. The bar icon and the popup's rings change color with the level.
- **Distance to the kill lines.** The popup draws RAM, swap and pressure as thin bars. The swap and pressure bars end at their oomd kill line, and a bar takes the level color only when that constraint is the one in warn or critical.
- **Per-app memory by cgroup.** The popup section "Apps oomd could kill" lists the units oomd actually kills, with RAM, swap and how full each app's `memory.max` or swap cap is. Apps marked `user.oomd_omit` are dimmed because oomd skips them.
- **Notifications.** Entering warn or critical sends a desktop notification. Critical uses critical urgency and names the largest app oomd could kill.
- **Light polling.** The cgroup scan runs only while the panel is open or the level is warn or worse.
- **Tests.** `tests/run` covers the scripts against fixture trees and the level logic under node.

## Install

```sh
omarchy plugin add https://github.com/arnaldo-delisio/omarchy-memory-oomd.git --enable
```

The widget lands in the right section of the bar. To place it somewhere else, for example right after the agents widget:

```sh
omarchy plugin enable io.github.arnaldo-delisio.memory-oomd --section right --after omarchy.agents
```

Update it later with `omarchy plugin update io.github.arnaldo-delisio.memory-oomd`.

## Remove

```sh
omarchy plugin remove io.github.arnaldo-delisio.memory-oomd
```

That disables the plugin and deletes its folder. To keep the files and only hide the widget, run `omarchy plugin disable io.github.arnaldo-delisio.memory-oomd` instead. Removing the plugin changes no other configuration: it writes nothing outside its own folder and the bar settings you set for it. If you also run the upstream plugin, the two do not conflict: the ids differ.

## Development

Run `scripts/install-local` from a checkout to validate the plugin and copy it, without `.git` or `tests`, to `~/.config/omarchy/plugins/io.github.arnaldo-delisio.memory-oomd/`. Run it again after any change; the shell reloads plugin files when they change. It uses `rsync`, so the install is a plain copy that updates in one command. It is a developer convenience and the plugin does not use it at runtime.

## The popup

The popup follows the style of the built-in Agents popup: one foreground color on a track color, dim text for secondary information, and the level color only where oomd is getting close. It is 380 px wide at the default font size and scrolls if the screen is too short. From top to bottom:

1. Two rings, pressure and memory. Each has a track arc and one arc of the value in the foreground color, which turns to the level color while the level is warn or critical. Memory is a single arc of RAM used. Pressure is the app.slice PSI `full avg10` figure oomd judges, the same number the Pressure row shows.
2. The level, `NORMAL` in dim, `WARN` or `CRITICAL` in the level color.
3. Three rows with thin bars: `RAM` (used of total and percent), `Swap` (percent and the kill line) and `Pressure` (percent, the kill line and its duration). The swap and pressure bars are scaled to their kill line, so the end of the bar is where oomd acts. Each is foreground on the track and takes the level color only when its own constraint is in warn or critical. The RAM bar never changes color, because oomd does not act on RAM.
4. `APPS OOMD COULD KILL`: one plain row per app with the name on the left (elided when long) and `RAM + swap` on the right, for example `4.0 + 4.2 GB`. An app with a RAM or swap cap gets a dim second line such as `94% of cap`, in the urgent color from 90%. Apps protected from oomd are dimmed.
5. With `listMode` set to `processes` or `both`, a `TOP PROCESSES` section in the same style: name, RSS, and a dim line with the share of RAM.
6. A dim footer, `dimmed apps are protected from oomd`.

Press `R` in the popup to refresh, and the arrow keys scroll it.

## The bar icon

The bar shows the RAM chip glyph (Nerd Font `nf-md-memory`, U+F035B) in the bar's icon slot, drawn like the other first-party bar icons but larger: 17 px by default, where the standard bar icon is 13 px. The `iconSize` setting changes it (12 to 24); the glyph's canvas is always 3 px larger than the glyph, as in the standard 13 in 16, and the glyph stays centered in the bar. It fills from the bottom with RAM used, the same figure as upstream's meter: `MemTotal - MemAvailable` as a share of `MemTotal`. The glyph is drawn twice, dimmed underneath and at full color on top inside a box that is clipped to the used share of the glyph's height, so the two copies line up exactly. The fill height eases over a third of a second.

The color follows the oomd level, not the RAM figure:

| Level | Color | Source |
| --- | --- | --- |
| normal | the bar foreground | `bar.barForeground` |
| warn | the theme's orange | `orange` in the theme's `colors.toml`, else its `yellow` |
| critical | the theme's red | `bar.urgent` (`red` in `colors.toml`, or `[bar] active` in `shell.toml`) |

The popup uses the same colors for its rings, level label and constraint bars.

The shell's own color API does not expose orange or yellow, so the widget reads `colors.toml` of the current theme itself, again after a theme switch and every 5 minutes. A theme with neither key gets a derived warn color: the urgent color turned to an orange hue (about 32 degrees) with at least 60% saturation. Themes that define `red` and `orange` oddly (for example a monochrome theme) show those colors as given.

The old `width` setting only sized the `MEM` label and meter, so it was removed. The widget takes the standard icon slot of the bar, which follows the theme's `icon-slot` size, so a very large `iconSize` is limited by the bar's height.

## Settings

Set one with `omarchy bar set <id> <key> <value>`, for example:

```sh
omarchy bar set io.github.arnaldo-delisio.memory-oomd notify false
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `iconSize` | 17 | Size in pixels of the RAM chip icon in the bar (12 to 24). |
| `listMode` | `apps` | Panel list: `apps` (cgroups), `processes` (executables, as upstream) or `both`. |
| `appCount` | 6 | Rows in the apps list (1 to 12). |
| `processCount` | 5 | Rows in the process list (1 to 10). |
| `notify` | `true` | Send a notification when the level enters warn or critical. |
| `notifyCooldownSec` | 300 | Minimum seconds between two notifications of the same level. |
| `swapWarnMargin` | 15 | Warn when swap used is within this many percentage points of the oomd swap limit. |
| `swapCriticalMargin` | 5 | Critical when swap used is within this many points of the swap limit. |
| `pressureWarnPercent` | 50 | Warn when app.slice pressure reaches this percent of the oomd pressure limit. |
| `criticalHoldPercent` | 50 | Critical when pressure has stayed at or above the limit for this percent of the oomd duration. |

## How levels map to oomd

systemd-oomd kills when either of these holds:

1. System swap used is above `SwapUsedLimit` (in `oomd.conf`).
2. The memory pressure of a monitored cgroup, here `app.slice`, is at or above `DefaultMemoryPressureLimit` for `DefaultMemoryPressureDurationSec`. oomd reads PSI **full** `avg10`, which is what the panel's app.slice figure shows.

`scripts/oomd-config` reads the limits the way systemd does: `oomd.conf`, then the `oomd.conf.d` drop-ins from `/etc`, `/run` and `/usr/lib` (an earlier directory shadows a later one by file name, drop-ins apply in name order), plus `ManagedOOMMemoryPressureLimit` drop-ins on `app.slice`. If nothing is configured the widget falls back to swap 90%, pressure 50%, 20 s. Stock systemd uses 90%, 60% and 30 s, and Omarchy sets 50% and 20 s, so the fallback follows Omarchy.

With the limits known, the widget computes:

| Level | When |
| --- | --- |
| warn | swap used >= swap limit - `swapWarnMargin`, or pressure >= pressure limit x `pressureWarnPercent` / 100 |
| critical | swap used >= swap limit - `swapCriticalMargin`, or pressure >= the limit for at least `criticalHoldPercent` of the duration |

With the defaults and Omarchy's limits that is warn at 75% swap or 25% pressure, and critical at 85% swap or 50% pressure held for 10 s. The held-above counter restarts whenever pressure drops under the limit. A level is left only after the value falls a little below where it started (3 points of swap, 20% of the pressure), so the bar does not flicker around a line.

Notifications fire on escalation only. Each level has its own cooldown, so a warn notification does not hold back a later critical one.

## Per-app memory

`scripts/app-memory` reads the cgroup v2 files of the units at depth 1 and 2 under `app.slice`: `memory.current`, `memory.swap.current`, `memory.max`, `memory.high`, `memory.swap.max` and `memory.pressure`. Names come from the unit name with the prefix and suffix removed and `\x2d` unescaped. Terminal scopes are named by what runs inside, for example `terminal (claude)`, preferring claude, codex and nvim over shells. Units that resolve to the same name are summed. Rows are sorted by RAM plus swap, largest first, and the top N are shown. The cap figure is the fullest unit of the app, not a sum. The popup shows it as `94% of cap`, the fuller of the RAM cap and the swap cap.

Use it directly:

```sh
scripts/app-memory --top 10 | jq '.apps[] | {name, ramBytes, swapBytes, capPercent}'
```

## Polling

The bar samples `scripts/memory-stats` every 2 seconds while memory is normal and every 1 second while the panel is open or the level is warn or worse. PSI averages only change about every 2 seconds, so a faster idle poll would only repeat the same numbers. The oomd config is re-read every 5 minutes.

## How the base metrics work

These are unchanged from upstream. Overall usage is `MemTotal - MemAvailable` from `/proc/meminfo`. The memory ring is a single arc of that figure. The popup no longer shows upstream's composition split (Applications, Kernel, Cache, Free) or the swap in and out rates; `scripts/memory-stats` still reports the composition bytes, and the swap counters were dropped. The pressure ring and row show the `app.slice` PSI `full avg10` that oomd acts on, not the whole machine's `some` figure that upstream showed. Process totals are RSS grouped by executable name, so shared pages can be counted in more than one row.

## Dependencies and security

The plugin runs unsandboxed with your user permissions, like every Omarchy shell plugin. No sudo or pkexec is required. It does not install packages, start services or access the network.

It reads `/proc` and `/sys/fs/cgroup`, and uses commands from a standard Omarchy install: Bash, `jq`, `awk`, `ps`, `sort`, `head`, `date` and `notify-send` (libnotify). `getfattr` (package `attr`) is optional: without it the widget cannot tell which apps are protected with `user.oomd_omit` and shows none as protected. `scripts/install-local` (development only) also needs `rsync`, and the tests need `node`.

## Tests

```sh
tests/run
```

The shell tests build fixture trees (a fake `/proc`, `/sys/fs/cgroup` and oomd config files) and point the scripts at them with `MEMORY_OOMD_ROOT`, which defaults to `/`. The level logic in `Levels.js` is tested with node. `tests/run` exits non-zero if anything fails.

## Changelog

- **1.2.0** (2026-10-12): first public release of the fork. oomd levels, kill-line bars, per-app memory by cgroup, notifications, adaptive polling, the RAM chip bar icon with the `iconSize` setting, the restyled popup, tests, a new preview image, and install and removal instructions for the plugin marketplace. 1.1.0 was an internal version and was not published.
- **1.0.0**: upstream's `dev.egoist.memory-usage` by EGOIST.

## License

MIT. Copyright (c) 2026 EGOIST and Arnaldo Delisio, see `LICENSE`.
