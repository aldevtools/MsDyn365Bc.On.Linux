# Business Central on Windows on ARM

Running this amd64 stack on an **arm64 Windows** machine (Snapdragon X Elite and
similar) under Docker Desktop, with FEX-Emu providing x86-64 emulation.

Status: **works, with one caveat that is the whole story** — BC itself is solid,
and SQL Server under emulation is not. Read "SQL Server is the limiting
component" before relying on this for anything you would be upset to lose.

Companion docs: [ARM64.md](../ARM64.md) (the measurements this builds on),
[ARM64-LESSONS.md](ARM64-LESSONS.md) (the arm64 *Linux* session log — most of its
traps apply here too).

## Quick start

```powershell
# 1. Install Docker Desktop for Windows (arm64), start it once, then:
wsl --version                     # confirm WSL2 is present

# 2. Give the WSL2 VM enough memory. The compose limits total 22 GB, and WSL2
#    defaults to half of host RAM. A VM-level OOM kill looks exactly like the
#    emulation corruption this stack is prone to, so this is not tuning.
#    Create %UserProfile%\.wslconfig:
#        [wsl2]
#        memory=24GB
#        processors=12
#        swap=8GB
wsl --shutdown                    # then restart Docker Desktop
```

```bash
# 3. Clone with LF endings. The image build runs these scripts as bash; CRLF
#    gives "bad interpreter" / "\r: command not found".
git -c core.autocrlf=false clone https://github.com/StefanMaron/MsDyn365Bc.On.Linux
cd MsDyn365Bc.On.Linux

# 4. One command. Registers binfmt, checks the images, starts SQL (retrying),
#    starts BC, starts periodic backups.
bash scripts/arm64-windows-up.sh
```

First boot downloads ~2 GB of BC artifacts and restores the demo database; expect
15-20 minutes. Subsequent boots reuse both and reach `Ready for extensions` in
about 150 seconds.

The script preflights before touching anything, because most of these fail late
and illegibly otherwise:

| check | why it matters |
|---|---|
| Docker daemon reachable, arch `aarch64` | wrong host entirely |
| `docker compose` v2 | the stack needs `--wait` and per-service `platform:` |
| VM page size == 4096 | x86-64 emulation assumes 4 KB pages |
| CPU has `uscat` (FEAT_LSE2) | the published images bake `fex-emu-armv8.4`; without LSE2 it SIGILLs, which reads as a broken image rather than a CPU mismatch. Rebuild with `--build-arg FEX_PACKAGE=fex-emu-armv8.0` |
| VM memory ≥ 22 GB | below the compose `mem_limit`s the VM OOM-kills a container, which looks exactly like emulation corruption |
| ≥ 25 GB free in the VM | running out mid-restore fails inside SQL and reads as corruption |
| FEX present in every amd64 image | with `POC` binfmt an image without it cannot exec at all |

Memory and disk are warnings; the rest are hard stops.

Then: web client on <http://localhost:8080>, dev endpoint 7049, OData 7048, API
7052. Sign in as `BCRUNNER` / `Admin123!`.

If SQL dies later, `bash scripts/arm64-recover.sh` recreates it and restores the
newest backup.

## Why this is different from arm64 Linux

`docker-compose.arm64.yml` bind-mounts `/usr/bin/FEX` and the aarch64 loader from
the host. That cannot work here: **Docker Desktop's daemon runs inside its own
`docker-desktop` WSL2 distro**, so a host bind-mount source resolves in that
filesystem — not in Windows, and not in another WSL distro.

So FEX is **baked into the images** instead ([src/Dockerfile.fex-graft](../src/Dockerfile.fex-graft)):
an arm64 stage installs FEX from `ppa:fex-emu/fex`, and a COPY-only amd64 stage
copies `/usr/bin/FEX`, `FEXServer`, the aarch64 loader and its `DT_NEEDED` libs
into the amd64 rootfs. None of those paths collide with x86-64 ones. The published
tags are `bc-runner:latest-fex` and `mssql:2022-fex`, built by
[build-fex-images.yml](../.github/workflows/build-fex-images.yml) on an arm64
runner so no emulation is needed at build time.

