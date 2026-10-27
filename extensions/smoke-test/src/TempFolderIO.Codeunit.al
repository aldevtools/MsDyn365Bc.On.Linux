// Regression guard for issues #175, #176 and #181: AL's File functions and .NET System.IO
// must see the same folder under TemporaryPath().
//
// BC builds TemporaryPath() as Path.Combine(userFolder, 'TEMP\'), which ends in a backslash on
// every system. AL's File functions turn '\' into '/', but a DotNet DirectoryInfo or
// Directory.GetFiles got the raw string on Linux and found nothing, and MediaSet.ImportFile
// stored 'TEMP\name.png' as the file name because Path.GetFileName only splits at '/'. The
// PatchTempPath IL patch fixes both and leaves TemporaryPath() as it is.
//
// Issue #183: Windows matches '*.xml' against 'b.XML' and lists in name order. The listing
// methods of Directory and DirectoryInfo are routed through BcLinuxFileListing (the filelisting
// patch) to do the same.
//
// Issue #185: Directory.Exists(Path + '/') and a read-only call that must not make a folder.
// Issue #189: a write into a missing folder fails like Windows and does not make the folder.
//
// Expected values are what Windows BC 27.5, 28.5 and 29.0 containers reported.
dotnet
{
    assembly("mscorlib")
    {
        type("System.IO.Directory"; BcLinuxDirectory) { }
        type("System.IO.DirectoryInfo"; BcLinuxDirectoryInfo) { }
        type("System.IO.FileInfo"; BcLinuxFileInfo) { }
        type("System.IO.SearchOption"; BcLinuxSearchOption) { }
    }
}

