# PearlPilot

PearlPilot is a Windows 11 tray app. It supervises Linux WildRig in Docker Desktop with WSL2 and NVIDIA GPU access. Support Windows PowerShell 5.1.

## Project map

- `RunPearlPilot.vbs` launches `PearlPilot.ps1` without a console. Keep the launcher and icon paths stable for existing shortcuts and sign-in tasks.
- `PearlPilot.ps1` owns tray actions and mining policy. `Core/Menu.ps1` owns the Windows Forms UI.
- `Core/PearlPilot.psm1` owns configuration and Windows integration. `Core/Backend.psm1` and `Core/BackendWorker.ps1` own Docker operations and worker supervision.
- `Core/Docker/` contains the pinned build recipe, CUDA probe, and lease supervisor. `Install.ps1` and `Uninstall.ps1` are the public setup and removal entry points.

## Runtime contracts

- Keep settings, logs, and worker state under `%LOCALAPPDATA%\PearlPilot`. Preserve existing user settings on upgrade. Use a separate data root for tests.
- Preserve thermal and session policy, atomic worker messages, Docker ownership checks, and the container lease. Limit cleanup to PearlPilot-owned resources.
- Keep WildRig updates one click. Automatic updates are opt-in and run while mining is idle. Fetch official stable Linux assets and verify the published checksum when available. Keep downloaded miner code inside the restricted container.
- Keep local settings, payout addresses, runtime logs, downloads, and generated artifacts out of commits. Keep fixtures sanitized.

## Verification

Run the same tests as CI from the repository root.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
```

Use the isolated `Install.ps1 -NoLaunch -DataRoot <absolute-directory>` path for hardware build checks. Run a live mining smoke test only with explicit authorization. Before tagging a release, verify the exact candidate on Windows with Docker Desktop and NVIDIA hardware. Include first install, launch, lock and unlock, update, rollback, and uninstall.

Push a stable tag such as `v1.0.0` to run the release workflow. It reruns CI against the tagged commit before publishing the GitHub source release.
