// Regression guard for issue #207: an OR filter on a DateFormula field matches every term.
//
// BC stores the unit of a formula as a control character (1D is "1" + U+0002, 1M is "1" + U+0005)
// and compares values with the session culture. ICU ignores control characters, so 1M and 1D
// compared equal and BC dropped a term: '1M|1D' matched the 1M rows only. Windows BC 27.5 and 28.5
// match the union. The dateformula IL patch in PatchNclTestPage breaks such ties ordinally.
// The expected rows below are the Windows results.
table 70078 "BC Linux DateFormula Row"
{
    DataClassification = SystemMetadata;

    fields
    {
        field(1; Id; Integer) { }
        field(2; Formula; DateFormula) { }
    }

    keys
    {
        key(PK; Id) { Clustered = true; }
    }
}

codeunit 70078 "BC Linux DateFormula Filter"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure OrFilterMatchesEveryTerm()
    begin
        Seed();
        LibraryAssert.AreEqual('1,2,4', Matches('1M|1D'), '1M|1D');
        LibraryAssert.AreEqual('1,2,4', Matches('1D|1M'), '1D|1M');
        LibraryAssert.AreEqual('1,2,4,5', Matches('1M|1D|1W'), '1M|1D|1W');
        LibraryAssert.AreEqual('1,4', Matches('1M|1M'), '1M|1M');
    end;

    local procedure Seed()
    begin
        AddRow(1, '<1M>');
        AddRow(2, '<1D>');
        AddRow(3, '');
        AddRow(4, '<1M>');
        AddRow(5, '<1W>');
    end;

    local procedure AddRow(Id: Integer; Formula: Text)
    var
        Row: Record "BC Linux DateFormula Row";
    begin
        Row.Id := Id;
        if Formula <> '' then
            Evaluate(Row.Formula, Formula);
        Row.Insert();
    end;

    local procedure Matches(Filter: Text) Ids: Text
    var
        Row: Record "BC Linux DateFormula Row";
    begin
        Row.SetFilter(Formula, Filter);
        if Row.FindSet() then
            repeat
                if Ids <> '' then
                    Ids += ',';
                Ids += Format(Row.Id);
            until Row.Next() = 0;
    end;
}
