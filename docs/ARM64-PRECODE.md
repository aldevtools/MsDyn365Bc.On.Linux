# ARM64 CoreCLR precode reference

Reference material for porting `StartupHook.cs`'s detour layer to arm64
(ARM64-BATTLEPLAN.md Track 2b). Everything here is read from `dotnet/runtime`
sources on `release/8.0` and `release/10.0`, not inferred from observed bytes —
three successive hand-written decoders were wrong before this was written, and
every one of them crashed the process.

## The two forms (arm64, .NET 8)

From `src/coreclr/vm/arm64/thunktemplates.S` (release/8.0, lines 7-23). The
`.irp STUB_PAGE_SIZE, 16384, 32768, 65536` means one template per OS page size.

```
StubPrecode                     FixupPrecode  (24-byte CodeSize, 20 bytes used)
  +0x00  ldr x10,[Target]         +0x00  ldr x11,[Target]
  +0x04  ldr x12,[MethodDesc]     +0x04  br  x11
  +0x08  br  x10                  +0x08  ldr x12,[MethodDesc]   ← this+8 = FixupCodeOffset
                                  +0x0c  ldr x11,[PrecodeFixupThunk]
                                  +0x10  br  x11
                                  +0x14  NOP (0xD503201F) — padding to the 24-byte stride
```

**What a never-called method's entry looks like, and why that misled me.** The
FixupPrecode *is* the temporary entry point — there is no separate wrapper. While
un-JITted, `Target` holds the sentinel `this + 8`, so control flows
`br Target` → `+0x08` → load MethodDesc → `br PrecodeFixupThunk` → **ThePreStub**.
Observing `cell == entry+8` and concluding "indirection cell, find another" was
wrong: it is the right cell holding a sentinel that must be **refused**, not
worked around.

**Stride is guaranteed 24 bytes** (`FixupPrecode::CodeSize`, `vm/precode.h`
release/8.0 lines 235-238; `FillStubCodePage` copies in `codeSize` units,
`vm/util.cpp` line 1941). So `+0x18` is the **next method's precode** — which is
what a naive "find the last BR in an 8-word window" scan patches. Read **only
w0/w1/w2** (12 bytes); classification never needs more.

## Data page and cells

Both forms compute their data as `this + GetStubCodePageSize()` — `precode.h`
lines 124-128 (Stub) and 266-270 (Fixup). That is the 16384 seen on a 4 KB-page
host; it is 16384/32768/65536 depending on OS page size, so **decode the `LDR`
literal rather than assuming**.

```c
struct FixupPrecodeData { PCODE Target;      /* +0  ← write this */
                          MethodDesc* MD;    /* +8  */
                          PCODE PrecodeFixupThunk; /* +16 == GetPreStubEntryPoint() */ };

struct StubPrecodeData  { TADDR SecretParam; /* +0  (named MethodDesc in 8.0) */
                          PCODE Target;      /* +8  ← write this */
                          BYTE  Type;        /* +16 */ };
```

Conveniently, **`w0` loads `Target` in both forms**, so one literal decode finds
the cell to patch regardless of form.

CoreCLR writes it interlocked: `InterlockedCompareExchangeT<PCODE>(&pData->Target, …)`
(`precode.h` 165-176 and 308-330). The cell is on the **RW data page** — no
`PROT_EXEC`, no I-cache flush needed (`precode.cpp` 361-363).

## Classify by instruction shape, never by a type byte

```
LDR (literal, 64-bit):  (w & 0xFF000000) == 0x58000000    Rt = w & 0x1F
BR   Xn:                (w & 0xFFFFFC1F) == 0xD61F0000    Rn = (w>>5) & 0x1F

FixupPrecode:  w0=LDR Xt   ; w1=BR Xt
StubPrecode:   w0=LDR Xt   ; w1=LDR       ; w2=BR Xt
cell = entry + SignExtend(imm19(w0)) * 4
```

**Do not use the `Precode::Type` byte.** In .NET 8 the constants are Stub `0x4A`
/ Fixup `0x0B`; in .NET 10 they became `0x3` / `0x2` and no longer coincide with
the code bytes at all (`precode.h` release/10.0 lines 90, 375) — .NET 10 detects
form by byte-comparing against the resolved template. A hardcoded type byte
silently misfires there.

