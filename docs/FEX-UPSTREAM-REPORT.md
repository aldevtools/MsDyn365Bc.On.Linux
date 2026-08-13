# Upstream bug report draft — FEX-Emu

**Status: DRAFT. Nothing has been filed.** This file is a GitHub-issue-ready
body plus submitter notes. The decision to submit, and where, is the user's.

Everything below was measured on 2026-08-12 on this box. Configurations are
reported with the number of runs, because a 5-run batch cannot distinguish
"fixed" from "less likely" — one intermediate conclusion in this investigation
was reversed for exactly that reason.

---

## Suggested title

`CoreCLR (.NET 8) memory corruption: forced GC thread suspension via SIGRTMIN activation injection — small repro, no allocation required`

## Where it probably belongs

Almost certainly **not a new issue**. Three existing issues cover it:

| issue | state | relevance |
|---|---|---|
| [#5766](https://github.com/FEX-Emu/FEX/issues/5766) "Barotrauma: Random memory corruption in .NET 8 (CoreCLR)" | open, 2026-07-17 | Same bug, same class of host (Qualcomm Oryon, Ubuntu 26.04, 4 K pages). Maintainer replied same day: *"Yep. CoreCLR is known broken under FEX. Affects S&Box and Slay the Spire 2 as well."* |
| [#5810](https://github.com/FEX-Emu/FEX/issues/5810) "Async signal ucontext RIP rewrite corrupts guest state" | open, 2026-08-06 | The **mechanism**, reported for Go's async preemption with a standalone C reproducer. Maintainer: *"Yea, known issue atm that FEX isn't async signal safe. I have some plans for working around it but haven't gotten there yet. Nice to have the small repro test."* |
| [#5813](https://github.com/FEX-Emu/FEX/issues/5813) "HotSpot ZGC under FEX corrupts object fields…" | open, 2026-08-07 | Same shape in a different managed runtime (Java/ZGC), also signal-coordinated GC. |

All three verified by fetching the GitHub API on 2026-08-12.

**Recommendation: comment on #5766 and cross-link #5810**, rather than opening a
fourth issue. What is new here, and worth adding, is:

1. A **small reproducer that allocates nothing** — no game, no engine, no
   package, ~1 s to fail, and it isolates GC thread suspension as the trigger.
2. A **three-cell control** that pins the mechanism: identical threads with no
   GC are clean 20/20; adding one `GC.Collect()` thread is 0/20; disabling
   CoreCLR's signal-based activation injection restores 20/20.
3. Confirmation that this is **not memory ordering**, including that the
   `FEX_VECTORTSOENABLED` / `FEX_MEMCPYSETTSOENABLED` knobs (which *did* change
   behaviour for a different, larger .NET workload on this box) do **not** help
   this one at all.
4. Confirmation on FEX-**2608**, i.e. with the AVX signal-state save/restore fix
   from that release already in place.

---

# Issue body

## Summary

.NET 8 (CoreCLR) workloads under FEX suffer nondeterministic memory corruption
on aarch64. What is *measured* is that the trigger is **CoreCLR forcibly
suspending a thread that is not at a GC-safe point**: turning that one mechanism
off (`DOTNET_INTERNAL_ThreadSuspendInjection=0`) takes the reproducer from 0/20
to 20/20 while it still performs ~25,000 collections in 3 s. CoreCLR implements
that suspension by sending `SIGRTMIN` to the thread and having the handler
rewrite the interrupted `RIP` in the `ucontext` before returning — the pattern
#5810 reports as broken under FEX for Go's async preemption. The causal link is
a hypothesis and is marked as one below.

It reproduces in a single small file whose failing mode performs **no allocation
and no shared memory access at all** — pure integer arithmetic on N threads
while one thread calls `GC.Collect()` in a loop. The same threads without the
collector thread are clean 20/20.

Across the family of workloads tested on this host, failures present as
`SIGSEGV`, `AccessViolationException`, `NullReferenceException`,
`InvalidCastException`, `Internal CLR error (0x80131506)` — a different one
almost every run — and also as **silent wrong data**: a self-checking managed
array read back holding another object's contents, with no crash at all. The
minimal reproducer below fails as a bare `SIGSEGV`; the exception variety and
the silent-corruption cases are quoted with their sources under
[Observed](#observed).

## Environment

| | |
|---|---|
| FEX | `fex-emu-armv8.4` + `fex-emu-binfmt64`, **2608~1-3~r** from `ppa:fex-emu/fex` (resolute). Build string: `#2608 SMP Aug  5 2026 02:13:09` |
| Invocation | `binfmt_misc` (`/proc/sys/fs/binfmt_misc/FEX-x86_64`, flags `POCF`), `FEX_ROOTFS=/` inside an amd64 container |
| Host CPU | Qualcomm **Oryon**, 12 cores (1 thread/core). `atomics uscat lrcpc ilrcpc flagm2 rng bti ecv i8mm bf16 …` |
| Kernel | `7.0.0-29-generic #29-Ubuntu SMP PREEMPT_DYNAMIC aarch64` |
| Page size | **4096** |
| Host OS | Ubuntu 26.04 LTS (Resolute Raccoon), aarch64 |
| Container runtime | Docker 29.1.3, `--platform linux/amd64` |
| Guest rootfs | `debian:12-slim` (linux/amd64) |
| .NET | self-contained `linux-x64` publish, `Microsoft.NETCore.App` **8.0.30**, built by SDK 8.0.424 |

Note on the .NET build: the reproducer is IL, so it was **built natively on
arm64** with the arm64 SDK and published `-r linux-x64 --self-contained`, then
run under FEX. No x86-64 toolchain was involved in producing it.

## Reproduction

`repro.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <AssemblyName>repro</AssemblyName>
    <Nullable>disable</Nullable>
    <!-- so the app needs no libicu in a slim guest rootfs -->
    <InvariantGlobalization>true</InvariantGlobalization>
  </PropertyGroup>
</Project>
```

`Repro.cs`:

```csharp
// FEX-Emu + .NET 8 (CoreCLR) memory corruption reproducer.
//   dotnet publish -c Release -r linux-x64 --self-contained
//   ./repro compute     (also: ./repro alloc, ./repro spin)
// Exit 0 = clean. Non-zero, SIGSEGV, or any "CORRUPT:" line = reproduced.
using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading;

static class Repro
{
    static string bad;
    static long iters;
    static Stopwatch sw = Stopwatch.StartNew();
    static int ms, nthreads;

    static int Main(string[] a)
    {
        string mode = a.Length > 0 ? a[0] : "alloc";
        ms = a.Length > 1 ? int.Parse(a[1]) : 1000;
        nthreads = a.Length > 2 ? int.Parse(a[2]) : Environment.ProcessorCount;
        Console.WriteLine($"mode={mode} ms={ms} threads={nthreads}");

        var ts = new Thread[nthreads];
        for (int t = 0; t < nthreads; t++)
        {
            int tid = t;
            ts[t] = new Thread(mode == "compute" || mode == "spin" ? () => Compute(tid) : (ThreadStart)(() => Alloc(tid)));
            ts[t].IsBackground = true;
        }
        Thread collector = null;
        if (mode == "compute")
        {
            collector = new Thread(() => { while (sw.ElapsedMilliseconds < ms) GC.Collect(); }) { IsBackground = true };
            collector.Start();
        }
        foreach (var th in ts) th.Start();
        foreach (var th in ts) th.Join();
        collector?.Join();

        Console.WriteLine($"iters={iters} gc0={GC.CollectionCount(0)} gc1={GC.CollectionCount(1)} gc2={GC.CollectionCount(2)}");
        if (bad == null) return 0;
        Console.WriteLine("CORRUPT: " + bad);
        return 3;
    }

    // Each thread owns a private rolling window of self-describing byte arrays:
    // a[j] == (byte)(a[0] + j*7). Nothing is shared between threads, so no data
    // race in this program can explain a mismatch -- a mismatch means the
    // contents of a managed array changed after it was written.
    static void Alloc(int tid)
    {
        const int SIZE = 256, WIN = 64;
        var win = new byte[WIN][];
        long k = tid * 1000;
        while (sw.ElapsedMilliseconds < ms && bad == null)
        {
            var arr = new byte[SIZE];
            arr[0] = (byte)k;
            for (int j = 1; j < SIZE; j++) arr[j] = (byte)(arr[0] + j * 7);
            win[(int)(k % WIN)] = arr;
            for (int w = 0; w < WIN; w++)
            {
                var b = win[w];
                if (b == null) continue;
                if (b.Length != SIZE) { Interlocked.CompareExchange(ref bad, $"t{tid} slot{w} length={b.Length}", null); return; }
                for (int j = 1; j < SIZE; j++)
                    if (b[j] != (byte)(b[0] + j * 7))
                    { Interlocked.CompareExchange(ref bad, $"t{tid} slot{w} byte{j}={b[j]} expected {(byte)(b[0] + j * 7)} (base {b[0]})", null); return; }
            }
            k++;
            Interlocked.Increment(ref iters);
        }
    }

    // No allocation at all in the workers: pure integer arithmetic, each chunk
    // computed twice and compared, while one thread forces collections (i.e.
    // forces every other thread to be suspended) as fast as it can.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static long Chunk(long seed)
    {
        long x = seed, y = ~seed, z = seed * 3, w = seed ^ 0x5555555555555555L;
        for (int i = 0; i < 4096; i++)
        {
            x = x * 6364136223846793005L + 1442695040888963407L;
            y ^= y << 13; y ^= y >> 7; y ^= y << 17;
            z += x ^ y; z = (z << 1) | (long)((ulong)z >> 63);
            w = w * 2862933555777941757L + 3037000493L + (x & 0xff);
        }
        return x ^ y ^ z ^ w;
    }

    static void Compute(int tid)
    {
        long seed = tid * 104729 + 7;
        while (sw.ElapsedMilliseconds < ms && bad == null)
        {
            long p = Chunk(seed), q = Chunk(seed);
            if (p != q) { Interlocked.CompareExchange(ref bad, $"t{tid} chunk mismatch {p:x} != {q:x}", null); return; }
            seed = p;
            Interlocked.Increment(ref iters);
        }
    }
}
```

Build (on any machine; IL is architecture-neutral, so an arm64 SDK is fine):

```bash
dotnet publish -c Release -r linux-x64 --self-contained true -o ./out-x64
```

Run under FEX. Either directly with an x86-64 rootfs, or — as measured here —
in a minimal amd64 container with FEX bind-mounted in:

```bash
docker run --rm --platform linux/amd64 --ulimit core=0 \
  -e FEX_ROOTFS=/ -e HOME=/tmp \
  -v /usr/bin/FEX:/usr/bin/FEX:ro \
  -v /usr/bin/FEXServer:/usr/bin/FEXServer:ro \
  -v /lib/ld-linux-aarch64.so.1:/lib/ld-linux-aarch64.so.1:ro \
  -v /usr/lib/aarch64-linux-gnu/libstdc++.so.6:/usr/lib/aarch64-linux-gnu/libstdc++.so.6:ro \
  -v /usr/lib/aarch64-linux-gnu/libm.so.6:/usr/lib/aarch64-linux-gnu/libm.so.6:ro \
  -v /usr/lib/aarch64-linux-gnu/libgcc_s.so.1:/usr/lib/aarch64-linux-gnu/libgcc_s.so.1:ro \
  -v /usr/lib/aarch64-linux-gnu/libc.so.6:/usr/lib/aarch64-linux-gnu/libc.so.6:ro \
  -v "$PWD/out-x64:/app:ro" \
  debian:12-slim /app/repro compute 3000 12
```

> `--ulimit core=0` is not cosmetic. A FEX core dump of this address space fed
> to Ubuntu's `apport` reached ~20 GB resident and took a 30 GB host down three
> times during this investigation. Please do not enable core dumps for it.

## Observed

`./repro compute 3000 12` — **0 of 20 runs completed.** It dies within ~1 s of
the workers starting. Every observed failure is a bare `SIGSEGV` (exit 139) with
no managed diagnostic at all — the whole output is the banner line:

```
mode=compute ms=3000 threads=12
   (exit 139)
```

`./repro alloc 3000 12` — 3 of 10, and 3 of 6 in a later batch. Same bare
`SIGSEGV`. A passing run reports the work it did, e.g.
`iters=2512879 gc0=170 gc1=0 gc2=0`.

### Corruption signatures from the larger variants, quoted with their source

The minimal reproducer above only ever crashed for us. The variety of managed
symptoms, and the silent-corruption cases, came from two larger workloads on the
same host — worth quoting because they show *what* is being corrupted:

**(a) A linked-object-graph variant** of the same program (worker threads build
a 400-node chain of objects with a checksum and a self-describing `byte[]`
payload per node, verify freshly built chains, aged chains, and a set of
read-only gen2 chains). 0/5 at 12 threads. Verbatim failures:

```
CORRUPT: aged: payload byte 0 of node 1: 8 != 143
CORRUPT: gen2: payload byte 34 of node 179: 9 != 203
CORRUPT: fresh: checksum of node 349: 47822931cadc6567 != 7ee03011d4878605
CORRUPT: aged: null payload at 127
Fatal error. System.AccessViolationException: Attempted to read or write protected memory. This is often an indication that other memory is corrupt.
   at P.Verify(Node, Int32)
Fatal error. Internal CLR error. (0x80131506)
```

The first line is the important one: at that position the payload's first byte
must be 143, and 8 is the value belonging to a *different* node — a reference
that now designates the wrong object. In this program the graphs being verified
are either thread-local or built before any worker starts and never written
again, and the only cross-thread state is an `Interlocked` counter and a
`CompareExchange`d error string. No data race in the program can produce those
lines.

**(b) `dotnet restore` of an empty `net8.0` console project** inside
`mcr.microsoft.com/dotnet/sdk:8.0` (linux/amd64) — our original repro, 0/5 at
runtime defaults, a different place every run:

```
System.InvalidCastException: Unable to cast object of type 'Microsoft.Build.Construction.XmlElementWithLoca…   (our capture truncated the type name here)
System.InvalidCastException: Unable to cast object of type 'System.String' to type 'System.Byte[]'.
System.NullReferenceException: Object reference not set to an instance of an object.
Fatal error. System.AccessViolationException: Attempted to read or write protected memory.
Segmentation fault / Aborted
```

Earlier runs of the same restore also produced `MSB4248` ("ValueFactory
attempted to access the Value property of this instance" — a torn `Lazy<T>`) and
faults inside `System.Text.RegularExpressions.Match.Reset` and
`System.Lazy'1.CreateValue`.

## Expected

Exit 0. The identical IL, published `-r linux-arm64` and run natively on the
same host, passes every mode every time (`alloc`, `compute`, `spin`, 3 runs each
plus further runs during bisection; also a longer graph-verifying variant 5/5).

## The three-cell control that localises it

All on the same binary, `3000 ms`, 12 worker threads:

| # | configuration | difference from the row above | pass |
|---|---|---|---|
| 1 | `spin` — 12 threads, pure arithmetic, **no GC activity** | — | **20/20** |
| 2 | `compute` — same 12 threads **+ one thread calling `GC.Collect()`** | GC now suspends the workers | **0/20** |
| 3 | `compute` + `DOTNET_INTERNAL_ThreadSuspendInjection=0` | CoreCLR no longer sends `SIGRTMIN` to force threads to a safe point | **20/20** |

Row 3 still performs the collections. Three consecutive passing runs reported:

```
iters=79340 gc0=24761 gc1=24761 gc2=24761
iters=73136 gc0=25431 gc1=25431 gc2=25431
iters=79051 gc0=25413 gc1=25413 gc2=25413
```

That is ~25,000 full collections in 3 s with 12 threads to suspend each time —
on the order of 300,000 thread suspensions, all clean. What changes between rows
2 and 3 is only *how* a thread that is not at a safe point is brought to one.

`DOTNET_INTERNAL_ThreadSuspendInjection=0` maps to
`CLRConfig::INTERNAL_ThreadSuspendInjection`
([clrconfigvalues.h:514](https://github.com/dotnet/runtime/blob/release/8.0/src/coreclr/inc/clrconfigvalues.h)),
read in `Thread::InjectActivation`
([threadsuspend.cpp:6022](https://github.com/dotnet/runtime/blob/release/8.0/src/coreclr/vm/threadsuspend.cpp)),
which is what calls `PAL_InjectActivation` for `ActivationReason::SuspendForGC`.
Setting it to 0 makes that return `false`, so the runtime waits for cooperative
polling instead of interrupting the thread.

## Mechanism — hypothesis

**Marked as hypothesis.** The measurements above are facts; the causal chain
below is inference, though it matches an already-confirmed FEX defect.

CoreCLR suspends a thread that is not at a GC-safe point like this
([pal/src/exception/signal.cpp](https://github.com/dotnet/runtime/blob/release/8.0/src/coreclr/pal/src/exception/signal.cpp),
`inject_activation_handler`, `INJECT_ACTIVATION_SIGNAL = SIGRTMIN` at line 56):

1. Send `SIGRTMIN` to the target thread.
2. In the handler, convert the kernel's `ucontext` to a `CONTEXT`
   (`CONTEXTFromNativeContext`, with `CONTEXT_XSTATE` on amd64).
3. Ask the code manager whether the interrupted PC is a safe place to hijack
   (`g_safeActivationCheckFunction(CONTEXTGetPC(...))`).
4. Run the activation, which **modifies that `CONTEXT`** — hijacking the thread
   so it redirects to a stub instead of continuing where it was.
5. Write the modified context **back into the kernel's `ucontext`**
   (`CONTEXTToNativeContext(&winContext, ucontext)`, with the comment
   *"Activation function may have modified the context, so update it"*), then
   return so `sigreturn` resumes the guest at a different `RIP` with modified
   registers.

That is precisely the pattern #5810 reports as broken under FEX: a guest signal
handler rewriting `uc_mcontext` `RIP` and resuming. Go's async preemption
(`SIGURG`) does the same thing and is fixed by `GODEBUG=asyncpreemptoff=1`, the
exact analogue of `DOTNET_INTERNAL_ThreadSuspendInjection=0` here.

If the guest state FEX presents in the signal frame — or the state it restores
from the rewritten frame — is not exactly the architectural state at the
interrupted instruction boundary, then after resumption the thread runs with a
wrong register set or a wrong `RSP`/`RIP`. Under a moving GC that is maximally
destructive: a register holding an object reference that the GC has since
relocated, a stack slot the GC scanned at the wrong address, or a hijack return
address written into the wrong stack location. All three would surface exactly
as observed — a crash or a wrong value at an arbitrary later point, in a
different place every run.

Two consistent corollaries:

- **The failure rate scales with the number of forced suspensions**, not with
  GC flavour. Server GC is widely reported to "fix" .NET-under-FEX problems;
  on this box Server GC's benefit is fully reproduced on **Workstation** GC by
  just enlarging the gen0 budget, which only changes how *often* collections
  happen. `dotnet restore` in `mcr.microsoft.com/dotnet/sdk:8.0` fails 0/5 at
  defaults but passes **5/5** with `DOTNET_GCgen0size=10000000` (that value is
  parsed as hex, so ~256 MiB) and nothing
  else changed — same GC flavour, same tiered compilation.
- **It needs ≥2 threads.** One worker thread is clean 10/10: with a single
  mutator the collector is that same thread, which suspends itself
  cooperatively and never has to be interrupted.

## What was ruled out

`repro alloc`, 3000 ms, 12 threads, N=10 per cell unless stated. Default is
3/10 for this cell; anything in the 2/10–7/10 band is not distinguishable from
it at N=10, and is reported as "no effect".

| hypothesis | test | pass | verdict |
|---|---|---|---|
| **Memory ordering (x86-TSO on a weak model)** | `FEX_PARANOIDTSO=1` | 2/10 | no effect |
| | `FEX_TSOENABLED=0` | 7/10 | no effect |
| | pinned to one core (`--cpuset-cpus 0`) | **0/10** | still fails where cross-thread store reordering cannot be observed |
| **Unordered vector / memcpy stores** | `FEX_VECTORTSOENABLED=1` | 5/10 | no effect |
| | `FEX_MEMCPYSETTSOENABLED=1` | 6/10 | no effect |
| | both, on `alloc` | 6/10 | no effect |
| | both, on `compute` | **0/10** | no effect at all — `compute` has no allocation and no vector work |
| **Signal-context precision from multiblock** | `FEX_MULTIBLOCK=0` | 7/10 | no effect |
| **Self-modifying-code detection** | `FEX_SMCCHECKS=full`, `compute` with a 60 s budget | **0/2** | no effect. Both runs `SIGSEGV` at 32 s and 33 s, against a 1 s time-to-crash for the same command without the knob — i.e. the knob slows startup by ~30 s and then the program still dies as the workload begins. (Previously unevaluable for us: an MSBuild-based repro never finished under it. A short program makes it testable.) |
| **Tiered compilation rewriting JIT'd code** | `DOTNET_TieredCompilation=0` | 7/10 | no effect |
| **Concurrent / background GC** | `DOTNET_gcConcurrent=0` | 5/10 | no effect |
| **GC flavour** | `DOTNET_gcServer=1` | 5/10 | no effect on this repro (see gen0 note above) |
| | `DOTNET_gcServer=1 DOTNET_TieredCompilation=0` | 3/10 | no effect on this repro |
| **W^X dual mapping** | `DOTNET_EnableWriteXorExecute=0` | not tested on this repro | no effect when tested against the larger .NET server workload on this host (2 runs); not re-run against the reproducer |
| **`membarrier` / `FlushProcessWriteBuffers` missing** | probed the syscall from an x86-64 guest | works | `membarrier(QUERY)` returns `0x3ff`; `REGISTER_PRIVATE_EXPEDITED`, `PRIVATE_EXPEDITED` and `GLOBAL` all return 0. FEX passes syscall 324 straight through to the host. Not the bug. |
| **Multithreading per se** | `spin`: 12 threads, no GC | **20/20** | clean — it is the GC's forced suspension, not threads |
| **Number of threads** | 1 / 2 / 4 / 12 threads | 10/10, 8/10, 0/10, 3/10 | needs ≥2; not monotonic above that |
| **Native control** | same IL, `-r linux-arm64`, native | all pass | not a .NET bug |

Also worth recording, since it postdates the last release: FEX **2608** already
contains *"Fixes AVX signal state saving and restoring"* and *"Fix untracked
thread handling"*, and the corruption is unchanged with those in place. FEX
`main` is 34 commits past `FEX-2608` and none of them touch signals, SMC
invalidation, TSO/atomics or syscall handling behaviourally, so building `main`
is unlikely to change this.

## Other observations from the same box, for context

- **A larger .NET workload on this host responds to a *different* knob.** The
  application this investigation started from — a large, long-running .NET 8
  server that previously never finished booting under FEX — reached a working
  boot with `FEX_VECTORTSOENABLED=1` or `FEX_MEMCPYSETTSOENABLED=1` (either
  sufficed, plus an application-level change), which fits vector stores not
  being TSO-ordered by default. Those same knobs do **nothing** for the
  reproducer above (`compute` 0/10 with both set), and conversely
  `DOTNET_INTERNAL_ThreadSuspendInjection=0` does nothing for `dotnet restore`
  (0/5). That asymmetry suggests **more than one defect is in play** for real
  .NET workloads, and that the reproducer above isolates only one of them — the
  one that needs no allocation and no vector code. The boot result is a single
  configuration measured once, not a rate.
- **Not everything under FEX is fragile.** SQL Server 2022 CU26 (native C++)
  runs emulated on this same host and passes DDL/DML/transaction/collation
  checks. The failures are specific to managed runtimes with signal-coordinated
  GC, consistent with #5766 / #5813.

---

# Submitter notes (not part of the issue body)

1. **FEX has an explicit anti-AI policy.** `CONTRIBUTING.md` is one line: *"No
   AI/ML/LLM/etc code contributions."* `AGENTS.md`/`CLAUDE.md` say *"AI must not
   be used to generate code for contributions to this project."* The written
   policy covers code, not bug reports, but maintainers also apply an
   **`ml-report`** label to issues that read as machine-written — #5766, #5810
   and #5813 all carry it. They do still answer those substantively, same day.
   If you submit, consider trimming to first-person prose about what you ran,
   and drop anything you have not personally re-run.
2. **Prefer commenting on #5766** over opening a fourth issue, and link #5810 as
   the mechanism. Given the maintainer's *"Nice to have the small repro test"* on
   #5810, the reproducer is the part with real value.
3. **Do not paste the whole matrix** into a comment. The three-cell control plus
   the reproducer is the argument; the rest is backup if asked.
4. If you want the strongest possible version of this, the missing piece is a
   **pure C reproducer** of CoreCLR's exact shape (`SIGRTMIN` + `CONTEXTToNativeContext`
   RIP rewrite). #5810 already ships one for Go's `SIGURG` variant, so it may be
   redundant. We could not build one here: this host has no x86-64 C toolchain
   and no root to install one.
5. **Honest gap in the reduction.** The reproducer is far smaller than the
   original `dotnet restore`-in-the-SDK-image repro (25 lines vs a 216 MB image
   plus MSBuild), but it is **still .NET**. We did not reduce it to a non-.NET
   program, and we did not identify a single mechanism that explains every .NET
   failure on this box — see the asymmetry noted above.
