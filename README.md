# PearlPilot

[![CI](https://github.com/joelfourhman/PearlPilot/actions/workflows/ci.yml/badge.svg)](https://github.com/joelfourhman/PearlPilot/actions/workflows/ci.yml)

PearlPilot is a small Windows 11 tray app with one job:

> Lock → wait three minutes → mine. Unlock → stop. Or choose **Mine now** from the tray.

It runs as the signed-in user, starts WildRig automatically only when the session remains locked, and stops the exact process it owns as soon as Windows unlocks. A deliberate **Mine now** override can mine while unlocked. Missing NVIDIA temperature telemetry always prevents mining.

## Install

Requirements:

- Windows 11
- Windows PowerShell 5.1
- An NVIDIA GPU with `nvidia-smi.exe`
- A verified [WildRig](https://github.com/andru-kun/wildrig-multi/releases) executable
- A public PRL payout address—never a seed phrase or private key

Run from Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The setup window asks only for the WildRig path, public wallet, worker name, GPU index, lock delay, temperature limit, and startup preference. Settings are stored in `%LOCALAPPDATA%\PearlPilot`.

## Tray UX

PearlPilot stays out of the way. Its right-click menu contains:

```text
Status: Locked · starts in 2:41 · 45°C
────────────────────────────────────
Mine now
Automatic mining ✓
Settings…
Open logs
────────────────────────────────────
Exit PearlPilot
```

Choose **Mine now** to start while Windows is unlocked; it changes to **Stop mining** until manual mode is turned off. Double-click the icon to open Settings. Turning off **Automatic mining** stops lock-triggered mining. Exiting PearlPilot always stops its miner.

## Safety behavior

- Lock and unlock events come from `Microsoft.Win32.SystemEvents.SessionSwitch`.
- The current session state is reconciled every 30 seconds in case an event was missed.
- A working WinForms message pump keeps session events responsive.
- NVIDIA temperature is checked every 10 seconds; unavailable telemetry fails closed.
- Manual mining bypasses only the lock requirement; telemetry, temperature, duplicate-process, and crash-loop protections remain active.
- Thermal shutdown remains latched until the GPU cools 10 °C below the configured limit.
- PID plus process creation time prevents PearlPilot from stopping an unrelated process.
- Duplicate WildRig instances are refused.
- Unexpected exits retry after 10 seconds, with a maximum of five retries per lock session/hour.
- A limited per-user Task Scheduler entry starts PearlPilot after sign-in; no service or elevation is used.

PearlPilot configures WildRig for `pearlhash` at `pool.pearlhash.xyz:9000`. It deliberately does not scrape pool pages, estimate earnings, tune GPU clocks, or maintain a second background agent.

## Test

The dependency-free test suite validates lock timing, fail-closed behavior, thermal policy, WildRig arguments, exact process ownership, mock-miner cleanup, and startup identity:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```

Physical Win+L, sleep/resume, Task Scheduler, the target GPU, and the current WildRig/PearlHash connection must still be validated on the target desktop.

## Uninstall

Remove startup registration and stop owned processes while preserving settings and logs:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

Add `-DeleteUserData` to remove `%LOCALAPPDATA%\PearlPilot` after confirmation.

## Project layout

```text
PearlPilot.ps1          tray, settings, lock policy, supervision
Core/PearlPilot.psm1    configuration, safety, miner, GPU, startup helpers
Config/defaults.json    defaults
Install.ps1             compatibility check and first launch
Uninstall.ps1           startup and owned-process cleanup
Tests/                  focused dependency-free tests and mock miner
```
