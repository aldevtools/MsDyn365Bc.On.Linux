// ARM64 CoreCLR precode target-cell locator + patcher.
//
// Reference implementation for the spec in docs/ARM64-PRECODE.md. Derived from
// dotnet/runtime release/8.0 and release/10.0 (vm/precode.h,
// vm/arm64/thunktemplates.S, vm/jitinterface.cpp) — NOT from reading bytes and
// inferring, which produced three wrong decoders before this was written.
//
// STATUS: compiles and embodies the spec; it has NOT been exercised against BC's
// real hook set. The standalone spike that validated the underlying primitive
// (patch the FixupPrecode Target cell of a PrepareMethod'd method -> the
// replacement runs, 5/5) lived in a tmpfs scratchpad and is gone. Treat this as
// a starting point to re-validate, not as proven code.
//
// IMPORTANT — this is only half a hook. Patching the precode Target cell
// intercepts callers that route THROUGH the precode. Callers JITted after the
// target has stable native code bind directly to the compiled code and bypass it
// entirely (CEEInfo::getFunctionEntryPoint, jitinterface.cpp release/8.0
// :9042-9094). Measured on x64: 21 of 21 hooks take the compiled-code write on
// every boot. A complete detour needs this cell write AND a veneer over the
// compiled body — see ARM64.md for the CMODX and I-cache obligations that brings.

using System;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

public static unsafe class Arm64PrecodePatcher
{
    // ---- ARM64 encodings ----------------------------------------------------
    const uint LDR_LIT_MASK = 0xFF000000u, LDR_LIT_OP = 0x58000000u; // LDR (literal), 64-bit
    const uint BR_MASK = 0xFFFFFC1Fu, BR_OP = 0xD61F0000u;           // BR Xn
    const int FixupCodeOffset = 8; // precode.h ARM64; identical on 8.0 and 10.0

    static uint Rt(uint ins) => ins & 0x1F;              // LDR-literal destination register
    static uint BrRn(uint ins) => (ins >> 5) & 0x1F;     // BR source register
    static bool IsLdrLit(uint i) => (i & LDR_LIT_MASK) == LDR_LIT_OP;
    static bool IsBr(uint i) => (i & BR_MASK) == BR_OP;

    static byte* LdrLiteralTarget(byte* pc, uint ins)    // pc + SignExtend(imm19)*4
    {
        int imm19 = (int)((ins >> 5) & 0x7FFFF);
        if ((imm19 & 0x40000) != 0) imm19 |= unchecked((int)0xFFF80000);
        return pc + (long)imm19 * 4;
    }

    /// <summary>
    /// Locate the writable Target cell for a method's precode. Returns false rather
    /// than ever handing back a shared or prestub-pointing cell — writing one of
    /// those redirects every method still resolving through it, which is the
    /// documented crash in KNOWN-LIMITATIONS.md:171-179.
    /// </summary>
    public static bool TryGetTargetCell(MethodBase m, out IntPtr cell, out string form)
    {
        cell = IntPtr.Zero; form = "unknown";
        if (m is null) return false;

        RuntimeMethodHandle h = m.MethodHandle;
        // Required: without it the Target cell legitimately still holds the
        // un-JITted `entry+8` sentinel and is (correctly) refused below.
        RuntimeHelpers.PrepareMethod(h);
        byte* entry = (byte*)h.GetFunctionPointer();
        if (entry is null) return false;

        // Read ONLY the first three words. The precode stride is 24 bytes, so a
        // wider window runs into the NEXT method's precode — scanning for "the
        // last BR" in an 8-word window patches the neighbour's target and crashes.
        uint w0 = ((uint*)entry)[0], w1 = ((uint*)entry)[1], w2 = ((uint*)entry)[2];
        if (!IsLdrLit(w0)) return false;   // both forms start: LDR Xt,[Target]

        bool isFixup;
        if (IsBr(w1) && BrRn(w1) == Rt(w0)) isFixup = true;                          // LDR;BR
        else if (IsLdrLit(w1) && IsBr(w2) && BrRn(w2) == Rt(w0)) isFixup = false;    // LDR;LDR;BR
        else return false;

        // w0 loads Target in BOTH forms, so one literal decode finds the cell.
        // Decode the immediate rather than assuming a page size: the data page sits
        // GetStubCodePageSize() ahead, which is 16K/32K/64K depending on the kernel.
        byte* targetCell = LdrLiteralTarget(entry, w0);
        long delta = (long)(targetCell - entry);
        if (delta <= 0 || ((nint)targetCell & (IntPtr.Size - 1)) != 0) return false;
        long ps = delta - (isFixup ? 0 : 8);
        if (ps != 16384 && ps != 32768 && ps != 65536) return false;

        IntPtr cur = *(IntPtr*)targetCell;

        // Refusals, mirroring Precode::IsPointingToPrestub (precode.cpp 8.0 :170-186)
        if (cur == (IntPtr)(entry + FixupCodeOffset)) return false;  // un-JITted sentinel
        IntPtr preStub = GetPreStubEntryPoint();
        if (preStub != IntPtr.Zero && cur == preStub) return false;  // ThePreStub (shared!)
        if (cur == (IntPtr)entry) return false;                      // .NET 10 loop-seed

        cell = (IntPtr)targetCell;
        form = isFixup ? "FixupPrecode" : "StubPrecode";
        return true;
    }

