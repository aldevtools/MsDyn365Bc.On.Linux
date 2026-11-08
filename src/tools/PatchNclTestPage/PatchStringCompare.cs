using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// Temporary table sort order (issue #222). CollationAwareStringComparer.Compare(CompareInfo,
/// CompareOptions, string, string) is the one place temporary tables and their filters compare
/// Code and Text keys. Its call to CompareInfo.Compare(ReadOnlySpan, ReadOnlySpan, CompareOptions)
/// is rewritten in place to BcLinuxStringCompare.CollationCompare, which gives the hyphen and the
/// apostrophe the weight NLS gives them on Windows. Session-culture Text comparison
/// (NavStringValue.CompareTo) is not touched: it was not measured against Windows.
///
/// Idempotent. Exits with an error when the call is not found, because a BC update has then moved
/// the code and the fix would stop working without a sign.
/// </summary>
static class PatchStringCompare
{
    const string Helper = "CollationCompare";

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

            var type = module.GetTypes().FirstOrDefault(t => t.FullName == "Microsoft.Dynamics.Nav.Runtime.CollationAwareStringComparer");
            var method = type?.Methods.FirstOrDefault(m => m.Name == "Compare" && m.IsStatic && m.HasBody && m.Parameters.Count == 4);
            if (method == null)
            {
                Console.WriteLine("ERROR: CollationAwareStringComparer.Compare(CompareInfo, CompareOptions, string, string) not found; the sort order fix cannot be applied");
                return 1;
            }

            int rewritten = 0, already = 0;
            foreach (var ins in method.Body.Instructions)
            {
                if (ins.Operand is not MethodReference mr) continue;
                if (mr.Name == Helper && mr.DeclaringType?.FullName == HelperCloner.HolderType) { already++; continue; }
                if (ins.OpCode.Code != Code.Callvirt && ins.OpCode.Code != Code.Call) continue;
                if (mr.Name != "Compare" || mr.DeclaringType?.FullName != "System.Globalization.CompareInfo"
                    || mr.Parameters.Count != 3
                    || !mr.Parameters[0].ParameterType.FullName.StartsWith("System.ReadOnlySpan`1", StringComparison.Ordinal)
                    || mr.Parameters[2].ParameterType.FullName != "System.Globalization.CompareOptions") continue;
                ins.OpCode = OpCodes.Call;
                ins.Operand = HelperCloner.Clone(module, "BcLinuxStringCompare", Helper);
                rewritten++;
            }

            Console.WriteLine($"Rewrote {rewritten} collation comparison(s) in CollationAwareStringComparer in {Path.GetFileName(inputPath)} (already patched: {already})");
            if (rewritten + already != 1)
            {
                Console.WriteLine($"ERROR: expected 1 CompareInfo.Compare call in CollationAwareStringComparer.Compare, found {rewritten + already}; BC moved the code and the fix is not applied");
                return 1;
            }
            if (rewritten == 0) return 0;
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
