# Running BC on Linux/arm64

Status: **investigation, nothing implemented.** This document records what is
actually in the way of running this stack on aarch64, measured rather than
assumed, so the work can be scoped without re-deriving the facts.

Two independent routes exist and they are not alternatives — they solve
different halves of the problem:

- **Route A — emulate.** Keep the amd64 images, run them under an x86-64
  userspace emulator on the arm64 host. Zero repo changes for BC itself.
  This is the only route that can ever work for the SQL container.
- **Route B — go native.** Build `bc-runner` for linux/arm64. Cheap for
  everything except `StartupHook`'s method-detour layer, which is x86-64
  machine code.

The honest summary: **BC's own binaries are not the obstacle.** `StartupHook`
and SQL Server are.

What measurement changed about that picture, versus what you would guess:

- **1034 of 1051 service-tier binaries are AnyCPU IL, none ReadyToRun.** A
  native arm64 NST is a real possibility, not a rewrite.
- **The arm64 method-detour primitive turned out to be *simpler* than the x64
  one** — .NET's arm64 precode loads its branch target from a data page, so a
  redirect is an 8-byte data write with no code emission and no icache
  maintenance. Demonstrated working on real arm64 .NET 8, 5/5.
- **The emulation line falls between the two containers, not where expected.**
  SQL Server — assumed to be the blocker, and listed as crashing in the
  published FEX compatibility notes — boots healthy under FEX in ~13 s and
  passes real DDL/DML/transaction checks. The **.NET runtime** is the one that
  breaks: `dotnet restore` failed 11 of 11 attempts across two independent
  environments with varied memory corruption, and contended atomics ran ~20×
  slower than native. FEX did handle the `StartupHook` patching trick correctly.

That inverts the intuitive plan twice over. Emulation looks like the cheap way
in because it needs no repo changes — and for SQL it genuinely is, which removes
the dependency everyone assumed was fatal. But the emulated NST is the part with
the unresolved correctness problem, and the native route's supposedly hard part
turned out to have a cheaper primitive than expected. **Both facts push the same
way: emulate SQL, go native for BC.**

## What Microsoft actually ships (measured)

Range-read of the BC 28.4.53241.53533 sandbox platform artifact
(`https://bcartifacts-…/sandbox/28.4.53241.53533/platform`, 1.41 GB, 6956
entries), PE-classifying all 1051 `.dll`/`.exe` files under
`ServiceTier/PFiles64/Microsoft Dynamics NAV/280/Service/`:

| Class | Count |
|---|---|
| IL-only, AnyCPU (machine `0x14c`), **not** ReadyToRun | 1034 |
| IL-only but COFF machine stamped `AMD64` (`0x8664`) | 6 |
| Native Windows x64 PEs | 11 |

Nothing in the service tier is ReadyToRun-precompiled, so there is no
AOT'd x64 code to trip over — the arm64 JIT would compile the same IL.

**The 11 native PEs are all Windows DLLs**, i.e. unloadable on Linux at *any*
architecture, and every one is already replaced or stubbed by this repo:

```
Microsoft.Data.SqlClient.SNI.dll        (Service/ + Admin/)  — unused on Linux (managed TDS path)
libSkiaSharp.dll                        (Service/ + Admin/)  — replaced by bundled libSkiaSharp.so
harfbuzz.dll                                                 — replaced by system libharfbuzz
grpc_csharp_ext.x64.dll                 (Service/, Admin/, SideServices/)
sqlserverspatial160.dll                 (SideServices/x64/)
Microsoft.DiaSymReader.Native.amd64.dll (SideServices/)
Microsoft.Dynamics.Nav.Server.exe                            — Windows apphost; entrypoint runs `dotnet …Server.dll`
```

**The 6 AMD64-stamped managed assemblies are the one real BC-side risk:**

```
Microsoft.BusinessCentral.AI.Abstractions.dll
Microsoft.BusinessCentral.CopilotService.AgentService.Client.dll
Microsoft.BusinessCentral.CopilotService.Orchestrator.Client.dll
Microsoft.BusinessCentral.CopilotService.SkillEngine.Client.dll
Microsoft.BusinessCentral.NodeAgent.Models.dll
Microsoft.BusinessCentral.ServiceFabric.dll
```

These are `ILONLY` with no `32BITREQUIRED`, but the COFF machine word says
AMD64 — the equivalent of `/platform:x64`. An arm64 CLR cannot honour that
declaration and raises `BadImageFormatException` on load. Whether that matters
depends entirely on whether the Linux boot path touches them; verify
empirically before doing anything. If it does, the fix is small and fits the
existing patch pipeline: rewrite the 2-byte machine field to `0xAA64` (or
`0x14c`) in the Step-2 patch stage, exactly where `Mono.Cecil.dll` and
`TestPageClient.dll` are already rewritten.

## Route B: native arm64 — the cheap part

All verified available for arm64:

