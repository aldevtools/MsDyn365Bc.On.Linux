# Can we fix FEX ourselves? — feasibility study of the CoreCLR-under-FEX defect

Measured 2026-08-12 on the same Qualcomm Oryon / Ubuntu 26.04 / 4 K-page host as
[FEX-UPSTREAM-REPORT.md](FEX-UPSTREAM-REPORT.md). Everything below was run here;
where something was *not* run, it says so.

**Verdict: architectural. Not hours, not days — weeks, and it is JIT work, not
signal-plumbing work.** A prototype of the most plausible small fix was written,
built and measured. It changed nothing: `0/10` before, `0/8` after (batch cut
short, see [Measurements](#measurements)). The instrumentation explains why, and
that explanation is the most useful result in this document.

---

## Summary of findings

1. **FEX already does the obvious things.** It reads the guest's edits to the
   signal `ucontext` back on `rt_sigreturn` — *all* GPRs, XMM, EFLAGS and RIP —
   and it can resume at an **arbitrary guest RIP** by bouncing through the top of
   the dispatcher. The feared killer ("FEX can only re-enter a translated block at
   its entry point") **is not the problem**: `RestoreFrame_x64` sets
   `Frame->State.rip` to whatever the guest wrote and jumps to
   `AbsoluteLoopTopAddressFillSRA`, which looks up or compiles a block for that
   RIP. So defect class (i)/(ii)/(iii) from the task framing are all wrong.

2. **The defect is on the capture side, and it is a precision defect.** When an
   async signal arrives, the host PC is at an arbitrary point *inside* the
   translation of a guest instruction. FEX reconstructs the guest RIP by walking a
   per-block table that maps host-PC offsets to guest-RIP offsets, and its own
   comment says this is *"as close as FEX can get"* — it yields the **start of the
   guest instruction being translated**, while the statically-allocated registers
   (SRA) already hold **partially applied results of that same instruction**. The
   context handed to the guest therefore describes a machine state that never
   existed. A guest that only reads it (a crash reporter) is fine. A guest that
   *resumes from it* — CoreCLR activation injection, Go async preemption, ZGC —
   is not, and a moving GC that scans those registers as roots is the worst
   possible consumer.

3. **Upstream's model for fixing this is already in the tree — for Windows.**
   Both the WOW64 and ARM64EC backends interrupt guest threads **only at block
   entries**, via a pending-interrupt check the JIT emits, and the WOW64 code says
   so in as many words: *"Since interrupts only happen at the start of blocks, the
   reconstructed state should be entirely accurate."* On Linux that check is
   compiled out unless the gdbserver is enabled.

4. **So the prototype wrote itself**: turn the block-entry check on for Linux and
   route async signals that arrive inside a JIT code buffer through FEX's existing
   deferred-signal queue, so they are delivered at the next block entry. ~15 lines.
   It builds, it demonstrably fires — and the repro still dies at the same rate.

5. **Instrumentation says why: only a third of the injections arrive in JIT code
   at all.** Classifying every `SIGRTMIN` (signal 34) in one failing run by where
   the host PC was:

   | arrival site | count | share | covered by the prototype? |
   |---|---|---|---|
   | inside a JIT code buffer | 11 | 34 % | yes |
   | inside FEX's dispatcher | 3 | 9 % | no — FEX's own comment: *"Signals in dispatcher have unsynchronized context"* |
   | while in a guest syscall (`InSyscallInfo != 0`) | 4 | 13 % | no |
   | elsewhere in FEX host code (JIT compiler, thunks, allocator, signal machinery) | 14 | 44 % | no |

   Making the JIT case precise fixes at most a third of the events, and one bad
   suspension out of ~30 is enough to corrupt the heap. A real fix has to make
   **every** async-signal delivery point precise, which means the whole runtime —
   dispatcher, syscall thunks, compiler — has to be able to name a guest state.
   That is the "not async signal safe" the maintainer is referring to in #5810,
   and it is a much bigger job than a signal-frame patch.

---

## File:line map

Clone: `github.com/FEX-Emu/FEX` at `adea3e410f85` (2026-08-10, `main`, 34+ commits
past the `FEX-2608` the PPA ships), in
`<scratchpad>/FEX` (see [Where things are](#where-things-are)).

### (a) Where the guest context is synthesised from FEX's internal CPU state

| what | where |
|---|---|
| Async/sync signal entry for a guest-handled signal | `Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp:592` `HandleGuestSignal` |
| Builds the frame, spills SRA, switches the guest to the handler | `SignalDelegator.cpp:284` `HandleDispatcherGuestSignal` |
| **RIP reconstruction from the host PC** (the defect) | `SignalDelegator.cpp:106-137` `SpillSRA` → `SignalDelegator.cpp:108` calls `CTX->RestoreRIPFromHostPC` |
| The reconstruction itself, and the admission of its limits | `FEXCore/Source/Interface/Core/Core.cpp:139-173`, comment at `:146-147` *"This is currently as close as FEX can get RIP reconstructions."* |
| The host-PC→guest-RIP table this walks, emitted per block | `FEXCore/Source/Interface/Core/JIT/JIT.cpp:1019-1056`; markers pushed at `JIT.cpp:939` (block entry) and `FEXCore/Source/Interface/Core/JIT/MiscOps.cpp:41-46` (`DEF_OP(GuestOpcode)`, per guest instruction) |
| `OriginalRIP` recorded for the later comparison | `SignalDelegator.cpp:358` |
| x86-64 frame construction: RIP, EFLAGS, all GPRs, x87/XMM | `Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp:365-521` (`RIP` at `:422`, GPRs `:450-467`, XMM `:478-482`) |
| ia32 / rt-ia32 equivalents | `GuestFramesManagement.cpp:523-652`, `:654-854` |
| Admission that a faulting RIP can't be given honestly in `si_addr` | `GuestFramesManagement.cpp:432`, `:797` |

### (b) Where guest-visible edits are read back on sigreturn

| what | where |
|---|---|
| `rt_sigreturn` trampoline lands as SIGILL | `SignalDelegator.cpp:406-437` `HandleSIGILL` |
| Restores host context, then the guest frame | `SignalDelegator.cpp:182-282` `RestoreThreadState` |
| **Read-back of the guest's edits** | `GuestFramesManagement.cpp:125-206` `RestoreFrame_x64` |
| Guard: read-back happens **only if the guest changed RIP** (or a fault was synthesised) | `GuestFramesManagement.cpp:131` |
| Resume at an arbitrary guest RIP — dispatcher-top bounce | `GuestFramesManagement.cpp:136-143` (`SetPc(AbsoluteLoopTopAddressFillSRA)`, `Frame->State.rip = <guest's RIP>`) |
| All GPRs / XMM / EFLAGS copied back | `GuestFramesManagement.cpp:147-204` |
| Explicit "we can't do this properly" note for the in-JIT case | `SignalDelegator.cpp:263-270` — *"XXX: Unsupported since it needs state reconstruction … might result in tearing without real state reconstruction"* |

Two smaller defects visible in that code, both real but neither is the CoreCLR bug:

- **Register-only edits are silently dropped.** `GuestFramesManagement.cpp:131`
  only reads the frame back when RIP changed. A handler that fixes up, say, `RAX`
  and returns normally has its edit discarded. CoreCLR always changes RIP when it
  hijacks, so this is not what bites us; it would bite a Windows-style
  "fix up the context and continue" handler.
- **AVX upper halves are not spilled on SVE256 hosts**, `SignalDelegator.cpp:119-125`
  (`// TODO: This doesn't save the upper 128-bits`). Not applicable to this host.

### (c) The mechanism upstream already uses to make interruption precise

| what | where |
|---|---|
| JIT emits the pending-interrupt check | `FEXCore/Source/Interface/Core/JIT/JIT.cpp:767-781` `EmitSuspendInterruptCheck`, called from block entry (`JIT.cpp:815` via `EmitEntryPoint`) and loop back-edges (`JIT.cpp:918`, `:974`) |
| Gate — off on Linux unless gdbserver | `FEXCore/Source/Interface/Core/Core.cpp:356-364` (`NeedsPendingInterruptFaultCheck`) |
| Windows WOW64 consumer, and the design statement | `Source/Windows/WOW64/Module.cpp:393-415`, comment at `:403` |
| ARM64EC equivalent (suspend doorbell + `brk`) | `Source/Windows/ARM64EC/Module.cpp:727-`, JIT side `JIT.cpp:783-790` |
| Linux deferred-signal queue that the prototype reuses | `SignalDelegator.cpp:598-666`, design doc `docs/DeferredSignals.md` |

---

## Building FEX on this host

**Nothing needed for a build was installed** — no `cmake`, no `ninja`, no C++
compiler. Rather than ask for root, the build was done **inside an `ubuntu:24.04`
aarch64 container** (native, not emulated), which needs no host privileges and
produces a binary that runs fine against this host's newer glibc.

If you would rather build on the host directly:

```bash
sudo apt install -y cmake ninja-build clang clang-tools lld python3 python3-setuptools git pkg-config libc6-dev
```

`clang-tools` is not optional and its absence is a confusing failure: FEX's
bundled `fmt` uses C++20 module dependency scanning, and without
`clang-scan-deps` the build dies with
`"CMAKE_CXX_COMPILER_CLANG_SCAN_DEPS-NOTFOUND": not found`. On Ubuntu 24.04 the
package installs only `/usr/bin/clang-scan-deps-18`, so a symlink to
`/usr/bin/clang-scan-deps` is also required before configuring (CMake caches the
NOTFOUND, so fix it *before* the first `cmake -S`).

Configure used here (LTO and FEXConfig off; FEXConfig would pull in Qt):

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DUSE_LINKER=lld \
  -DENABLE_LTO=False -DENABLE_CCACHE=False -DENABLE_ASSERTIONS=False \
  -DBUILD_FEXCONFIG=False -DBUILD_TESTING=False -DBUILD_THUNKS=False
cmake --build build -j12
```

**Build time on this box: ~4 minutes** for a clean 344-target Release build,
~40 s for an incremental relink after touching `SignalDelegator.cpp`. It is not
the 10-30 minute job the task assumed.

### The trap that invalidated the first round of measurements

`binfmt_misc` is registered with flags `POCF`. The **`F` flag** ("fix binary")
makes the kernel hold an open fd to `/usr/bin/FEX` *as it was at registration
time*. Bind-mounting a different FEX over `/usr/bin/FEX` inside the container
therefore **does nothing** — every "self-built FEX" run silently used the PPA's
2608. This was caught only because tracing instrumentation compiled into the new
binary produced no output at all.

The fix, since we have no root to re-register binfmt: **invoke the interpreter
explicitly** —

```bash
docker run ... debian:12-slim /usr/bin/FEX /app/repro compute 3000 12
```

Anyone testing a locally built FEX on this host must do the same, or they will be
measuring the packaged build. (`<scratchpad>/fexrepro/runbuilt.sh` does.)

---

## The prototype patch

Saved at `<scratchpad>/fex-precise-async-signals.patch` (125 lines including the
tracing instrumentation, which is roughly half of it). Two functional hunks:

**1. `FEXCore/Source/Interface/Core/Core.cpp` (`InitCore`)** — enable the
block-entry pending-interrupt check on Linux when
`FEX_PRECISE_ASYNC_SIGNALS` is set, exactly as WOW64 does unconditionally:

```cpp
#ifndef _WIN32
  {
    const char* Env = getenv("FEX_PRECISE_ASYNC_SIGNALS");
    if (Env && Env[0] != '0') {
      Config.NeedsPendingInterruptFaultCheck = true;
    }
  }
#endif
```

**2. `Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator.cpp`
(`HandleGuestSignal`)** — extend the deferral condition from "FEX is in an
uninterruptible section" to "…or the thread is executing inside a JIT code
buffer", so the signal is queued and delivered at the next block entry:

```cpp
  } else if (const bool DeferForPrecision =
               !MustDeferSignal && PreciseAsyncSignalsEnabled() &&
               CTX->IsAddressInCodeBuffer(Thread, ArchHelpers::Context::GetPc(UContext));
             IsAsyncSignal(&SigInfo, Signal) && (MustDeferSignal || DeferForPrecision)) {
```

Everything downstream — queueing the `siginfo_t`, `mprotect`ing the interrupt
fault page to `PROT_NONE`, the SIGSEGV at the next check, popping the frame,
re-arming on `rt_sigreturn` — is FEX's existing machinery, unmodified.

The knob is deliberately env-gated so the *same binary* is the control: with
`FEX_PRECISE_ASYNC_SIGNALS=0` the JIT emits no check and the deferral never
triggers, i.e. stock behaviour.

### Measurements

`/app/repro compute 3000 12`, self-built `main` invoked explicitly (not via
binfmt), `--ulimit core=0`, one container per run.

| configuration | pass |
|---|---|
| self-built `main`, knob off (= stock behaviour) | **0/10** |
| self-built `main`, knob on (deferral active) | **0/8** — batch stopped after run 8; all 8 were the same bare SIGSEGV |
| PPA FEX 2608 via binfmt, same repro (earlier, FEX-UPSTREAM-REPORT.md) | 0/20 |
| `spin 1000 4` (control workload, no GC), knob on | 2/2 |

The knob-on batch was cut off because two runs hung past the 60 s cap rather than
crashing, and a `timeout` on `docker run` does not kill the container — worth
knowing, but with 8 identical failures the pass rate is not in doubt.

**Proof the mechanism was actually running** (single traced run, knob on):
27 async signals took the new deferral path, 57 deferred-signal deliveries fired
at interrupt checks. So the patch is not inert; it simply does not fix the bug,
for the reason in the table at the top: two thirds of the activation injections
never arrive in JIT code at all.

Honest caveat: N=8-10 per cell is enough to say "no improvement" against a 0/20
baseline. It is not enough to detect a small partial improvement, and no attempt
was made to measure one.

---

## What a real fix would have to do

In rough order of how much of the problem each covers:

1. **Make every async-signal delivery point precise, not just the JIT ones.**
   Signals landing in the dispatcher, in the syscall thunk, and in the JIT
   compiler all need a defined guest state — either by deferring them the same
   way (needs a safe place to redeliver, and a guarantee it is reached, which a
   blocking guest syscall breaks) or by making those regions able to reconstruct
   state on demand.
2. **Deal with the delivery point that isn't a block start.** The interrupt check
   is also emitted on loop back-edges (`JIT.cpp:918`, `:974`), where the
   reconstructed RIP is the *last instruction of the block*, not the branch
   target. For the common case (a back-edge that is a plain conditional jump) a
   re-execution is idempotent and harmless; for `loop`, `jrcxz` or a `rep` tail it
   is not. Upstream's Windows path appears to have the same hazard.
3. **Avoid the deadlock the deferral introduces.** If a signal is deferred and the
   thread then blocks in a guest syscall, nothing delivers it and the syscall is
   not interrupted. CoreCLR retries suspension, so this may self-heal; Go's
   preemption might not. Two of the knob-on runs hanging instead of crashing is
   consistent with this and was not investigated.
4. **Decide what `RestoreFrame_x64:131` should do about register-only edits.**
   Reading them back unconditionally is wrong today (the host context is resumed
   verbatim, so SRA would tear); getting it right needs the same state
   reconstruction as everything above.

Point 1 is the whole job, and it is spread across the JIT, the dispatcher and the
syscall layer. Calling it weeks of work for someone who already knows FEX is, if
anything, optimistic — and it is exactly what the maintainer means by *"I have
some plans for working around it but haven't gotten there yet"*.

## Do not send this upstream

FEX's `CONTRIBUTING.md` is one line: *"No AI/ML/LLM/etc code contributions."*
`AGENTS.md` and `CLAUDE.md` in the FEX tree repeat it. **The patch above was
written by an LLM and must not be offered to them**, in a PR or pasted into an
issue. What is legitimately useful upstream is the *measurement* in the table at
the top of this document — where the 32 injections actually land — because it
bounds how much a block-entry-only fix can ever buy. If that is shared, it should
be re-derived and written up by a human.

## What this means for the arm64 track

`ARM64-BATTLEPLAN.md` Track 1d ("patch FEX ourselves — days; out of scope for a
PoC unless the fix is small") can now be closed: **the fix is not small.** The
plan's own exit condition applies — Track 2 (native arm64 NST) stays the primary
route, with FEX kept for SQL Server and possibly `alc`, both of which are
native-code workloads that do not use signal-coordinated GC and are not affected
by any of this.

## Where things are

Everything lives in the session scratchpad
(`/tmp/claude-1000/-home-sshadows-bc/be83ad9e-.../scratchpad/`), which is tmpfs
and **will not survive a reboot**. Nothing was written outside it except this
file.

| path | what |
|---|---|
| `FEX/` | shallow clone of `main` @ `adea3e410f85`, with the prototype applied |
| `FEX/build-vanilla/Bin/` | unpatched build |
| `FEX/build-patched/Bin/` | prototype build (knob + tracing) |
| `FEX/buildfex.sh` | the in-container build script |
| `fex-precise-async-signals.patch` | the diff |
| `fexrepro/runbuilt.sh` | repro runner against a locally built FEX (explicit interpreter invocation) |
| `fexrepro/trace1.sh` | single traced run, prints the signal histogram |
| `build-*.log` | build logs |

## What was not done

- No attempt to make the non-JIT arrival sites precise — that is the actual fix
  and it was out of scope for a feasibility probe.
- No perf measurement of the extra block-entry store.
- The two hanging knob-on runs were not diagnosed.
- No `main`-vs-2608 comparison beyond this repro; `main` was only ever exercised
  through it.
- The FEX unit/regression suites were never run, so the prototype is not known to
  be non-destructive for anything else. Do not put it near a workload you care
  about.
