# arm64 battleplan

Companion to [ARM64.md](ARM64.md), which holds the measurements. This holds the
plan: every option, what would kill it, and in what order to spend effort.

**Proof of concept. The target box is disposable** (its only use is this PoC and
it gets wiped), so crashes and reboots are acceptable costs and no experiment
below is gated on host safety. `ulimits: core: 0` and `mem_limit` stay in the
overlay anyway — not for politeness, but because a run that OOMs the host
produces no data, and a run that survives its own SIGSEGV does.

## Objective and success criteria

Run this stack on an arm64 Linux host well enough to be *believable*. Three
tiers, and it matters which one we are aiming at:

| tier | definition | good enough for |
|---|---|---|
| **T1 boots** | NST reaches `Ready for extensions`, dev endpoint answers | demo, "it runs on ARM" |
| **T2 works** | publishes an extension and runs `extensions/smoke-test` green | development use |
| **T3 trustworthy** | full BCApps sweep at the same pass rate as x86-64, repeatably | CI, which is this project's actual product |

T3 is the bar that matters, and it is the bar the current emulated path fails —
not on speed, but on **nondeterministic runtime-state corruption**. A substrate
that corrupts memory under concurrency turns every future red test into "real
failure, or emulator?", which is worse than no CI. Any plan that reaches T1 and
stops has not solved the problem this repo exists to solve.

## FEX is load-bearing no matter which track wins

Worth stating plainly, because it reframes "native vs emulated" as a question of
*scope* rather than *either/or*. Two components have **no arm64 build in
existence**:

- **SQL Server.** No arm64 build, and Microsoft will not ship one. Options are
  emulate it, or put it on another machine.
- **`alc`, the AL compiler**, as this repo currently invokes it. The `.Linux`
  package ships a linux-x64 ELF with a bundled x64 runtime, and there is no
  arm64 build for Linux *or* macOS. (There is a way out — see Track 3c — but it
  is a code change, not a download.)

So the realistic end state is a **hybrid**, and the design question is how much
runs emulated. Notably the two mandatory-emulation workloads are the *good* case
for an emulator: SQL is native C++ that has already proven clean under FEX, and
`alc` is a short-lived batch process. The NST — long-lived, lock-heavy, heavily
concurrent — is the *bad* case, and is exactly where the corruption shows up.

## What is already established

From ARM64.md, all measured on this box (Oryon, Ubuntu 26.04, FEX 2608 armv8.4):

- 1034/1051 BC service-tier binaries are AnyCPU IL, zero ReadyToRun. A native
  arm64 NST is not a rewrite.
- SQL Server 2022 CU26 runs emulated: healthy in ~13 s, restores CRONUS in 7 s,
  passes DDL/DML/transaction/collation checks.
- The emulated NST reaches "NAV application mounted" + tenant connect, then
  dies. **The failure is nondeterministic** — two identical boots gave
  `EntryPointNotFoundException` @ `ConcurrentDictionary.TryGetValue`
  (SubscriberId 935) and `NullReferenceException`/`CustomAttributeFormatException`
  @ `Reflection.CustomAttribute.AddCustomAttributes` (SubscriberId 931).
- `DOTNET_gcConcurrent=0` converts a hard SIGSEGV into a managed exception. It
  does not fix anything; it changes which corruption survives to be observed.
- On a minimal `dotnet restore` repro: default GC 0/3, `gcServer=1` 2/3,
  `gcServer=1`+`TieredCompilation=0` 3/3, `TieredCompilation=0` alone 0/3.
- StartupHook's JMP detours *do* apply and fire correctly under FEX, and no
  hooked method appears on any failing stack. The detour layer is not the
  suspect.
- An arm64 detour primitive is proven *as far as it goes*: .NET arm64 precode is
  `LDR X11,[pc+16384]; BR X11`, so redirecting a precode-routed call is an 8-byte
  aligned data write — no code emission, no I-cache maintenance, no CMODX hazard,
  5/5 clean on real arm64 .NET 8. **But it is only half a hook.** Callers JITted
  after the target has stable native code bind directly and bypass the precode
  (`CEEInfo::getFunctionEntryPoint`), and 21 of 21 hooks take the compiled-code
  write on every x64 boot. The veneer — with its CMODX and I-cache obligations —
  is required, not a fallback. See docs/ARM64-PRECODE.md.

## Track 0 — Instrumentation and facts (do first, cheap, unblocks everything)

