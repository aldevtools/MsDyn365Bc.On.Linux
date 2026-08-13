#!/usr/bin/env bash
# Prepare an arm64 (aarch64) Linux host to run this stack. PROOF OF CONCEPT —
# see ARM64.md for what is known to work and what is known to be broken.
#
#   scripts/setup-arm64-host.sh --check   # report only, change nothing
#   scripts/setup-arm64-host.sh           # install what is missing, ask first
#   scripts/setup-arm64-host.sh --yes     # same, unattended
#
# What it installs, only where missing:
#   1. docker + compose v2 + buildx        (Ubuntu's docker.io by default;
#                                           --docker-ce for Docker's own repo)
#   2. FEX-Emu from ppa:fex-emu/fex        (microarch build chosen from
#                                           /proc/cpuinfo)
#   3. the FEX-x86_64 binfmt_misc handler  (so `platform: linux/amd64`
#                                           containers run without extra flags)
#   4. docker-compose.arm64.yml            (mounts FEX into the amd64
#                                           containers — see step 3 note below)
#   5. optionally the arm64 .NET 8 SDK     (--with-dotnet; only needed to hack
#                                           on StartupHook natively)
#
# Then it VERIFIES, rather than assuming:
#   - FEX runs a static x86-64 binary on the host
#   - FEX runs an x86-64 binary INSIDE an amd64 container with those mounts
#
# Read this before running it:
#   * SQL Server was expected to be the blocker and turned out not to be. There
#     is no arm64 build and the published FEX compatibility notes list MSSQL as
#     crashing, but measured 2026-08-12 on Oryon/FEX-2608-armv8.4 it boots
#     healthy in ~13s and passes DDL/DML/transaction checks under emulation
#     (SQL 2022 CU26, uname inside the container = x86_64). See ARM64.md.
#     If it does NOT work for you, point BC at an x86-64 SQL host with
#     SQL_SERVER=<host> instead.
#   * Emulating the BC container is NOT recommended on the current evidence:
#     11 of 11 `dotnet restore` runs under FEX died with memory corruption
#     (AccessViolationException in Lazy<T>), in a minimal rootfs AND in
#     Microsoft's own amd64 SDK image, and contended atomics measured ~20x
#     slower than native. ARM64.md has the numbers. This script sets up
#     emulation because it is the only route that needs no code changes, and
#     because it is what makes the SQL half work — not because the NST is
#     known to survive it.
#
# What it will never do: remove anything, restart the docker daemon without
# asking, or touch BC_* configuration.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

CHECK_ONLY=0; ASSUME_YES=0; DOCKER_CE=0; WITH_DOTNET=0
FEX_PPA="ppa:fex-emu/fex"
OVERLAY="docker-compose.arm64.yml"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --docker-ce) DOCKER_CE=1; shift ;;
    --with-dotnet) WITH_DOTNET=1; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
todo() { printf '  \033[33mTODO\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
ask() {
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$CHECK_ONLY" = 1 ] && return 1
  read -r -p "  -> $1 [y/N] " a </dev/tty
  [ "$a" = y ] || [ "$a" = Y ]
}

NEED=0
echo "checking arm64 host prerequisites"

# ── 0. is this machine even a candidate ───────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
  bad "this host is $ARCH, not aarch64 — you do not need any of this"
  exit 1
fi
ok "aarch64 host"

# FEX emulates x86-64, which assumes 4 KB pages. A 16 KB-page kernel (some
# distro arm64 kernels, Asahi) is a different problem entirely, so say so up
# front rather than letting it fail three steps later.
PAGESIZE=$(getconf PAGESIZE)
if [ "$PAGESIZE" = 4096 ]; then
  ok "4 KB page size"
else
  bad "page size is $PAGESIZE — x86-64 emulation expects 4096. Stop here."
  NEED=1
fi

MEM_GB=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
if [ "$MEM_GB" -ge 12 ]; then
  ok "${MEM_GB} GB RAM"
else
  warn "${MEM_GB} GB RAM — BC + SQL wants ~15 GB; expect trouble under emulation"
fi

# ── 1. FEX microarch build ────────────────────────────────────────────────────
# The PPA ships three builds. The higher ones use newer atomics, which is
# exactly where x86 store-ordering emulation spends its time, so picking the
# right one is a real performance decision and not cosmetic.
CPUFLAGS=$(grep -m1 '^Features' /proc/cpuinfo | cut -d: -f2)
FEX_PKG=fex-emu-armv8.0
case "$CPUFLAGS" in
  *uscat*) FEX_PKG=fex-emu-armv8.4 ;;   # FEAT_LSE2
  *atomics*) FEX_PKG=fex-emu-armv8.2 ;; # FEAT_LSE
