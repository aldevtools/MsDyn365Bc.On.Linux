# Prior art: async-signal thread suspension under binary translation

Who else has hit "moving GC + emulator + signal that rewrites the interrupted
context", what actually fixed it for them, and what of that transfers to us.

Compiled 2026-08-12. Companion to [FEX-UPSTREAM-REPORT.md](FEX-UPSTREAM-REPORT.md)
(the defect, measured) and [FEX-FIX-FEASIBILITY.md](FEX-FIX-FEASIBILITY.md)
(can we patch FEX — no).

Every claim is tagged:

- **[V]** verified — a link or a local measurement you can re-run
- **[C]** claimed but unverified — someone says so, nobody re-derived it
- **[I]** inference — mine, from the evidence cited next to it

---

## The one-paragraph answer

This is a **known, named, ~25-year-old class of defect** in dynamic binary
translation, it has exactly **two known-correct fixes**, and **both live in the
emulator, not in the runtime**. Of the emulators that can run x86-64 on arm64,
the ones that get it right (qemu-user, Rosetta 2, blink) get it right *by
design* and pay for it in throughput; the ones that are fast (FEX, box64) all
have the bug. **Nobody has ever fixed it on the runtime side, in any ecosystem.**
Go has lived with `GODEBUG=asyncpreemptoff=1` since February 2020. The one time
a vendor *did* fix it — Apple, for Rosetta 2, at Microsoft's request in
2020 — the fix shipped in the emulator and .NET changed nothing. Our
`DOTNET_INTERNAL_ThreadSuspendInjection=0` is the CoreCLR spelling of
`asyncpreemptoff=1`, it is a **RETAIL config knob honoured in shipping builds**,
Microsoft already ships an *automatic* version of the same idea for x64-on-arm64
Windows, and it is the answer — not a bridge to one.