    /// <summary>
    /// Publish a new Target atomically, mirroring CoreCLR's own
    /// InterlockedCompareExchangeT&lt;PCODE&gt;(&amp;pData-&gt;Target, ...). The cell lives on the
    /// RW data page, so no PROT_EXEC and no I-cache maintenance are required.
    /// </summary>
    public static bool TryPatchTargetCell(IntPtr cell, IntPtr newTarget, out IntPtr previous)
    {
        previous = IntPtr.Zero;
        if (cell == IntPtr.Zero) return false;

        long ps = PageSize();                                  // never hardcode 4096
        long start = (long)cell & ~(ps - 1);
        long end = ((long)cell + IntPtr.Size + ps - 1) & ~(ps - 1);
        if (mprotect((IntPtr)start, (UIntPtr)(end - start), PROT_READ | PROT_WRITE) != 0)
            return false;

        previous = Interlocked.Exchange(ref *(IntPtr*)cell, newTarget);
        return true;
    }

    // Recover GetPreStubEntryPoint() with no symbols: an un-JITted FixupPrecode
    // stores PrecodeFixupThunk == GetPreStubEntryPoint() at data+16 (precode.cpp :700).
    static IntPtr _preStub = (IntPtr)(-1);
    static IntPtr GetPreStubEntryPoint()
    {
        if (_preStub != (IntPtr)(-1)) return _preStub;
        _preStub = IntPtr.Zero;
        try
        {
            MethodInfo probe = typeof(Arm64PrecodePatcher)
                .GetMethod(nameof(NeverCalledProbe), BindingFlags.NonPublic | BindingFlags.Static)!;
            byte* pe = (byte*)probe.MethodHandle.GetFunctionPointer(); // realizes precode, no JIT
            uint w0 = ((uint*)pe)[0], w1 = ((uint*)pe)[1];
            if (!IsLdrLit(w0) || !(IsBr(w1) && BrRn(w1) == Rt(w0))) return _preStub;
            byte* data = LdrLiteralTarget(pe, w0);
            if (*(IntPtr*)data != (IntPtr)(pe + FixupCodeOffset)) return _preStub; // prove un-JITted
            _preStub = *(IntPtr*)(data + 16);
        }
        catch { _preStub = IntPtr.Zero; }
        return _preStub;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void NeverCalledProbe() => throw new InvalidOperationException();

    const int _SC_PAGESIZE = 30; // Linux/glibc
    [DllImport("libc", SetLastError = true)] static extern long sysconf(int name);
    static long PageSize()
    {
        try { long v = sysconf(_SC_PAGESIZE); if (v > 0) return v; } catch { }
        return Environment.SystemPageSize;
    }

    const int PROT_READ = 0x1, PROT_WRITE = 0x2;
    [DllImport("libc", SetLastError = true)] static extern int mprotect(IntPtr addr, UIntPtr len, int prot);
}

// Not handled, and each will bite:
//  * Generic methods need PrepareMethod(handle, instantiation) with a realized
//    instantiation.
//  * After PrepareMethod a tiered method's cell may point at a CallCountingStub
//    rather than final code. That is still per-method and patchable — but if you
//    veneer, veneer whatever the cell currently points at, and only after the
//    refusals above pass.
//  * .NET 10 inserts `dmb ishld` at +0x08 in FixupPrecode and changed the
//    Precode::Type constants (0x4A->0x3, 0x0B->0x2) so they no longer match code
//    bytes. Classification here is by instruction shape, which is why it survives
//    that; any type-byte check would not.
