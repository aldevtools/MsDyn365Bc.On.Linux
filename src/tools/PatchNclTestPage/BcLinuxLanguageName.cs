using System;
using System.Globalization;

/// <summary>
/// The Name column of the Windows Language and Language Selection tables (issue #223). BC reads
/// CultureInfo.EnglishName, which is ICU's English name here and NLS's on Windows. The 49 names
/// below are the ones that differ, read from the Language Selection table of Windows containers
/// on BC 27.5, 28.5 and 29.0 (all three identical). Every other culture keeps its EnglishName,
/// which already matches Windows. Looked up by LCID, so a newer ICU with other English names
/// still gets the Windows text.
///
/// Cloned by HelperCloner: framework calls only, no lambdas, closures, static fields or
/// try/catch, and the data is a string array (an int[] initializer would compile to a helper
/// outside the class).
/// </summary>
internal static class BcLinuxLanguageName
{
    public static string WindowsEnglishName(CultureInfo culture)
    {
        string lcid = culture.LCID.ToString(CultureInfo.InvariantCulture);
        string[] names = new string[]
        {
            "1027", "Catalan (Catalan)",
            "1028", "Chinese (Traditional, Taiwan)",
            "1034", "Spanish (Spain, Traditional Sort)",
            "1042", "Korean (Korea)",
            "1069", "Basque (Basque)",
            "1072", "Sesotho (South Africa)",
            "1073", "Xitsonga (South Africa)",
            "1074", "Setswana (South Africa)",
            "1076", "isiXhosa (South Africa)",
            "1077", "isiZulu (South Africa)",
            "1083", "Sami, Northern (Norway)",
            "1089", "Kiswahili (Kenya)",
            "1093", "Bengali (India)",
            "1109", "Burmese (Myanmar)",
            "1110", "Galician (Galician)",
            "1117", "Inuktitut (Syllabics, Canada)",
            "1127", "Fulah (Latin, Nigeria)",
            "1132", "Sesotho sa Leboa (South Africa)",
            "1144", "Yi (China)",
            "1148", "Mohawk (Mohawk)",
            "1153", "Maori (New Zealand)",
            "1156", "Alsatian (France)",
            "1157", "Sakha (Russia)",
            "1158", "K'iche' (Guatemala)",
            "1170", "Central Kurdish (Iraq)",
            "2051", "Valencian (Spain)",
            "2052", "Chinese (Simplified, China)",
            "2098", "Setswana (Botswana)",
            "2107", "Sami, Northern (Sweden)",
            "2118", "Punjabi (Pakistan)",
            "2128", "Mongolian (Traditional Mongolian, China)",
            "2137", "Sindhi (Pakistan)",
            "2151", "Fulah (Latin, Senegal)",
            "3076", "Chinese (Traditional, Hong Kong SAR)",
            "3082", "Spanish (Spain, International Sort)",
            "3131", "Sami, Northern (Finland)",
            "3152", "Mongolian (Traditional Mongolian, Mongolia)",
            "4100", "Chinese (Simplified, Singapore)",
            "4155", "Sami, Lule (Norway)",
            "5124", "Chinese (Traditional, Macao SAR)",
            "5179", "Sami, Lule (Sweden)",
            "6203", "Sami, Southern (Norway)",
            "7194", "Serbian (Cyrillic, Bosnia and Herzegovina)",
            "7227", "Sami, Southern (Sweden)",
            "8218", "Bosnian (Cyrillic, Bosnia and Herzegovina)",
            "8251", "Sami, Skolt (Finland)",
            "9228", "French Congo (DRC)",
            "9275", "Sami, Inari (Finland)",
            "15369", "English (Hong Kong SAR)",
        };
        for (int i = 0; i < names.Length; i += 2)
        {
            if (string.Equals(names[i], lcid, StringComparison.Ordinal))
                return names[i + 1];
        }
        return culture.EnglishName;
    }
}