esac
ok "FEX build for this CPU: $FEX_PKG"
case "$CPUFLAGS" in
  *uscat*) : ;;
  *) warn "no FEAT_LSE2 (uscat) — TSO emulation will cost more here" ;;
esac

# ── 2. docker + compose v2 ────────────────────────────────────────────────────
install_docker() {
  if [ "$DOCKER_CE" = 1 ]; then
    # Docker's own repo. Only reached on request: it needs a keyring and a
    # codename that Docker has actually published.
    CODENAME=$(. /etc/os-release; echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/$CODENAME/Release" >/dev/null 2>&1; then
      bad "Docker has no repo for '$CODENAME' — drop --docker-ce to use Ubuntu's docker.io"
      return 1
    fi
    sudo install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg || return 1
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  else
    # Ubuntu's packages. Fewer moving parts, and adequate for a PoC.
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker.io docker-compose-v2 docker-buildx
  fi
}

DOCKER_FRESH=0
if ! command -v docker >/dev/null; then
  todo "docker is not installed"
  if ask "install docker + compose v2?"; then
    install_docker && DOCKER_FRESH=1 || { bad "docker install failed"; NEED=1; }
  else
    NEED=1
  fi
else
  ok "docker present ($(docker --version 2>/dev/null | head -1))"
fi

if command -v docker >/dev/null; then
  if docker compose version >/dev/null 2>&1; then
    ok "compose v2 present ($(docker compose version --short 2>/dev/null))"
  else
    # The repo uses `docker compose up --wait`, which podman-compose and the
    # old docker-compose v1 do not support.
    todo "compose v2 plugin missing (this repo needs 'docker compose ... --wait')"
    if ask "install the compose v2 plugin?"; then
      if [ "$DOCKER_CE" = 1 ]; then sudo apt-get install -y -qq docker-compose-plugin
      else sudo apt-get install -y -qq docker-compose-v2; fi
    else NEED=1; fi
  fi

  if docker info >/dev/null 2>&1; then
    ok "docker reachable as $(id -un)"
  elif id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker; then
    warn "you are in the 'docker' group but this shell predates it — run 'newgrp docker' or re-login"
  else
    todo "cannot talk to the docker daemon as $(id -un)"
    if ask "add $(id -un) to the 'docker' group?"; then
      sudo usermod -aG docker "$(id -un)" \
        && warn "group added — run 'newgrp docker' or log out and back in, then re-run this script"
    else NEED=1; fi
  fi
fi

# ── 3. FEX-Emu ────────────────────────────────────────────────────────────────
if command -v FEX >/dev/null; then
  ok "FEX present ($(command -v FEX))"
else
  todo "FEX-Emu is not installed"
  if ask "add $FEX_PPA and install $FEX_PKG + fex-emu-binfmt64?"; then
    command -v add-apt-repository >/dev/null || sudo apt-get install -y -qq software-properties-common
    if sudo add-apt-repository -y "$FEX_PPA"; then
      sudo apt-get install -y -qq "$FEX_PKG" fex-emu-binfmt64 \
        || { bad "FEX install failed — check that the PPA has a build for this release"; NEED=1; }
    else
      bad "could not add $FEX_PPA"; NEED=1
    fi
  else
    NEED=1
  fi
fi

# binfmt_misc: the deb ships /usr/lib/binfmt.d/FEX-x86_64.conf, so systemd-binfmt
# owns the registration. It is not always applied at install time.
if [ -e /proc/sys/fs/binfmt_misc/FEX-x86_64 ]; then
  ok "binfmt handler FEX-x86_64 registered"
elif command -v FEX >/dev/null; then
  todo "FEX-x86_64 binfmt handler is not registered"
  if ask "register it (systemctl restart systemd-binfmt)?"; then
    sudo systemctl enable --now systemd-binfmt 2>/dev/null
    sudo systemctl restart systemd-binfmt 2>/dev/null
    if [ ! -e /proc/sys/fs/binfmt_misc/FEX-x86_64 ]; then
      # binfmt-support is the other possible owner on Debian-derived systems.
      sudo update-binfmts --enable FEX-x86_64 2>/dev/null
    fi
    [ -e /proc/sys/fs/binfmt_misc/FEX-x86_64 ] \
      && ok "binfmt handler registered" \
      || { bad "could not register the FEX-x86_64 handler"; NEED=1; }
  else
    NEED=1
  fi
fi

# Warn about a competing handler: whichever binfmt entry matches first wins, and
# it is not per-container. If qemu is also registered, which emulator you get is
# not obvious from anything in this repo.
if [ -e /proc/sys/fs/binfmt_misc/qemu-x86_64 ] && [ -e /proc/sys/fs/binfmt_misc/FEX-x86_64 ]; then
  warn "both FEX-x86_64 and qemu-x86_64 handlers are registered — the kernel picks one"
  warn "  disable the other with: echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-x86_64"
fi

# ── 4. the compose overlay that makes FEX reachable inside amd64 containers ───
# /usr/bin/FEX is dynamically linked, and binfmt's F flag pins only the
# interpreter executable, not its libraries. An amd64 container has no aarch64
# loader and no aarch64 libc, so FEX cannot start there without these mounts.
# None of the paths collide with x86-64 ones, which is why this is safe.
write_overlay() {
  local libs=(libstdc++.so.6 libm.so.6 libgcc_s.so.1 libc.so.6)
  local loader=/lib/ld-linux-aarch64.so.1
  [ -e "$loader" ] || loader=/lib64/ld-linux-aarch64.so.1
  {
    echo "# Generated by scripts/setup-arm64-host.sh — arm64 host, amd64 containers."
    echo "#"
    echo "# FEX is invoked by the kernel via binfmt_misc, but it is dynamically linked,"
    echo "# so the aarch64 loader and its four libraries have to be visible INSIDE the"
    echo "# container. FEX_ROOTFS=/ tells FEX to use the container's own x86-64 rootfs"
    echo "# instead of downloading one."
    echo "#"
    echo "# HOME is not optional. FEX needs a writable HOME for its config dir and for"
    echo "# the FEXServer handshake; the mssql image runs as uid 10001 with no HOME set"
    echo "# at all, so FEX falls back to './.config/fex-emu/' in an unwritable cwd and"
    echo "# dies with 'Couldn't connect to FEXServer socket'. Verified: HOME alone fixes"
    echo "# it, XDG_CONFIG_HOME alone does not."
    echo "#"
    echo "# Usage:"
    echo "#   docker compose -f docker-compose.yml -f $OVERLAY up -d --wait"
    echo "#"
    echo "# See ARM64.md. SQL Server under emulation is the known risk — bring 'sql' up"
    echo "# on its own first."
    echo "services:"
    for svc in sql bc; do
      # sql's tmpfs for /var/opt/mssql/data counts against its cgroup, so it needs
      # headroom above MSSQL_MEMORY_LIMIT_MB; bc gets the larger share.
      case "$svc" in sql) svc_mem=8g ;; *) svc_mem=16g ;; esac
      echo "  $svc:"
      echo "    platform: linux/amd64"
      echo "    # core: 0 is NOT optional, and it is not about disk space. FEX reserves a"
      echo "    # ~35 GB virtual address space to emulate x86-64. When an emulated process"
      echo "    # faults, the kernel hands that core to whatever core_pattern points at --"
      echo "    # on Ubuntu that is apport, which processed it to ~20 GB resident and drove"
      echo "    # a 30 GB machine into global OOM three times, taking the host down."
      echo "    # Learned the hard way on 2026-08-12. See ARM64.md."
      echo "    ulimits:"
      echo "      core: 0"
      echo "    # A hard cap so a runaway emulated NST kills its own container instead of"
      echo "    # the desktop. Tune up if BC needs more; do not remove."
      echo "    mem_limit: ${svc_mem}"
      echo "    environment:"
      echo "      FEX_ROOTFS: /"
      echo "      HOME: /tmp"
      echo "    volumes:"
      echo "      - /usr/bin/FEX:/usr/bin/FEX:ro"
      echo "      - /usr/bin/FEXServer:/usr/bin/FEXServer:ro"
      echo "      - $loader:$loader:ro"
      for l in "${libs[@]}"; do
        echo "      - /usr/lib/aarch64-linux-gnu/$l:/usr/lib/aarch64-linux-gnu/$l:ro"
      done
    done
  } > "$OVERLAY"
}

