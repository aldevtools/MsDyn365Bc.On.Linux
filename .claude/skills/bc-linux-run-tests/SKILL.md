---
name: bc-linux-run-tests
description: Start a local Business Central container with MsDyn365Bc.On.Linux (any BC version, e.g. 29), compile an AL app and its test app with the Linux AL compiler, publish them and run the AL tests with scripts/run-tests.sh. Use when asked to run AL tests against a real BC, "spin up a BC container", or reproduce a CI failure locally.
---

# Run AL tests on a local BC Linux container

Everything below was verified end to end on BC 29.0.54011.56465 in a cloud
sandbox (Ubuntu 24.04, Docker 29, no .NET preinstalled, all HTTPS through an
inspecting proxy). Steps marked **[sandbox only]** are not needed on a normal
machine or in a Codespace/devcontainer where `postCreateCommand` already does
the clone + `docker compose up -d --wait`.

Set once, reuse in every step:

```bash
BC=29.0.54011.56465          # full version, see step 2
WORK=$PWD/.bc-work           # scratch dir, keep out of git
BCL=$WORK/bc-linux           # clone of MsDyn365Bc.On.Linux (or the repo you are in)
```

## 1. Docker daemon [sandbox only]

The CLI is installed but the daemon is not running:

```bash
(dockerd > $WORK/dockerd.log 2>&1 &); sleep 8; docker info | grep 'Server Version'
```

## 2. Pin the full BC version