| # | spike | method | cost | kill/answer criteria |
|---|---|---|---|---|
| 0a | Is the NST failure deterministic? | 3-5 identical boots, record exception/frame/subscriber | ~10 min | **DONE — it moves.** Corruption confirmed |
| 0b | FEX knob matrix on the minimal repro | `dotnet restore` with **default** GC (known 0/3); one axis per run: `FEX_PARANOIDTSO=1`, `FEX_SMCCHECKS=full`, `FEX_MULTIBLOCK=0`, `FEX_TSOENABLED=1` | ~30 min | any knob → 3/3 identifies the mechanism and gives Track 1 a dial |
| 0c | Reduce to a minimal upstream repro | smallest program that corrupts under FEX; ideally no BC, no SDK | ~1 h | a filable FEX issue — worth having regardless of track |
| 0d | Does the corruption need >1 core? | rerun repro with `--cpuset-cpus 0` | ~10 min | single-core clean ⇒ memory-ordering, not codegen |

0d is cheap and sharply diagnostic: TSO emulation bugs vanish on one core;
codegen bugs do not.

## T1 REACHED (2026-08-12): the emulated NST boots and serves — bare-bones only

**`docker-compose.arm64-tso.yml` is the working recipe.** Measured on Qualcomm
Oryon / Ubuntu 26.04 / FEX 2608 armv8.4:

```
bc   Up (healthy)      Ready for extensions. Total startup: 57s
sql  Up (healthy)
GET :7049/BC/dev/metadata -> HTTP 200
{"runtimeVersion":"17.0","webApiVersion":"7.0","debuggerVersion":"7.0",
 "webEndpoint":"","extensionAllowedTargetLevel":"OnPrem"}
uname -m inside the container = x86_64, /usr/share/dotnet/dotnet is an ELF
```

Two settings, **both required** — neither works alone:

1. **`FEX_VECTORTSOENABLED=1` and/or `FEX_MEMCPYSETTSOENABLED=1`.** FEX applies
   x86 store ordering to ordinary loads/stores by default but **not** to vector
   accesses or memcpy/memset patterns. .NET uses 16-byte SIMD constantly for
   struct copies and `Span` operations, so those were free to reorder in ways x86
   forbids. Either knob alone sufficed in testing.
   **Do not add `FEX_HALFBARRIERTSOENABLED`** — it fails differently
   (`ArgumentException` in `Mono.Cecil.ModuleWriter.Write`).
2. **`BC_CLEAR_ALL_APPS=deps-only`.** With the full ~137-app set the boot instead
   dies in `PlatformMetadataProvider.LoadMetadata` during system-tenant load, so
   metadata/reflection volume still matters even with the ordering fix.

### Why this took so long to find

`FEX_TSOENABLED` — the knob whose name suggests it covers this — is **on by
default**, so testing it proved nothing, and testing `=0` only disabled what was
already working. The three knobs that actually mattered
(`VECTORTSOENABLED`, `MEMCPYSETTSOENABLED`, `HALFBARRIERTSOENABLED`) all default
**off** and were missed for hours. Worse, the single-core result
(`--cpuset-cpus 0`, still 0/3) was read as excluding memory ordering entirely.
That inference was wrong: uniprocessor coherence only excludes reordering
between concurrently *running* threads, while a partially-published 16-byte
vector store is still visible to another thread after a preemption — and the GC
reads everything.

### Honest limits of this result

- `deps-only` clears **all** published apps including Base Application, so this
  NST answers the dev endpoint but has **no business objects**. It demonstrates
  "BC's service tier runs on arm64", it is not a usable ERP.
- Stability beyond a single boot is unmeasured. The acceptance bar in this plan
  (30 sequential boots, then a BCApps sweep) has **not** been run.
- SQL Server under FEX aborted (`exit 134`) in two separate runs, including a
  synthetic 12-writer soak. It survived every successful BC boot, but it is not
  proven reliable under load.
- The remaining crash sites are still worth reporting upstream — see
  `docs/FEX-UPSTREAM-REPORT.md`.

## Track 1d CLOSED (2026-08-12): patching FEX ourselves is architectural, not plumbing

Assessed by cloning FEX, mapping the code, **building a candidate fix and measuring
it**. Verdict: weeks of JIT work, not a weekend. Full write-up in
[docs/FEX-FIX-FEASIBILITY.md](docs/FEX-FIX-FEASIBILITY.md).

**The feared blocker was not the blocker.** FEX *does* read guest `ucontext` edits
back on sigreturn — all 16 GPRs, XMM, EFLAGS and RIP — and it *can* resume at an
arbitrary guest RIP by bouncing through the dispatcher top
(`GuestFramesManagement.cpp:136-143`). So "FEX can't re-enter a translated block
mid-way" is false, and the plumbing fix we hoped for is unnecessary.