if [ -f "$OVERLAY" ]; then
  ok "$OVERLAY exists (not overwritten)"
elif [ "$CHECK_ONLY" = 1 ]; then
  todo "$OVERLAY not written yet"
else
  if ask "write $OVERLAY (mounts FEX into the amd64 containers)?"; then
    write_overlay && ok "wrote $OVERLAY"
  fi
fi

# ── 5. optional: arm64 .NET SDK, for working on StartupHook natively ─────────
if [ "$WITH_DOTNET" = 1 ]; then
  if command -v dotnet >/dev/null; then
    ok "dotnet present ($(dotnet --version 2>/dev/null))"
  elif ask "install the arm64 .NET 8 SDK to ~/.dotnet (no root)?"; then
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
      && bash /tmp/dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet" \
      && ok "installed to ~/.dotnet — add it to PATH: export PATH=\"\$HOME/.dotnet:\$PATH\"" \
      || bad "dotnet install failed"
    rm -f /tmp/dotnet-install.sh
  fi
fi

# ── 6. verify, rather than assume ────────────────────────────────────────────
echo
echo "verifying"

# 6a. FEX on the host, with a static x86-64 binary so no guest rootfs is needed.
if command -v FEX >/dev/null; then
  # The basename MUST stay "busybox": busybox dispatches on argv[0] and exits
  # 127 with "applet not found" under any other name, which looks exactly like
  # an emulation failure and is not one.
  BBX=/tmp/bc-arm64-check.fex/busybox
  if [ ! -x "$BBX" ]; then
    D=$(mktemp -d)
    if curl -fsSL --max-time 120 \
        "http://archive.ubuntu.com/ubuntu/pool/main/b/busybox/busybox-static_1.36.1-6ubuntu3_amd64.deb" \
        -o "$D/bb.deb" 2>/dev/null \
       && (cd "$D" && ar x bb.deb && tar xf data.tar.* ./usr/bin/busybox 2>/dev/null); then
      install -D -m 0755 "$D/usr/bin/busybox" "$BBX"
    fi
    rm -rf "$D"
  fi
  if [ -x "$BBX" ]; then
    if "$BBX" echo fex-ok 2>/dev/null | grep -qx fex-ok; then
      # Ran with no explicit interpreter → binfmt_misc dispatched it.
      ok "x86-64 binary runs via binfmt (transparent emulation works)"
    elif FEX "$BBX" echo fex-ok 2>/dev/null | grep -qx fex-ok; then
      warn "FEX works when invoked directly, but binfmt did not dispatch it"
      NEED=1
    else
      bad "FEX could not run a static x86-64 binary"
      NEED=1
    fi
  else
    warn "could not fetch the x86-64 test binary — skipped the host emulation check"
  fi
