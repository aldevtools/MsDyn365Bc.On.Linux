// Time zone checks for Patch #24 (StartupHook), W6b (WebClientHook) and BcLinuxTimeZoneLookup.
// Plain asserts, exit code 1 on the first failure. Must run on Linux: that is where a zone
// with DST rules does not survive ToSerializedString -> FromSerializedString. From the repository root:
//   docker run --rm -v "$PWD":/src -w /src/tests/timezone mcr.microsoft.com/dotnet/sdk:8.0-noble-amd64 dotnet run
using System;
using System.Linq;
using System.Reflection;

static class Program
{
    const BindingFlags Any = BindingFlags.Static | BindingFlags.NonPublic | BindingFlags.Public;
    static readonly Type NstHook = Type.GetType("StartupHook, StartupHook", true)!;
    static readonly Type WebHook = Type.GetType("StartupHook, WebClientHook", true)!;
    static int failures;

    static void Check(bool ok, string what)
    {
        Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {what}");
        if (!ok) failures++;
    }

    static bool RoundTrips(TimeZoneInfo tz)
    {
        try { TimeZoneInfo.FromSerializedString(tz.ToSerializedString()); return true; }
        catch { return false; }
    }

    static int Main()
    {
        int year = DateTime.UtcNow.Year;
        var winter = new DateTime(year, 1, 15, 12, 0, 0, DateTimeKind.Utc);
        var summer = new DateTime(year, 7, 15, 12, 0, 0, DateTimeKind.Utc);

        Check(!RoundTrips(TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin")),
            "precondition: a DST zone does not round-trip on this host (else these checks prove nothing)");

        // Patch #24: the substitute has a fixed offset, so it must be recomputed across a DST
        // transition, and stay the same instance within one offset period.
        var resolve = NstHook.GetMethod("ResolveClientTimeZone", Any)!;
        foreach (var id in new[] { "W. Europe Standard Time", "Eastern Standard Time", "Europe/Zurich" })
        {
            var rules = TimeZoneInfo.FindSystemTimeZoneById(id);
            var w = (TimeZoneInfo)resolve.Invoke(null, new object[] { id, winter })!;
            var s = (TimeZoneInfo)resolve.Invoke(null, new object[] { id, summer })!;
            var w2 = (TimeZoneInfo)resolve.Invoke(null, new object[] { id, winter })!;
            Check(w.Id == id && s.Id == id, $"Patch #24 {id}: id kept ('{w.Id}', '{s.Id}')");
            Check(w.BaseUtcOffset == rules.GetUtcOffset(winter), $"Patch #24 {id}: winter offset {w.BaseUtcOffset}");
            Check(s.BaseUtcOffset == rules.GetUtcOffset(summer), $"Patch #24 {id}: offset after the DST transition {s.BaseUtcOffset}");
            Check(ReferenceEquals(w, w2), $"Patch #24 {id}: same instance within one offset period");
            Check(RoundTrips(w) && RoundTrips(s), $"Patch #24 {id}: both substitutes round-trip");
        }
        var utc = (TimeZoneInfo)resolve.Invoke(null, new object[] { "UTC", summer })!;
        Check(utc.Id == "UTC" && utc.BaseUtcOffset == TimeSpan.Zero, "Patch #24 UTC: unchanged");

        // BcLinuxTimeZoneLookup (the "tzlookup" rewrite): no cache, the offset in effect now.
        foreach (var id in new[] { "W. Europe Standard Time", "Europe/Zurich", "India Standard Time" })
        {
            var rules = TimeZoneInfo.FindSystemTimeZoneById(id);
            var before = DateTime.UtcNow;
            bool found = BcLinuxTimeZoneLookup.TryFindSystemTimeZoneById(id, out var tz);
            Check(found && tz.Id == id && tz.GetAdjustmentRules().Length == 0 && RoundTrips(tz)
                && tz.BaseUtcOffset == rules.GetUtcOffset(before),
                $"tzlookup {id}: same id, offset now {tz?.BaseUtcOffset}, round-trips");
        }
        Check(!BcLinuxTimeZoneLookup.TryFindSystemTimeZoneById("No/Such_Zone", out _), "tzlookup: unknown id is not found");

        // W6b: which ids a browser in Europe/Zurich is given, in both BC_WINDOWS_TEXT modes.
        var zurich = TimeZoneInfo.FindSystemTimeZoneById("Europe/Zurich");
        var (start, end) = Transitions(zurich, year);
        var detect = WebHook.GetMethod("DetectWindowsTimeZone", Any)!;
        var cache = WebHook.GetField("_windowsZones", Any)!;
        TimeZoneInfo Detect(string? mode)
        {
            Environment.SetEnvironmentVariable("BC_WINDOWS_TEXT", mode);
            cache.SetValue(null, null);
            return (TimeZoneInfo)detect.Invoke(null, new object?[] { 60, 60, start, end, null })!;
        }
        var windowsIds = BcLinuxTimeZones.WindowsTimeZones().Select(z => z.Id).ToHashSet();
        var icuIds = TimeZoneInfo.GetSystemTimeZones().Select(z => z.Id).ToHashSet();

        var def = Detect(null);
        Check(def.Id == "W. Europe Standard Time", $"W6b default mode: Zurich browser -> '{def.Id}' (a Windows id, in the patched table)");
        var off = Detect("0");
        Check(icuIds.Contains(off.Id) && !windowsIds.Contains(off.Id),
            $"W6b BC_WINDOWS_TEXT=0: Zurich browser -> '{off.Id}' (in GetSystemTimeZones(), the unpatched table)");
        var offRules = TimeZoneInfo.FindSystemTimeZoneById(off.Id);
        Check(offRules.GetUtcOffset(winter) == zurich.GetUtcOffset(winter) && offRules.GetUtcOffset(summer) == zurich.GetUtcOffset(summer),
            $"W6b BC_WINDOWS_TEXT=0: '{off.Id}' has Zurich's offsets");
        Check(off.BaseUtcOffset == zurich.GetUtcOffset(DateTime.UtcNow) && RoundTrips(off),
            $"W6b BC_WINDOWS_TEXT=0: fixed offset now {off.BaseUtcOffset}, round-trips");
        Check(!icuIds.Contains("Etc/GMT-1"), "the old Etc/GMT-1 id is not in the ICU table either (so mode 0 was broken before too)");
        Environment.SetEnvironmentVariable("BC_WINDOWS_TEXT", null);

        Console.WriteLine(failures == 0 ? "ALL PASSED" : $"{failures} FAILED");
        return failures == 0 ? 0 : 1;
    }

    // The last UTC second before each offset change in the year: what ValidateDstStart/End
    // test for (offset at t < offset at t+1s for the start, > for the end).
    static (DateTime start, DateTime end) Transitions(TimeZoneInfo tz, int year)
    {
        DateTime start = DateTime.MinValue, end = DateTime.MinValue;
        var t = new DateTime(year, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        while (t.Year == year)
        {
            var next = t.AddMinutes(30);
            var a = tz.GetUtcOffset(t); var b = tz.GetUtcOffset(next);
            if (a != b)
            {
                var last = next.AddSeconds(-1);
                if (b > a) start = last; else end = last;
            }
            t = next;
        }
        return (start, end);
    }
}
