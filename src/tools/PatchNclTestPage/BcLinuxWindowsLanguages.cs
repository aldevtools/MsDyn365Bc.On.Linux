using System;
using System.Globalization;

/// <summary>
/// The cultures BC lists in the Windows Language and Language Selection tables (issues #198
/// and #223). Cloned into Nav.Types.dll
/// by HelperCloner, so the same rules apply as for BcLinuxCulture: framework calls only, no
/// lambdas, closures, static fields or try/catch.
///
/// WindowsLanguageHelper builds its culture list from CultureInfo.GetCultures. Windows lists
/// zh-TW, zh-HK, zh-SG and zh-MO there. ICU lists them only as zh-Hant-TW, zh-Hant-HK,
/// zh-Hans-SG and zh-Hant-MO, whose LCID is 4096, so BC's own filter drops them, and zh-Hant
/// (31748) then takes the abbreviation ZHH that zh-HK (3076) has on Windows. ICU also leaves
/// 34 other cultures out of the listing although it knows them by these names, with the
/// Windows LCID (issue #223: arn-CL, en-029, the Sami and Quechua cultures, ...). The names
/// are Windows data: the Language Selection table of Windows containers on BC 27.5, 28.5 and
/// 29.0, 248 rows each. Each is added only when the listing does not have it already. BC then
/// filters, sorts and removes duplicates as it always does, and lists the same 248 cultures.
/// </summary>
internal static class BcLinuxWindowsLanguages
{
    public static CultureInfo[] WindowsLanguageCultures(CultureTypes types)
    {
        CultureInfo[] listed = CultureInfo.GetCultures(types);
        if ((types & CultureTypes.SpecificCultures) == 0)
            return listed;

        string[] names = new string[]
        {
            "zh-TW", "zh-HK", "zh-SG", "zh-MO",
            "arn-CL", "ba-RU", "ca-ES-valencia", "chr-Cher-US", "co-FR", "dv-MV",
            "en-029", "gn-PY", "ha-Latn-NG", "iu-Cans-CA", "iu-Latn-CA", "ku-Arab-IQ",
            "mn-Mong-CN", "mn-Mong-MN", "moh-CA", "nso-ZA", "prs-AF", "quc-Latn-GT",
            "quz-BO", "quz-EC", "quz-PE", "sma-NO", "sma-SE", "smj-NO",
            "smj-SE", "sms-FI", "st-ZA", "tg-Cyrl-TJ", "tn-BW", "tn-ZA",
            "ts-ZA", "tzm-Arab-MA", "tzm-Latn-DZ", "tzm-Tfng-MA"
        };
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