fi

# 6b. The check that actually matters: FEX inside an amd64 container.
if command -v docker >/dev/null && docker info >/dev/null 2>&1 && [ -f "$OVERLAY" ]; then
  MOUNTS=()
  while read -r m; do [ -n "$m" ] && MOUNTS+=(-v "$m"); done <<EOF
$(grep -oE '^\s+- [^ ]+:[^ ]+:ro' "$OVERLAY" | sed 's/^ *- //' | sort -u)
EOF
  if [ "${#MOUNTS[@]}" -gt 0 ]; then
    # As uid 10001 with HOME set, i.e. the way the sql container actually runs.
    # Testing this as root passes even when the real thing cannot start.
    if docker run --rm --platform linux/amd64 -e FEX_ROOTFS=/ -e HOME=/tmp \
         --user 10001:10001 "${MOUNTS[@]}" \
         debian:12-slim /bin/echo container-fex-ok 2>/dev/null | grep -q container-fex-ok; then
      ok "x86-64 container runs under FEX as non-root with the overlay mounts"
    else
      bad "could not run an amd64 container under FEX — the overlay mounts are not sufficient here"
      echo "        reproduce it directly:"
      echo "          docker run --rm --platform linux/amd64 -e FEX_ROOTFS=/ \\"
      echo "            \$(grep -oE '^\\s+- [^ ]+:ro' $OVERLAY | sed 's/^ *- /-v /' | sort -u | tr '\\n' ' ') \\"
      echo "            debian:12-slim /bin/echo hello"
      NEED=1
    fi
  fi
else
  todo "skipped the container check (needs docker access and $OVERLAY)"
fi

# ── what to do next ──────────────────────────────────────────────────────────
echo
if [ "$NEED" = 0 ]; then
  echo "host is ready for the PoC."
else
  echo "host is NOT fully ready — see the FAIL/TODO lines above."
fi
[ "$DOCKER_FRESH" = 1 ] && echo "NOTE: docker was just installed; you may need 'newgrp docker' before it works as $(id -un)."
cat <<'NEXT'

next steps:

  # 1. SQL Server under emulation. Measured working: healthy in ~13s, and it
  #    passes DDL/DML/transaction checks (SQL 2022 CU26, emulated x86_64).
  docker compose -f docker-compose.yml -f docker-compose.arm64.yml up -d sql
  docker compose exec sql /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U sa -P "$SA_PASSWORD" -C -No -Q "SELECT @@VERSION"

  # 2. The whole stack, with the NST emulated too. THIS IS THE PART THAT IS
  #    NOT EXPECTED TO WORK: 11 of 11 `dotnet restore` runs under FEX died
  #    with memory corruption (AccessViolationException in Lazy<T>), in both
  #    a minimal rootfs and Microsoft's own amd64 SDK image. The NST is a far
  #    heavier .NET workload than that. Try it if you want the data point.
  docker compose -f docker-compose.yml -f docker-compose.arm64.yml up -d --wait
  docker compose logs -f bc

  # 3. Tear down (also removes the artifact cache volume)
  docker compose -f docker-compose.yml -f docker-compose.arm64.yml down -v

the supported-looking route is the other one: native arm64 for `bc`, emulated
FEX for `sql`. ARM64.md has the measurements and the remaining port work.
NEXT