| Item | Location | Note |
|---|---|---|
| `--platform=linux/amd64` (both stages) | `src/Dockerfile:2`, `:104` | drop, or parameterize |
| `platform: linux/amd64` | `docker-compose.yml:66` | drop |
| .NET 8 / 10 SDK + aspnet base images | `src/Dockerfile` | already multi-arch on mcr |
| `dotnet-install.sh` | `src/Dockerfile:18`, `:130` | detects arm64 |
| `libSkiaSharp.so` | `src/Dockerfile:69-75` | `runtimes/linux-arm64/native/` exists in **both** pinned versions (2.88.9, 3.119.0) — verified against the nupkgs |
| `mssql-tools18` / `msodbcsql18` | `src/Dockerfile:118-120` | arm64 debs published in `packages.microsoft.com/debian/12/prod` (18.6.2.1 as of 2026-08) |
| `libwin32_stubs.so` | `src/StartupHook/kernel32_stubs.c` | plain C, no asm — recompiles as-is |
| harfbuzz symlink | `scripts/entrypoint.sh:515` | hardcoded `/usr/lib/x86_64-linux-gnu/` → resolve via `ldconfig -p` rather than swapping in another hardcoded triplet |
| ~~`reporting-service-stub`~~ | `stubs/` | **nothing to do.** The committed x86-64 ELF is `COPY`'d to `/bc/stubs/` (`src/Dockerfile:163-165`) and **never referenced at runtime** — `grep -rn /bc/stubs scripts/ src/ tools/` matches only those COPY lines. The stub BC actually gets is written inline by the entrypoint at `:1213` and is `#!/bin/sh exec sleep infinity`, i.e. architecture-neutral. Verified 2026-08-12; the three committed files are dead weight on every architecture |
| `dotnet-trace` | `scripts/entrypoint.sh:1160` | `aka.ms/dotnet-trace/linux-x64` → `linux-arm64` |
| **AL compile step** | `.github/workflows/bc-test-from-source.yml:700-767` and the two copies of it | x64-only today; needs a package swap — see below |

Everything Cecil-based — `MergeNetstandard`, `PatchNclTestPage`, the on-disk IL
rewrites — is architecture-neutral and needs no work. So are all four Microsoft
analyzers (`CodeCop`, `UICop`, `AppSourceCop`, `PerTenantExtensionCop`) and
`Analyzers.Common`: verified AnyCPU ILONLY in every package variant.

### AL compilation needs a package swap

The compile step resolves and unpacks
`Microsoft.Dynamics.BusinessCentral.Development.Tools.**Linux**`
(`scripts/resolve-al-tool-version.py:57-58`) and invokes the `alc` binary out of
it. That binary is a **linux-x64 ELF** (`e_machine=0x3e`) shipping a
self-contained x64 runtime — 230 ReadyToRun framework assemblies stamped AMD64,
14 x86-64 `.so` files, and `includedFrameworks` in `alc.runtimeconfig.json`. The
`.nuspec` declares no RuntimeIdentifier and there are no `runtimes/<rid>/`
folders, so NuGet cannot select an arm64 asset: none exists. Microsoft ships no
arm64 `alc` for Linux at all — nor for macOS (the `.Osx` package is x86_64
Mach-O with no arm64 slice), though the `.Altpgen` sibling *does* carry
`win-arm64` natives, so the family is not arm64-blind on principle. The AL
language server in the VS Code extension (`bin/linux`, 18 ELFs) is likewise
x86-64 only.

**The compiler itself is architecture-neutral, though.** The cross-platform
package this repo *already* installs for the altool test runner
(`Microsoft.Dynamics.BusinessCentral.Development.Tools`, no `.Linux` suffix,
`bc-test-from-source.yml:794`) ships the same compiler as pure AnyCPU IL under
`tools/net8.0/any/` + `tools/net10.0/any/`: zero `.so`/`.dylib`, all 127 DLLs
`0x14c` ILONLY, a framework-dependent `runtimeconfig`, and
`DotnetToolSettings.xml` declaring `<Command Name="al" Runner="dotnet"/>` with
no RID. `alc.dll` is loaded **in-process as a managed library** (per
`altool.deps.json`), not shelled out to a native binary, and 18.x exposes a
`compile` command.

So the fix is to route the compile step through `al compile` (or
`dotnet <store>/tools/net10.0/any/alc.dll`) from the cross-platform package.
That also collapses two packages into one. Unverified: flag parity between
`al compile` and raw `alc` for what the workflow passes (`/project:`,
`/packagecachepath:`, `/analyzer:`, `/ruleset:`, `/enableexternalrulesets`,
`/preprocessorsymbols`), and whether 17.x's `compile` matches 18.x's.

Worth noting for scoping: `.app` output is IL and metadata with no architecture
of its own, and server-side compilation inside the NST is IL too. So an amd64 CI
leg can produce apps that an arm64 BC publishes and runs — the compile step is
detachable from the arm64 question if the swap turns out to be awkward.

## Route B: the hard part — `StartupHook`'s JMP hooks

`ApplyJmpHook` is called 30× in `src/StartupHook/StartupHook.cs` and 6× in
`src/WebClientHook/WebClientHook.cs`. The mechanism is x86-64 specific in three
separate ways, all in `StartupHook.cs:3274-3450`:

1. **`WriteJmp` emits x86-64.** `FF 25 00000000` + 8-byte absolute address (14
   bytes). The arm64 equivalent is a 16-byte veneer using the ABI-reserved
   scratch register X16 — the same shape a linker emits for a range-extension
   thunk:

   ```
   58000050   LDR  X16, #8     ; literal is the 8 bytes following BR
   D61F0200   BR   X16
   <8-byte absolute target>
   ```

2. **Precode decoding is x64-format.** `ApplyJmpHook:3316-3341` recognizes the
   .NET x64 FixupPrecode (`49 BA <MethodDesc> FF 25 <disp32>`), StubPrecode
   (`FF 25 <disp32>`) and `E9 <rel32>` layouts to locate the JIT-compiled code
   behind the entry point. arm64 CoreCLR uses entirely different precode
   sequences; that block and `IsAlreadyJmpHooked`'s `FF 25 00 00 00 00`
   signature test both need arm64 branches, for **both** .NET 8 and .NET 10
   (the repo runs both, and the precode design changed between them).

