using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// Control add-ins and other package directories (issue #216). ReadDirectoryFilePaths compares
/// Path.GetDirectoryName(file).Trim('\\') with "addin" (or "perm", "serv", "replay", "profile").
/// On Linux the leading '/' survives, so every comparison fails and installation silently
/// registers no control add-ins. Replace only this predicate's filesystem lookup with a
/// package-path lookup. Other Path.GetDirectoryName calls are left alone.
/// Idempotent; refuse to write if the expected single call has moved in a new BC build.
/// </summary>
static class PatchPackagePaths
{
    const string Reader = "Microsoft.Dynamics.Nav.CodeAnalysis.Packaging.NavAppPackageReader";
    const string Helper = "PackageDirectoryName";

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
            var methods = module.GetTypes().Where(t => OuterName(t) == Reader)
                .SelectMany(t => t.Methods).Where(m => m.HasBody &&
                    (m.Name == "ReadDirectoryFilePaths" || m.Name.StartsWith("<ReadDirectoryFilePaths>", StringComparison.Ordinal)));
            var calls = methods.SelectMany(m => m.Body.Instructions).Where(i =>
                i.OpCode.Code == Code.Call && i.Operand is MethodReference mr &&
                ((mr.DeclaringType.FullName == "System.IO.Path" && mr.Name == "GetDirectoryName" &&
                    mr.Parameters.Count == 1 && mr.Parameters[0].ParameterType.FullName == "System.String") ||
                 (mr.DeclaringType.FullName == HelperCloner.HolderType && mr.Name == Helper))).ToList();
            if (calls.Count != 1)
            {
                Console.WriteLine($"ERROR: expected one package directory lookup, found {calls.Count}; the package path fix is not applied");
                return 1;
            }
            var call = calls[0];
            if (((MethodReference)call.Operand).Name == Helper)
            {
                Console.WriteLine($"Rewrote 0 package directory lookup(s) in {Path.GetFileName(inputPath)} (already patched: 1)");
                return 0;
            }
            call.Operand = HelperCloner.Clone(module, "BcLinuxPackagePaths", Helper);
            if (inputPath == outputPath) assembly.Write(); else assembly.Write(outputPath);
            Console.WriteLine($"Rewrote 1 package directory lookup in {Path.GetFileName(inputPath)} (issue #216)");
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
            return 1;
        }
    }

    static string OuterName(TypeDefinition type)
    {
        while (type.DeclaringType != null) type = type.DeclaringType;
        return type.FullName;
    }
}
