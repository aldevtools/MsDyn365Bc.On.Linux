#!/bin/sh
# Register FEX-Emu as the kernel's x86-64 binfmt_misc handler, idempotently.
#
# Runs inside a PRIVILEGED container -- binfmt_misc is kernel-global state shared
# by the whole VM (every WSL2 distro, and the Docker daemon), so registering it
# from a throwaway container changes it for everything. That is what makes this a
# compose init service rather than a host prerequisite: it re-runs on every `up`,
# so a host reboot, a `wsl --shutdown` or a Docker Desktop restart self-heals
# without the user ever learning that binfmt exists.
#
# There is no way to make the registration persist across a VM restart -- the
# docker-desktop distro's rootfs is managed by Docker Desktop and nothing we write
# there survives. Re-register-on-every-up IS the correct design here, not a
# workaround for one.
#
# POSIX sh, no bashisms: this runs in alpine.
set -eu

BF=/proc/sys/fs/binfmt_misc
mount -t binfmt_misc binfmt_misc "$BF" 2>/dev/null || true
[ -e "$BF/register" ] || { echo "[binfmt] FAIL: binfmt_misc unavailable (needs --privileged)"; exit 1; }

# Already ours and enabled? Then this is a no-op -- the common case on every `up`
# after the first.
if [ -e "$BF/FEX-x86_64" ] && head -1 "$BF/FEX-x86_64" | grep -q enabled; then
    echo "[binfmt] FEX-x86_64 already registered and enabled"
else
    # Copy magic+mask from the handler Docker Desktop ships rather than
    # transcribing 20 bytes by hand -- a single wrong nibble yields a handler that
    # either never matches or matches the wrong ELFs, and neither says so.
    if [ -e "$BF/x86_64" ]; then
        magic=$(awk '/^magic/{print $2}' "$BF/x86_64")
        mask=$(awk '/^mask/{print $2}'  "$BF/x86_64")
    else
        # Fall back to the canonical x86-64 ELF signature if no handler exists to
        # copy from (e.g. a plain Linux host that never had QEMU registered).
        magic=7f454c4602010100000000000000000002003e00
        mask=fffffffffffefe00fffffffffffffffffeffffff
    fi
    esc() { printf '%s' "$1" | sed 's/../\\x&/g'; }

    # flags POC, deliberately NOT POCF. The F (fix-binary) flag makes the kernel
    # open the interpreter ONCE at registration time and pin that fd -- so it would
    # resolve /usr/bin/FEX in THIS container, which is alpine and has no FEX.
    # Without F the kernel resolves the path at exec time in the mount namespace of
    # the process being executed, i.e. inside each target container, which is what
    # makes FEX-baked-into-the-image work at all.
    #
    # Consequence worth knowing: with POC, any amd64 image WITHOUT FEX baked in
    # fails to exec entirely, with "permission denied" and no further explanation.
    [ -e "$BF/FEX-x86_64" ] && printf -- '-1' > "$BF/FEX-x86_64" 2>/dev/null || true
    printf ':FEX-x86_64:M:0:%s:%s:/usr/bin/FEX:POC' "$(esc "$magic")" "$(esc "$mask")" > "$BF/register"
    echo "[binfmt] registered FEX-x86_64 (flags POC)"
fi

# Disable, not unregister, whatever else claims x86-64 (Docker Desktop ships
# qemu-x86_64). Two handlers cannot both own the magic, and which one wins is not
# something any config in this repo controls. `0` is reversible: `printf 1` puts
# Docker's QEMU back, which is the rollback if you want stock behaviour.
#
# This matters more than it sounds: under QEMU, SQL Server 2022 dies instantly
# with "qemu: uncaught target signal 11" (measured deterministic, exit 139),
# whereas under FEX it boots healthy. Leaving QEMU enabled is not a slower path,
# it is a broken one.
if [ -e "$BF/x86_64" ] && head -1 "$BF/x86_64" | grep -q '^enabled'; then
    printf '0' > "$BF/x86_64"
    echo "[binfmt] disabled the qemu-x86_64 handler (reversible: printf 1 > $BF/x86_64)"
fi

echo "[binfmt] x86-64 emulation is FEX. ok"
