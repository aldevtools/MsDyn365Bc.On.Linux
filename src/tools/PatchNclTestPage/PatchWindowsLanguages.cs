using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

/// <summary>
/// The Windows Language and Language Selection tables (issues #198 and #223). Two commands:
///
/// windowslanguages (Nav.Types.dll): WindowsLanguageHelper.GetDistinctCultures starts from
/// CultureInfo.GetCultures; that call becomes BcLinuxWindowsLanguages.WindowsLanguageCultures,
/// which adds the cultures ICU does not list. Everything after it (filter, order, duplicate
/// removal) is BC's own. CultureInfo.EnglishName in GetAllCultures (BC's name to LCID map),
/// GetDisplayNameFromTag and GetDisplayNameFromLcid goes through BcLinuxLanguageName, and
/// the abbreviation in AbbreviatedName (ThreeLetterWindowsLanguageName on BC 27/28, BC's own
/// WindowsLanguageNameLookup table on BC 29) through BcLinuxLanguageAbbreviation.
///
/// windowslanguagerows (Nav.Ncl.dll): the two table providers build each row from the
/// CultureInfo. Name, tag and Primary CodePage go through the BcLinuxLanguage* helpers.
///
/// Idempotent. Exits with an error when a call is not where it is expected, because a BC
/// update has then moved the code and the fix would stop working without a sign.
/// </summary>
static class PatchWindowsLanguages
{
    public static int Run(string inputPath, string outputPath) => Patch(inputPath, outputPath, nav: false);

    public static int RunRows(string inputPath, string outputPath) => Patch(inputPath, outputPath, nav: true);

    static int Patch(string inputPath, string outputPath, bool nav)
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

            // (method that holds the call, CultureInfo/TextInfo getter, helper class, helper root, calls expected)
            var plan = new List<(MethodDefinition? method, string where, string type, string getter, string helper, string root, int expected)>();
            if (!nav)
            {
                var helperType = module.GetTypes().FirstOrDefault(t => t.FullName == "Microsoft.Dynamics.Nav.Types.WindowsLanguageHelper");
                plan.Add((IteratorBody(helperType, "GetDistinctCultures"), "GetDistinctCultures", "System.Globalization.CultureInfo", "GetCultures",
                    "BcLinuxWindowsLanguages", "WindowsLanguageCultures", 1));
                plan.Add((IteratorBody(helperType, "GetAllCultures"), "GetAllCultures", "System.Globalization.CultureInfo", "get_EnglishName",
                    "BcLinuxLanguageName", "WindowsEnglishName", 1));
                plan.Add((Method(helperType, "GetDisplayNameFromTag"), "GetDisplayNameFromTag", "System.Globalization.CultureInfo", "get_EnglishName",
                    "BcLinuxLanguageName", "WindowsEnglishName", 1));
                plan.Add((Method(helperType, "GetDisplayNameFromLcid"), "GetDisplayNameFromLcid", "System.Globalization.CultureInfo", "get_EnglishName",
                    "BcLinuxLanguageName", "WindowsEnglishName", 1));
                plan.Add((Method(helperType, "AbbreviatedName"), "AbbreviatedName", "System.Globalization.CultureInfo", "get_ThreeLetterWindowsLanguageName",
                    "BcLinuxLanguageAbbreviation", "WindowsAbbreviatedName", 1));
            }
            else
            {
                var windowsLanguage = module.GetTypes().FirstOrDefault(t => t.FullName == "Microsoft.Dynamics.Nav.Runtime.WindowsLanguageDataProvider");
                var languageSelection = module.GetTypes().FirstOrDefault(t => t.FullName == "Microsoft.Dynamics.Nav.Runtime.LanguageSelectionDataProvider");
                var wl = IteratorBody(windowsLanguage, "GetAllWindowsLanguageRecords");
                var ls = IteratorBody(languageSelection, "GetAllSelectableLanguageRecords");
                plan.Add((wl, "GetAllWindowsLanguageRecords", "System.Globalization.CultureInfo", "get_EnglishName", "BcLinuxLanguageName", "WindowsEnglishName", 1));
                plan.Add((wl, "GetAllWindowsLanguageRecords", "System.Globalization.CultureInfo", "get_Name", "BcLinuxLanguageTag", "WindowsCultureName", 1));
                plan.Add((wl, "GetAllWindowsLanguageRecords", "System.Globalization.TextInfo", "get_OEMCodePage", "BcLinuxLanguageCodePage", "WindowsOemCodePage", 1));
                plan.Add((ls, "GetAllSelectableLanguageRecords", "System.Globalization.CultureInfo", "get_EnglishName", "BcLinuxLanguageName", "WindowsEnglishName", 1));
                plan.Add((ls, "GetAllSelectableLanguageRecords", "System.Globalization.TextInfo", "get_CultureName", "BcLinuxLanguageTextTag", "WindowsTextInfoCultureName", 1));
            }

