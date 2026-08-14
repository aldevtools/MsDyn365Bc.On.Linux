#!/usr/bin/env bash
# Shared helper: work out which compose overlay set this HOST needs for the
# emulated arm64 stack, so the arm64-* scripts don't need BC_COMPOSE_FILES set by
# hand. Sourced, not executed:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/_arm64-compose.sh"
#   C=$(arm64_compose_files)
#
# Why this exists: getting it wrong is silent and expensive. Running
# arm64-recover.sh with the Linux default on a Docker Desktop host built
# containers from the STOCK images, and because the FEX binfmt handler is
# registered with flags POC (interpreter resolved per-container at exec time), an
# amd64 image with no FEX baked in cannot exec anything at all -- SQL died with
# `exec /opt/mssql/bin/launch_sqlservr.sh: permission denied` and the recovery loop
# then waited 15 minutes for a container that could never start.
#
# Precedence:
#   1. BC_COMPOSE_FILES  — explicit override, used verbatim. Nothing is added.
#   2. auto-detected     — base + platform overlay + disk + goal.
#   3. BC_COMPOSE_EXTRA  — appended to the auto-detected set (diagnostic overlays).

# Print the -f arguments for this host. Chatter goes to stderr so the result can
# be captured with $(...).
arm64_compose_files() {
  if [ -n "${BC_COMPOSE_FILES:-}" ]; then
    printf '%s' "$BC_COMPOSE_FILES"
    return 0
  fi

  local files="-f docker-compose.yml" platform="" why=""

  # The discriminator is the DAEMON, not the shell. Docker Desktop runs its daemon
  # inside its own `docker-desktop` WSL2/VM distro, so docker-compose.arm64.yml's
  # bind-mounts of /usr/bin/FEX and the aarch64 loader resolve in THAT filesystem
  # -- not in Windows and not in another WSL distro. Such a host needs the overlay
  # whose images carry FEX internally instead.
  local dockeros
  dockeros=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || echo '')

  local shellos=no
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) shellos=yes ;;
  esac

  if [ -f docker-compose.arm64-windows.yml ] && \
     { case "$dockeros" in *"Docker Desktop"*) true ;; *) [ "$shellos" = yes ] ;; esac; }; then
    platform="-f docker-compose.arm64-windows.yml"
    why="Docker Desktop / Windows host — FEX baked into images"
  elif [ -f docker-compose.arm64.yml ]; then
    platform="-f docker-compose.arm64.yml"
    why="Linux host — FEX bind-mounted from the host"
  else
    why="no arm64 overlay found — base compose only"
  fi
  files="$files $platform"

  # Both apply on either platform: storage layout, then the mitigation set. goal
  # stays LAST so its settings win, which is what its header assumes.
  [ -f docker-compose.arm64-disk.yml ] && files="$files -f docker-compose.arm64-disk.yml"
  [ -f docker-compose.arm64-goal.yml ] && files="$files -f docker-compose.arm64-goal.yml"

  # Windows-only, and it MUST come after goal to win: goal sets
  # `restart: on-failure:10` on sql, which combined with the tmpfs data dir
  # destroys the database on every SQL crash and reports it as a login failure.
  # See the overlay's own header.
  if [ "$platform" = "-f docker-compose.arm64-windows.yml" ] && \
     [ -f docker-compose.arm64-windows-late.yml ]; then
    files="$files -f docker-compose.arm64-windows-late.yml"
  fi

  [ -n "${BC_COMPOSE_EXTRA:-}" ] && files="$files $BC_COMPOSE_EXTRA"

  printf '[arm64] compose set: %s\n' "$why" >&2

  # Deliberately NO image check here any more. The overlay now defaults to
  # published :latest-fex / :2022-fex tags, so "not present locally" is the normal
  # first-run state and warning about it would be noise. Verifying that the images
  # really contain FEX -- which is the check that actually matters, and is not the
  # same as the image existing -- belongs to scripts/arm64-windows-up.sh, which can
  # fail loudly instead of printing into a command substitution.

  printf '%s' "$files"
}
