## MacOS steps

* Podman needs to run in "rootful" mode. 

  `podman machine set --rootful`

* Enable Rosetta. Touching `enable-rosetta` alone is not enough: the VM then
  silently falls back to qemu-user emulation and `rosetta-activation` fails
  with "wrong fs type". Rosetta is only active when
  _~/.config/containers/containers.conf_ contains the following **before**
  `podman machine init` (remove and re-create an existing machine):
  ```
    [machine]
    provider = "applehv"
    rosetta = true
  ```

  `podman machine ssh 'sudo touch /etc/containers/enable-rosetta'`

  Verify: `podman machine inspect <name>` shows `"Rosetta": true`,
  `/proc/sys/fs/binfmt_misc/rosetta` exists inside the VM (`podman machine ssh`),
  and `podman run --rm --platform linux/amd64 alpine uname -m` prints `x86_64`.

* You will need at least 15G to run BC. 
  
  `podman machine set --memory 15000`

* You will need to install docker-compose, podman compose does not support "wait"

  `brew install docker-compose`

## Starting BC

Use the macOS overlay on top of the main compose file. It pins SQL Server
to 2022-CU17 (later 2022 CUs crash under Rosetta emulation) and runs the
SQL container as root (rootful podman mounts the data tmpfs root-owned,
which the image's non-root mssql user cannot write to). It also drops the
tmpfs `uid=`/`gid=` options of the base file, which podman rejects
(`unknown mount option "uid=10001"`):

```bash
docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d --wait
```

Everything else (ports, env vars like `BC_VERSION`/`BC_COUNTRY`, running
tests via `scripts/run-tests.sh`) works the same as on Linux.

