using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// Every TimeZoneInfo.TryFindSystemTimeZoneById call in the assembly becomes
/// BcLinuxTimeZoneLookup.TryFindSystemTimeZoneById (BcLinuxTimeZones.cs): a zone with DST rules
/// comes back as a fixed-offset custom zone with the same id. NavSession.GetPersonalization
/// loads the user's stored time zone id this way and stores the zone through an inlined
/// UserSettings setter that Patch #24 cannot hook; a DST zone then fails to deserialize on the
/// next sign-in (InvalidTimeZoneException in NSService.OpenConnection).
///
/// This is a Linux serialization fix, not Windows text emulation, so the entrypoint runs it
/// whatever BC_WINDOWS_TEXT says. Same signature, so the call is swapped in place. Idempotent:
/// a rewritten call no longer names System.TimeZoneInfo.
/// </summary>
static class PatchTimeZoneLookup
{
    public static int Run(string inputPath, string outputPath)
    {
        if (!File.Exists(inputPath))
        {
            Console.WriteLine($"ERROR: {inputPath} not found");
            return 1;
        }
        try
        {
            var resolver = new DefaultAssemblyResolver();
            resolver.AddSearchDirectory(Path.GetDirectoryName(Path.GetFullPath(inputPath)) ?? ".");
            using var assembly = AssemblyDefinition.ReadAssembly(inputPath,
                new ReaderParameters { AssemblyResolver = resolver, ReadWrite = inputPath == outputPath });
            var module = assembly.MainModule;

            int patched = 0;
            MethodDefinition? helper = null;
            foreach (var type in module.GetTypes().ToList())
            {
                if (type.Name == HelperCloner.HolderType) continue;
                foreach (var method in type.Methods.Where(m => m.HasBody))
                {
                    foreach (var ins in method.Body.Instructions)
                    {
                        if (ins.OpCode.Code != Code.Call || ins.Operand is not MethodReference find) continue;
                        if (find.Name != "TryFindSystemTimeZoneById" || find.DeclaringType?.FullName != "System.TimeZoneInfo") continue;
                        helper ??= HelperCloner.Clone(module, "BcLinuxTimeZoneLookup", "TryFindSystemTimeZoneById");
                        ins.Operand = helper;
                        patched++;
                    }
                }
            }

            Console.WriteLine($"Routed {patched} TryFindSystemTimeZoneById call(s) through the time zone lookup fix in {Path.GetFileName(inputPath)}");
            if (patched == 0) return 0;
            if (inputPath == outputPath) assembly.Write(); else assembly.Write(outputPath);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }
}
