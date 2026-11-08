using System;
using System.Globalization;

/// <summary>
/// The Abbreviated Name column (issue #223): CultureInfo.ThreeLetterWindowsLanguageName. ICU
/// gives "QUT" for K'iche' (1158); Windows gives "QUC" (measured on Windows BC 27.5, 28.5 and
/// 29.0). Every other abbreviation already matches. Only WindowsLanguageHelper.AbbreviatedName
/// goes through this; BC's duplicate check in GetDistinctCultures keeps the ICU value. BC 29
/// reads the abbreviation off Windows from its own table (WindowsLanguageNameLookup), which has
/// QUT for 1158 and no row for 1164 (Dari, ZZZ); Windows gives QUC and PRS. ICU plus the one
/// value below matches Windows for all 248 rows, so BC 29 goes through this too.
/// </summary>
internal static class BcLinuxLanguageAbbreviation
{
    public static string WindowsAbbreviatedName(CultureInfo culture)
    {
        if (culture.LCID == 1158) return "QUC";
        return culture.ThreeLetterWindowsLanguageName;
    }
}