`BC_VERSION=29.0` did **not** resolve in the container ("Could not resolve
version 29.0 from .../indexes/w1.json"). Pin the full version. Newest public
build for a major:

```bash
curl -s https://bcartifacts-exdbf9fwegejdqak.b02.azurefd.net/sandbox/indexes/w1.json \
 | python3 -I -c "import sys,json;v=[x['Version'] for x in json.loads(sys.stdin.buffer.read().decode('utf-8-sig')) if x['Version'].startswith('29.')];print(v[-1])"
```

## 3. Start BC

```bash
git clone --depth 1 https://github.com/StefanMaron/MsDyn365Bc.On.Linux.git $BCL
cd $BCL
```

**[sandbox only]** The container does not trust the proxy CA, so artifact
downloads fail with `SSL certificate problem: self-signed certificate in
certificate chain`. Do not disable verification; mount the CA instead:

```bash
cat > docker-compose.override.yml <<'EOF'
services:
  bc:
    volumes:
      - /root/.ccr/ca-bundle.crt:/etc/ssl/certs/ccr-ca-bundle.crt:ro
    environment:
      SSL_CERT_FILE: /etc/ssl/certs/ccr-ca-bundle.crt
      CURL_CA_BUNDLE: /etc/ssl/certs/ccr-ca-bundle.crt
      REQUESTS_CA_BUNDLE: /etc/ssl/certs/ccr-ca-bundle.crt
EOF
```

Then:

```bash
BC_VERSION=$BC docker compose up -d
until docker compose logs bc 2>&1 | grep -q 'Ready for extensions'; do sleep 10; done
```

Cold start was about 290 s (NST ~120 s). After "Ready for extensions" the test
toolkit (Library Assert, Any, Test Runner, ...) is published.
`Business Foundation Test Libraries.app: HTTP 422` in the log was harmless
unless your tests depend on it.

Endpoints: dev `:7049/BC/dev`, OData `:7048/BC/ODataV4`, API `:7052`, web client
`:8080` (only with `BC_WEBCLIENT=1`). Login `BCRUNNER` / `Admin123!` (not `admin`).

## 4. AL compiler

Needs the .NET 8 SDK on the host. [sandbox only] install it without root:

```bash
curl -sSL https://dot.net/v1/dotnet-install.sh -o $WORK/dotnet-install.sh
bash $WORK/dotnet-install.sh --channel 8.0 --install-dir $WORK/dotnet
export DOTNET_ROOT=$WORK/dotnet PATH=$WORK/dotnet:$PATH
```

Install the compiler matching the BC major (AL major = BC major - 11):

```bash
cd $BCL && bash scripts/install-al-compiler.sh $BC     # prints AL_TOOL_DIR / AL_BIN_DIR
export PATH=/root/.al-bin:$PATH                         # AL_BIN_DIR from the output
```

For BC 29 this resolves to AL 18.1 and falls back to the framework-dependent
`alc.dll` in the base package; the script handles it. Runtime for BC 29 is
`"18.0"`, `"application"` is `"29.0.0.0"`.

## 5. Stage symbols from the artifacts volume

Symbols come from the artifacts the container already downloaded. The compose
project is named after the directory, so the volume is `bc-linux_bc-artifacts`:

```bash
ART=$(docker volume inspect bc-linux_bc-artifacts --format '{{.Mountpoint}}')
python3 -I $BCL/scripts/stage-symbols.py \
  --app-json app/app.json --app-json test/app.json \
  --artifact-dir "$ART" --out-dir symbols
for d in app test; do mkdir -p $d/.alpackages; cp symbols/*.app $d/.alpackages/; done
```

(`$ART` is root-owned under `/var/lib/docker`; run as root or via sudo.)

## 6. Compile, publish, test

Order matters: main app first, then copy its `.app` into the test app's
`.alpackages` so the dependency resolves.

```bash
AL compile /project:$PWD/app  /packagecachepath:$PWD/app/.alpackages  /out:$PWD/build/app.app
cp build/app.app test/.alpackages/
AL compile /project:$PWD/test /packagecachepath:$PWD/test/.alpackages /out:$PWD/build/test.app

cd $BCL && . scripts/publish-app.sh && bc_publish_app $OLDPWD/build/app.app
./scripts/run-tests.sh --app $OLDPWD/build/test.app --junit-output results.xml
```

`run-tests.sh` publishes the test app itself, discovers the test codeunits,
runs them over the WebSocket client and writes JUnit XML. Useful flags:
`--codeunit-range 71180500..71180599`, `--company <name>`, `--timeout <min>`.
Summarise failures by message rather than reading the log:

```bash
python3 -I - <<'EOF'
import xml.etree.ElementTree as ET, collections
c = collections.Counter()
for tc in ET.parse("results.xml").iter("testcase"):
    f = tc.find("failure")
    c["PASS" if f is None else (f.get("message") or "")[:150]] += 1
for k, v in c.most_common(): print(v, k)
EOF
```

## 7. Clean up

```bash
cd $BCL && docker compose down -v
```

## Compile errors seen and what they mean

| Error | Cause / fix |
|---|---|
| `AL0666 'Internal' is not available in runtime version '18.0'` | `"target": "Internal"` only works below runtime 11. Use `Cloud` (or `OnPrem`) for the BC build. |
| `AL0161 ... inaccessible due to its protection level` | Main app objects are `Access = Internal`. Add `internalsVisibleTo` with the test app's id/name/publisher to the main app's `app.json`. |
| `AL0185 Codeunit 'Assert' is missing` | Real BC calls it `Codeunit "Library Assert"` in namespace `System.TestLibraries.Utilities`; add that `using` and the dependency `dd0be2ea-f733-4d65-bb34-a28f4624fb14`. |
| `AL0185 Table 'Company' is missing` | System tables live in `System.Environment` etc.; add the `using`. |

## Test failures seen and what they mean

| Message | Cause / fix |
|---|---|
| `Sorry, the current permissions prevented the action` | Add `TestPermissions = Disabled;` to the test codeunits (or assign a permission set). |
| `Text optimized index ... Full-Text Search component is not installed` | Use the FTS SQL image: `BC_SQL_IMAGE=ghcr.io/stefanmaron/msdyn365bc.on.linux/mssql:2022-fts docker compose up -d`. |
| `The record in table X already exists` / `User Security ID ... is not valid` | The test inserts into a table that the CRONUS DB already fills, or into a system table (`User`, `NAV App Installed App`) that cannot be written on a real BC. The test was written for an emulator; it needs data isolation or a seam, not a retry. |
| `Unhandled UI: Confirm ...` / `Page 672` | Add `[ConfirmHandler]` / `[PageHandler]` procedures. |
| Alert/record counts higher than expected | Real demo data is present; assert on a filtered set. |