**The defect is on the capture side.** An async signal lands at an arbitrary host
PC part-way through translating one guest instruction.
`RestoreRIPFromHostPC` (`FEXCore/Source/Interface/Core/Core.cpp:139-173`, whose own
comment says *"as close as FEX can get"*) reconstructs the RIP of the *start* of
that instruction while the static register allocator already holds partially
applied results of it. The reported context therefore describes a machine state
that never existed — harmless to read, fatal to resume from, and catastrophic when
a moving GC scans those registers as roots.

**Upstream's own fix model is already in-tree — for Windows.** Interrupt only at
block entries via a JIT-emitted pending-interrupt check (`JIT.cpp:767`, gated at
`Core.cpp:356-364`); `Source/Windows/WOW64/Module.cpp:403` states *"Since
interrupts only happen at the start of blocks, the reconstructed state should be
entirely accurate."* On Linux that check is compiled out unless gdbserver is on.

**We ported it (~15 functional lines, env-gated) and it did not help:**
`repro compute 3000 12` scored 0/10 with the knob off and 0/8 with it on, while
tracing confirmed the mechanism fired (27 deferrals, 57 deliveries in one run).

**Why, in one table.** Classifying all 32 `SIGRTMIN` injections in a failing run by
where the host PC actually was:

| arrival site | count |
|---|---|
| JIT code (what a block-entry fix covers) | 11 (34%) |
| elsewhere in FEX host code | 14 (44%) |
| guest syscall | 4 |
| FEX dispatcher (own comment: "unsynchronized context") | 3 |

A block-entry gate covers at most a third, and **one bad suspension in thirty
corrupts the heap**. Making every delivery point precise spans the JIT, the
dispatcher and the syscall layer — which is exactly what the maintainer means by
"FEX isn't async signal safe".

Two operational notes worth keeping:

- **binfmt_misc's `F` flag pins the interpreter fd at registration time**, so
  bind-mounting a self-built FEX over `/usr/bin/FEX` silently changes nothing.
  Invoke the built binary explicitly (`/path/to/FEX /app/repro …`). This
  invalidated a whole measurement round before it was caught.
- Build deps, if anyone wants to try: `sudo apt install -y cmake ninja-build clang
  clang-tools lld python3 python3-setuptools git pkg-config libc6-dev`.
  `clang-tools` is mandatory (C++20 module scanning) and on 24.04 needs a
  `clang-scan-deps` symlink *before* first configure. A clean Release build is
  ~4 minutes in an `ubuntu:24.04` aarch64 container.
- **Do not offer the patch upstream** — FEX's `CONTRIBUTING.md` bans AI-generated
  code. The arrival-site table is the part with upstream value, and a human should
  re-derive it.

## Track 1 history: what was refuted before the fix was found

Eight hypotheses tested, all refuted. Recording them so nobody re-runs them.

| hypothesis | test | result |
|---|---|---|
| Misclassified hardware fault → bogus managed exception | read `MapWin32FaultToCOMPlusException`, `excep.cpp:3063` | **impossible** — no signal path yields `EntryPointNotFoundException`; only P/Invoke binding throws it, and with a *parameterized* message we never saw |
| x86-TSO on ARM's weak memory model | `FEX_PARANOIDTSO=1`, `FEX_TSOENABLED=0`, single core | **refuted** — 0/3 at both ordering extremes, and 0/3 on one core, where store reordering cannot be observed |
| `FEX_MULTIBLOCK=0` (signal-context precision) | knob matrix | 0/3 |
| CoreCLR W^X dual-mapping defeating FEX's SMC write-traps | `DOTNET_EnableWriteXorExecute=0`, NST boot ×2 | **refuted** — SIGSEGV. (Repo had already tested it once for criu: no difference) |
| Tiered compilation rewriting JIT'd code | `DOTNET_TieredCompilation=0` alone | **refuted** — 0/3 |
| Concurrent/background GC | `DOTNET_gcConcurrent=0` alone | **refuted** — 0/5. (`gcServer=1`+`TC=0` gives 8/8 on the small repro but the NST already runs that config and still corrupts) |
| Patch #26's 20 s delay landing in the wrong boot phase under emulation | `BC_DISABLE_PATCHES=26` ×2 | **refuted** — SIGSEGV, then a *fifth* distinct corruption site |
| Our own `mprotect(RWX)` in `WriteJmp` stripping FEX's write-protection | added an opt-in re-protect after the code write, built the hook natively on arm64, mounted it in | **refuted** — 38 hooks applied, every re-protect succeeded, still SIGSEGV |

