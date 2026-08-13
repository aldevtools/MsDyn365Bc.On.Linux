# arm64: what was tried, what worked, what wasted time

Session log from bringing Business Central up on arm64 Linux (Qualcomm Oryon,
Ubuntu 26.04, FEX-Emu 2608). Written for the next person — including the wrong
turns, because several cost hours and are easy to repeat. Companion docs:
[ARM64.md](../ARM64.md) (measurements), [ARM64-BATTLEPLAN.md](../ARM64-BATTLEPLAN.md)
(routes + refuted ledger), [ARM64-PRECODE.md](ARM64-PRECODE.md) (native port
reference), [PRIOR-ART.md](PRIOR-ART.md), [FEX-UPSTREAM-REPORT.md](FEX-UPSTREAM-REPORT.md),
[FEX-FIX-FEASIBILITY.md](FEX-FIX-FEASIBILITY.md).

## Where it ended up

BC 28.4 with all 137 apps, serving API / OData / dev endpoint / web client, on
an emulated amd64 container stack on an arm64 host. `Ready for extensions` in
127s. A 3-hour soak (238 polls at 45s) recorded SQL 100%, API 99.6%, web 99.6%,
no failures. SQL Server then aborted at ~5h uptime — that is the limiting
component, and it is why the backup/recover scripts exist.

## The three settings that made it work

Each looks useless when tested alone. That is the whole reason this took a day.

