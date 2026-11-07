// Regression guard for issue #218: the server_settings input reaches CustomSettings.config.
//
// test-versions.yml starts the tier with DisableWriteInsideTryFunctions=false. A default tier
// has it true and refuses a database write inside a TryFunction whose result is used, so the
// insert below only succeeds when the setting was applied before NST started.
table 70081 "BC Linux Server Setting Row"
{
    DataClassification = SystemMetadata;

    fields
    {
        field(1; Id; Integer) { }
    }

    keys
    {
        key(PK; Id) { Clustered = true; }
    }
}

codeunit 70081 "BC Linux Server Settings"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure WriteInsideTryFunctionIsAllowed()
    var
        Row: Record "BC Linux Server Setting Row";
    begin
        LibraryAssert.IsTrue(TryInsert(), 'Insert inside a TryFunction was refused: ' + GetLastErrorText());
        LibraryAssert.IsTrue(Row.Get(1), 'The row inserted inside the TryFunction is missing');
    end;

    [TryFunction]
    local procedure TryInsert()
    var
        Row: Record "BC Linux Server Setting Row";
    begin
        Row.Id := 1;
        Row.Insert();
    end;
}
