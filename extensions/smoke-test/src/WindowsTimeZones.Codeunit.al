// Regression guard for issue #132: the virtual table "Time Zone" (2000000164).
//
// BC fills the table from TimeZoneInfo.GetSystemTimeZones(). On Windows that is the 144
// Windows time zones, with Windows ids and display names; on Linux it was 419 IANA zones, so
// AL code that looks up 'W. Europe Standard Time' found nothing. `PatchNclTestPage culture`
// hands the table the Windows list instead (BcLinuxTimeZones.cs).
//
// Every expected value is what an official Windows container reported (BC 27.5 and 29.0).
//
// The session and user time zone tests guard the other end of the same table: the id BC stores
// for a session must be one of those Windows ids, or "Time Zone Selection" (My Settings) fails
// with "'Time Zone' does not exist. =<>". Patch #24 and the web client's W6b used to store
// 'Etc/GMT-1' for a Europe/Zurich browser.
codeunit 70041 "BC Linux Time Zone Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure TableHoldsTheWindowsTimeZones()
    var
        TimeZone: Record "Time Zone";
    begin
        LibraryAssert.AreEqual(144, TimeZone.Count(), 'number of time zones');
    end;

    [Test]
    procedure WindowsIdsAreNumberedAsOnWindows()
    begin
        CheckZone(1, 'Dateline Standard Time', '(UTC-12:00) International Date Line West');
        CheckZone(2, 'UTC-11', '');
        CheckZone(3, 'Aleutian Standard Time', '');
        CheckZone(50, 'UTC', '(UTC) Coordinated Universal Time');
        CheckZone(55, 'W. Europe Standard Time', '(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna');
        CheckZone(144, 'Line Islands Standard Time', '');
    end;

    [Test]
    procedure IanaIdsAreNotListed()
    var
        TimeZone: Record "Time Zone";
    begin
        TimeZone.SetRange(ID, 'Europe/Berlin');
        LibraryAssert.RecordIsEmpty(TimeZone);
    end;

    [Test]
    procedure SessionTimeZoneIsListed()
    var
        CurrentSession: SessionSettings;
    begin
        CurrentSession.Init();
        CheckListed(CurrentSession.TimeZone());
    end;

    [Test]
    procedure UserTimeZoneIsListed()
    var
        UserPersonalization: Record "User Personalization";
    begin
        if not UserPersonalization.Get(UserSecurityId()) then
            exit;
        if UserPersonalization."Time Zone" = '' then
            exit;
        CheckListed(UserPersonalization."Time Zone");
    end;

    [Test]
    procedure IdsTheHooksStoreAreListed()
    begin
        // What the web client hook maps UTC, Europe/Zurich, America/New_York and Asia/Kolkata
        // browsers to, as Windows' own detection does.
        CheckListed('UTC');
        CheckListed('W. Europe Standard Time');
        CheckListed('Eastern Standard Time');
        CheckListed('India Standard Time');
    end;

    local procedure CheckListed(Id: Text)
    var
        TimeZone: Record "Time Zone";
        TimeZoneSelection: Codeunit "Time Zone Selection";
    begin
        TimeZone.SetRange(ID, Id);
        LibraryAssert.RecordIsNotEmpty(TimeZone);
        // My Settings' path: errors with "'Time Zone' does not exist. =<>" for an unlisted id.
        LibraryAssert.AreNotEqual('', TimeZoneSelection.GetTimeZoneDisplayName(CopyStr(Id, 1, 180)), 'display name of ' + Id);
    end;

    local procedure CheckZone(No: Integer; Id: Text; DisplayName: Text)
    var
        TimeZone: Record "Time Zone";
    begin
        TimeZone.SetRange(ID, Id);
        LibraryAssert.IsTrue(TimeZone.FindFirst(), 'time zone ' + Id);
        LibraryAssert.AreEqual(No, TimeZone."No.", 'No. of ' + Id);
        if DisplayName <> '' then
            LibraryAssert.AreEqual(DisplayName, TimeZone."Display Name", 'Display Name of ' + Id);
    end;
}
