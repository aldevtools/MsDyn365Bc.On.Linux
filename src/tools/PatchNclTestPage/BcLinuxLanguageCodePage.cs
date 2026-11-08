using System;
using System.Globalization;

/// <summary>
/// The Windows Language table's Primary CodePage column (issue #223): TextInfo.OEMCodePage.
/// For the 44 cultures with no OEM code page of their own (Armenian, Georgian, Hindi, ...)
/// Windows BC 27.5 and 28.5 containers give 65001 and a BC 29 SaaS sandbox gives 1 (corpus
/// codeunit 92700). ICU gives 1 on .NET 8 and .NET 10, so only the .NET 8 tiers (BC 27 and 28)
/// need a different value.
/// </summary>
internal static class BcLinuxLanguageCodePage
{
    public static int WindowsOemCodePage(TextInfo textInfo)
    {
        int codePage = textInfo.OEMCodePage;
        if (codePage == 1 && Environment.Version.Major < 10)
            return 65001;
        return codePage;
    }
}
