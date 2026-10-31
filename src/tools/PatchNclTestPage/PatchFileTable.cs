using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// The File virtual table (issue #199). FileDataProvider builds the folder from the Path field,
/// which BC upper-cases. Two calls are rewritten in place to BcLinuxFileTable, which finds the
/// folder ignoring case:
///   * <c>new DirectoryInfo(string)</c> in GetItemsInTheDirectory (the listing);
///   * <c>Path.Combine(string, string)</c> in GetBlobContent (reading a file's Blob field).
///
/// Idempotent. Exits with an error when either call is not found, because a BC update has then
/// moved the code and the fix would stop working without a sign.
/// </summary>
static class PatchFileTable
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

            var provider = module.GetTypes().FirstOrDefault(t => t.FullName == "Microsoft.Dynamics.Nav.Runtime.FileDataProvider");
            // GetItemsInTheDirectory is an iterator: the listing lives in its state machine's MoveNext.
            var listing = provider?.NestedTypes
                .Where(t => t.Name.StartsWith("<GetItemsInTheDirectory>", StringComparison.Ordinal))
                .SelectMany(t => t.Methods)
                .FirstOrDefault(m => m.Name == "MoveNext" && m.HasBody);
            var blob = provider?.Methods.FirstOrDefault(m => m.Name == "GetBlobContent" && m.HasBody);
            if (listing == null || blob == null)
            {
                Console.WriteLine("ERROR: FileDataProvider.GetItemsInTheDirectory/GetBlobContent not found; the File table fix cannot be applied");
                return 1;
            }

            MethodDefinition? directoryHelper = null, fileHelper = null;
            void EnsureHelpers()
            {
                if (directoryHelper != null) return;
                directoryHelper = HelperCloner.Clone(module, "BcLinuxFileTable", "FileTableDirectory");
                fileHelper = HelperCloner.Holder(module).Methods.First(m => m.Name == "BcLinuxFileTable_FileTableFilePath");
            }

            int dirRewritten = 0, dirAlready = 0;
            foreach (var ins in listing.Body.Instructions)
            {
                if (ins.Operand is not MethodReference mr) continue;
                if (mr.Name == "FileTableDirectory" && mr.DeclaringType?.FullName == HelperCloner.HolderType) { dirAlready++; continue; }
                if (ins.OpCode.Code != Code.Newobj || mr.DeclaringType?.FullName != "System.IO.DirectoryInfo"
                    || mr.Parameters.Count != 1 || mr.Parameters[0].ParameterType.FullName != "System.String") continue;
                EnsureHelpers();
                ins.OpCode = OpCodes.Call;
                ins.Operand = directoryHelper;
                dirRewritten++;
            }

            int fileRewritten = 0, fileAlready = 0;
            foreach (var ins in blob.Body.Instructions)
            {
                if (ins.Operand is not MethodReference mr) continue;
                if (mr.Name == "BcLinuxFileTable_FileTableFilePath" && mr.DeclaringType?.FullName == HelperCloner.HolderType) { fileAlready++; continue; }
                if (ins.OpCode.Code != Code.Call || mr.Name != "Combine" || mr.DeclaringType?.FullName != "System.IO.Path"
                    || mr.Parameters.Count != 2) continue;
                EnsureHelpers();
                ins.Operand = fileHelper;
                fileRewritten++;
            }

            Console.WriteLine($"Rewrote {dirRewritten} folder lookup(s) and {fileRewritten} file path(s) in FileDataProvider in {Path.GetFileName(inputPath)} (already patched: {dirAlready + fileAlready})");
            if (dirRewritten + dirAlready == 0 || fileRewritten + fileAlready == 0)
            {
                Console.WriteLine("ERROR: new DirectoryInfo or Path.Combine not found in FileDataProvider; BC moved the code and the File table fix is not applied");
                return 1;
            }
            if (dirRewritten + fileRewritten == 0) return 0;
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