3. **Instruction-cache maintenance is mandatory on arm64.** x86-64 keeps I- and
   D-cache coherent; arm64 does not. After writing the veneer you must issue
   the clean/invalidate sequence (`DC CVAU` / `DSB ISH` / `IC IVAU` / `DSB ISH`
   / `ISB`), most easily via a `__builtin___clear_cache` helper added to the
   existing `libwin32_stubs.so`. Omitting it produces nondeterministic
   "sometimes the unpatched code still runs" behaviour — the failure mode most
   likely to burn a day.

### CORRECTION (2026-08-12): the literal-slot primitive is NOT sufficient on its own

Two measurements taken after the section below was written, both of which cut
against it. Read them first.

**1. Every hook needs the compiled-code write.** Grepping four real boot logs for
`Patched … (code)` — the second-phase write `ApplyJmpHook` performs after
patching the precode entry — shows **21 of 21 hooks that log take it, identically
on every boot.** Not a subset: all of them. So a slot-only arm64 port would miss
every hook, because `ApplyJmpHook` calls `PrepareMethod` on the original first,
which backpatches the precode to freshly compiled code that later callers bind
to directly.

**2. Patching the pristine precode instead (skipping `PrepareMethod`) is
catastrophic, not clever.** Tried on real arm64 .NET 8: SIGSEGV 5/5. The reason
is the layout — a not-yet-JITted method's entry is a *temporary entry point*
whose first cell holds the address of its own fixup body, and the 8-word window
around it spans the *neighbouring* method's precode:

```
+0x00  5802000B  LDR X11,[pc+16384]   → cell holds entry+8 (indirection, NOT the target)
+0x04  D61F0160  BR  X11
+0x08  5802000C  LDR X12,[pc+16384]   → MethodDesc (secret param)
+0x0c  5802002B  LDR X11,[pc+16388]   → the actual target cell
+0x10  D61F0160  BR  X11
+0x14  D503201F  NOP
+0x18  5802000B  LDR X11,…            ← the NEXT method's precode starts here
```

Patch that cell while the method is un-JITted and you overwrite the sentinel
that routes to the prestub; scan for "the last BR" in an 8-word window and you
patch the *next method's* target (the stride is 24 bytes). Both crash.

**The authoritative layout, refusal rules and a reference implementation are now
in [docs/ARM64-PRECODE.md](docs/ARM64-PRECODE.md)**, read from CoreCLR sources
rather than inferred. Two corrections to the paragraph above: the cell found from
the first `LDR` *is* the right one (`Target` is loaded by `w0` in both precode
forms) — the bug was patching it while it still held the un-JITted `entry+8`
sentinel instead of refusing that value; and .NET 10 adds a `dmb ishld` to the
FixupPrecode, so any decoder keyed on byte patterns or the `Precode::Type`
constants breaks there. This is the same class of hazard the repo already documented
at `KNOWN-LIMITATIONS.md:171-179` — hooking a shared not-yet-JITted stub
"hijacked every OTHER method resolving through the same shared stub".

**Consequence for Track 2b:** the arm64 port needs either a correct two-step
walk (follow the temporary-entry cell to the fixup body, then decode *its*
target cell) or the veneer-over-compiled-code path, with all the CMODX and
I-cache consequences that implies. It is not the 8-byte-write freebie the
section below implies. Three successive hand-written decoders were wrong here
before this was understood, which is itself the honest measure of the risk: the
authoritative layout must come from CoreCLR's arm64 sources, not from reading
bytes and inferring.

### Measured: the arm64 port is easier than (1)-(3) suggest

Running the same `ApplyJmpHook` reproduction on native arm64 .NET 8.0.424 dumped
the real precode, and it is friendlier than the x64 one. Entry bytes:

```
0B 00 02 58   LDR X11, [pc+16384]     ; literal lives in a data page 16 KB ahead
60 01 1F D6   BR  X11
0C 00 02 58   LDR X12, [pc+16384]     ; (second form: X12 = MethodDesc, then X11 = target)
2B 00 02 58   LDR X11, [pc+16388]
```

The precode does not *contain* the target — it **loads it from a data page**. So
redirecting a method on arm64 is an 8-byte **data** write into the literal slot
at `entry + imm19*4`: no instruction encoding, no veneer, no icache
maintenance, no W^X interaction. Verified end to end — patch the slot with the
replacement's function pointer, call the method, get `REPLACEMENT` — 5/5 clean
runs, exit 0. Sketch:

```csharp
uint w0 = (uint)Marshal.ReadInt32(fp, 0), w1 = (uint)Marshal.ReadInt32(fp, 4);
if ((w0 >> 24) != 0x58 || (w1 & 0xFFFFFC1F) != 0xD61F0000) { /* not LDR+BR */ }
int imm19 = (int)((w0 >> 5) & 0x7FFFF);
if ((imm19 & (1 << 18)) != 0) imm19 -= 1 << 19;        // sign-extend
IntPtr slot = fp + imm19 * 4;                          // holds the BR target
// mprotect ONLY the pages the 8 bytes span, PROT_READ|PROT_WRITE, write, restore.
```

