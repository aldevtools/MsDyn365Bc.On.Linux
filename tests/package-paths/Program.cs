// No BC download or test framework is needed for package/URI separator cases.
var cases = new (string Path, string Expected)[]
{
    ("/addin/controladdins.dock", "addin"),
    ("/addin/Probe.zip", "addin"),
    (@"\addin\Probe.zip", "addin"),
    (@"/addin\Probe.zip", "addin"),
    ("/addin/src/script.js", "addin/src"), // must not be mistaken for a direct addin entry
    ("/perm/permission.xml", "perm"),
    ("/serv/services.xml", "serv"),
    ("/replay/layout.xml", "replay"),
    ("/profile/profile.xml", "profile"),
    ("/AddIn/Probe.zip", "AddIn"), // the caller owns its case-insensitive comparison
    ("/manifest.xml", ""),
    ("manifest.xml", ""),
    ("", "")
};
int failed = 0;
foreach (var test in cases)
{
    string actual = BcLinuxPackagePaths.PackageDirectoryName(test.Path);
    if (actual == test.Expected) continue;
    Console.Error.WriteLine($"{test.Path}: expected '{test.Expected}', got '{actual}'");
    failed++;
}
Console.WriteLine($"{cases.Length} package path cases, {cases.Length - failed} passed, {failed} failed");
return failed == 0 ? 0 : 1;