codeunit 70075 "BC Linux Temp Folder IO"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";
        MissingPathTxt: Label 'Could not find a part of the path ''%1''.', Locked = true;
        ImportedTxt: Label 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', Locked = true;

    [Test]
    procedure DirectoryInfoListsFilesFileCreateWrote()
    var
        Folder: Text;
        Dir: DotNet BcLinuxDirectoryInfo;
        Directory: DotNet BcLinuxDirectory;
        Files: DotNet Array;
        Found: DotNet BcLinuxFileInfo;
        i: Integer;
        Names: Text;
    begin
        Folder := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Directory.CreateDirectory(Folder);
        WriteFile(Folder + '\a.xml');
        WriteFile(Folder + '\b.XML');
        WriteFile(Folder + '\c.xml');
        WriteFile(Folder + '\d.txt');
        WriteFile(Folder + '\e.xml.bak');

        Dir := Dir.DirectoryInfo(Folder);
        LibraryAssert.IsTrue(Dir.Exists, 'DirectoryInfo.Exists');
        Files := Dir.GetFiles('*.xml');
        LibraryAssert.AreEqual(3, Files.Length, 'GetFiles(*.xml) count');
        for i := 0 to Files.Length - 1 do begin
            Found := Files.GetValue(i);
            Names += '|' + Found.Name;
        end;
        Found := Files.GetValue(0);
        LibraryAssert.AreEqual(Folder + '\a.xml', Found.FullName, 'FileInfo.FullName');
        LibraryAssert.AreEqual(Folder, Dir.FullName, 'DirectoryInfo.FullName');
        LibraryAssert.AreEqual('|a.xml|b.XML|c.xml', Names, 'GetFiles(*.xml) names in order');
    end;

    [Test]
    procedure DirectoryGetFilesIsCaseInsensitiveAndSorted()
    var
        Directory: DotNet BcLinuxDirectory;
        Folder: Text;
        Files: DotNet Array;
    begin
        Folder := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Directory.CreateDirectory(Folder);
        WriteFile(Folder + '\c.xml');
        WriteFile(Folder + '\B.xml');
        WriteFile(Folder + '\a.XML');
        WriteFile(Folder + '\d.txt');

        Files := Directory.GetFiles(Folder, '*.xml');
        LibraryAssert.AreEqual(3, Files.Length, 'Directory.GetFiles(*.xml) count');
        LibraryAssert.AreEqual(Folder + '\a.XML', Format(Files.GetValue(0)), 'first');
        LibraryAssert.AreEqual(Folder + '\B.xml', Format(Files.GetValue(1)), 'second');
        LibraryAssert.AreEqual(Folder + '\c.xml', Format(Files.GetValue(2)), 'third');
    end;

    // .NET walks a tree folder by folder: the entries of a folder first, then its subfolders in
    // the order they were found. A sort of the full paths would put 'sub1\m.xml' between
    // 'a.xml' and 'z.xml'.
    [Test]
    procedure RecursiveListingListsAFolderBeforeItsSubfolders()
    var
        Directory: DotNet BcLinuxDirectory;
        Option: DotNet BcLinuxSearchOption;
        Folder: Text;
        Files: DotNet Array;
    begin
        Folder := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Directory.CreateDirectory(Folder + '\sub1\deeper');
        Directory.CreateDirectory(Folder + '\sub2');
        WriteFile(Folder + '\z.xml');
        WriteFile(Folder + '\a.xml');
        WriteFile(Folder + '\sub2\a.xml');
        WriteFile(Folder + '\sub1\M.xml');
        WriteFile(Folder + '\sub1\deeper\k.xml');

        Files := Directory.GetFiles(Folder, '*.xml', Option.AllDirectories);
        LibraryAssert.AreEqual(5, Files.Length, 'count');
        LibraryAssert.AreEqual(Folder + '\a.xml', Format(Files.GetValue(0)), '1');
        LibraryAssert.AreEqual(Folder + '\z.xml', Format(Files.GetValue(1)), '2');
        LibraryAssert.AreEqual(Folder + '\sub1\M.xml', Format(Files.GetValue(2)), '3');
        LibraryAssert.AreEqual(Folder + '\sub2\a.xml', Format(Files.GetValue(3)), '4');
        LibraryAssert.AreEqual(Folder + '\sub1\deeper\k.xml', Format(Files.GetValue(4)), '5');
    end;

    [Test]
    procedure TemporaryPathStillEndsInABackslash()
    var
        Temp: Text;
    begin
        Temp := TemporaryPath();
        LibraryAssert.IsTrue(Temp.EndsWith('TEMP\'), 'TemporaryPath() ends with TEMP\, got ' + Temp);
    end;

    [Test]
    procedure MediaSetImportFileStoresTheBareFileName()
    var
        Probe: Record "BC Linux Media Probe";
        TenantMedia: Record "Tenant Media";
        FileName: Text;
    begin
        Probe.DeleteAll();
        FileName := TemporaryPath() + 'bclinux-mediaset.png';
        WritePng(FileName);

        Probe.Init();
        Probe.Id := 1;
        Probe.Pictures.ImportFile(FileName, 'bc-linux probe');
        Probe.Insert();

        TenantMedia.Get(Probe.Pictures.Item(1));
        LibraryAssert.AreEqual('bclinux-mediaset.png', TenantMedia."File Name", 'Tenant Media File Name');
    end;

    // Issue #185: an AL expression such as Path + '/' reaches a DotNet call as a plain string and
    // used to skip the '\' to '/' conversion, so the folder AL made was not found.
    [Test]
    procedure DirectoryExistsAcceptsATrailingSeparator()
    var
        Directory: DotNet BcLinuxDirectory;
        Folder: Text;
    begin
        Folder := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Directory.CreateDirectory(Folder);
        LibraryAssert.IsTrue(Directory.Exists(Folder), 'Exists(folder)');
        LibraryAssert.IsTrue(Directory.Exists(Folder + '/'), 'Exists(folder + /)');
        LibraryAssert.IsTrue(Directory.Exists(Folder + '\'), 'Exists(folder + \)');
        LibraryAssert.IsFalse(Directory.Exists(Folder + '\missing'), 'Exists(missing subfolder)');
        Directory.Delete(Folder, true);
        LibraryAssert.IsFalse(Directory.Exists(Folder + '/'), 'Exists(deleted folder + /)');
    end;

    // Issue #185: a read-only call on a path in a missing folder must not make the folder
    // (File.Exists did, and a later Directory.Delete of the parent found it).
    [Test]
    procedure ReadOnlyFileCallsDoNotCreateTheFolder()
    var
        Directory: DotNet BcLinuxDirectory;
        InFile: File;
        Parent: Text;
        Missing: Text;
    begin
        Parent := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Missing := Parent + '\sub\x.txt';

        LibraryAssert.IsFalse(File.Exists(Missing), 'File.Exists');
        LibraryAssert.IsFalse(Directory.Exists(Parent), 'File.Exists made the parent folder');
        asserterror InFile.Open(Missing);
        LibraryAssert.IsFalse(Directory.Exists(Parent), 'File.Open made the parent folder');
        LibraryAssert.IsTrue(Directory.Exists(TemporaryPath()), 'TemporaryPath() exists');
    end;

    // Issue #189: Windows BC 27.5, 28.5 and 29.0 do not make a missing folder when AL writes into
    // it. File.Create fails with .NET's text, naming the path as AL passed it, and the folder is
    // not made.
    [Test]
    procedure FileCreateIntoAMissingFolderFails()
    var
        Directory: DotNet BcLinuxDirectory;
        OutFile: File;
        Parent: Text;
        Target: Text;
    begin
        Parent := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Target := Parent + '\a.txt';

        asserterror OutFile.Create(Target);

        LibraryAssert.AreEqual(StrSubstNo(MissingPathTxt, Target), GetLastErrorText(), 'File.Create error text');
        LibraryAssert.AreEqual('InvalidPath', GetLastErrorCode(), 'File.Create error code');
        LibraryAssert.IsFalse(Directory.Exists(Parent), 'File.Create made the folder');

        // Control: the same call directly in TemporaryPath() works.
        WriteFile(TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-') + '.txt');
    end;

    [Test]
    procedure ReportSaveAsPdfIntoAMissingFolderFails()
    var
        Directory: DotNet BcLinuxDirectory;
        Parent: Text;
        Target: Text;
    begin
        Parent := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Target := Parent + '\x.pdf';

        asserterror Report.SaveAsPdf(Report::"BC Linux Pdf Sections", Target);

        LibraryAssert.AreEqual(StrSubstNo(MissingPathTxt, Target), GetLastErrorText(), 'SaveAsPdf error text');
        LibraryAssert.AreEqual('InvalidPath', GetLastErrorCode(), 'SaveAsPdf error code');
        LibraryAssert.IsFalse(Directory.Exists(Parent), 'SaveAsPdf made the folder');
    end;

    // A folder that exists is written into, and a file can be copied and renamed inside it.
    [Test]
    procedure WritingIntoAnExistingFolderWorks()
    var
        Directory: DotNet BcLinuxDirectory;
        Parent: Text;
    begin
        Parent := TemporaryPath() + 'bclinux-io-' + DelChr(Format(CreateGuid()), '=', '{}-');
        Directory.CreateDirectory(Parent);

        WriteFile(Parent + '\a.xml');
        File.Copy(Parent + '\a.xml', Parent + '\b.xml');
        LibraryAssert.IsTrue(File.Exists(Parent + '\b.xml'), 'copied file exists');
        File.Rename(Parent + '\b.xml', Parent + '\c.xml');
        LibraryAssert.IsTrue(File.Exists(Parent + '\c.xml'), 'renamed file exists');
        LibraryAssert.IsFalse(File.Exists(Parent + '\b.xml'), 'renamed source is gone');

        Directory.Delete(Parent, true);
    end;

    local procedure WriteFile(FileName: Text)
    var
        OutFile: File;
        OutStr: OutStream;
    begin
        OutFile.Create(FileName);
        OutFile.CreateOutStream(OutStr);
        OutStr.WriteText('<x/>');
        OutFile.Close();
    end;

    local procedure WritePng(FileName: Text)
    var
        TempBlob: Codeunit "Temp Blob";
        Base64: Codeunit "Base64 Convert";
        InStr: InStream;
        OutStr: OutStream;
        OutFile: File;
        FileOutStr: OutStream;
    begin
        TempBlob.CreateOutStream(OutStr);
        Base64.FromBase64(ImportedTxt, OutStr);
        TempBlob.CreateInStream(InStr);
        OutFile.Create(FileName);
        OutFile.CreateOutStream(FileOutStr);
        CopyStream(FileOutStr, InStr);
        OutFile.Close();
    end;
}