`scripts/_arm64-compose.sh` picks the right overlay set automatically by asking
`docker info` whether the daemon is Docker Desktop, so none of the arm64 scripts
need `BC_COMPOSE_FILES` set by hand.

## Findings specific to this platform

Measured 2026-08-13/14 on a Snapdragon X Elite X1E78100 (12 cores, 32 GB),
Windows 11 26200, Docker Desktop 4.86, WSL2 kernel 6.18, FEX 2608 armv8.4.

### Docker Desktop's stock QEMU cannot run SQL Server at all

Docker Desktop pre-registers `/usr/bin/qemu-x86_64` (flags `POCF`) as the x86-64
binfmt handler. Under it, SQL Server 2022 dies **before printing a single line of
its own log**:

```
qemu: uncaught target signal 11 (Segmentation fault) - core dumped
launch_sqlservr.sh: line 24: 14 Segmentation fault  "$@"
```

Deterministic, exit 139, 2/2 attempts. Under FEX the identical image reports
healthy in 22s and passes DDL / 20k-row DML / exact-arithmetic / `LIKE` /
transaction-rollback / collation checks.

This inverts the published guidance: the FEX-on-podman compatibility table lists
MSSQL as *crashing under FEX*. On this platform the reverse is true, and the same
claim aimed at QEMU is exactly right.

### The binfmt handler must be registered `POC`, not `POCF`

The `F` (fix-binary) flag makes the kernel open the interpreter **once at
registration time** and pin that fd. That is what
[ARM64-LESSONS.md](ARM64-LESSONS.md) records as silently invalidating two
measurement rounds on Linux. With FEX baked into images rather than mounted from
the host, `F` is not merely unhelpful — it is wrong, because the interpreter has
to be resolved per-container.

Consequence worth internalising: **with `POC`, an amd64 image that does *not*
contain FEX cannot exec anything at all**, and the only diagnostic is

```
exec /opt/mssql/bin/launch_sqlservr.sh: permission denied
```

`scripts/arm64-windows-up.sh` checks for `/usr/bin/FEX` in every amd64 image
before starting anything, because that error names nothing useful.

Registration is **kernel-global VM state and cannot be made to persist** across a
host reboot, `wsl --shutdown`, or a Docker Desktop restart — the docker-desktop
distro's rootfs is managed. It *does* survive host sleep (verified across ~20h and
two sleep cycles). The fix is the `binfmt` compose init service, which re-runs on
every `up`; re-registering every time IS the design, not a workaround.

### SQL Server fails in three distinct ways — do not lump them together

Roughly **one SQL start in three fails** on this box. Lumping these together is
the same mistake [ARM64-LESSONS.md](ARM64-LESSONS.md) calls the costliest of the
Linux session:

| mode | signature | when |
|---|---|---|
| SQLPAL abort | `exit 134` (SIGABRT), `Reason: 0x00000006`, sqlpal.dll frames | after ~35 min of uptime, under load |
| LSA/SAM crash | `exit 248`, `Reason: 0x2`, `Last errno: 2`, frames through emulated `lsass.exe` → `lsasrv.dll` → `samsrv.dll` | at startup |
| silent hang | container up, `sqlservr` at ~1% CPU, only the 3 banner lines ever printed, never reaches `ready for client connections`, no dump | at startup |

Note `exit 248` here does **not** mean what the ARM64-LESSONS table says it means
("crash recovery of an existing data dir") — the tmpfs data dir was fresh every
time. Same exit code, different cause.