Two knobs could not be *reached* rather than being disproved:

- **`FEX_SMCCHECKS=full`** — 35 min and still inside "Generating merged assemblies",
  a step that takes 2-3 s normally. Unusable as a configuration *and* unusable as
  a diagnostic. (It also re-confirms the `/bc/patched` bug in CLAUDE.md:381-421 —
  the log says "first boot" on every boot because the guard checks a path nothing
  writes to, so that merge never gets skipped.)
- **Rebuilding the amd64 image on this host** — `apt`/`gpg`/`dpkg` die with exit
  255 under emulation. Worked around usefully: `StartupHook.dll` is IL, so it
  **builds natively on arm64 in ~4 s and bind-mounts into the amd64 container**.
  That is the iteration loop to use for any further hook work under FEX.

**The one test that partitioned the space:** booting with a no-op
`StartupHook.dll` mounted over the real one (zero detours, zero P/Invoke
redirection) fails **deterministically and identically** — `PlatformNotSupportedException`
at `EventLog.WriteEntry` ← `NavEventLogEntryWriter` ← `EventLogWriter.ProcessEventQueue`,
both runs. So FEX executes BC's managed code faithfully through early boot; the
nondeterministic corruption only appears once our patches are installed. Caveat:
the no-hook boot dies at ~50 s and never reaches tenant mount, so this clears
FEX for early boot only, not for the phase where corruption actually occurs.

**Conclusion.** Track 1 has nothing left that we control. What remains is
upstream: a newer FEX build, an upstream bug report against a reduced repro, or
qemu-user purely to establish whether the corruption is FEX-specific at all. The
plan's timebox has been spent, so **Track 2 is now the primary route** — not
because it was preferred, but because Track 1 ran out of locally-fixable causes.

## Track 1 — Make FEX good enough for the NST (the preferred outcome)

Pursue because the user's instinct is that FEX is needed, and because a green
result here is the cheapest possible end state — zero repo changes.

| # | spike | method | cost | kill criteria |
|---|---|---|---|---|
| 1a | Knob-tune the NST | best config from 0b, then 5 consecutive boots | ~1 h | <5/5 green ⇒ 1a dead |
| 1b | Newer FEX | build FEX `main` from source (PPA has 2608); check upstream for .NET/TSO fixes since | ~2 h | main no better than 2608 ⇒ 1b dead |
| 1c | Upstream it | file 0c's repro; ask maintainers whether .NET-on-FEX is expected to work | days-weeks | not our critical path; do it anyway |
| 1d | Patch FEX ourselves | only if 0b/0d localizes the bug to a specific FEX subsystem | days | out of scope for a PoC unless the fix is small |

**Track 1 exit condition:** even if 1a goes green, the result only reaches T2,
not T3, until a full BCApps sweep matches x86-64 pass rates. A knob that works
by making every atomic operation slow (ParanoidTSO) on a lock-heavy server may
also be too slow to be useful — measure before celebrating.

## Track 2 — Native arm64 NST (the recommended default)

Independent of Track 1 and worth doing even if Track 1 succeeds, because it
removes the corruption-prone substrate from the component that matters.

| # | work | detail | cost | risk |
|---|---|---|---|---|
| 2a | Mechanical multi-arch | drop the two `--platform=linux/amd64`, arm64 `libSkiaSharp.so`, `ldconfig`-resolved harfbuzz, arm64 `dotnet-trace`, rebuild `reporting-service-stub`; `mssql-tools18` arm64 already exists | half day | low — all verified available |
| 2b | arm64 detour layer | literal-slot primitive **plus** a compiled-code veneer — both are required (docs/ARM64-PRECODE.md); **keep** the x64 precode-byte validation and add arm64 twins rather than deleting it. **Before starting, bake off against Cecil build-time IL body replacement** (ARM64.md) — that is architecture-independent by construction and reuses a pipeline this repo already runs | 3-6 days | medium-high — the real work |
| 2c | The 6 AMD64-stamped assemblies | `Microsoft.BusinessCentral.{AI.Abstractions,CopilotService.*,NodeAgent.Models,ServiceFabric}` — patch COFF machine `0x8664`→`0xAA64` in the Step-2 stage *if* the boot path touches them | hours | low, and may be a no-op |
| 2d | Boot and iterate | expect a tail of arm64-specific gaps; each is a normal StartupHook patch | unknown | the schedule risk |
| 2e | Keep `TieredCompilation=0` | same reason as x64: Tier-1 recompilation abandons the patched entry | free | — |