| setting | why |
|---|---|
| `FEX_VECTORTSOENABLED=1` / `FEX_MEMCPYSETTSOENABLED=1` | FEX applies x86 store ordering to ordinary loads/stores by default but **not** to vector accesses or memcpy/memset patterns. .NET uses 16-byte SIMD constantly for struct copies and `Span`. |
| `DOTNET_EnableWriteXorExecute=0` | CoreCLR writes JIT code through a different virtual alias than it executes, defeating FEX's self-modifying-code tracking. Exposure scales with JIT volume, so it only became necessary once Base Application was loaded. |
| `DOTNET_INTERNAL_ThreadSuspendInjection=0` | CoreCLR forces threads to a GC-safe point with `SIGRTMIN` and rewrites the interrupted RIP in the kernel `ucontext`; FEX cannot report a precise guest context mid-instruction (FEX-Emu/FEX#5810). |

Plus `DOTNET_TieredCompilation=0` (already load-bearing for JMP hooks on x64;
under emulation it also stops runtime code rewriting) and keeping apps
pre-published so ReadyToRun survives.

## The single most expensive mistake

**`FEX_TSOENABLED` is on by default.** Testing it proved nothing, and testing
`=0` only disabled something that was already working. That produced a confident
"memory ordering is ruled out" conclusion which was wrong, and sent the
investigation through W^X, tiered compilation, concurrent GC, patch-timing
hazards, `mprotect` re-protection, box64 and Azure SQL Edge before the three
knobs that actually matter (`VECTORTSOENABLED`, `MEMCPYSETTSOENABLED`,
`HALFBARRIERTSOENABLED`) were even discovered — all three default **off**, all
three invisible unless you enumerate the config names out of the binary:

```
strings /usr/bin/FEX | grep -iE 'TSO'
```

Second-order mistake from the same episode: **single-core testing does not rule
out memory ordering.** Uniprocessor coherence only excludes reordering between
concurrently *running* threads; a partially-published 16-byte vector store is
still visible to another thread after a preemption, and the GC reads everything.

## Failure signatures and what they mean

| symptom | meaning |
|---|---|
| `Segmentation fault (core dumped)` from entrypoint, no managed stack | NST died below the runtime. Set `DOTNET_gcConcurrent=0` to convert it into a catchable managed exception with a stack — that is how the failure *sites* were identified. |
| Managed exception at a nonsensical frame (`EntryPointNotFoundException` in `ConcurrentDictionary.TryGetValue`) | Memory corruption, not the exception it claims. `EntryPointNotFoundException` only has one throw site (P/Invoke binding) and it carries a *parameterised* message; a bare one is a corrupted exception object. |
| A different crash site on every boot | Corruption, not a deterministic bug. Four boots gave four distinct sites in four subsystems. |
| SQL `exit 134`, SQLPAL frames, `__sigaction` near the top | SQLPAL's own signal handling. It rewrites `ucontext` like CoreCLR does but has **no** equivalent knob, so it cannot be fixed from outside. |
| SQL `exit 248`, crash-looping on startup | Crash recovery of an existing data dir under emulation. Give it a fresh one. |
| Container `healthy` while every request hangs | The stock healthcheck is served from NST cache. Probe a real TDS roundtrip. |

## Dead ends, so nobody re-runs them

- **Emulator swapping.** box64 fails the same minimal reproducer 3/20 with
  byte-identical signatures, and `ThreadSuspendInjection=0` fixes box64 too —
  the mitigation is emulator-independent. box64 also cannot run .NET properly:
  it natively wraps libc/libpthread and libstdc++'s versioned symbol lookups
  fail (`pthread_cond_destroy@GLIBC_2.3.2`).
- **Patching FEX ourselves.** Architectural, not plumbing. FEX *can* resume at
  an arbitrary guest RIP; the defect is capture-side (`RestoreRIPFromHostPC`
  reconstructs the instruction *start* while the register allocator already
  holds partial results). Upstream's Windows-only block-entry mitigation was
  ported and measured: 0/10 → 0/8, because only 34% of `SIGRTMIN` arrivals land
  in JIT code at all.
- **Azure SQL Edge** (native arm64, no emulation): its engine is SQL 2019
  (db version 931) and BC's backup is SQL 2022 (957). Downgrade restore does not
  exist. Note `RESTORE FILELISTONLY` **succeeds** on an incompatible backup — it
  reads the header only. Do not mistake that for compatibility.
- **`FEX_SMCCHECKS=full`** — never completed a 2-3s step in 35 minutes.
- **Reducing the app set to shrink the crash window** — clearing all 137 apps
  did not help; the corruption is not proportional to workload volume.
- **`DOTNET_GCHijack`** — does not exist, it is folklore.

## Operational traps

- **binfmt_misc's `F` flag pins the interpreter fd at registration**, so
  bind-mounting a self-built FEX over `/usr/bin/FEX` silently changes nothing.
  Invoke the built binary explicitly. This invalidated two measurement rounds.
- **FEX needs a writable `HOME`.** The mssql image runs as uid 10001 with no
  HOME, so FEX falls back to `./.config/fex-emu` and dies with "Couldn't connect
  to FEXServer socket". Testing as root passes while the real thing cannot start.
- **Root-owned mounts kill SQL** in `BootstrapSystemDataDirectories`
  (`HRESULT 0x80070005`) — chown to 10001 *before* first start.
- **`restart: on-failure` does not fix a hung SQL.** It brings the container
  back; `sqlservr` then wedges in recovery (up 1h, 2% CPU, errorlog frozen, no
  new dump). Recovery must *recreate*.
- **A FEX core dump can take the host down.** An emulated process has a ~35 GB
  virtual address space; apport tried to process one, reached 20 GB resident and
  OOM-killed the machine. Always `ulimits: core: 0`.
- **Do not run two `docker compose` experiments concurrently** on the same
  project — each `down` destroys the other's containers and both results are junk.

## Notes for Windows on ARM (Prism)

Untested here, but the research already answers the parts that transfer:

- **The CoreCLR suspension fix is already automatic on Windows.**
  `Thread::InitializeSpecialUserModeApc` detects x64-emulated-on-arm64 via
  `IsWow64Process2` and disables the context-injecting suspension API on builds
  before 24H2 (dotnet/runtime#100425). So the equivalent of
  `ThreadSuspendInjection=0` should not need setting by hand — verify rather
  than assume, especially on 24H2+ where the detection may no longer apply.
- **The `FEX_*` knobs are meaningless there.** Whether Prism has an equivalent
  vector/memcpy ordering gap is unknown and would need its own investigation;
  x86 store ordering still has to be emulated on arm64 by *someone*.
- **`DOTNET_EnableWriteXorExecute=0` is worth trying early** — the W^X
  dual-mapping vs SMC-tracking interaction is not FEX-specific in principle.
- **SQL Server is the open question.** Microsoft ships no arm64 build; under
  Windows/Prism it would also be emulated, and SQLPAL is what aborts here.
  `SQL_SERVER=<external x86-64 host>` remains the way to remove that variable.
- **The whole StartupHook layer may be unnecessary.** It exists to make a
  *Windows* binary run on *Linux* — event log, Windows identity, ETW, Watson,
  registry. On Windows those APIs are real, so a Windows-on-ARM attempt is a
  fundamentally different (and probably much shorter) problem: emulation only,
  no platform shims. Start from stock BC on Windows, not from this repo.
