using System;
using System.Globalization;

/// <summary>Language Selection's tag column: TextInfo.CultureName. See BcLinuxLanguageTag.</summary>
internal static class BcLinuxLanguageTextTag
{
    public static string WindowsTextInfoCultureName(TextInfo textInfo)
    {
        if (textInfo.LCID == 1127) return "ff-Latn-NG";
        if (textInfo.LCID == 2051) return "ca-ES-valencia";
        return textInfo.CultureName;
    }
}
