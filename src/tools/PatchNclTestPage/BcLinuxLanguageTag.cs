using System;
using System.Globalization;

/// <summary>
/// The language tag columns (issue #223): CultureInfo.Name in the Windows Language table,
/// TextInfo.CultureName in Language Selection. ICU names 1127 "ff-NG" and 2051
/// "ca-ES-VALENCIA"; Windows names them "ff-Latn-NG" and "ca-ES-valencia" in both tables
/// (measured on Windows BC 27.5, 28.5 and 29.0). Every other tag already matches. Cloned by
/// HelperCloner, same rules as BcLinuxLanguageName.
/// </summary>
internal static class BcLinuxLanguageTag
{
    public static string WindowsCultureName(CultureInfo culture)
    {
        string tag = Fix(culture.LCID);
        return tag.Length > 0 ? tag : culture.Name;
    }

    static string Fix(int lcid)
    {
        if (lcid == 1127) return "ff-Latn-NG";
        if (lcid == 2051) return "ca-ES-valencia";
        return "";
    }
}
