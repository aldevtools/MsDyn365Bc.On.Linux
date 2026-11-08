// Regression guard for issue #222: a temporary table sorts Code and Text keys as Windows does.
//
// A temporary table compares keys with the database collation's culture: NLS on Windows, ICU on
// Linux. NLS gives the hyphen and the apostrophe no weight at the first level, as SQL Server does
// for a normal table, and orders the other ASCII punctuation differently from ICU. On Linux the
// temporary table put A-B before AB. The stringcompare IL patch in PatchNclTestPage restores the
// Windows order. The expected orders below are the
// Windows BC 27.5 and 29.0 results from the issue.
table 70082 "BC Linux Sort Row"
{
    DataClassification = SystemMetadata;

    fields
    {
        field(1; "Code Key"; Code[50]) { }
        field(2; "Text Value"; Text[50]) { }
    }

    keys
    {
        key(PK; "Code Key") { Clustered = true; }
        key(TextKey; "Text Value") { }
    }
}

codeunit 70082 "BC Linux Temp Table Sort"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        WindowsOrderTxt: Label 'A.B|AB|A-B|TTS.001|TTSA|TTS-A|TTS-HD.001', Locked = true;

    [Test]
    procedure TemporaryCodeKeySortsAsOnWindows()
    var
        TempRow: Record "BC Linux Sort Row" temporary;
    begin
        Seed(TempRow);
        LibraryAssert.AreEqual(WindowsOrderTxt, Order(TempRow, false), 'temporary table, Code key, ascending');
        LibraryAssert.AreEqual('TTS-HD.001|TTS-A|TTSA|TTS.001|A-B|AB|A.B', Order(TempRow, true), 'temporary table, Code key, descending');
    end;

    [Test]
    procedure TemporaryTextKeySortsAsOnWindows()
    var
        TempRow: Record "BC Linux Sort Row" temporary;
    begin
        Seed(TempRow);
        TempRow.SetCurrentKey("Text Value");
        LibraryAssert.AreEqual(WindowsOrderTxt, Order(TempRow, false), 'temporary table, Text key, ascending');
    end;

    [Test]
    procedure TemporaryFiltersFollowTheWindowsOrder()
    var
        TempRow: Record "BC Linux Sort Row" temporary;
    begin
        Seed(TempRow);
        TempRow.SetFilter("Code Key", '>%1', 'AB');
        LibraryAssert.AreEqual('A-B|TTS.001|TTSA|TTS-A|TTS-HD.001', Order(TempRow, false), 'filter >AB');
        TempRow.SetRange("Code Key", 'AB', 'TTSA');
        LibraryAssert.AreEqual('AB|A-B|TTS.001|TTSA', Order(TempRow, false), 'range AB..TTSA');
    end;

    // Other ASCII punctuation is in another order under ICU too: Linux had _B before !B and $B
    // last. Windows BC 27.5 and 29.0, corpus codeunit 95572, measured 2026-11-07.
    [Test]
    procedure TemporaryPunctuationSortsAsOnWindows()
    var
        TempRow: Record "BC Linux Sort Row" temporary;
    begin
        Add(TempRow, 'B');
        Add(TempRow, '+B');
        Add(TempRow, '~B');
        Add(TempRow, '_B');
        Add(TempRow, '$B');
        Add(TempRow, '!B');
        LibraryAssert.AreEqual('!B|$B|_B|~B|+B|B', Order(TempRow, false), 'temporary table, leading punctuation');
    end;

    [Test]
    procedure NormalTableAgreesWithTemporaryTable()
    var
        Row: Record "BC Linux Sort Row";
    begin
        Seed(Row);
        LibraryAssert.AreEqual(WindowsOrderTxt, Order(Row, false), 'normal table (SQL Server), Code key');
    end;

    local procedure Seed(var Row: Record "BC Linux Sort Row")
    begin
        Add(Row, 'TTS.001');
        Add(Row, 'TTS-HD.001');
        Add(Row, 'TTSA');
        Add(Row, 'TTS-A');
        Add(Row, 'A-B');
        Add(Row, 'AB');
        Add(Row, 'A.B');
    end;

    local procedure Add(var Row: Record "BC Linux Sort Row"; Value: Text)
    begin
        Row.Init();
        Row."Code Key" := CopyStr(Value, 1, MaxStrLen(Row."Code Key"));
        Row."Text Value" := CopyStr(Value, 1, MaxStrLen(Row."Text Value"));
        Row.Insert();
    end;

    local procedure Order(var Row: Record "BC Linux Sort Row"; Descending: Boolean) Result: Text
    begin
        Row.Ascending(not Descending);
        if Row.FindSet() then
            repeat
                if Result <> '' then
                    Result += '|';
                Result += Row."Code Key";
            until Row.Next() = 0;
    end;
}
