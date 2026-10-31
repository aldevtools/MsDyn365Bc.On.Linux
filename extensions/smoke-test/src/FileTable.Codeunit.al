// Regression guard for issue #199: the File virtual table (2000000022) lists a file AL just
// wrote.
//
// The table's Path field is Code[98], so BC upper-cases the filter: '/tmp/<folder>/' reaches
// BC's FileDataProvider as '/TMP/<FOLDER>/'. Windows (BC 27.5, 28.5) ignores the case and
// returns the file: Is a file = Yes, Size = 13, Date = Today. On Linux the folder did not exist
// in upper case and the table was empty. The filetable IL patch finds the folder ignoring case.
// The folder name is lower case on purpose, so that the upper-casing changes it.
//
// The table is opened by number because this app declares no platform dependency (see
// SmokeTest1). Fields: 1 Path, 2 Is a file, 3 Name, 4 Size, 5 Date, 7 Data.
codeunit 70077 "BC Linux File Table"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure FileTableListsAFileALWrote()
    var
        TempBlob: Codeunit "Temp Blob";
        FileRef: RecordRef;
        OutFile: File;
        Folder: Text;
        FileName: Text;
    begin
        Folder := '/tmp/bclinux-ft-' + LowerCase(DelChr(Format(CreateGuid()), '=', '{}-')) + '/';
        FileName := 'probe.txt';
        CreateFolder(Folder);
        LibraryAssert.IsTrue(OutFile.Create(Folder + FileName), 'File.Create');
        OutFile.Write('hello bc-linux');
        OutFile.Close();

        FileRef.Open(2000000022);
        FileRef.Field(1).SetRange(Folder);
        LibraryAssert.IsFalse(FileRef.IsEmpty(), 'File table is empty for the folder (issue #199)');
        FileRef.Field(2).SetRange(true);
        FileRef.Field(3).SetRange(FileName);
        LibraryAssert.IsTrue(FileRef.FindFirst(), 'File table has no row for the file (issue #199)');
        LibraryAssert.AreNotEqual(0, FileRef.Field(4).Value(), 'Size');
        LibraryAssert.AreEqual(Today(), FileRef.Field(5).Value(), 'Date');

        FileRef.Field(7).CalcField();
        TempBlob.FromFieldRef(FileRef.Field(7));
        LibraryAssert.AreEqual(FileRef.Field(4).Value(), TempBlob.Length(), 'Data has the file''s bytes');
        FileRef.Close();
        Erase(Folder + FileName);
    end;

    local procedure CreateFolder(Folder: Text)
    var
        Directory: DotNet BcLinuxDirectory;
    begin
        // AL has no "create folder", and File.Create into a missing folder fails as on Windows
        // (issue #189). BcLinuxDirectory is declared in TempFolderIO.Codeunit.al.
        Directory.CreateDirectory(Folder);
    end;
}
