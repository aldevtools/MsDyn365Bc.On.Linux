using Mono.Cecil;
using Mono.Cecil.Cil;
using System;
using System.IO;
using System.Linq;

/// <summary>
/// [HttpClientHandler] in a test codeunit (issue #192). NavTestExecution.TestHandleHttpClientRequest
/// only calls the handler when <c>NavEnvironment.Topology.IsServiceRunningInLocalEnvironment</c> is
/// true. A Windows tier runs StandardServiceTopology, which always answers true. Patch #9 replaces
/// the topology with a proxy that answers false, so BC 27 and 28 never called the handler: a
/// request under BlockOutboundRequests or AllowOutboundFromHandler failed with
/// TestCodeunitUnhandledHttpRequest, and under AllowAllOutboundRequests it went to the network.
/// (BC 29 has the same code and calls the handler,
/// so something on 29 restores the real topology before tests run; that was not traced.)
///
/// The property read in that method becomes a call to a helper that drops the topology and returns
/// true, the value StandardServiceTopology gives. Every other reader of the property still sees
/// Patch #9's answer.
///
/// Idempotent. Exits with an error when the read is not found, because a BC update has then moved
/// the code and the fix would stop working without a sign.
/// </summary>
static class PatchTestHttpHandler
{
    const string HelperName = "TestHttpHandlerTopologyIsLocal";

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

            var testExecution = module.GetTypes().FirstOrDefault(t => t.FullName == "Microsoft.Dynamics.Nav.Runtime.NavTestExecution");
            var methods = testExecution?.Methods.Where(m => m.Name == "TestHandleHttpClientRequest" && m.HasBody).ToList();
            if (methods == null || methods.Count == 0)
            {
                Console.WriteLine("ERROR: NavTestExecution.TestHandleHttpClientRequest not found; the HTTP client handler fix cannot be applied");
                return 1;
            }

            int rewritten = 0, already = 0;
            MethodDefinition? helper = null;
            foreach (var method in methods)
            {
                foreach (var ins in method.Body.Instructions)
                {
                    if (ins.Operand is not MethodReference mr) continue;
                    if (mr.Name == HelperName && mr.DeclaringType?.FullName == HelperCloner.HolderType) { already++; continue; }
                    if (ins.OpCode.Code != Code.Callvirt || mr.Name != "get_IsServiceRunningInLocalEnvironment"
                        || mr.DeclaringType?.FullName != "Microsoft.Dynamics.Nav.Runtime.IServiceTopology") continue;
                    helper ??= Helper(module);
                    // Same stack shape: takes the topology, leaves a bool. In place, so a branch
                    // that targets this instruction still lands on it.
                    ins.OpCode = OpCodes.Call;
                    ins.Operand = helper;
                    rewritten++;
                }
            }

            Console.WriteLine($"Rewrote {rewritten} topology read(s) in NavTestExecution.TestHandleHttpClientRequest in {Path.GetFileName(inputPath)} (already patched: {already})");
            if (rewritten + already == 0)
            {
                Console.WriteLine("ERROR: the topology read was not found in TestHandleHttpClientRequest; BC moved the code and the HTTP client handler fix is not applied");
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

    /// <summary><c>static bool TestHttpHandlerTopologyIsLocal(object topology) => true;</c></summary>
    static MethodDefinition Helper(ModuleDefinition module)
    {
        var holder = HelperCloner.Holder(module);
        var existing = holder.Methods.FirstOrDefault(m => m.Name == HelperName);
        if (existing != null) return existing;

        var helper = new MethodDefinition(HelperName,
            MethodAttributes.Static | MethodAttributes.Assembly | MethodAttributes.HideBySig,
            module.TypeSystem.Boolean);
        helper.Parameters.Add(new ParameterDefinition("topology", ParameterAttributes.None, module.TypeSystem.Object));
        var il = helper.Body.GetILProcessor();
        il.Append(il.Create(OpCodes.Ldc_I4_1));
        il.Append(il.Create(OpCodes.Ret));
        holder.Methods.Add(helper);
        return helper;
    }
}