The most useful new measurement in this document: **box64 has the identical
defect** (3/20 vs FEX's 0/20 on the same repro on this box), and
`DOTNET_INTERNAL_ThreadSuspendInjection=0` fixes box64 too (10/10). Switching
emulators is not an escape hatch; the mitigation is emulator-independent.

The mitigation is not free, and §1d characterises the cost exactly: on Linux,
signal injection is CoreCLR's *only* suspension mechanism, and RyuJIT answers a
call-free loop by marking the method fully interruptible rather than by inserting
a GC poll. So with injection off, a hot managed loop with no calls, allocations
or blocking can stall `SuspendEE` indefinitely — there is no retail timeout. The
failure mode moves from silent heap corruption to a diagnosable pause. That is a
much better place to be, but it wants a watchdog, not optimism (§10 item 1).

---

## Contents

1. [What the defect actually is, in CoreCLR's own source](#1-what-the-defect-actually-is-in-coreclrs-own-source)
2. [The same bug in other runtimes](#2-the-same-bug-in-other-runtimes)
3. [The same bug in other emulators — and the two designs that avoid it](#3-the-same-bug-in-other-emulators--and-the-two-designs-that-avoid-it)
4. [Rosetta 2: the one time this was fixed properly](#4-rosetta-2-the-one-time-this-was-fixed-properly)
5. [Windows on Arm: Microsoft ships our workaround, automatically](#5-windows-on-arm-microsoft-ships-our-workaround-automatically)
6. [CoreCLR-side knobs: what exists, what is inert](#6-coreclr-side-knobs-what-exists-what-is-inert)
7. [Field reports: x64 .NET on arm64 via emulation](#7-field-reports-x64-net-on-arm64-via-emulation)
8. [Out-of-tree work on FEX and box64](#8-out-of-tree-work-on-fex-and-box64)
9. [Measurements taken on this box today](#9-measurements-taken-on-this-box-today)
10. [What transfers to us — ranked list of things to try](#10-what-transfers-to-us--ranked-list-of-things-to-try)
11. [Dead ends](#11-dead-ends)
12. [The literature](#12-the-literature)

---

## 1. What the defect actually is, in CoreCLR's own source

Worth pinning down precisely, because it determines which prior art transfers.
All of this is **[V]** — read out of the `.NET 8` sources
([`threadsuspend.cpp`](https://github.com/dotnet/runtime/blob/main/src/coreclr/vm/threadsuspend.cpp),
[`pal/src/exception/signal.cpp`](https://github.com/dotnet/runtime/blob/main/src/coreclr/pal/src/exception/signal.cpp))
and cross-checked against the shipping `libcoreclr.so`.

The suspension path on Unix is:

```
ThreadSuspend::SuspendEE
  → Thread::Hijack
      → Thread::InjectActivation(SuspendForGC)        [gated on INTERNAL_ThreadSuspendInjection]
          → PAL_InjectActivation → pthread_kill(SIGRTMIN)
              → inject_activation_handler(ucontext)   [pal/.../signal.cpp]
                  CONTEXTFromNativeContext(ucontext, &winContext, ...)
                  if (g_safeActivationCheckFunction(CONTEXTGetPC(&winContext), TRUE))
                      InvokeActivationHandler(&winContext)
                          → HandleSuspensionForInterruptedThread(&winContext)
                  CONTEXTToNativeContext(&winContext, ucontext)   ← writes RIP *and every GPR* back
```

Three details matter:

**(a) The whole register file round-trips, not just RIP.** `CONTEXTToNativeContext`
copies the full context back into the kernel ucontext unconditionally. So it is
not only "FEX's reconstructed RIP is the start of the instruction" — it is that
FEX then *resumes from* a register file it never had a consistent snapshot of.

**(b) CoreCLR does have a safe-point check, and it is far weaker than Go's.**
`CheckActivationSafePoint` (threadsuspend.cpp) is, in full, "am I in managed
code":

```cpp
BOOL isActivationSafePoint = pThread != NULL &&
    (pThread->m_StateNC & Thread::TSNC_DebuggerIsStepping) == 0 &&
    pThread->PreemptiveGCDisabled() &&
    (ExecutionManager::GetScanFlags(pThread) != ExecutionManager::ScanReaderLock) &&
    ExecutionManager::IsManagedCodeNoLock(ip);
```

FEX's reconstructed RIP *is* a real instruction address inside a real managed
method, so this check passes every time and buys nothing. Contrast Go's
`isAsyncSafePoint` (§2), which additionally bounds-checks SP against the
goroutine's stack, looks the PC up in `pclntab`, and consults a per-PC
`PCDATA_UnsafePoint` table. **[I]** Even Go's much stronger check does not save
Go under FEX — see #5810 — because a DBT's characteristic failure is a
*plausible but wrong* context, not an implausible one. So "make CoreCLR validate
harder" is not a fix for anyone.

**(c) Both downstream branches consume the bogus registers.**
`HandleSuspensionForInterruptedThread` splits on `pEECM->IsGcSafe(...)`:

- at a GC-safe point → pushes a `RedirectedThreadFrame(interruptedContext)` and
  pulses GC mode. **The GC then scans those registers as roots.** With a
  compacting GC, a bogus root is not a leak — it is a pointer that gets
  dereferenced and rewritten.
- not at a safe point → stack-walks *using the bogus SP/RBP* to locate the
  caller's return-address slot, then `HijackThread` **writes to that slot**. A
  wrong SP means writing a hijack address over an arbitrary stack word.

So there is no "safe half" of this mechanism to keep.

**(d) On Linux, signal injection is the *only* suspension mechanism.** This is
worth being exact about, because it determines the cost of turning it off.
`switches.h` defines `PLATFORM_SUPPORTS_SAFE_THREADSUSPEND` only `#if
!defined(TARGET_UNIX)`, so `threads.h` defines `DISABLE_THREADSUSPEND`, so
`Thread::UseContextBasedThreadRedirection()` returns **false unconditionally on
Linux**. The Windows `SuspendThread`+`GetThreadContext` path does not exist here,
and the Windows special-user-mode-APC path is `FEATURE_SPECIAL_USER_MODE_APC`,
Windows-AMD64 only. Return-address hijacking as a *separate* mechanism is almost
entirely `#if defined(FEATURE_HIJACK) && !defined(TARGET_UNIX)` — on Linux it
happens only *inside* the activation handler. **[V]**

`Thread::Hijack`'s own comment says the fallback is:

> - Otherwise, we rely on the GCPOLL mechanism enabled by `TrapReturningThreads`.

**That comment oversells it, and the gap is the one real risk we are taking.**
RyuJIT does **not** insert a GC poll in every loop. `Compiler::fgInsertGCPolls`
is gated on `OMF_NEEDS_GCPOLLS`, which is set only for `SuppressGCTransition`
P/Invokes and recursive/fast tail calls. For an ordinary call-free loop the JIT
instead does this (`Compiler::fgSetBlockOrder`, [`jit/flowgraph.cpp`](https://github.com/dotnet/runtime/blob/main/src/coreclr/jit/flowgraph.cpp)) **[V]**:

```cpp
if (fgHasCycleWithoutGCSafePoint())
{
    JITDUMP("Marking method as fully interruptible\n");
    SetInterruptible(true);
}
```

i.e. it makes the method **fully interruptible** — every instruction is a GC-safe
point, and there are *no poll instructions at all*, because the intended way to
stop such a thread is precisely the asynchronous interrupt we just disabled.

**[I]** So with injection off, `Hijack()` is a no-op and `SuspendEE` degenerates
into a spin-wait for each cooperative thread to voluntarily transition to
preemptive mode — which happens at P/Invoke transitions, blocking waits, and VM
helpers with `GC_TRIGGERS`. A thread inside a call-free, allocation-free managed
loop will not transition, and the suspension loop has no retail timeout
(`SuspendDeadlockTimeout` is debug-only, §6). The failure mode therefore changes
from *silent heap corruption* to *a bounded-in-practice but unbounded-in-theory
GC pause*. See §10 item 1 for what to watch. Counter-intuitively, **P/Invoke-heavy
and long-native-call code is not a risk** — such threads are already preemptive
and never needed stopping.

---

## 2. The same bug in other runtimes

### Go — the closest analogue, and it was never fixed

Go 1.14's non-cooperative preemption
([proposal 24543](https://go.googlesource.com/proposal/+/master/design/24543-non-cooperative-preemption.md),
[golang/go#24543](https://github.com/golang/go/issues/24543)) sends `SIGURG` and
rewrites the ucontext in the handler. `signal_amd64.go`'s `pushCall` is
structurally identical to CoreCLR's hijack, and *worse* in one respect — it
writes a return address to guest memory at the kernel-reported RSP **[V]**:

```go
func (c *sigctxt) pushCall(targetPC, resumePC uintptr) {
	sp := uintptr(c.rsp())
	sp -= goarch.PtrSize
	*(*uintptr)(unsafe.Pointer(sp)) = resumePC
	c.set_rsp(uint64(sp)); c.set_rip(uint64(targetPC))
}
```

**Under qemu-user, arm64 guest:**
[golang/go#36981](https://github.com/golang/go/issues/36981), filed Feb 2020,
**still open**. Go maintainer cherrymui **[V]**:

> As @bcmills said, QEMU user mode is not actually supported. I think this is a
> QEMU bug in handling async signals, especially with signal context
> modifications. And it's not only ARM64, but also other architectures.

ianlancetaylor asked the reporter to try `GODEBUG=asyncpreemptoff=1`; the reply
was "Yes, it runs very happily with that variable set." That is the entire
resolution, six years on. bcmills invoked Go's porting policy: no builder, no
maintainer, not supported.

**Under FEX:** [FEX#5810](https://github.com/FEX-Emu/FEX/issues/5810), the issue
we already have. Also [FEX#4131](https://github.com/FEX-Emu/FEX/issues/4131)
(*Bear's Restaurant*, a Go-engine game, "sends SIGURG /very/ quickly for doing
preemption") — same mechanism, open since Oct 2024.

**Under Rosetta 2:** [golang/go#42700](https://github.com/golang/go/issues/42700)
(2020) — Rosetta's own internal assertions fired under Go's signal traffic;
**Apple fixed it** in macOS 11.2 and Go changed nothing. A regression returned in
macOS 14.5+ ([golang/go#68485](https://github.com/golang/go/issues/68485), open),
where the reporter measured `asyncpreemptoff=1` → 3200 runs / 0 failures vs
`asyncpreemptoff=0` → 600 runs / **351 failures (58.5%)** **[C]** — that ratio is
one reporter's numbers, not re-derived.

**Does Go auto-detect emulation and disable preemption?** No. Searched several
ways, found nothing; it has never been proposed. **[V, negative]**

**Why Go survives at all and we do not.** This is the most transferable insight
in the whole document, and it is three properties CoreCLR lacks:

| Go | CoreCLR |
|---|---|
| Heap GC is **non-moving** (concurrent mark-sweep, non-compacting). A bogus root is a leak. | GC **compacts**. A bogus root is a write through a fabricated pointer. |
| Async-preempted frames are **scanned conservatively** by design ([conservative-inner-frame.md](https://go.googlesource.com/proposal/+/master/design/24543/conservative-inner-frame.md)) — "treating anything that could be a valid heap pointer as a heap pointer". Garbage registers are *expected*. | Precise root reporting from GC info. Garbage registers are trusted. |
| Its one moving collector (stack copying) is **explicitly disabled** for such frames — shrinking is deferred to the next cooperative preemption. | No equivalent suppression. |

**[I]** Same wrong input, three orders of magnitude of difference in blast
radius. This is why the identical emulator defect gives Go a flaky test suite
and gives us silent heap corruption.

### HotSpot JVM — different mechanism, and the GC choice matters

HotSpot does **not** asynchronously rewrite the PC for safepoints. JIT'd code
loads from a thread-local polling page; when the VM arms it, *the thread's own
instruction* faults SIGSEGV and the handler redirects it
([Shipilev, JVM Anatomy Quark #22](https://shipilev.net/jvm/anatomy-quarks/22-safepoint-polls/)).
**[I]** That is a categorical improvement for emulation: a *synchronous* fault
has a precise guest PC by construction, and every DBT must already reconstruct
state for SIGSEGV or it could not run anything. JDK 10+ thread-local handshakes
and ZGC's stack-watermark barriers (JEP 376) use the same polling machinery.
The one async signal (`SR_handler`, SIGUSR2) only *reads* the context.

Yet [FEX#5813](https://github.com/FEX-Emu/FEX/issues/5813) still shows ZGC
corrupting under FEX — and its control matrix is the sharpest single datapoint
anywhere on this problem **[V]**:

| config | result |
|---|---|
| ZGC + JIT under FEX | 3/3 fail (`ZUncoloredRoot::process` SIGSEGV; NPE on a `final` field set immediately prior) |
| ZGC + `-Xint` under FEX | passes |
| **G1GC + JIT under FEX** | **passes** |
| **ZGC + JIT under `qemu-x86_64`** | **passes** |

The last row isolates the defect to FEX's context precision rather than to ZGC.
The G1-vs-ZGC row is the reason "try a less concurrent GC" appears on our list
below — though see §9, where it did **not** help for us.

There is **no** JVM flag that disables signal-based safepoints. `-XX:+UseMembar`
and `-XX:-ThreadLocalHandshakes` were both removed and were about other things.
**[V, negative]**

### Mono — the precedent that is also a .NET runtime

Mono deliberately abandoned preemptive signal-based suspension. From
[mono-project.com: Runtime Cooperative Suspend](https://www.mono-project.com/docs/advanced/runtime/docs/coop-suspend/)
**[V]**: the suspender runs "in the equivalent of signal context - a very very
restrictive setup"; and on platform limits, on watchOS and WebAssembly there
aren't "enough OS facilities to examine the context when a thread is suspended -
we can't see the contents of their registers, or their stack, and thus
preemptive suspend on those systems wouldn't be useful for GC." Mono shipped
**hybrid suspend** as the default in 5.16: managed threads suspend cooperatively
at safepoints; only threads in native code get preempted.

**[I]** A DBT emulator belongs in the same category as watchOS and WASM — a
platform that cannot report a trustworthy register context. Mono's answer to
that category was to stop asking. That is exactly what
`DOTNET_INTERNAL_ThreadSuspendInjection=0` does for us.

Default suspend policy on Linux is **hybrid** (`src/mono/CMakeLists.txt`), and
`MONO_THREADS_SUSPEND=coop|hybrid|preemptive` overrides it — and, contrary to
the [mono(1) man page](https://manpages.debian.org/unstable/mono-runtime-common/mono.1.en.html),
in current dotnet/runtime source the env var is checked **first** and wins over
the compiled default (`mono_threads_suspend_policy_init`,
[`mono-threads-coop.c`](https://github.com/dotnet/runtime/blob/main/src/mono/mono/utils/mono-threads-coop.c)). **[V]**

But the load-bearing difference is not the suspend policy — it is two other
things, and both are verifiable in source:

**Mono's suspend signal handler never asks the emulator to resume elsewhere.**
`suspend_signal_handler` ([`mono-threads-posix-signals.c`](https://github.com/dotnet/runtime/blob/main/src/mono/mono/utils/mono-threads-posix-signals.c))
saves the interrupted state, notifies the initiator, then `sigsuspend()`s
*inside the handler* until the restart signal. It writes back to the ucontext
only for `async_target` (thread abort/interrupt), never for GC. **[V]** **[I]**
"Park here" is a far easier thing for a DBT to get right than "resume at this
other RIP with this register file".

**SGen scans stacks *and the saved register context* conservatively — always.**
[`sgen-mono.c`](https://github.com/dotnet/runtime/blob/main/src/mono/mono/metadata/sgen-mono.c)
sets `conservative_stack_mark = TRUE` in `sgen_client_init()` with the comment
*"Precise marking is broken on all supported targets. Disable until fixed."*, and
`sgen_client_scan_thread_data()` calls `sgen_conservatively_pin_objects_from()`
over the stack **and** over `info->client_info.ctx` — the entire saved register
snapshot. The precise GC-map implementation in `mini-gc.c` is `#if 0`'d out
entirely. **[V]**

**[I] That is almost certainly the real reason Unity/Mono titles run under FEX
and box64 while CoreCLR does not** — and it is the same property that lets Go
survive (§2). Hand SGen a partly-wrong register snapshot and the worst outcome is
some floating garbage pinned. Hand CoreCLR's precise GC the same snapshot and a
bogus value is interpreted as an object reference and relocated.

This matches the single most-repeated field observation, from the FEX
maintainer's own bug tracker **[V]**
([FEX#5766](https://github.com/FEX-Emu/FEX/issues/5766)): *"Mono-based .NET games
work fine on this same setup (e.g. Celeste runs great) while CoreCLR does not."*
FEX has also invested specifically in Mono/Unity compatibility — `MonoHacks`
(default **on**, [PR#4728](https://github.com/FEX-Emu/FEX/pull/4728)), Unity
ringbuffer acquire/release ordering ([PR#4825](https://github.com/FEX-Emu/FEX/pull/4825)),
and notably [PR#2722 "JIT: Implement support for per-instruction RIP
reconstruction"](https://github.com/FEX-Emu/FEX/pull/2722), whose description is
the defect in one sentence: *"FEX's current implementation of RIP reconstruction
is limited to the entrypoint that a single block has. This will cause the RIP to
be incorrect past the first instruction in that block."* It was motivated by
Mono. There is no CoreCLR equivalent of any of it.

### Everything else

BEAM, CPython, CRuby, V8, LuaJIT: cooperative/polling only, no ucontext
rewriting. Searched; **no incidents of this class found** for any of them.
**[V, negative]**

---

## 3. The same bug in other emulators — and the two designs that avoid it

There are exactly two known-correct designs. FEX uses neither.

| | Design | Who | Guarantee | Cost |
|---|---|---|---|---|
| **A** | **Defer the guest signal to a guest-instruction boundary.** Never run the guest handler from the host handler; queue it, force an exit to the dispatch loop, build the guest frame from the emulator's own architectural state. | qemu-user, blink, DynamoRIO (delayable signals) | Always a real, self-consistent guest state. Possibly *late*, never *torn*. | signal latency ≤ block length |
| **B** | **Make every host instruction boundary a legal guest boundary.** Constrain the translator so guest architectural registers are only committed at the end of each guest instruction. | Rosetta 2 (documented), Transmeta CMS (via hardware commit/rollback) | Precise *at* the interruption point. | forbids essentially all inter-instruction optimisation |

### qemu-user — Design A, verified in source

`linux-user/signal.c`'s `host_signal_handler` does not run guest code for async
signals. It records the pending guest signal and kicks the CPU out **[V]**:

```c
k = &ts->sigtab[guest_sig - 1];
k->info = tinfo;  k->pending = guest_sig;
ts->signal_pending = 1;
...
cpu_exit(thread_cpu);
```

The host ucontext is used only to rewind an interrupted safe-syscall and to
block further host signals; it is **never** translated into a guest context.
Delivery happens later from `process_pending_signals()` in the CPU loop, where
`CPUArchState` is coherent. The old QEMU internals doc states it plainly **[V]**:

> Normal and real-time signals are queued along with their information
> (`siginfo_t`) as it is done in the Linux kernel. Then an interrupt request is
> done to the virtual CPU. When it is interrupted, one queued signal is handled
> by generating a stack frame in the virtual CPU as the Linux kernel does.

`restore_sigcontext` in `linux-user/i386/signal.c` reads RIP and all GPRs back
out of the guest frame on `rt_sigreturn`, so **CoreCLR's hijack works exactly as
on bare metal**. QEMU's `cpu_restore_state` / `restore_state_to_opc` side table —
the analogue of FEX's `RestoreRIPFromHostPC` — is used **only for synchronous
faults**, where "RIP = start of instruction, registers = pre-instruction" is the
*correct* answer. That distinction is precisely what FEX is missing. **[V]**
([QEMU TCG internals](https://www.qemu.org/docs/master/devel/tcg.html))

Does .NET actually run under `qemu-x86_64`? **Honest answer: unproven, and
Microsoft says no** — but the failures on record are a different class. Rich
Lander, [dotnet/dotnet-docker#3832](https://github.com/dotnet/dotnet-docker/issues/3832):
".NET isn't supported in QEMU", with the demonstrated failure being
`System.IO.IOException: Function not implemented` out of
`FileSystemWatcher.StartRaisingEvents()` — a **missing inotify syscall**, not
memory corruption. **[V]** Meanwhile CoreCLR is routinely brought up on new
architectures under QEMU with `SIGRTMIN` activation injection active (RISC-V
port: "100% pass rate both on qemu and on StarFive VisionFive2 board",
[dotnet/runtime#84834](https://github.com/dotnet/runtime/issues/84834)), and
FEX's own ZGC report says qemu-user passes the identical reproducer. **[I]**
qemu-user's architecture *cannot* produce our failure mode; whether a given
workload runs end to end is a separate, more tractable syscall-coverage problem.

One footnote that will matter if anyone tries it: qemu-user **remaps guest RT
signals** because the host's own glibc reserves the low ones, and that remapping
has broken Go before ([golang/go#33746](https://github.com/golang/go/issues/33746)).
CoreCLR's `INJECT_ACTIVATION_SIGNAL` is `SIGRTMIN`. **[I]** Expect to have to
verify the remap works before concluding anything.

Useful bisection tool: `qemu-x86_64 -one-insn-per-tb` collapses signal latency
to a single guest instruction. **[V]**

### box64 — same defect as FEX. Verified here, contradicting the folklore.

`getX64Address()` in `src/dynarec/dynablock.c` walks a per-block `instsize[]`
table and returns **the start address of the guest instruction under
translation** — structurally the same answer as FEX's `RestoreRIPFromHostPC`, with
the same soundness problem, and with an inline caveat in `signals.c` that it
"will be incorrect in the case of the callret". box64 keeps x86 registers in
fixed ARM64 registers and materialises the guest sigcontext from live host
state; on return it copies everything back (`GO(RAX) … GO(RIP)`). It *does* have
a `defer_signal()` path, but it gates on `emu->critical_section` — box64's own
re-entrancy sections, not guest-instruction boundaries. **[V]**

Two research agents disagreed about box64: one inferred "same bug", one collected
field reports (Stardew Valley running for hours under box64 vs Barotrauma dying
in 10–40 s under FEX) and recommended a box64 spike as the highest-value
untried experiment.

**We settled it by measurement (§9): box64 0.3.8 fails our repro 17/20, with
byte-identical failure signatures to FEX** (`CORRUPT: tN chunk mismatch …`,
`System.AccessViolationException`). box64 is not an escape hatch. The Stardew
folklore is **[C]** and is probably explained by a much lower GC rate rather than
by box64 being sound.

### Rosetta 2 — Design B, stated as a design goal

dougallj, [Why is Rosetta 2 fast?](https://dougallj.wordpress.com/2022/11/09/why-is-rosetta-2-fast/)
**[V]**:

> To allow for precise exception handling, sampling profiling, and attaching
> debuggers, Rosetta 2 maintains a mapping from translated ARM instructions to
> their original x86 address, and **guarantees that the state will be canonical
> between each instruction**.
>
> There are some tradeoffs to keeping state canonical between each instruction:
> Either all emulated register values must be kept in host registers, or you need
> load or store instructions every time certain registers are used. …
> **This almost entirely prevents inter-instruction optimisations.**

That is the whole answer, and the last sentence is exactly the optimisation FEX
relies on. Rosetta affords the tax because AArch64 has 31 GPRs to x86-64's 16 (so
the entire guest register file lives permanently in host registers), plus
FEAT_FlagM for cheap x86 flags and the M-series TSO bit.

### blink, Hangover, GPTK, Houdini — brief

- **blink** (jart): interpreter + path-stitching JIT; the README states async
  signals are only checked "from the main interpreter loop" — Design A, obtained
  the easy way. No one has tried CoreCLR on it. **[V]**
- **Hangover** dropped its QEMU backend in 11.0 keeping FEX and box64, on
  performance grounds. Notably box64's Wine work was upstreamed as
  **`WowBox64.dll`**, which means box64 implements the Windows CPU-plugin
  contract — including `BTCpuResetToConsistentState` — *on Windows duty* while
  providing no equivalent on Linux. **[V]** Worth reading as a sketch of what a
  Linux-side API could look like. No .NET/Mono Hangover reports found. **[V, negative]**
- **Apple Game Porting Toolkit** is CrossOver/Wine + D3DMetal *on top of*
  Rosetta 2; it inherits Rosetta's guarantee and adds nothing. **[V]**
- **Intel Houdini**: closed, discontinued, ARM-on-x86 (wrong direction), no
  public internals. Total dead end. **[V, negative]**

---

## 4. Rosetta 2: the one time this was fixed properly

[dotnet/runtime#44897 "Support .NET on Apple Silicon with Rosetta 2 emulation"](https://github.com/dotnet/runtime/issues/44897)
is the single most on-point document that exists. Microsoft's runtime team and
Apple's Rosetta lead (zwarich) debugged it together in the issue thread. From
the issue body **[V]**:

> - [x] Rosetta 2 emulation doesn't populate `exceptionState.__trapno` for other
>   kernel entry than hardware exceptions (for example for syscalls). **This means
>   we fail to inject code necessary for garbage collection and sometimes
>   deadlock.** *Edit:* This is at least partially fixed in the macOS 11.2 beta
>   release … It is being investigated at the Apple side.

zwarich, 2020-11-25 **[V]**:

> There might be other issues that I am not aware of, but I have investigated all
> of the ones mentioned here and I believe they can all be addressed in Rosetta.
> **There should be no workarounds required in .NET** (at least on M1, as opposed
> to the DTK).

zwarich, 2020-12-01 **[V]**:

> it should be possible to fix all of these issues, so that both the `__trapno`
> approach and the signals approach work under Rosetta as well as they do
> natively.

zwarich, 2020-12-16 **[V]**:

> All of the issues presented here from .NET 5 should be fixed in the macOS 11.2
> Beta (build 20D5029f) released today. **This includes the
> `exceptionState.__trapno` issue manifesting as GC hangs.**

**What transfers:** the shape of the fix — emulator vendor engages, emulator
gets fixed, runtime changes nothing — and the confirmation that this exact
CoreCLR mechanism is what breaks under emulation. **What does not transfer:**
Rosetta was already architecturally precise (§3), so these were bugs *in* that
machinery. FEX would have to build precision it has never had. **[I]** dougallj's
"almost entirely prevents inter-instruction optimisations" is the price tag, and
it is most of FEX's reason to exist.

Also note the mechanism differs on macOS: CoreCLR there suspends via Mach
`thread_suspend`/`thread_get_state`/`thread_set_state`, not signals — which puts
the precision burden on Rosetta+XNU rather than on a guest signal frame.

---

## 5. Windows on Arm: Microsoft ships our workaround, automatically

This is the most directly load-bearing finding for us, and it is not in any
issue tracker — it is in the runtime source.

[`src/coreclr/vm/threads.cpp`, `Thread::InitializeSpecialUserModeApc`](https://github.com/dotnet/runtime/blob/main/src/coreclr/vm/threads.cpp) **[V]**:

```cpp
#ifdef HOST_AMD64
    IsWow64Process2Proc pfnIsWow64Process2Proc = (IsWow64Process2Proc)GetProcAddress(hKernel32, "IsWow64Process2");
    USHORT processMachine, hostMachine;
    if (pfnIsWow64Process2Proc != nullptr &&
        (*pfnIsWow64Process2Proc)(GetCurrentProcess(), &processMachine, &hostMachine) &&
        (hostMachine == IMAGE_FILE_MACHINE_ARM64) &&
        !IsWindowsVersionOrGreater(10, 0, 26100))
    {
        // Special user-mode APCs are broken on WOW64 processes (x64 running on Arm64 machine)
        // with Windows older than 11.0.26100 (24H2)
        return;
    }
#endif
```

`QueueUserAPC2` with `SpecialUserModeApcWithContextFlags` is the Windows
equivalent of the Unix activation-injection signal: it interrupts a running
thread and hands the runtime the interrupted `CONTEXT`. **CoreCLR detects "I am
x64 emulated on an arm64 host, on a build where that mechanism is broken" and
turns it off**, falling back (`UseContextBasedThreadRedirection()` → true) to
`SuspendThread`/`GetThreadContext` redirection.

The history behind it is [dotnet/runtime#100425](https://github.com/dotnet/runtime/issues/100425):
x64 .NET 9 previews hung on Windows-on-Arm with the main thread parked in
`ThreadSuspend::SuspendRuntime`. janvorli, 2024-05-15 **[V]**:

> Windows developers helped me to investigate the issue. It turns out that it is
> a windows bug that is fixed in 24H2. So, the recommendation is to update
> Windows to this version. We will also add a workaround to runtime that will
> prevent using the Windows API with the bug when running x64 emulated on arm64
> Windows on older Windows versions. But please note that **this workaround may
> have some performance consequences in GC runtime suspension time in case of a
> lot of threads.**

Read that last sentence twice: it is a precise statement of the cost we are
accepting, from the person who wrote the code.

**Microsoft's formal stance on emulation**, from
[dotnet/sdk#17463](https://github.com/dotnet/sdk/issues/17463) **[V]**: Microsoft
is *"not committed to resolving issues that the operating system vendor does not
address in their emulation subsystem. This includes functional, performance, and
security issues."* So there will be no .NET-side fix for FEX. The fix, if it
comes, comes from FEX.

**And ARM64EC is the answer Microsoft actually chose.** Rather than making x64
emulation precise enough for the CLR, Microsoft defined a native Arm64 ABI that
is x64-shaped, so the *runtime* — the part that JITs, walks stacks and suspends
threads — runs native while x64 leaves stay emulated
([Understanding Arm64EC ABI](https://learn.microsoft.com/en-us/windows/arm/arm64ec-abi)).
**[I]** The Linux analogue is "run the arm64 .NET build and emulate only the
genuinely-native x64 leaves", i.e. our Track 2. This is the structural fix, and
every ecosystem that solved this problem for real solved it this way.

Windows also does not let its emulator improvise: the WoW64 CPU-plugin contract
requires `BTCpuResetToConsistentState`, `BTCpuGetContext`/`BTCpuSetContext` and
`BTCpuSuspendLocalThread` ([wbenny, WoW64 internals](https://wbenny.github.io/2018/11/04/wow64-internals.html)),
so `SuspendThread`+`GetThreadContext`+`SetThreadContext` — exactly CoreCLR's
Windows suspension primitives — are routed *through* the emulator. **[V]** How
`xtajit64` implements the rollback is not public. **[V, negative]**

---

## 6. CoreCLR-side knobs: what exists, what is inert

Checked three ways: `clrconfigvalues.h` / `jitconfigvalues.h` source, a string
scan of the **shipping** `libcoreclr.so` / `libclrjit.so` (8.0.30), and the
repro. Anything marked inert below was also measured — see §9.

| knob | exists? | honoured in release? | verdict |
|---|---|---|---|
| `DOTNET_INTERNAL_ThreadSuspendInjection` | **yes** | **yes** — `RETAIL_CONFIG_DWORD_INFO(INTERNAL_ThreadSuspendInjection, W("INTERNAL_ThreadSuspendInjection"), 1, "Specifies whether to inject activations for thread suspension on Unix")`; UTF-16 string present in shipping `libcoreclr.so` | **the fix** |
| `DOTNET_GCHijack` | **no — does not exist** | — | folklore. No `Hijack` string of any kind in `clrconfigvalues.h` or in the shipping binary. Delete it from the vocabulary. |
| `DOTNET_JitFullyInt` | yes in source | **no** — `CONFIG_INTEGER(JitFullyInt, …)` is compiled out unless `DEBUG`; absent from shipping `libclrjit.so` | inert; measured 0/8 |
| `DOTNET_gcConservative` | **yes** | **yes** — `#define FEATURE_CONSERVATIVE_GC 1` is **unconditional** in [`inc/switches.h`](https://github.com/dotnet/runtime/blob/main/src/coreclr/inc/switches.h), and the config is `RETAIL_CONFIG_DWORD_INFO(UNSUPPORTED_gcConservative, W("gcConservative"), 0, …)`. Confirmed live in the shipping `libcoreclr.so`. | live, but **measured 0/8** — see below |
| `DOTNET_gcServer`, `DOTNET_gcConcurrent`, `DOTNET_GCHeapCount`, `DOTNET_GCgen0size` | yes | yes | change GC *frequency*, not the mechanism. Measured 0/8 in every combination. |
| `DOTNET_TieredCompilation=0`, `TieredPGO=0`, `ReadyToRun=0`, `JITMinOpts=1`, `JitDebuggable=1` | yes | yes | no effect. Interruptibility is decided by `fgSetBlockOrder` regardless of opt level (§1d), so none of these change the mechanism. Also reported ineffective in [FEX#5766](https://github.com/FEX-Emu/FEX/issues/5766). |
| `DOTNET_EnableWriteXorExecute=0` | yes | yes | **separately required** to get CoreCLR to start under FEX or box64 at all. Universal in every field report. |
| `DOTNET_EnableDiagnostics=0` | yes | yes | not a fix, but removes three *other* `SuspendEE` callers — `SUSPEND_FOR_DEBUGGER`, `SUSPEND_FOR_PROFILER`, ReJIT. Strictly fewer suspensions. Worth setting. |
| `DOTNET_GCStress` | yes | effectively **no** — the machinery needs `HAVE_GCCOVER`, which `switches.h` defines only for `_DEBUG` | inert, and would *increase* suspensions. Don't. |
| `DOTNET_SuspendDeadlockTimeout` (40000), `SuspendThreadDeadlockTimeoutMs` (2000) | source only | **no** — plain `CONFIG_DWORD_INFO`, debug builds only | **there is no retail suspension timeout.** The `SuspendEE` loop retries forever. This is why §10 item 1 recommends an external watchdog. |
| `DOTNET_GCHijack`, `DOTNET_JitForceFullyInterruptible`, `DOTNET_UseWaitForSingleObjectOnSuspension` | **none of these exist** | — | folklore. Not in `clrconfigvalues.h`, `jitconfigvalues.h`, `gcconfig.h`, `RhConfigValues.h`, or the historical [clr-configuration-knobs.md](https://github.com/dotnet/coreclr/blob/v2.2.0/Documentation/project-docs/clr-configuration-knobs.md). |

**On `gcConservative` specifically** — this looked like the ideal mitigation and
it is worth recording exactly why it is not. It *is* live: `GCToEEInterface::GcScanRoots`
([`vm/gcenv.ee.cpp`](https://github.com/dotnet/runtime/blob/main/src/coreclr/vm/gcenv.ee.cpp))
switches to "treat everything on stack as a pinned interior GC pointer" when it
is set. **[I]** But it addresses only *bogus roots*, and our failure has a second
half: after `HandleSuspensionForInterruptedThread` returns,
`CONTEXTToNativeContext` writes the context back and the thread **resumes from
it**. Pinning conservatively does nothing about resuming a thread with a register
file that never existed. The measurement agrees — 0/8 (§9). Caveats if anyone
retries it in another context: `switches.h` warns it breaks unloadable
assemblies and LCG (i.e. `Reflection.Emit`, collectible `AssemblyLoadContext`),
and Microsoft calls it not-supported-for-production
([dotnet/runtime#61919](https://github.com/dotnet/runtime/issues/61919)).

Two conventions that will waste your afternoon if you get them wrong: on Linux
the env name is matched **case-sensitively** against the `W("...")` string, and
DWORD values are parsed **base 16** unless the knob opts into
`ParseIntegerAsBase10` (the GC size knobs do not). So `DOTNET_GCgen0size=40000000`
means 1 GiB, not 40 MB. **[V]**

**Historical prior art for the knob** — it has been used exactly once before, and
for the same underlying reason. [dotnet/runtime#6220 "CoreCLR runtime doesn't
work on Linux kernel 4.6.x"](https://github.com/dotnet/runtime/issues/6220),
janvorli 2016-06-27 **[V]**:

> It looks like the problem is caused by the thread suspend injection on Unix.
> Disabling it by setting `COMPlus_INTERNAL_ThreadSuspendInjection` environment
> variable to 0 makes the issue go away.

The root cause there was a **broken ucontext round-trip** — a kernel 4.6 change
repurposed padding bits in `sigcontext`, and CoreCLR's
`CONTEXTFromNativeContext`/`CONTEXTToNativeContext` clobbered them. Structurally
identical to ours (the round-trip does not preserve the machine state); different
culprit. Fixed in [dotnet/coreclr#6027](https://github.com/dotnet/coreclr/pull/6027).
This is the canonical "the ucontext round-trip is broken on this host" switch, and
we are using it for its intended purpose.

**NativeAOT is strictly worse, not a way out.** **[V]** It uses the identical
signal (`#define INJECT_ACTIVATION_SIGNAL SIGRTMIN` in
[`nativeaot/Runtime/unix/UnixSignals.h`](https://github.com/dotnet/runtime/blob/main/src/coreclr/nativeaot/Runtime/unix/UnixSignals.h)),
the identical `pthread_kill` in `PalHijack`, and the identical three-way decision
in `Thread::HijackCallback` — including `HijackReturnAddress`, which does
`*ppvRetAddrLocation = pvHijackedAddr;`. And
[`RhConfigValues.h`](https://github.com/dotnet/runtime/blob/main/src/coreclr/nativeaot/Runtime/RhConfigValues.h)
is nine entries long with **no `ThreadSuspendInjection`**: same hazard, no
workaround. (It does have `gcConservative`, and its hijack path already
special-cases it — a mild point in favour of conservative mode being taken
seriously, even though it did not help us.)

**Mono instead of CoreCLR?** Mechanically it exists —
`-p:UseMonoRuntime=true -r linux-x64 --self-contained` pulls
`Microsoft.NETCore.App.Runtime.Mono.linux-x64`, which is published and serviced
through 8.0.30. **[V]** But it requires republishing the whole application, and
BC's service tier is a closed-source Microsoft binary we never recompile. **Not
viable for us** — treat Mono as *evidence about the root cause* (§2), not as a
deployment option. **[I]**

**Forward-looking footnote [V]:** the CoreCLR interpreter (.NET 10+) *forces*
conservative GC — `vm/gcenv.ee.cpp` has
`#ifdef FEATURE_INTERPRETER if (strcmp(privateKey, "gcConservative") == 0) { *value = true; return true; }`.
If an interpreter-only CoreCLR ever becomes viable, "no JIT + conservative GC"
would be the most emulation-tolerant CoreCLR configuration that exists. Not
actionable today.

---

## 7. Field reports: x64 .NET on arm64 via emulation

The decisive axis is **Mono works, CoreCLR does not**, on both emulators.

| target | runtime | emulator | status |
|---|---|---|---|
| Valheim | Unity/**Mono** | box64 | **works** — `BOX64_DYNAREC_BLEEDING_EDGE=0 BIGBLOCK=0 STRONGMEM=2` ([box64#1182](https://github.com/ptitSeb/box64/issues/1182), [Gornius/valheim_box64](https://github.com/Gornius/valheim_box64)) **[C]** |
| 7 Days to Die | Unity/**Mono** | box64 | **works** after disabling EAC **[C]** |
| Celeste | **Mono**/FNA | FEX | **works** — stated in [FEX#5766](https://github.com/FEX-Emu/FEX/issues/5766) **[V]** |
| Palworld | native C++ (UE5) | FEX | **works** — [nitrog0d/palworld-arm64](https://github.com/nitrog0d/palworld-arm64), no .NET **[C]** |
| Stardew Valley + SMAPI | **CoreCLR .NET 6** | box64 | partial — runs 1–2 h then random double SIGSEGV ([box64#3026](https://github.com/ptitSeb/box64/issues/3026)) **[C]** |
| CS2 + CounterStrikeSharp | **CoreCLR .NET 8** | box64 | broken ([box64#2753](https://github.com/ptitSeb/box64/issues/2753)) |
| CS2 + CounterStrikeSharp | **CoreCLR .NET 8** | FEX | broken, differently — SourceHook trampolines never fire ([FEX#5527](https://github.com/FEX-Emu/FEX/issues/5527)) |
| Barotrauma | **CoreCLR .NET 8** | FEX | broken — our reference case ([FEX#5766](https://github.com/FEX-Emu/FEX/issues/5766)) |
| Divinity: Original Sin II | CoreCLR | FEX | crash in `ExecutionManager::getNextJumpStub` ([FEX#4582](https://github.com/FEX-Emu/FEX/issues/4582)) |
| Vintage Story | CoreCLR .NET 7/8 | box64 | never reaches the GC — dies on an OpenSSL symbol ([box64#3243](https://github.com/ptitSeb/box64/issues/3243)) |

FEX maintainer Sonicadvance1, on the Barotrauma report, 2026-07-17 **[V]**:

> Yep. CoreCLR is known broken under FEX. Affects S&Box and Slay the Spire 2 as
> well.

**Why there is so little data:** every open-source x64 .NET server people
actually want on arm64 — Sonarr, Radarr, Lidarr, Prowlarr, Jellyfin, Ombi,
TShock — ships a **native linux-arm64 build**, because .NET cross-compiles
trivially. Nobody emulates them. Searches for Plex / Emby / Tdarr / TeamCity /
Azure DevOps agents / SQL Server under FEX or box64 returned nothing for exactly
this reason. **[V, negative]** SQL Server has no arm64 Linux build at all and
nobody emulates it either — which, note, is why *our* SQL Server track is
unaffected by any of this: it is native code with no signal-coordinated GC.

Searches for "Business Central / Dynamics 365 on ARM64 / Graviton / emulation"
returned **nothing**. We are in genuinely uncharted territory. **[V, negative]**

One real production FEX recipe worth flagging as a **hazard**:
[ayayrom/CS2-Server-ARM-Docker](https://github.com/ayayrom/CS2-Server-ARM-Docker)
ships `"TSOEnabled":"0"` in its `Config.json`. That disables x86 total-store-order
emulation entirely and is an *independent* source of nondeterministic corruption
for any multithreaded CoreCLR workload. This config gets copy-pasted. Verify we
run `TSOEnabled=1` (the default) before attributing anything to signal
precision. **[I]**

---

## 8. Out-of-tree work on FEX and box64

**Short version: there is a four-year-old design issue, no implementation, and
no roadmap.**

[FEX#1682 "Signal Handling"](https://github.com/FEX-Emu/FEX/issues/1682) (skmp,
2022-05-04, still open, labelled `documentation`) is the design document. It
enumerates our defect as category **(c)** and describes today's behaviour in as
many words **[V]**:

> signals can interrupt the translated code in places where we can't recover the
> guest architectural place, due to optimisations

> FEX currently only partially recovers the guest architectural state, store it
> alongside the host architectural state, and **hope the guest code doesn't care
> too much about the contents of the guest state**

and proposes the Design-A fix:

> deferring the signal delivery until we have a fully recoverable guest state,
> and storing metadata that can help us exit from the middle of a block

[FEX#1666 "Deferred signals investigation"](https://github.com/FEX-Emu/FEX/issues/1666)
(open since 2022-04) is the same proposal in checklist form, down to the
implementation sketch (`ldb/stb [ctx-1], #0` plus a guard page). Neither has an
assignee. Sonicadvance1 on #5810, 2026-08-06 **[V]**:

> Yea, known issue atm that FEX isn't async signal safe. I have some plans for
> working around it but haven't gotten there yet.

**PRs that touch signals** (#2493, #2927, #3624, #3926, #4177, #4501, #4974,
#5401, #5703, #5725, #4783, #4891, #5228, #5273) — read the list carefully:
**every one is plumbing for *deferring delivery out of FEX's own unsafe regions*.
None makes the delivered guest context precise.** That is the gap, and it is
unstaffed. **[V]**

Two historical bugs prove the SRA-spill-into-signal-context path is a repeat
offender: [#3252](https://github.com/FEX-Emu/FEX/pull/3252) (fix GPR fill mask in
`FillStaticRegs` — corrupted x86↔AArch64 GPR mapping in signal handlers) and
[#3304](https://github.com/FEX-Emu/FEX/pull/3304) (corruption when spilling SRA
registers). **[V]**

**Knobs that do not exist** (all **[V, negative]**, from
`FEXCore/Source/Interface/Config/Config.json.in` and the generated option list on
this box):

- **No SRA disable.** Removed by [FEX PR#3357](https://github.com/FEX-Emu/FEX/pull/3357)
  "Removes SRA option, it's now permanently enabled" (Jan 2024). There is no
  `FEX_DISABLE_SRA`. Closed lead.
- **No interpreter / non-JIT core.** FEX removed the IR interpreter and the
  x86-64 host JIT in [FEX-2310](https://fex-emu.com/FEX-2310/). There is no
  `FEX_Core=irint`. (Don't be misled by FEX-2608 "removes the deprecated
  FEXInterpreter binary" — that was the binfmt shim, not an IR interpreter.)
- **No `ParanoidTSO`.** Split into `TSOEnabled` / `HalfBarrierTSOEnabled` /
  `VectorTSOEnabled` / `MemcpySetTSOEnabled`. Guides mentioning it are stale.
- **No signal-context-fidelity option of any kind.**

The full option list on this box is: `Multiblock`, `MaxInst` (5000),
`EnableCodeCachingWIP`, `HostFeatures`, `SmallTSCScale`, `HideHybrid`,
`CPUFeatureRegisters`, `RootFS`, `Thunk*`, `Env`/`HostEnv`, `DisableL2Cache`,
`DynamicL1Cache`, `SingleStep`, `GdbServer`, `DumpIR`, `O0`, `*JITNaming`,
`SMCChecks`, `TSOEnabled`, `VectorTSOEnabled`, `MemcpySetTSOEnabled`,
`HalfBarrierTSOEnabled`, `StrictInProcessSplitLocks`,
`KernelUnalignedAtomicBackpatching`, `VolatileMetadata`, `X87ReducedPrecision`,
`HideHypervisorBit`, `MonoHacks`, `NeedsSeccomp`, `ExtendedVolatileMetadata`.
Env-var form is `FEX_` + the key uppercased. **[V]**

**Per-app profiles.** FEX's `Data/AppConfig/` ships only `client.json` and
`steamwebhelper.json`; box64's `system/box64.box64rc` has hundreds of game
entries and auto-detects Mono (`BOX64_DYNAREC_BLEEDING_EDGE`), Unity and the JVM
(`BOX64_JVM` → `BIGBLOCK=0 STRONGMEM=1 SSE42=0`) — but **neither ships a
dotnet/CoreCLR profile**. **[V]** That makes "add a CoreCLR AppConfig profile" a
well-shaped upstream request in a form both projects already accept.

**Distro packaging:** no downstream signal patches found. The real out-of-tree
effort in this space is Fedora Asahi's **muvm/libkrun** — a microVM providing a
4 KB-page guest kernel because FEX needs 4 K and Apple Silicon is 16 K. Not our
problem (this box is already 4 K). Fedora's `fex-emu.spec` could not be read
(`src.fedoraproject.org` returns 403 behind an anti-scraper challenge), so "no
Fedora patches" is **[C]**, not verified.

**One process note.** Our upstream issues carry the `ml-report` label, which FEX
triage appears to apply to AI-assisted reports. #5810 has one maintainer reply;
#5813 has none. Bear that in mind when judging upstream responsiveness, and note
that FEX's `CONTRIBUTING.md` forbids AI-authored code contributions — see the
"Do not send this upstream" section of
[FEX-FIX-FEASIBILITY.md](FEX-FIX-FEASIBILITY.md).

---

## 9. Measurements taken on this box today

All on the same Qualcomm Oryon / Ubuntu 26.04 / 4 K-page host, same repro
(`repro compute 3000 12` — 12 threads of integer arithmetic + one thread looping
`GC.Collect()`), same .NET 8 x64 self-contained publish. FEX runs are the
packaged FEX 2608 in a `debian:12-slim` amd64 container; box64 runs are
box64 0.3.8 (Ubuntu `box64_0.3.8+dfsg-1_arm64.deb`) invoked natively on the host
against the same binary. Scripts in the session scratchpad
(`fexrepro/matrix3.sh`, `fexrepro/box64host.sh`, `fexrepro/run3.sh`).

### FEX — knobs not previously tried

| configuration | pass | note |
|---|---|---|
| baseline | **0/8** | control, reproduces the known 0/20 |
| `DOTNET_INTERNAL_ThreadSuspendInjection=0` | **8/8** | control, reproduces the known 20/20 |
| `DOTNET_gcConservative=1` | 0/8 | knob is **live** (§6) — conservative root scanning does not help, because the corrupted *resume* is untouched |
| `DOTNET_JitFullyInt=1` | 0/8 | knob is inert — `CONFIG_INTEGER`, DEBUG-only |
| `DOTNET_gcServer=1 DOTNET_GCHeapCount=1` | 0/8 | |
| `DOTNET_gcConcurrent=0 DOTNET_gcServer=0` | 0/8 | the HotSpot "try a less concurrent GC" lead does **not** transfer |
| `FEX_GDBSERVER=1` | 0/8 | see below |
| **`DOTNET_INTERNAL_ThreadSuspendInjection=0` + `DOTNET_gcServer=1`** | **8/8** | **the config we actually ship** (the entrypoint sets `gcServer=1`) |

`FEX_GDBSERVER=1` is worth a note: setting it flips
`Config.NeedsPendingInterruptFaultCheck` on
(`FEXCore/Source/Interface/Core/Core.cpp`), which makes the JIT emit the
block-entry pending-interrupt check — the same mechanism the custom prototype in
[FEX-FIX-FEASIBILITY.md](FEX-FIX-FEASIBILITY.md) enabled. It reproduces that
prototype's null result **without a custom build**, from a stock FEX. Anyone
re-testing that hypothesis should use this instead of building FEX.

### box64 — the emulator-swap hypothesis, settled

| configuration | result |
|---|---|
| box64, baseline | **pass=3 fail=15 hang=2** (n=20) |
| box64, `DOTNET_INTERNAL_ThreadSuspendInjection=0` | **pass=10 fail=0 hang=0** (n=10) |

Failure signatures are the same as under FEX: `CORRUPT: t7 chunk mismatch
cb9371003f831903 != 368`, `Fatal error. System.AccessViolationException`, plus
SIGABRT and two hangs. `DOTNET_EnableWriteXorExecute=0` was required to get
CoreCLR to start at all, matching every field report.

**Two conclusions.** (1) box64 has the same defect; swapping emulators is not a
route out. (2) The mitigation is **emulator-independent** — it fixes the runtime's
dependency on precise contexts, not any one emulator's bug. That is the strongest
argument that `ThreadSuspendInjection=0` is the durable answer rather than a
FEX-specific hack.

A host-native FEX control was run for shape parity (same binary, a minimal
hand-built x86-64 rootfs of just `ld-linux`, libc, libstdc++, libgcc_s):
**pass=0 fail=1 hang=9** (n=10). It confirms FEX fails in the host-native shape
too, so the box64 result is not an artefact of container-vs-host. But the
dominant mode there is *hang*, not the crash we see in the container, which most
likely reflects the stripped rootfs rather than anything about signals —
**treat this control as confirmation of direction, not as a clean A/B.**

**Caveats, stated plainly.** The box64 runs are host-native (box64 wrapping the
host's arm64 libc) while the primary FEX runs are containerised with a full x86
userland — different shapes, so the 3/20-vs-0/20 gap should not be read as
"box64 is slightly better". What the numbers *do* establish, unambiguously, is
that box64 produces the same corruption, with the same signatures, and that the
CoreCLR-side mitigation fixes it there too. n is small (8–20 per cell): enough to
separate 0-ish from 100%, not enough to detect a partial improvement.

**Reproducing.** Everything lives in the session scratchpad, which is tmpfs and
will not survive a reboot: `fexrepro/run3.sh` (FEX-in-container runner with a
kill timeout), `fexrepro/matrix3.sh` (the knob matrix), `fexrepro/box64host.sh`
and `fexrepro/fexhost.sh` (host-native runners), `x64libs/` + `x64rootfs/` (the
minimal x86-64 userland extracted from the `debian:12-slim` amd64 image). The
`repro` binary is the same one used in
[FEX-UPSTREAM-REPORT.md](FEX-UPSTREAM-REPORT.md).

---

## 10. What transfers to us — ranked list of things to try

Everything above collapses into a short list. Items 1–2 are what we should
actually do; 3–5 are cheap experiments worth running for evidence; 6–7 are the
long game.

**1. Keep `DOTNET_INTERNAL_ThreadSuspendInjection=0`, and treat it as permanent.**
Not a stopgap. It is a `RETAIL` knob (§6), it is what Microsoft's own runtime
does automatically for x64-on-arm64 Windows (§5), it is the CoreCLR spelling of
the workaround Go has shipped for six years (§2), and it works under both
emulators we have tested (§9). Set it alongside the already-mandatory
`DOTNET_EnableWriteXorExecute=0`.

*What to watch, and be precise about it:* the fallback is **not** "GC polls
everywhere" — §1d shows RyuJIT answers a call-free loop by making the method
fully interruptible with *no* poll sites, and there is **no retail suspension
timeout**. So the risk is specifically: one hot managed loop with no calls, no
allocations and no blocking, and `SuspendEE` waits for it indefinitely.
janvorli's warning about the analogous Windows workaround — *"may have some
performance consequences in GC runtime suspension time in case of a lot of
threads"* — is the thing to measure. **[I]** A BC-class workload is call-,
allocation- and I/O-dense, so threads cross the coop/preemptive boundary
constantly and this converges in practice; the exposure is a single unlucky
codepath, not a general fragility. Ship it with a watchdog rather than hope:
monitor the EventPipe/ETW `GCSuspendEEBegin`→`GCSuspendEEEnd` interval and alarm
past a few hundred ms. That converts an unbounded freeze into a diagnosable
event. Also set `DOTNET_EnableDiagnostics=0` to remove the debugger/profiler/ReJIT
suspension sources entirely.

**2. Verify `FEX_TSOENABLED` is 1 (the default) everywhere, before anything else.**
A widely copy-pasted community FEX config sets it to 0 (§7). If any of that has
crept into our configs we have two independent corruption sources and can
attribute nothing. Cheap; do it first.

**3. Measure the cost of item 1 on the real workload.** Run the BCApps / Bucket 4
sweeps from `PipelinePerformanceComparison` with and without the knob and compare
wall clock and GC pause distribution. This is the only number that decides
whether the mitigation is deployable at BC's thread counts, and nobody anywhere
has published it — Go's ecosystem never measured `asyncpreemptoff=1`'s cost
either.

**4. Try qemu-user as a correctness oracle** (not as a deployment target).
`qemu-x86_64` is the one emulator whose architecture provably cannot produce this
failure (§3), and FEX's own ZGC report shows it passing the analogous Java
reproducer. If our repro passes 20/20 under `qemu-x86_64` *with injection
enabled*, that closes the causal argument completely and is a strong artefact to
attach to the FEX issue. Expect two obstacles: qemu-user's RT-signal remapping
versus CoreCLR's `SIGRTMIN`, and missing syscalls (inotify is the documented one).
`-one-insn-per-tb` is available if latency needs bounding. **Do not** consider
qemu-user for production — it is several times slower than FEX.

**5. `FEX_MULTIBLOCK=0 FEX_MAXINST=1` as a diagnostic.** **[I]** One guest
instruction per block makes every block entry an instruction boundary. If
corruption frequency drops sharply, that is direct evidence for the imprecision
hypothesis and a concrete artefact for upstream. Expect a severe slowdown; this
is a measurement, not a config. Note the block-entry interrupt check itself is
separately testable via `FEX_GDBSERVER=1` and did *not* help (§9), so temper
expectations.

**6. Upstream, framed as a profile rather than a bug.** Both FEX and box64
already have per-application config mechanisms with auto-detection for Mono,
Unity and the JVM, and neither has a CoreCLR entry (§8). "Ship a dotnet
AppConfig profile" is a shape maintainers accept, and whatever mitigation lands
has a natural home. Cross-link #5810 to the existing taxonomy — #1682(c), #1666,
#4131, #5766, #5813 — rather than leaving it as a fresh report. Do not offer
code (see §8).

**7. The structural fix is Track 2, and every ecosystem that solved this for real
solved it this way.** Microsoft's answer to x64-on-arm64 was ARM64EC: port the
runtime, emulate the leaves (§5). Vintage Story shipped an official arm64 server
build. TShock dropped Mono for native arm64. The one project that *stayed*
emulated — Go — has simply disabled the feature for six years. Native arm64 NST
remains the primary route; FEX stays for genuinely-native x64 workloads (SQL
Server, `alc`) which do not use signal-coordinated GC and are unaffected by any
of this.

**Explicitly not worth trying**, all measured or source-verified inert:
`DOTNET_GCHijack` / `DOTNET_JitForceFullyInterruptible` /
`DOTNET_UseWaitForSingleObjectOnSuspension` (none exist), `DOTNET_JitFullyInt`
(debug-only, and would be counterproductive — fully interruptible code is the
case that *needs* async interruption), `DOTNET_gcConservative` (live but measured
0/8, and does not address the corrupted resume), `DOTNET_GCStress` (needs a
checked build), GC-frequency tuning of any kind, tiered-compilation and MinOpts
knobs, NativeAOT (same signal, no knob), disabling SRA in FEX (no such option
since 2024), a FEX interpreter mode (removed in 2023), and switching to box64.

---

## 11. Dead ends

Recorded so nobody re-runs them.

| searched | result |
|---|---|
| `repo:dotnet/runtime box64 OR "FEX-Emu"` | **0 hits.** Nobody has ever reported an emulator/CoreCLR interaction to Microsoft. |
| `"ThreadSuspendInjection"` + emulation terms | 0 hits. The knob has *zero* prior use as an emulation workaround; its only prior art is the 2016 kernel-4.6 case (§6). We appear to be first. |
| `DOTNET_GCHijack` | The variable does not exist. Pure folklore. |
| `"Business Central" / Dynamics 365` + ARM64 / Graviton / emulation | Nothing, in either direction. Uncharted. |
| box64 + `asyncpreemptoff` | 0 hits in `ptitSeb/box64`. No Go async-preemption discussion exists there at all. |
| Go runtime emulation auto-detection | Does not exist, never proposed. |
| JVM flags to disable signal-based safepoints | Do not exist. `UseMembar` and `ThreadLocalHandshakes` were removed and were about other things. |
| Any vendor "run the JVM/CLR under emulation with these flags" recipe | None from Oracle, Red Hat, Adoptium or Microsoft. Only game-server community folklore. |
| A clean "x64 CoreCLR works under `qemu-x86_64` on arm64" report | Not found. Best proxy is FEX#5813's ZGC control. Hence item 4 above. |
| CoreCLR under `rr` | Searching `rr-debugger/rr` for `dotnet`/`coreclr` returns essentially nothing (3 hits, all an unrelated Wine file-copy bug). No published recipe. **[I]** rr is not a useful precedent anyway — it delivers signals at precise, deterministic instruction boundaries, so CoreCLR's context rewriting is never stressed. (rr's documented *Mono* trouble, [rr#2294](https://github.com/rr-debugger/rr/issues/2294), is a SIGPWR signal-number collision — a different problem.) |
| CoreCLR under valgrind | Works, and the recipe is unrelated to suspension: janvorli, [dotnet/runtime#76986](https://github.com/dotnet/runtime/issues/76986) — `DOTNET_GCHeapHardLimit=C800000` plus `valgrind --undef-value-errors=no`. That knob is about address-space reservation. **[I]** Valgrind serialises threads and synthesises a faithful ucontext, so hijacking works there. No transferable lesson. |
| Rosetta-for-Linux `ucontext` construction internals | No public reverse-engineering exists. Only syscall/cpuinfo spoofing is documented. |
| `xtajit64`'s `BTCpuResetToConsistentState` implementation | API surface is public; the mechanism is not. `emulators.com` (Darek Mihocka's ARM64 boot camp, the likeliest source) was unreachable — worth a manual retry. |
| Hangover issues about .NET/Mono GC corruption | None. |
| blink + CoreCLR | Nobody has tried. |
| Intel Houdini internals | Closed, discontinued, wrong direction. Drop it. |
| Plex / Sonarr / Radarr / Jellyfin / TeamCity / SQL Server under FEX or box64 | Nothing — they all ship native arm64, so nobody emulates them. |
| box86.org compatibility list | JS-rendered; static fetch returns a loading stub. Not enumerable. |
| Fedora `fex-emu.spec` | `src.fedoraproject.org` 403 (anti-scraper). "No downstream patches" is unverified for Fedora. |

---

## 12. The literature

This is a solved problem in the DBT literature and the solution space is small.
Naming it correctly is useful when talking to emulator maintainers.

- Dehnert et al., **"The Transmeta Code Morphing Software"**, CGO 2003 —
  [PDF](https://safari.ethz.ch/digitaltechnik/spring2018/lib/exe/fetch.php?media=dehnert_transmeta_code_morphing_software.pdf).
  Shadow registers + gated store buffer + commit/rollback at guest-instruction
  boundaries, plus adaptive de-optimisation to interpretation when a translation
  faults repeatedly. The hardware-assisted version of Design B.
- Gschwind & Altman, **"Precise Exception Semantics in Dynamic Compilation"**,
  CC 2002 — [Springer](https://link.springer.com/chapter/10.1007/3-540-45937-5_9).
  The canonical statement of the problem.
- Ebcioğlu & Altman, **"DAISY: Dynamic Compilation for 100% Architectural
  Compatibility"**, ISCA 1997.
- Baraz et al., **"IA-32 Execution Layer"**, MICRO-36 2003 —
  [IEEE](https://ieeexplore.ieee.org/document/1253195/). Two-phase
  interpret-then-optimise, with precise exceptions as a headline challenge.
- Bala, Duesterwald & Banerjia, **"Dynamo"**, PLDI 2000.
- **DynamoRIO's Code Manipulation API** —
  [dynamorio.org/API_BT.html](https://dynamorio.org/API_BT.html). The most
  complete *public* engineering treatment: store-vs-recompute translations
  (`DR_EMIT_STORE_TRANSLATIONS`), `dr_register_restore_state_ex_event()` for
  un-doing register spills and rebuilding condition codes, and the
  delayable-vs-non-delayable signal split
  ([`dr_siginfo_t`](https://dynamorio.org/struct__dr__siginfo__t.html)). If FEX
  ever implements this, it will look like this.
- Patent literature on the deferral design, worth knowing exists:
  [US8473930](https://patents.google.com/patent/US8473930B2/en) (handling signals
  and exceptions in a dynamic translation environment — queue and check at a safe
  point), [US8296551](https://patents.google.com/patent/US8296551),
  [US7065750](https://patents.google.com/patent/US7065750B2/en). The technique
  itself is ~1997 prior art.