One trap found the hard way: reuse the x64 `WriteJmp` page arithmetic here and
the process takes a `SIGSEGV` later. `WriteJmp` pads the region by a whole extra
page, which is harmless on x64 because it *adds* `PROT_EXEC` — on the data-page
path it strips exec from whatever code page follows. Round the span to just the
pages containing the slot.

Two caveats before treating the hook port as cheap:

- This redirects calls that go **through** the precode. Callers already
  backpatched to call the compiled code directly bypass it — which is exactly
  why the x64 path patches the compiled code too. That second half still needs a
  real arm64 veneer, so items (1)-(3) do not disappear; they stop being the
  *only* option.
- `GetFunctionPointer()` returned a precode entry here, but a hot method's entry
  can be backpatched to the compiled code directly, so both forms must be
  recognized — the same shape of problem the x64 code already handles with its
  three-way precode sniffing.

### Why the data-slot write is the *architecturally* correct choice, not just the tidier one

The 16-byte veneer is not merely inconvenient on arm64 — writing it over code
another thread might be executing is **CONSTRAINED UNPREDICTABLE**. Arm ARM
DDI 0487 §B2.2.5 (concurrent modification and execution) guarantees tear-free
modify-while-executing only for a **single naturally-aligned 4-byte store**, and
only when both old and new instruction come from a restricted set — `B`,
`B.cond`, `BL`, `BRK`, `CBNZ`, `CBZ`, `HVC`, `ISB`, `NOP`, `SMC`, `SVC`, `TBNZ`,
`TBZ`, `UDF`. Our veneer is two words, and neither `LDR (literal)` nor `BR` is in
that set. On x64 a ≤8-byte patch can at least be made atomic with one locked
store; on arm64 there is no equivalent for a 16-byte sequence.

Corroboration, since the ARM ARM itself is hard to cite verbatim: the Linux
kernel's own patcher (`arch/arm64/kernel/patching.c`) routes **multi-instruction**
patching through `stop_machine_cpuslocked()` with every other CPU parked and then
executing `isb()`, and Arm's own write-up notes that `ISB` is *not* broadcast to
other cores. No shipping .NET hooking library handles this;
MonoMod's `LinuxSystem.PatchData` carries a literal
`// TODO: should this be thread-safe? It definitely is not right now.`

The literal-slot write sidesteps all of it: a single naturally-aligned 8-byte
store to a **non-executable** page. That is precisely what CoreCLR itself does —
`precode.h` uses `InterlockedCompareExchangeT<PCODE>(&pData->Target, …)` and
comments that no `FlushInstructionCache` is needed *because* the store is
interlocked. Worth matching that exactly and using `Interlocked.Exchange` on the
slot rather than a plain `Marshal.WriteIntPtr`.

So the policy should be: **data-slot write wherever it suffices; veneer only at
startup, before the method is hot, and never retarget a live veneer twice.**
`StartupHook` already installs everything during initialization, which is the
regime where a veneer is defensible.

If a veneer is unavoidable, three refinements from the survey:

- **Keep X16.** MonoMod.Core uses X9 and legacy MonoMod used X15; both sit inside
  ranges CoreCLR uses for stub plumbing (x11 VSD cell, x12
  `REG_SECRET_STUB_PARAM`, x15 `REG_PINVOKE_COOKIE_PARAM`, x18 platform —
  never touch). X16/X17 (IP0/IP1) are the only registers the ABI designates for
  veneers, and are what CoreCLR's own `emitJump` uses.
- **Short methods are a worse hazard than on x64.** The minimum arm64 jitted
  method is a single `ret` — 4 bytes, against ~10-14 on x64 — and
  `CODE_SIZE_ALIGN` is 8 rather than 16, so there is less incidental slack to
  overrun into. Get the real code size and refuse below 16 bytes. The
  alternative is a **branch island**: allocate a veneer within ±128 MB and patch
  a single 4-byte `B imm26` (`0x14000000 | ((offset>>2) & 0x03FFFFFF)`), which is
  *also* the only CMODX-safe patch, since `B` is in the restricted set.