**2b is the whole gamble**, and it is better-odds than it looks: the primitive
is proven, the ~30 patch *targets* are arch-neutral managed methods, and the
x86-specific surface is confined to the detour-application layer.

## Track 3 — The parts that stay emulated (needed by every track)

| # | option | status | when to pick it |
|---|---|---|---|
| 3a | **SQL under FEX** | proven working; **not yet soak-tested** | default. Needs a sustained-load run before trusting it — it is the same substrate, and a corrupted database is worse than a crashed one |
| 3b | SQL on an external x86-64 host | `SQL_SERVER=<host>` already supported, no code change. Caveat: the license import uses `OPENROWSET BULK`, which reads from SQL's filesystem | if 3a fails a soak test, or for a trustworthy CI baseline |
| 3c | AL compile via the cross-platform package | swap `...Development.Tools.Linux`'s x64 `alc` for `...Development.Tools`'s AnyCPU `alc.dll` + `al compile`. Unverified: flag parity for `/project: /packagecachepath: /analyzer: /ruleset: /enableexternalrulesets /preprocessorsymbols`, and 17.x vs 18.x behaviour | preferred — removes an emulated CPU-heavy step |
| 3d | AL compile emulated under FEX | keeps the current x64 `alc`; short-lived batch process, the benign emulation case | fallback if 3c's flags do not line up |
| 3e | Compile off-box entirely | `.app` output is IL/metadata, architecture-neutral; an amd64 CI leg can produce apps an arm64 BC publishes | always available; decouples the compiler question from the runtime question |
| 3f | Azure SQL Edge (native arm64) | retired 2025, feature-reduced (no FTS, which this repo needs for `OptimizeForTextSearch`) | last resort |
| 3g | x86-64 SQL in a full-system VM | no KVM for a foreign arch ⇒ full CPU emulation ⇒ far slower than FEX userspace | do not bother |

## Track 4 — Alternative emulators and fallbacks

| # | option | why | cost |
|---|---|---|---|
| 4a | qemu-user instead of FEX | different bug surface entirely; if the NST survives qemu, the corruption is FEX-specific and that is a strong upstream datapoint. Expect 2-5× slower than FEX | ~1 h to try |
| 4b | box64 | third implementation, different codegen; thinner Linux/server track record | ~1 h |
| 4c | Rosetta | macOS/podman only — not applicable to this host, but it is why `docker-compose.macos.yml` works | n/a |
| 4d | Accept x86-64-only | document arm64 as unsupported, keep ARM64.md as the record of why | free |

4a is worth one hour purely as a diagnostic: it partitions "emulation is hard
for .NET" from "FEX 2608 has a bug".

## Sequencing

```
now ──┬── Track 0 (0b, 0c, 0d)         cheap, parallel, informs everything
      └── Track 2a (mechanical)        no dependencies, all upside
             │
   0b/0d results
      ├── knob found ──── Track 1a ──── 5/5 green? ── soak (T3) ── done-ish
      │                                  └─ no ──┐
      └── no knob ───────────────────────────────┤
                                                 ▼
                                          Track 2b (arm64 detours)
                                                 │
                                          Track 2d boot-and-fix
                                                 │
                                    Track 3a soak + 3c AL compile
                                                 │
                                          T2 → T3 validation
      Track 4a (qemu) ── run once alongside, purely diagnostic
```

**Parallelism:** Track 2a and Track 0 do not touch each other. Track 4a is one
hour, any time. Track 1 and Track 2b compete for the same attention, which is
the one real scheduling conflict — resolve it with 0b/1a, quickly.

**Timebox:** half a day on Tracks 0+1. If no knob makes the minimal repro clean
and the NST 5/5, stop treating emulated-NST as the primary route and commit to
Track 2, keeping FEX for SQL (3a) and possibly `alc` (3d).

## Risks

- **2b overruns.** The primitive is proven on a toy; 30 real hooks on real BC
  assemblies may surface precode forms the toy never hit (`StubPrecode` vs
  `FixupPrecode`, methods JITting to <16 bytes, hot methods whose entry is
  already backpatched). Mitigation: prototype on 2-3 `noop!` hooks first.
- **.NET 10 differs.** The arm64 precode layout was read off .NET 8 only, and
  this image runs both 8 and 10 (BC 29). Re-verify before assuming.
- **Emulated SQL corrupts data silently.** The scariest risk in the whole plan,
  because it fails quietly. 3a's soak test is not optional.
- **Chasing FEX indefinitely.** The timebox exists for this reason.
- **BC version drift.** Microsoft moves the revision daily; pin a full version
  while debugging so a changed artifact cannot be mistaken for a fix.
