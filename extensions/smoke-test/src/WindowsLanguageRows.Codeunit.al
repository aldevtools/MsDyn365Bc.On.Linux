// Regression guard for GitHub issue #223. Windows containers on BC 27.5, 28.5 and 29.0 list 248
// rows in both Language Selection and Windows Language. The image listed 214: ICU leaves 34
// cultures out of CultureInfo.GetCultures although it knows them by their Windows names
// (arn-CL, en-029, the Sami and Quechua cultures, ...). BC also builds each row from ICU's
// culture data, so 49 names, two tags, one abbreviation and, on BC 27/28, the Primary CodePage
// of 44 rows differed. BC 29 reads the abbreviation from its own table off Windows, which has
// QUT for 1158 and nothing for 1164 (ZZZ). The expected values below are the Windows ones (the Language Selection
// table read on Windows, and corpus codeunit 92700 for Windows Language).
codeunit 70083 "BC Linux Windows Language Rows"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure LanguageSelectionHasTheWindowsRows()
    var
        LanguageSelection: Record "Language Selection";
    begin
        LibraryAssert.AreEqual(248, LanguageSelection.Count(), 'Language Selection row count');
        AssertSelection(1034, 'Spanish (Spain, Traditional Sort)', 'es-ES_tradnl', 'ESP');
        AssertSelection(1127, 'Fulah (Latin, Nigeria)', 'ff-Latn-NG', 'ZZZ');
        AssertSelection(1158, 'K''iche'' (Guatemala)', 'quc-Latn-GT', 'QUC');
        AssertSelection(2051, 'Valencian (Spain)', 'ca-ES-valencia', 'VAL');
        AssertSelection(2107, 'Sami, Northern (Sweden)', 'se-SE', 'SMF');
        AssertSelection(9225, 'English (Caribbean)', 'en-029', 'ENB');
        AssertSelection(1027, 'Catalan (Catalan)', 'ca-ES', 'CAT');
        AssertSelection(1164, 'Dari (Afghanistan)', 'prs-AF', 'PRS');
    end;

    [Test]
    procedure WindowsLanguageHasTheWindowsRows()
    var
        WindowsLanguage: Record "Windows Language";
    begin
        LibraryAssert.AreEqual(248, WindowsLanguage.Count(), 'Windows Language row count');
        AssertWindows(1034, 'Spanish (Spain, Traditional Sort)', 'es-ES', 'ESP', '850');
        AssertWindows(1127, 'Fulah (Latin, Nigeria)', 'ff-Latn-NG', 'ZZZ', '850');
        AssertWindows(1158, 'K''iche'' (Guatemala)', 'quc-Latn-GT', 'QUC', '850');
        AssertWindows(2051, 'Valencian (Spain)', 'ca-ES-valencia', 'VAL', '850');
        AssertWindows(3082, 'Spanish (Spain, International Sort)', 'es-ES', 'ESN', '850');
        AssertWindows(1067, 'Armenian (Armenia)', 'hy-AM', 'HYE', Utf8CodePage());
        AssertWindows(1081, 'Hindi (India)', 'hi-IN', 'HIN', Utf8CodePage());
    end;

    // Windows BC 27.5 and 28.5 give 65001 for a culture with no OEM code page, a BC 29 SaaS
    // sandbox gives 1. The System Application's version gives the BC major.
    local procedure Utf8CodePage(): Text
    var
        Info: ModuleInfo;
    begin
        NavApp.GetModuleInfo('63ca2fa4-4f03-4f2b-a480-172fef340d3f', Info);
        if Info.AppVersion.Major >= 29 then
            exit('1');
        exit('65001');
    end;

    local procedure AssertSelection(LanguageId: Integer; Name: Text; Tag: Text; Abbreviation: Text)
    var
        LanguageSelection: Record "Language Selection";
    begin
        LanguageSelection.SetRange("Language ID", LanguageId);
        LibraryAssert.IsTrue(LanguageSelection.FindFirst(), StrSubstNo('Language Selection has no row for %1', LanguageId));
        LibraryAssert.AreEqual(Name, LanguageSelection.Name, StrSubstNo('Language Selection name of %1', LanguageId));
        LibraryAssert.AreEqual(Tag, LanguageSelection."Language Tag", StrSubstNo('Language Selection tag of %1', LanguageId));
        LibraryAssert.AreEqual(Abbreviation, LanguageSelection."Abbreviated Name", StrSubstNo('Language Selection abbreviation of %1', LanguageId));
    end;

    local procedure AssertWindows(LanguageId: Integer; Name: Text; Tag: Text; Abbreviation: Text; CodePage: Text)
    var
        WindowsLanguage: Record "Windows Language";
    begin
        LibraryAssert.IsTrue(WindowsLanguage.Get(LanguageId), StrSubstNo('Windows Language has no row for %1', LanguageId));
        LibraryAssert.AreEqual(Name, WindowsLanguage.Name, StrSubstNo('Windows Language name of %1', LanguageId));
        LibraryAssert.AreEqual(Tag, WindowsLanguage."Language Tag", StrSubstNo('Windows Language tag of %1', LanguageId));
        LibraryAssert.AreEqual(Abbreviation, WindowsLanguage."Abbreviated Name", StrSubstNo('Windows Language abbreviation of %1', LanguageId));
        LibraryAssert.AreEqual(CodePage, WindowsLanguage."Primary CodePage", StrSubstNo('Windows Language Primary CodePage of %1', LanguageId));
    end;
}