## Mandatory refusals (the shared-stub hazard)

`Precode::IsPointingToPrestub` (`precode.cpp` release/8.0 lines 170-186) refuses
two values, and so must we:

- `cur == entry + 8` — the un-JITted FixupPrecode sentinel
- `cur == GetPreStubEntryPoint()` — **ThePreStub**, shared by every pending method

This is the mechanism behind the crash already documented at
`KNOWN-LIMITATIONS.md:171-179`: the `Target` cell is per-method, but while
un-JITted it *points into shared code*, so veneering that address rewrites code
shared by every not-yet-called method. The existing 20-second delay is a
timing heuristic for this; on arm64 it should be replaced by the hard check
above.

`GetPreStubEntryPoint()` is recoverable at runtime with no symbols: read
`PrecodeFixupThunk` (data +16) from any un-JITted FixupPrecode — `precode.cpp`
line 700 assigns exactly that.

## .NET 10 differences

`thunktemplates.S` release/10.0 lines 63-68, 131-138 — FixupPrecode gains a
`dmb ishld` (`0xD50339BF`) load-acquire barrier at `+0x08`, making 6 real
instructions / 24 bytes with **no NOP padding**:

```
+0x00 ldr x11,[Target]   +0x04 br x11   +0x08 dmb ishld
+0x0c ldr x12,[MethodDesc]  +0x10 ldr x11,[PrecodeFixupThunk]  +0x14 br x11
```

`FixupCodeOffset` is still 8, so the `entry+8` refusal is unchanged. Because
classification only inspects w0/w1, the barrier is never examined — the shape
test is version-agnostic by construction.

## The decisive finding: the cell patch alone is NOT sufficient

`CEEInfo::getFunctionEntryPoint` (`vm/jitinterface.cpp` release/8.0 lines
9042-9094, the branch at 9065):

- Target still versionable-with-precode and **not** `IsPointingToStableNativeCode`
  → caller gets `IAT_PVALUE`, an **indirect** call through the `Target` cell.
  Patching the cell intercepts it.
- Target already has stable native code → `TryGetMultiCallableAddrOfCode`
  returns `GetNativeCode()` (`vm/method.cpp` line 2053) and the caller bakes in
  the **direct** address. The precode is never touched, so the cell patch cannot
  intercept it.

Since we cannot control which path every present and future caller took, **a
complete hook needs both writes** — the `Target` cell (catches precode-routed
callers, keeps tiering coherent) *and* a veneer over the compiled code body
(catches direct-bound callers). This independently confirms the empirical
measurement in ARM64.md: **21 of 21 hooks take the x64 compiled-code write on
every boot.**

So the arm64 port inherits the veneer, and with it the CMODX and I-cache
obligations documented in ARM64.md — the literal-slot write is a necessary
half, not a replacement.

## Implementation notes

- `RuntimeHelpers.PrepareMethod` **is** required before reading the cell, or the
  target legitimately still reads `entry+8` and gets refused. Generic methods
  need `PrepareMethod(handle, instantiation)` with a realized instantiation —
  not covered by the reference implementation.
- After `PrepareMethod`, a tiered method's cell may point at a
  **CallCountingStub** rather than final code. That is still per-method and
  patchable (not the prestub), so accept it — but if you veneer, veneer whatever
  the cell currently points at, and only after the refusals pass.
- Never hardcode 4096 for the `mprotect` span. Use `sysconf(_SC_PAGESIZE)` or
  `Environment.SystemPageSize`; arm64 hosts run 4K/16K/64K pages, and
  `addr & ~4095` on a 16K-page kernel yields an unaligned address and `EINVAL`.

A reference implementation lives in
[arm64-precode-patcher.cs](arm64-precode-patcher.cs) — `TryGetTargetCell` /
`TryPatchTargetCell`, including the runtime ThePreStub recovery and every
refusal above. It embodies this spec but has **not** been exercised against BC's
real hook set: the spike that validated the underlying primitive lived in a
tmpfs scratchpad and is gone. Re-validate before trusting it.
