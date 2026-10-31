using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// The Windows Language table's Chinese rows (issue #198). WindowsLanguageHelper.GetDistinctCultures
/// starts from CultureInfo.GetCultures; that call becomes a call to
/// BcLinuxWindowsLanguages.WindowsLanguageCultures, which adds the cultures ICU lists only
/// under a script name. Everything after it (filter, order, duplicate removal) is BC's own.
///
/// Idempotent. Exits with an error when the call is not found, because a BC update has then
/// moved the code and the fix would stop working without a sign.
/// </summary>
static class PatchWindowsLanguages
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

            var helperType = module.GetTypes().FirstOrDefault(t => t.FullName == "Microsoft.Dynamics.Nav.Types.WindowsLanguageHelper");
            // GetDistinctCultures is an iterator: the call lives in its state machine's MoveNext.
            var moveNext = helperType?.NestedTypes
                .Where(t => t.Name.StartsWith("<GetDistinctCultures>", StringComparison.Ordinal))
                .SelectMany(t => t.Methods)
                .FirstOrDefault(m => m.Name == "MoveNext" && m.HasBody);
            if (moveNext == null)
            {
                Console.WriteLine("ERROR: WindowsLanguageHelper.GetDistinctCultures not found; the Windows Language fix cannot be applied");
                return 1;
            }

            int rewritten = 0, already = 0;
            MethodDefinition? helper = null;
            foreach (var ins in moveNext.Body.Instructions)
            {
                if (ins.Operand is not MethodReference mr) continue;
                if (mr.Name == "WindowsLanguageCultures" && mr.DeclaringType?.FullName == HelperCloner.HolderType) { already++; continue; }
                if (ins.OpCode.Code != Code.Call || mr.Name != "GetCultures"
                    || mr.DeclaringType?.FullName != "System.Globalization.CultureInfo"
                    || mr.Parameters.Count != 1) continue;
                helper ??= HelperCloner.Clone(module, "BcLinuxWindowsLanguages", "WindowsLanguageCultures");
                ins.Operand = helper;
                rewritten++;
            }

            Console.WriteLine($"Rewrote {rewritten} CultureInfo.GetCultures call(s) in WindowsLanguageHelper.GetDistinctCultures in {Path.GetFileName(inputPath)} (already patched: {already})");
            if (rewritten + already == 0)
            {
                Console.WriteLine("ERROR: CultureInfo.GetCultures not found in GetDistinctCultures; BC moved the code and the Windows Language fix is not applied");
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
