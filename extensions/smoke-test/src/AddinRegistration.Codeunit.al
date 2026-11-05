// Issue #216: a successful publish must register the control packaged in this app.
// Checking the installed-app row or a TestPage alone does not catch a skipped registration.
codeunit 70080 "BC Linux Addin Registration"
{
    Subtype = Test;
    TestPermissions = Disabled;

    [Test]
    procedure PackagedControlIsRegistered()
    var
        TenantAddIns: RecordRef;
        AppField: FieldRef;
        NameField: FieldRef;
        AppId: Guid;
        LibraryAssert: Codeunit "Library Assert";
    begin
        Evaluate(AppId, 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee');
        TenantAddIns.Open(2000000169); // NAV App Tenant Add-In
        AppField := TenantAddIns.Field(1);
        AppField.SetRange(AppId);
        NameField := TenantAddIns.Field(2);
        NameField.SetRange('BC_Linux_Probe_Addin');
        LibraryAssert.AreEqual(1, TenantAddIns.Count(), 'The packaged control add-in was not registered during app installation.');
        TenantAddIns.FindFirst();
        LibraryAssert.AreEqual(0, TenantAddIns.Field(5).Value, 'The control must be registered as JavaScript.');
        LibraryAssert.IsTrue(Format(TenantAddIns.Field(3).Value) <> '', 'The control must have a public key token.');
        TenantAddIns.Close();
    end;
}
