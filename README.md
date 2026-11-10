# PearlPilot

**Lock Windows. Wait. Mine PearlHash.**

PearlPilot is a Windows tray app that builds and manages **Linux WildRig inside Docker**. It handles your payout address, mining policy, temperature protection, live statistics, updates and recovery. No Windows miner, private keys or manual Docker commands are required.

[Get started](#get-started) · [Everyday use](#everyday-use) · [Updates](#updates-and-rollback) · [Security](#security-model) · [Troubleshooting](#troubleshooting) · [Development](#development)

## Get started

### Before you clone

You need:

- **Windows 11 x64**, Git and Windows PowerShell 5.1, which is included with Windows.
- An **NVIDIA GPU** and a current Windows NVIDIA driver with working `nvidia-smi`.
- **Docker Desktop**, running Linux containers with **Use the WSL 2 based engine** enabled. Start Docker Desktop before installing PearlPilot.
- At least **2 GiB free** on the Windows data drive and in Docker storage, plus Internet access to GitHub, Docker Hub, Ubuntu packages and your mining pool.
- A **public PRL payout address**. Never enter a private key or recovery phrase.

Docker GPU passthrough requires WSL2. If it is not already working, follow [Docker's Windows GPU guide](https://docs.docker.com/desktop/features/gpu/) and [NVIDIA's WSL guide](https://docs.nvidia.com/cuda/wsl-user-guide/index.html). Install drivers on Windows, not inside Docker Desktop's managed Linux distribution. AMD/Intel GPUs and a native Linux tray app are not supported.

### Clone, install, enter your address

Run these commands in a regular, non-administrator PowerShell window:

```powershell
git clone https://github.com/joelfourhman/PearlPilot.git
cd PearlPilot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer checks prerequisites, verifies and downloads the latest official stable Linux WildRig release, builds the image, validates GPU/CUDA access, and opens **Menu → Settings**. The first build can take several minutes.

1. Enter your public payout address. Confirm your worker name and GPU index; the defaults suit a single GPU.
2. Choose automatic mining and sign-in startup if wanted, then **Save**.
3. Right-click the PearlPilot tray icon and choose **Mine now**, or let the automatic policy wait until Windows has been locked for three minutes.


Existing installations keep their wallet, worker, policy and other preferences. **Exit a running PearlPilot before using `Install.ps1`**; the installer refuses to compete with its worker. You can also update through the tray as described below.

## Everyday use

Double-click **`RunPearlPilot.vbs`** to start the app without a console window. If you enabled sign-in startup, PearlPilot starts automatically for your Windows account.

| Tray control | What it does |
| --- | --- |
| **Mine now / Stop mining** | Start a manual session, or stop and persist the stop choice |
| **View backend details / Retry mining controller** | Appears when the controller reports a problem. Retry preserves your mining preferences |
| **Automatic mining** | Enable or disable the lock/idle policy; re-enabling clears a saved manual stop |
| **Open Menu** | Open live statistics, settings, backend controls and diagnostics, and logs in one window |
| **Exit PearlPilot** | Stop the owned miner and exit the tray app |

**Menu** opens on **Overview**, which shows live mining and GPU data. The **Settings** and **Backend** pages pause mining. **Logs** shows recent PearlPilot and WildRig messages and can open the log folder.

Normal startup reevaluates automatic policy; it does not restore a manual mining session. A manual stop survives restarts. To explicitly start manually from a terminal:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\PearlPilot.ps1 -MineNow
```

### Mining policy and settings

| Setting | Default and behavior |
| --- | --- |
| Pool | `pool.pearlhash.xyz:9000`; accepts `host:port`, `stratum+tcp://host:port` or `stratum+ssl://host:port` |
| Worker | `pearlpilot`; 1–32 letters, numbers, dots, underscores or hyphens |
| GPU index | `0`; use comma-separated indices for multiple GPUs |
| Wait after lock | 3 minutes; adjustable from 0–60 |
| Stop temperature | 82 °C; mining resumes after cooling by 10 °C; adjustable from 50–95 °C |
| Unlocked idle minutes | `0` disables idle mining; 1–120 allows mining after that much inactivity |
| Pause for processes | Optional comma-separated game/GPU-app process names, with or without `.exe` |
| Automatically update WildRig when idle | Off by default. Installs new stable releases when mining is idle |
| PearlHash kernel / intensity | Kernel `2`, intensity automatic; blank uses WildRig's default; explicit intensity accepts 1–64 |

Unlocking or activity stops automatic lock/idle mining. Manual mode overrides ordinary activity, while **temperature, missing telemetry, configured game processes and suspend stop both modes**. Every selected GPU must report a temperature. PearlPilot does not change clocks, voltage, fan settings or power limits.

`MINING` means the container is running, doing recent positive work and connected to the pool. `STARTING` alone is not success. Share counters are reported separately, and a new image stays on functional probation until an accepted share arrives. Unknown or unavailable statistics remain unavailable; the 60-second average needs sufficient uptime.

**Benchmark 2 × 60s** deliberately runs two pool sessions to compare WildRig defaults with your configured kernel/intensity, reporting hashrate, power and efficiency. Close its setup panel to cancel. No profile is applied automatically. On supported RTX architectures, WildRig itself always selects kernel 2, so those runs may show no kernel difference.

## Updates and rollback

Click the WildRig update notification, then select **Update** on **Menu → Backend**. **Check for updates** refreshes the available version. To opt in to background updates, enable **Automatically update WildRig when idle** under **Menu → Settings** and save.

PearlPilot downloads the official stable Linux release, builds the Docker image, and runs compatibility checks before switching images. If the new image fails during mining, PearlPilot can restore the previous working image. You can also choose **Rollback** on the Backend page. To install a specific stable release from the command line, pass `-Version` to `Install.ps1`.

## Security model

The downloaded miner is treated as untrusted third-party native code:

- Only the official **Linux x86_64** archive is accepted. PearlPilot checks the published checksum when GitHub supplies one. Extraction rejects unsafe paths, links, devices, duplicates, oversized archives and unsupported layouts.
- **Image builds never execute WildRig or its bundled scripts.** Version/help validation happens afterward with no network, no GPU access, a non-root user, a read-only filesystem and the runtime limits. Timed-out helper containers are explicitly removed.
- Mining runs as **UID 65532**, with all Linux capabilities dropped, no-new-privileges and Docker's default seccomp filtering. Miner files are root-owned/read-only; scratch space is bounded, non-executable tmpfs. CPU, memory/swap, process, core-dump and log limits apply.
- No host directory, Docker socket or private credentials are mounted. The public payout address is passed at runtime, never baked into an image. The miner API is exposed only on an ephemeral **127.0.0.1** port.
- Runtime references use the verified **immutable image ID**, with ownership/version/hash/security-policy checks. Docker cannot automatically restart mining. Windows/native fallback is disabled.
- A serialized worker supervises parent identity, fresh policy, thermal safety and bounded recovery. Stop confirmation acknowledges the current intent. Benchmark requests expire and belong to one live setup panel. An operational 30-second lease stops ordinary unattended mining after controller loss.

**Docker reduces exposure; it does not guarantee containment.** GPU passthrough exposes the host driver. Mining needs outbound networking, and this project does not implement a pool-only egress firewall: malicious code could contact reachable Internet, LAN or host services. The lease shares the miner's container user and is not a boundary against hostile code. Kernel, driver or runtime vulnerabilities remain relevant; a separate mining machine provides a stronger boundary.

The Ubuntu LTS base, certificate bootstrap source and dated package snapshot are pinned. Rebuilding alone does **not** pick up new security fixes. Maintainers must deliberately update base digests/snapshot dates and retest. Keep Docker Desktop, WSL and the Windows NVIDIA driver updated through their supported mechanisms. PearlPilot does not replace or restart those host components.

References: [official WildRig releases](https://github.com/andru-kun/wildrig-multi/releases), [Docker runtime controls](https://docs.docker.com/engine/containers/run/), [Docker security](https://docs.docker.com/engine/security/), [Ubuntu security notices](https://ubuntu.com/security/notices).

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Docker unavailable / commands time out | Start Docker Desktop, select Linux containers and enable its WSL2 engine. If Docker is unresponsive, restart Docker Desktop, then choose **Retry mining controller** in the tray. Restarting Docker interrupts other containers. |
| GPU/CUDA check fails | Confirm host `nvidia-smi`, then run **Diagnostics**. Review the Windows NVIDIA driver and WSL GPU setup; `nvidia-smi` alone is not proof of CUDA initialization. |
| Download checksum mismatch | Retry **Update** to fetch the official download again. |
| Build fails | Open `%LOCALAPPDATA%\PearlPilot\Backend\last-build.log`. Check connectivity to Docker Hub, GitHub and the Ubuntu snapshot, plus Docker disk space. |
| STARTING persists | Inspect pool/DNS connectivity, payout address, API errors and miner logs. No useful work for 120 seconds triggers bounded recovery. |
| Repeated failures / ERROR | Correct the cause and choose **Retry**. Recovery backs off and stops after six failures; it never enables a native fallback. |
| Cooling down / telemetry unavailable | Allow a 10 °C cooldown and verify temperatures for every configured GPU. The tray shows the pause reason; application log transitions include policy, GPU temperature and telemetry availability. |
| Saved settings cannot be read | Back up and repair `%LOCALAPPDATA%\PearlPilot\config.json`, or move it aside to configure again. Invalid JSON is not silently overwritten. |
| Exit code 139 during shutdown | This occurred with upstream 0.51.8 in testing. Cleanup is checked separately; an intentional stop does not trigger restart. |

Settings and runtime data live in **`%LOCALAPPDATA%\PearlPilot`**, outside your checkout. `config.json` holds preferences; `Logs` holds application/miner logs; `Backend` holds downloads, image records, diagnostics and benchmark results; `Runtime` holds worker IPC and recovery state. Unknown saved settings survive upgrades. Cleanup is limited to PearlPilot ownership labels and never globally prunes Docker resources.

## Development

There is no compiled Windows app, package manager, Python requirement or separately installed PowerShell module. The checkout contains everything except the host prerequisites and verified downloads.

```powershell
# Same syntax, unit and worker-IPC checks as CI:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1

# Build and validate without opening Settings or starting mining:
# Exit PearlPilot first when using the default per-user data directory.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -NoLaunch

# Deliberate 60-second mining acceptance test; exit PearlPilot first:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-DockerBackend.ps1 -AuthorizeMining -Seconds 60
```

For a completely separate, empty installation cache, use `Install.ps1 -NoLaunch -DataRoot <absolute-directory>`. This builds/validates without touching your regular installation or requiring a configured wallet. Custom data roots are build/validation targets; the tray uses its standard per-user directory.

The mining smoke test requires positive work, GPU activity, a connected pool, an accepted share and confirmed cleanup. A short session may find no share and correctly remain unvalidated. Tests do not establish long-term stability or physical lock/sleep/sign-in behavior.

| Path | Purpose |
| --- | --- |
| `Install.ps1`, `RunPearlPilot.vbs`, `Uninstall.ps1` | Install/update, hidden launch and removal |
| `PearlPilot.ps1` | Tray UI, settings, statistics and host mining policy |
| `Core/` | Configuration defaults, backend worker, menu and Docker build files |
| `Assets/` | Windows tray and desktop shortcut icon |
| `Tests/` | Regression fixtures, project checks and opt-in hardware smoke test |

The installer stages the verified distribution for `Core/Docker/Dockerfile`. The CUDA probe compiles with warnings treated as errors. Production images omit the compiler and NVIDIA kernel drivers.

## Uninstall

```powershell
# Remove startup and owned runtime resources; keep preferences and logs:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1

# Also delete per-user settings, logs and cached downloads:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1 -DeleteUserData
```

Use `-WhatIf` to preview either command. Unrelated Docker resources are left alone. The checkout itself is not deleted.

## License

PearlPilot is available under the [MIT License](LICENSE). The installer downloads WildRig separately from its upstream release.