- **BTI is a non-issue today** — no `PROT_BTI` or `bti` anywhere in CoreCLR's
  Unix mapping code, and `dotnet/designs` lists BTI on Linux as future work
  (dotnet/runtime#40100). If you want to be immune to a future runtime enabling
  it for free, use `RET X16` (`0xD65F0200`) instead of `BR X16`: `RET` is not a
  BTI-guarded indirect branch, control flow is identical, and the veneer stays
  16 bytes.

**Do not crib the icache handling from MonoMod.Core.** Its Linux path has a
comment saying it flushes the instruction cache and then does not — no
`clear_cache`/`isb`/`dsb`/`ivau` anywhere in its Linux or shared code. It
survives because most aarch64 parts set `CTR_EL0.IDC`/`DIC` and because the write
usually precedes the first fetch. Legacy MonoMod.Common did it correctly, and so
does its macOS path (`sys_icache_invalidate`). Everyone who gets it right —
CoreCLR, Frida, funchook, shadowhook — routes through
`__builtin___clear_cache`, which is the `bc_clear_icache` helper suggested above.

Useful context for scoping: **there is no mature, CI-proven third-party arm64
detour path for CoreCLR on Linux.** Harmony gained arm64 only in 2.4.0 /
MonoMod.Core 1.3.0 (both 2025-08-17), Harmony's CI has no dotnet-on-arm64 job at
all, and PR #241's own runs reported 39-43 unique failures including on
`ubuntu-24.04-arm`. MonoMod.Core also has **no .NET 7+ `StubPrecode` pattern** —
only `FixupPrecode`, its .NET 10 `dmb ishld` variant, and call-counting stubs —
so the StubPrecode arm of any decoder we write is genuinely new code, not a
reimplementation. Writing our own here is not reinventing a solved wheel.

Also set `DOTNET_EnableWriteXorExecute=0` next to the existing
`DOTNET_TieredCompilation=0` (`scripts/entrypoint.sh:1150`). It happens to work
on x64 today; W^X double-mapping is not something to gamble on when adding a
second architecture. BTI landing pads may also be required if CoreCLR maps JIT
code `PROT_BTI` on Linux arm64 — verify before assuming.

### The alternative worth weighing

This repo already rewrites BC DLLs on disk with Cecil during Step 2. Moving
these detours from *runtime* JMP patching to *build-time* IL body replacement
(swap the method body for a `call` into a helper assembly) would be
architecture-independent by construction, and would also delete the class of
crash documented in the `IsAlreadyJmpHooked` comment — the .NET 10
`PrepareMethod`-on-an-already-patched-entry segfault. It is more work than
porting the veneer. It is also the version that does not need doing a third
time.

## Read this before running an emulated NST: core dumps will take your machine down

Not a theory. This happened on 2026-08-12 and it cost a laptop reboot.

FEX reserves a very large virtual address space to emulate x86-64 —
`total-vm: 35 GB` for the NST process. When an emulated process faults, the
kernel hands the core to whatever `/proc/sys/kernel/core_pattern` points at. On
Ubuntu that is `apport`, which tried to process the dump and reached **17.9 GB,
then 19.6 GB, then 19.7 GB resident**, invoking `global_oom` three times on a
30 GB machine and killing the desktop. The leftover evidence was a 565 MB
`/var/crash/_usr_bin_FEX.0.crash`.

Two consequences, both now baked into the generated overlay:

```yaml
ulimits:
  core: 0        # no core dump → apport is never invoked
mem_limit: 16g   # a runaway NST kills its own container, not the host
```

And do **not** enable `DOTNET_DbgEnableMiniDump` with `DbgMiniDumpType=4` on an
emulated NST for the same reason — a full managed dump of a 35 GB address space
is the same trap wearing a different hat. If you need a stack from an emulated
crash, get it from the managed exception (see below) rather than from a dump.

## The actual blocker: SQL Server

There is no arm64 build of SQL Server, and Microsoft states plainly that
emulation and translation layers (Rosetta 2, Prism, QEMU) are neither tested
nor supported for the container images. Options, best to worst:

1. **External x86-64 SQL host.** `SQL_SERVER` is already an env var
   (`scripts/entrypoint.sh:40`, `docker-compose.yml:152`) — no code change at
   all. Caveat: the entrypoint imports the license via `OPENROWSET BULK`, which
   reads from *SQL's* filesystem, so a remote server needs the license file
   reachable on its side.
2. **Mixed-architecture compose.** `bc` native arm64, `sql` pinned
   `platform: linux/amd64` under emulation. Compose supports per-service
   `platform`, so this is a one-line overlay in the shape of
   `docker-compose.macos.yml`. Whether it actually runs is the open question —
   see below.
3. **Azure SQL Edge.** The only native-arm64 Microsoft engine, but retired
   (2025) and feature-reduced — notably no Full-Text Search, which this repo
   already documents as required for `OptimizeForTextSearch`
   (KNOWN-LIMITATIONS.md, issue #20).

## Route A: FEX-Emu

FEX-Emu is a usermode x86-64 JIT for arm64 Linux and is substantially faster
than qemu-user. Facts established against the actual packages, because two of
them contradict the common advice:

**It is packaged for Ubuntu 26.04 arm64.** `ppa:fex-emu/fex` has a `resolute`
suite; build `2608~1-3~r` ships `fex-emu-armv8.0` / `-armv8.2` / `-armv8.4`
plus `fex-emu-binfmt32` / `fex-emu-binfmt64`. On a CPU advertising `atomics`
and `uscat` (LSE + LSE2 — e.g. Qualcomm Oryon), the `armv8.4` build is the
right one; the microarch level directly determines how expensive FEX's x86
store-ordering (TSO) emulation is.

**binfmt registration is host-kernel state, not image state.** The package
installs:

```
:FEX-x86_64:M:0:\x7fELF\x02\x01\x01…\x3e\x00:…:/usr/bin/FEX:POCF
```

`F` (fix-binary) means the kernel opens the interpreter at registration time,
so `/usr/bin/FEX` need not exist inside the container. This is why the
emulator does not belong in `src/Dockerfile` — the registration has to happen
on the host either way.

**But `/usr/bin/FEX` in this build is dynamically linked, not static-pie.**
Verified from the deb:

```
usr/bin/FEX: ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked,
             interpreter /lib/ld-linux-aarch64.so.1
DT_NEEDED:   libstdc++.so.6, libm.so.6, libgcc_s.so.1, libc.so.6
```

The `F` flag pins the interpreter *executable* — it does nothing for the
interpreter's shared libraries. Inside an amd64 container rootfs there is no
aarch64 loader and no aarch64 libc, so FEX cannot start. This is the concrete
gotcha behind projects that use an OCI pre-create hook to mount FEX into
foreign-arch containers.

The mount set is small and, usefully, **collision-free** — aarch64 and x86-64
paths do not overlap in a Debian-derived rootfs:

```
/usr/bin/FEX, /usr/bin/FEXServer          → same paths, read-only
/lib/ld-linux-aarch64.so.1                (amd64 uses /lib64/ld-linux-x86-64.so.2)
/usr/lib/aarch64-linux-gnu/{libstdc++.so.6,libm.so.6,libgcc_s.so.1,libc.so.6}
                                          (amd64 libs live in /usr/lib/x86_64-linux-gnu/)
```

So either bind-mount those from the host via an arm64 compose overlay, or —
the self-contained variant of "put FEX in the image" that does work — `curl`
the arm64 debs at build time and `dpkg-deb -x` them into the amd64 image
(~10 MB, at the cost of pinning a FEX version in the Dockerfile). Either way
the host still needs the binfmt entry.

Also required inside the container: `FEX_ROOTFS=/`. On an aarch64 host FEX
normally demands an x86-64 rootfs image, but an amd64 container's own `/` *is*
one, which sidesteps the squashfs/EROFS rootfs machinery entirely.

### SQL Server DOES run under FEX (measured 2026-08-12) — the published reports are wrong, or stale

This was expected to be the blocker and it is not. The FEX-on-podman project's
compatibility table lists MSSQL Server as crashing under FEX, and Microsoft
states that emulation is untested and unsupported. On this box it simply works:

```
docker compose -f docker-compose.yml -f docker-compose.arm64.yml up -d sql
→ Up 13 seconds (healthy);  sqlcmd answered ~10s after start
```

Confirmed genuinely emulated, not an arm64 image sneaking in: `uname -m` inside
the container is `x86_64`, `/opt/mssql/bin/sqlservr` is an ELF, and `@@VERSION`
reports **SQL Server 2022 (RTM-CU26) 16.0.4265.3 (X64) … on Linux (Ubuntu
22.04.5 LTS) \<X64\>**.

Confirmed functional, not merely listening:

| check | result |
|---|---|
| `CREATE DATABASE` / `CREATE TABLE` / `CREATE INDEX` | ok |
| 20,000-row `INSERT … GENERATE_SERIES` | ok |
| `SUM(n)` over the inserted rows | 300015000.0000 — arithmetically exact |
| `COUNT(*) WHERE v LIKE 'row1%'` | 11111 — exact (1+10+100+1000+10000) |
| `BEGIN TRAN` / `DELETE` / `ROLLBACK` | 0 rows then 20000 rows back |
| `SERVERPROPERTY('Collation')` | `SQL_Latin1_General_CP1_CI_AS` |

Note this is **CU26**, well past the CU18 that `docker-compose.macos.yml` pins
away from because it crashes under Rosetta 2. FEX is handling something here
that Rosetta does not.

Two caveats on how far to carry this: it is one box (Qualcomm Oryon, 4 KB pages,
FEX 2608 armv8.4), and "boots and serves a functional workload" is not the same
as "survives a BC demo-database restore plus a full test sweep". But the
go/no-go answer is **go**, and the plan below should stop treating SQL as the
thing most likely to sink the project.

### Measured on a Qualcomm Oryon / Ubuntu 26.04 box, FEX 2608 armv8.4

Run unprivileged, without binfmt registration: FEX unpacked from the deb, a
hand-built minimal amd64 guest rootfs (Ubuntu 24.04 libc/libstdc++/zlib), the
.NET 8.0.424 SDK for linux-x64 inside it, and the same SDK for linux-arm64
natively for comparison. `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` throughout.

**Basic execution works.** A static x86-64 busybox runs. `dotnet --version`
under FEX prints `8.0.424`.

**Compute and correctness are fine; contended atomics are not.** The same
AnyCPU IL benchmark DLL (built once with the arm64 SDK, run under both
runtimes), 5 runs each, zero failures, identical checksums, and the concurrency
phase — 12 threads racing on `Lazy<T>` + `ConcurrentDictionary` with results
verified — reported no nulls and no mismatches under emulation:

| phase | native arm64 | FEX x86-64 | ratio |
|---|---|---|---|
| scalar integer loop | 42 ms | 80 ms | **1.9×** |
| StringBuilder + Split | 39 ms | 122 ms | **3.1×** |
| 12-thread contended atomics | 27 ms | 534 ms | **~20×** |

That ~20× on the contended path is the number that matters for an NST, which is
lock- and atomic-heavy by nature. It is the cost of emulating x86 store
ordering on a CPU with no hardware TSO mode.

**But MSBuild does not survive it: 8 of 8 `dotnet restore` runs failed**, every
one in a *different* place — `AccessViolationException` in `Lazy<T>.CreateValue`,
`NullReferenceException` in `Regex.Match.Reset`, `MSB4248` ("ValueFactory
attempted to access the Value property of this instance" — a torn `Lazy<T>`),
and four hard `SIGABRT`/`SIGSEGV` core dumps. The identical restore natively on
arm64 takes 33 ms and never fails, including with `--force`.

Three things rule out the boring explanations:

- **Not authentication or a stalled prompt.** No log contains any of
  `NU1301`/`NU1101`/`401`/`unauthorized`/`credential`/`login`/`interactive`.
  The failures are crashes with exit 1/134/139, not hangs.
- **Not the network.** The project has no `PackageReference`; the native restore
  completes in 34 ms with the HTTP cache disabled.
- **Not a missing rootfs dependency.** Those fail deterministically at the same
  point. These fail in a different place every run, and every symptom converges
  on `Lazy<T>` state in shared-generic (`System.__Canon`) code.

### CORRECTION: those failures were the *default* runtime settings, not BC's

The restore failures above are real but **they do not describe this repo's
configuration**, and the earlier version of this document was wrong to imply
they did. Every one of those runs used .NET's default runtime settings.
`scripts/entrypoint.sh:1146,1150` sets `DOTNET_gcServer=1` and
`DOTNET_TieredCompilation=0`, and with those the same test passes. Four
configurations in Microsoft's official amd64 SDK image, 3 runs each:

| config | result |
|---|---|
| `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`, runtime defaults | 0/3 — `NullReferenceException` |
| invariant off, runtime defaults | 0/3 — `AccessViolationException` ×3 |
| invariant on, **`gcServer=1` + `TieredCompilation=0`** | **3/3 pass** |
| invariant off, **`gcServer=1` + `TieredCompilation=0`** | **3/3 pass** |

Globalization was a red herring (it was a variable the test rig introduced and
the BC container does not set). The runtime settings are the whole difference,
and BC already runs in the passing configuration.

The likely mechanism, and it is worth understanding rather than just noting:
**tiered compilation rewrites JIT'd code at runtime** — call-counting stubs,
tier-1 recompilation, entry-point backpatching — which is precisely the
self-modifying-code pattern an emulator has to detect and invalidate
translations for. Turn it off and code is compiled once and never rewritten.
CLAUDE.md already records `DOTNET_TieredCompilation=0` as load-bearing on x64
for a related reason (Tier-1 recompilation silently undoing JMP hooks); under
emulation it appears to matter for a second, independent reason.

So the useful framing is not "the .NET runtime breaks under FEX" but: **stock
.NET settings break under FEX; the settings this repo already uses do not.**

Knobs tried: `FEX_PARANOIDTSO=1` does not fix it. `DOTNET_TieredCompilation=0`
(which this repo already sets, and which was the most promising hypothesis since
tiering rewrites JIT'd code) does not fix it either — 0/3, all
`NullReferenceException`. `FEX_SMCCHECKS=full` never finished a single restore
inside 300 s, against ~40 s at the default setting, so it is not a usable
mitigation regardless of whether it would help.

The distinction is important: short, mostly tier-0 managed code is fine, while a
large, long-running, heavily re-JIT'd process is not. **The NST is much closer to
MSBuild than to the benchmark**, so "simple .NET works under FEX" should not be
read as "BC will work under FEX". This is consistent with the crash reports in
the FEX-on-podman table (Go crypto, esbuild, MSSQL).

**One genuinely good result: `StartupHook`'s patching mechanism survives FEX.**
A standalone reproduction of `ApplyJmpHook` — `PrepareMethod`, read the precode,
`mprotect`, write `FF 25` + absolute address over both the precode entry and the
compiled code, then call the method — took effect 3/3 under FEX, correctly
decoding a StubPrecode and returning `REPLACEMENT`. So FEX's self-modifying-code
detection handles the one trick this repo depends on most.

**Note what emulating `bc` actually buys.** BC is IL; a native arm64 `dotnet`
JITs it directly. Running the x86-64 `dotnet` under FEX means emulating a JIT
that emits x86-64 which FEX then re-translates to arm64. The *only* thing that
purchases is keeping `StartupHook`'s existing x86-64 JMP hooks working
unmodified. That is a legitimate reason — it is the entire hard part of Route B
— but it should be a deliberate choice, not an accident.

## Suggested order

1. **Do the cheap Route-B work.** The table above is all upside and independent
   of every open question.
2. **Prototype the arm64 detour** on the literal-slot primitive, against two or
   three of the simplest hooks (the `noop!` ones — `WatsonReporting.SendReport`,
   `NavOpenTaskPageAction.ShowForm`) before touching the 30-hook set. Keep
   `DOTNET_TieredCompilation=0`: CLAUDE.md already records that Tier-1
   recompilation silently undoes JMP hooks, and that hazard is unchanged on
   arm64.
3. ~~Run the SQL spike~~ — **done, and it passes.** `scripts/setup-arm64-host.sh`
   sets the host up and `docker-compose.arm64.yml` runs the sql service under
   FEX. No external SQL host needed, and no arm64 SQL build needed.
4. **Do not plan on emulating the NST.** 11 of 11 `dotnet restore` runs died
   under FEX across two environments. If you want to try anyway, that is the
   result to disprove first, and one clean run does not disprove it — the
   failures are nondeterministic.

The one-line version: **native for `bc`, emulated for `sql`.** Which is a better
position than this document started from, because the half that cannot be ported
is the half that emulates cleanly.

## Appendix: the host-side FEX spike, ready to run

`scripts/setup-arm64-host.sh` does all of this — installs docker + compose v2 and
FEX, registers the binfmt handler, writes `docker-compose.arm64.yml`, and then
verifies both that FEX runs a static x86-64 binary on the host and that it runs
inside an amd64 container with those mounts. `--check` reports without changing
anything. The manual steps below are what it automates, kept for reference.

Needs root (binfmt registration) and a container runtime — neither was available
where this document was written, so this part is unrun.

```bash
# 1. FEX from the PPA. Pick the microarch build matching the CPU:
#    grep Features /proc/cpuinfo → 'atomics' + 'uscat' means armv8.4 is right.
sudo add-apt-repository -y ppa:fex-emu/fex
sudo apt install -y fex-emu-armv8.4 fex-emu-binfmt64

# 2. Confirm the kernel picked it up (F flag = interpreter pinned at registration).
cat /proc/sys/fs/binfmt_misc/FEX-x86_64

# 3. FEX needs its aarch64 loader + 4 libs visible INSIDE the amd64 container.
#    None of these paths collide with x86-64 ones, so the mounts are safe.
cat > docker-compose.arm64.yml <<'YML'
services:
  sql:
    environment:
      FEX_ROOTFS: /
    volumes:
      - /usr/bin/FEX:/usr/bin/FEX:ro
      - /usr/bin/FEXServer:/usr/bin/FEXServer:ro
      - /lib/ld-linux-aarch64.so.1:/lib/ld-linux-aarch64.so.1:ro
      - /usr/lib/aarch64-linux-gnu/libstdc++.so.6:/usr/lib/aarch64-linux-gnu/libstdc++.so.6:ro
      - /usr/lib/aarch64-linux-gnu/libm.so.6:/usr/lib/aarch64-linux-gnu/libm.so.6:ro
      - /usr/lib/aarch64-linux-gnu/libgcc_s.so.1:/usr/lib/aarch64-linux-gnu/libgcc_s.so.1:ro
      - /usr/lib/aarch64-linux-gnu/libc.so.6:/usr/lib/aarch64-linux-gnu/libc.so.6:ro
YML

# 4. SQL FIRST — this is the go/no-go, and it is the cheap half of the test.
docker compose -f docker-compose.yml -f docker-compose.arm64.yml up -d sql
docker compose logs -f sql        # SQLPAL init is where it dies, if it dies
docker compose exec sql /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "$SA_PASSWORD" -C -No -Q "SELECT @@VERSION"
```

If step 4 works, extend the same overlay to the `bc` service and bring the whole
stack up. If it does not, SQL has to come from outside the box (`SQL_SERVER=…`)
regardless of which route BC itself takes.

## Open questions

Still open:

- Are any of the 6 AMD64-stamped assemblies on the Linux boot path? Needs a
  boot, so it needs the rest of the arm64 image first.
- ~~Does SQL Server survive FEX?~~ **Yes** — boots healthy in ~13s, passes
  DDL/DML/transaction checks (SQL 2022 CU26, verified emulated).
- The arm64 precode layout was read off .NET 8.0.424 only. **.NET 10 must be
  re-checked** — the repo runs both, and the precode design has changed across
  versions before.
- Whether the literal-slot patch is sufficient on its own, or whether call-site
  backpatching means the compiled-code veneer is still required for hot methods.
- Whether any of the 36 hook targets JITs to **under 16 bytes**, and whether any
  presents a `StubPrecode` rather than a `FixupPrecode`. Both need an
  on-hardware dump against real BC assemblies, so both are gated on the arm64
  image existing.
- The exact CMODX restricted-instruction set should be checked against a local
  DDI 0487 PDF before anything relies on it — the list has changed across
  revisions, and the copy here came from secondary sources.
- Whether `al compile` from the cross-platform package accepts the same flags
  the workflow passes to raw `alc`.

Answered, with evidence above:

- ~~Is the BC service tier architecture-neutral?~~ Yes — 1034/1051 AnyCPU IL,
  zero ReadyToRun; the 11 native PEs are Windows-only and already stubbed.
- ~~Is there an arm64 `libSkiaSharp.so` for both pinned SkiaSharp lines?~~ Yes.
- ~~Are `mssql-tools18` / `msodbcsql18` available for arm64?~~ Yes.
- ~~Does AL tooling work on arm64?~~ The `.Linux` package's `alc` is x64-only
  ELF and no arm64 build exists anywhere; the cross-platform package the repo
  already installs is AnyCPU IL and is the way out.
- ~~Do the analyzers carry native code?~~ No, all AnyCPU ILONLY.
- ~~Does FEX exist for Ubuntu 26.04 arm64, and can it work inside a container?~~
  Yes, and yes with a small collision-free mount set — but the interpreter is
  dynamically linked, so the `F` binfmt flag alone is not enough.
- ~~Does the `StartupHook` patching mechanism survive emulation?~~ Yes, 3/3.
- ~~Can a method be redirected on native arm64 without emitting code?~~ Yes —
  patch the precode's literal slot, 5/5. And it is the architecturally correct
  approach, not just the convenient one: it is a single aligned store to a
  non-executable page, which is what CoreCLR itself does.
- ~~Does CoreCLR map JIT code with `PROT_BTI` on Linux arm64?~~ No — not in the
  runtime's Unix mapping code, and BTI on Linux is still listed as future work
  in `dotnet/designs`. So no `BTI c` landing pad is needed today.
- ~~Is there an existing arm64 detour library to lean on?~~ Not usefully.
  Harmony/MonoMod gained arm64 in 2025-08 with no dotnet-on-arm64 CI, a
  known-missing `StubPrecode` pattern, and a Linux path whose icache flush is a
  comment rather than code.

## Sources

- FEX-Emu: <https://github.com/FEX-Emu/FEX>,
  <https://wiki.fex-emu.com/index.php/Development:Setting_up_FEX>
- FEX-on-podman compatibility notes: <https://github.com/tnk4on/podman-fex>
- SQL Server container support statement:
  <https://learn.microsoft.com/sql/linux/quickstart-install-connect-docker>
- Assembly platform targets and `BadImageFormatException`:
  <https://mihai-albert.com/2019/03/10/net-assembly-cross-bitness-loading/>