            int rewritten = 0, already = 0;
            foreach (var (method, where, type, getter, helperClass, root, expected) in plan)
            {
                if (method == null)
                {
                    Console.WriteLine($"ERROR: {where} not found in {Path.GetFileName(inputPath)}; BC moved the code and the Windows Language fix is not applied");
                    return 1;
                }
                int found = 0, done = 0;
                MethodDefinition? helper = null;
                foreach (var ins in method.Body.Instructions)
                {
                    if (ins.Operand is not MethodReference mr) continue;
                    if (mr.Name == root && mr.DeclaringType?.FullName == HelperCloner.HolderType) { done++; continue; }
                    if (ins.OpCode.Code != Code.Call && ins.OpCode.Code != Code.Callvirt) continue;
                    bool match = mr.Name == getter && mr.DeclaringType?.FullName == type
                        // GetCultures(CultureTypes) only; a property getter has no parameters.
                        && mr.Parameters.Count == (getter == "GetCultures" ? 1 : 0);
                    // BC 29 reads the abbreviation off Windows from its own table
                    // (WindowsLanguageNameLookup.GetThreeLetterWindowsLanguageName(CultureInfo)),
                    // which differs from Windows for 1158 (QUT) and 1164 (ZZZ). Same helper.
                    if (!match && getter == "get_ThreeLetterWindowsLanguageName")
                        match = mr.Name == "GetThreeLetterWindowsLanguageName"
                            && mr.DeclaringType?.FullName == "Microsoft.Dynamics.Nav.Types.WindowsLanguageNameLookup"
                            && mr.Parameters.Count == 1 && mr.Parameters[0].ParameterType.FullName == "System.Globalization.CultureInfo";
                    if (!match) continue;
                    helper ??= HelperCloner.Clone(module, helperClass, root);
                    ins.OpCode = OpCodes.Call;
                    ins.Operand = helper;
                    found++;
                }
                if (found + done != expected)
                {
                    Console.WriteLine($"ERROR: expected {expected} {type}.{getter} call(s) in {where}, found {found + done}; BC moved the code and the Windows Language fix is not applied");
                    return 1;
                }
                rewritten += found;
                already += done;
            }

            Console.WriteLine($"Rewrote {rewritten} culture call(s) for the Windows Language tables in {Path.GetFileName(inputPath)} (already patched: {already})");
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

    // An iterator's code lives in its state machine's MoveNext.
    static MethodDefinition? IteratorBody(TypeDefinition? type, string name) =>
        type?.NestedTypes
            .Where(t => t.Name.StartsWith("<" + name + ">", StringComparison.Ordinal))
            .SelectMany(t => t.Methods)
            .FirstOrDefault(m => m.Name == "MoveNext" && m.HasBody);

    static MethodDefinition? Method(TypeDefinition? type, string name) =>
        type?.Methods.FirstOrDefault(m => m.Name == name && m.HasBody);
}
