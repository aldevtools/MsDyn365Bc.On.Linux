using System;
using System.Globalization;

/// <summary>
/// The cultures BC lists in the Windows Language table (issue #198). Cloned into Nav.Types.dll
/// by HelperCloner, so the same rules apply as for BcLinuxCulture: framework calls only, no
/// lambdas, closures, static fields or try/catch.
///
/// WindowsLanguageHelper builds its culture list from CultureInfo.GetCultures. Windows lists
/// zh-TW, zh-HK, zh-SG and zh-MO there. ICU lists them only as zh-Hant-TW, zh-Hant-HK,
/// zh-Hans-SG and zh-Hant-MO, whose LCID is 4096, so BC's own filter drops them, and zh-Hant
/// (31748) then takes the abbreviation ZHH that zh-HK (3076) has on Windows. The four names
/// are Windows data, confirmed on Windows BC 27.5 and 28.5 and a BC 29 SaaS sandbox; ICU in
/// the image hides no other culture that has a Windows LCID. Each is added only when the
/// listing does not have it already. BC then sorts and removes duplicates as it always does.
/// </summary>
internal static class BcLinuxWindowsLanguages
{
    public static CultureInfo[] WindowsLanguageCultures(CultureTypes types)
    {
        CultureInfo[] listed = CultureInfo.GetCultures(types);
        if ((types & CultureTypes.SpecificCultures) == 0)
            return listed;

        string[] names = new string[] { "zh-TW", "zh-HK", "zh-SG", "zh-MO" };
        CultureInfo[] all = new CultureInfo[listed.Length + names.Length];
        Array.Copy(listed, all, listed.Length);
        int count = listed.Length;
        for (int i = 0; i < names.Length; i++)
        {
            bool found = false;
            for (int j = 0; j < listed.Length; j++)
            {
                if (string.Equals(listed[j].Name, names[i], StringComparison.OrdinalIgnoreCase))
                    found = true;
            }
            if (!found)
            {
                all[count] = CultureInfo.GetCultureInfo(names[i]);
                count++;
            }
        }
        if (count == all.Length)
            return all;
        CultureInfo[] result = new CultureInfo[count];
        Array.Copy(all, result, count);
        return result;
    }
}