SQL's own crash handler also fails under FEX (`Invalid or Unsupported elf file …
misconfigured x86-64 RootFS`), so no dump is ever captured. That message is
emitted by `paldumper` *after* the crash and is not the cause of anything.

### Do not poll SQL with an emulated client — it appears to be what kills it

The stock healthcheck (`docker-compose.yml`) runs `sqlcmd` every 5s with
`start_period: 20s`, i.e. from t=0. Under FEX **every one of those is a whole new
emulated guest process**, racing SQLPAL's LSA/SAM initialisation and sharing
`HOME=/tmp` for the FEXServer handshake.

| configuration | SQL uptime |
|---|---|
| stock healthcheck enabled | **35.5 min**, then `exit 134` |
| healthcheck disabled | **>20 h**, zero fatal errors |

Caveats, stated plainly: n=1 on each side, the host slept twice during the long
run (containers do not execute while suspended), and the load was near-idle. It is
not a clean 20-hour measurement. But 35 min → 20 h is far outside anything the
noise can explain, and it means the mitigation is *"don't poll SQL with an
emulated client"* rather than *"accept crash-only operation"*.

`docker-compose.arm64-windows.yml` therefore disables SQL's healthcheck. Nothing
depended on it: `docker-compose.yml` gates `bc` on `service_started`, and
`docker-compose.arm64-goal.yml`'s BC healthcheck already does a real TDS
roundtrip. `arm64-windows-up.sh` reads readiness from SQL's own log line instead.

### `restart: on-failure` plus a tmpfs data dir destroys the database silently

`docker-compose.arm64-goal.yml` sets `restart: on-failure:10` on sql. Combined
with the base compose's tmpfs `/var/opt/mssql/data`, a SQLPAL abort becomes:

> SQL aborts → container restarts → tmpfs is recreated **empty** → the restored
> CRONUS database and the `bctest` login are gone → NST reports
> `Login failed for user 'bctest'. Could not find a login matching the name
> provided.`

An authentication error, several restarts downstream of a crash that has already
scrolled out of the log. `docker-compose.arm64-windows-late.yml` sets
`restart: "no"` on the Windows path; the start script's recreate loop is the
restart policy, and `arm64-recover.sh` is the correct response to a death.
ARM64-LESSONS.md already says recovery must *recreate* rather than restart — what
it does not say is that restarting also destroys the data and misattributes the
failure.

### A healthy container is not a working stack

Because the NST answers `/dev/metadata` and the web client root from cache, both
returned **HTTP 200 for a fully dead database**, while OData and the API returned
nothing. If you are checking whether this is alive, check OData or the API.

## Operating it

Because SQL can die, two things run alongside the stack:

- **`scripts/arm64-backup.sh`** — `COPY_ONLY` CRONUS backups to a separate
  `/backups` volume that recovery never wipes. Measured **2s** for a 600 MB
  compressed backup (the tmpfs source helps), so a 5-minute interval is free.
  `arm64-windows-up.sh` starts this automatically.
- **`scripts/arm64-recover.sh`** — recreates SQL (never restarts it: a restarted
  `sqlservr` hangs in crash recovery under emulation), restores the newest backup,
  and reboots BC. Validated end to end.

## What actually works

BC itself has never been the cause of a failure here:

- Cold boot to `Ready for extensions` in **144-150s** (arm64 Linux: 127s)
- All 137 pre-installed apps, `BC_CLEAR_ALL_APPS=none`
- Dev endpoint, OData, API and the self-hosted web client all serving, sign-in
  through to role centre and list pages
- Zero container restarts across a 20h run

## Known limits and open questions

- **No native arm64 SQL Server exists**, including in the 2025 image (checked:
  `mssql/server:2025-latest` is a single amd64 manifest). Azure SQL Edge is the
  only native arm64 engine and its SQL-2019-era engine cannot restore BC's
  SQL-2022 backup — `RESTORE` is upgrade-only, and the internal database version
  is a property of the engine build, not a setting. `RESTORE FILELISTONLY`
  succeeding on an incompatible backup proves nothing; it reads the header only.
- **Untried: SQL Server 2022 CU17.** `docker-compose.macos.yml` pins away from
  CU18+ because those crash under Rosetta 2, and the mirror here is CU26. SQLPAL's
  emulator compatibility demonstrably moves per CU, so CU17 is the cheapest
  remaining experiment with a documented precedent behind it.
- **AL tests have not been run on this platform.**
- **The soak was interrupted by host sleep**, so no clean continuous-uptime figure
  exists yet.
- The `FEX_*` knobs in `docker-compose.arm64-goal.yml` are inherited from the
  Linux session and have **not** been individually re-validated here.
