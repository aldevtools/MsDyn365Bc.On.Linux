using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// DateFormula comparison (issue #207). NavDateFormula inherits CompareTo(NavStringValue) from
/// NavStringValue. This adds an override to NavDateFormula, with the same body except that the
/// string.Compare call goes to BcLinuxDateFormula, so Text and Code values are not affected.
///
/// Idempotent. Exits with an error when the method or the call is not found, because a BC update
/// has then moved the code and the fix would stop working without a sign.
/// </summary>
static class PatchDateFormula
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

            var formula = module.GetType("Microsoft.Dynamics.Nav.Runtime.NavDateFormula");
            var stringValue = module.GetType("Microsoft.Dynamics.Nav.Runtime.NavStringValue");
            var baseCompare = stringValue?.Methods.FirstOrDefault(m => m.Name == "CompareTo" && m.IsVirtual && m.HasBody
                && m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == stringValue.FullName);
            if (formula == null || baseCompare == null)
            {
                Console.WriteLine("ERROR: NavDateFormula or NavStringValue.CompareTo(NavStringValue) not found; the DateFormula fix cannot be applied");
                return 1;
            }
            if (formula.Methods.Any(m => m.Name == "CompareTo" && m.Parameters.Count == 1
                && m.Parameters[0].ParameterType.FullName == stringValue!.FullName))
            {
                Console.WriteLine($"Added 0 NavDateFormula.CompareTo override(s) in {Path.GetFileName(inputPath)} (already patched: 1)");
                return 0;
            }

            int compareCalls = baseCompare.Body.Instructions.Count(IsCultureCompare);
            if (compareCalls != 1)
            {
                Console.WriteLine($"ERROR: expected 1 string.Compare call in NavStringValue.CompareTo, found {compareCalls}; the DateFormula fix is not applied");
                return 1;
            }

            var helper = HelperCloner.Clone(module, "BcLinuxDateFormula", "DateFormulaCompare");
            var method = new MethodDefinition("CompareTo",
                baseCompare.Attributes & ~(MethodAttributes.NewSlot | MethodAttributes.Abstract),
                baseCompare.ReturnType);
            method.Parameters.Add(new ParameterDefinition("other", ParameterAttributes.None, baseCompare.Parameters[0].ParameterType));

            // The base body, instruction for instruction. Only the call differs: the helper has the
            // same parameters as string.Compare.
            var il = method.Body.GetILProcessor();
            var map = baseCompare.Body.Instructions.ToDictionary(i => i, i => Instruction.Create(OpCodes.Nop));
            foreach (var source in baseCompare.Body.Instructions)
            {
                var copy = map[source];
                copy.OpCode = source.OpCode;
                copy.Operand = source.Operand is Instruction target ? map[target] : source.Operand;
                if (IsCultureCompare(source))
                    copy.Operand = helper;
                il.Append(copy);
            }
            foreach (var local in baseCompare.Body.Variables)
                method.Body.Variables.Add(new VariableDefinition(local.VariableType));
            method.Body.InitLocals = baseCompare.Body.InitLocals;
            method.Body.MaxStackSize = baseCompare.Body.MaxStackSize;
            formula.Methods.Add(method);

            Console.WriteLine($"Added 1 NavDateFormula.CompareTo override(s) in {Path.GetFileName(inputPath)} (already patched: 0)");
            if (inputPath == outputPath) assembly.Write(); else assembly.Write(outputPath);
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    static bool IsCultureCompare(Instruction ins) =>
        ins.Operand is MethodReference mr && mr.Name == "Compare" && mr.DeclaringType?.FullName == "System.String"
        && mr.Parameters.Count == 4 && mr.Parameters[2].ParameterType.FullName == "System.Boolean"
        && mr.Parameters[3].ParameterType.FullName == "System.Globalization.CultureInfo";
}
