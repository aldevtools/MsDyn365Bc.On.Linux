// Regression guard for issue #227: the text of an error raised in OnClosePage.
//
// BC's client layer (Nav.Client.UI, NavFormCloseHandler) shows such an error as
// "One or more errors occurred while closing the page." + two Environment.NewLine + the error.
// GetLastErrorText turns every CRLF into "\". On Windows both sides use CRLF, so AL reads
// "...closing the page.\\bc-linux close page error" (two backslashes). On Linux the client
// layer wrote LF while the patched Nav.Ncl looked for CRLF, so AL read two line feeds.
// Measured on Windows BC 27.5, 28.5 and 29.0 by the corpus (close-errors probe, PR 1277).
//
// The objects live in this file because nothing else uses them.
page 70084 "BC Linux Close Error Card"
{
    PageType = Card;
    SourceTable = "BC Linux Windows Text Blob";
    ApplicationArea = All;
    UsageCategory = None;

    layout
    {
        area(Content)
        {
            field(CloseId; Rec.Id) { ApplicationArea = All; }
        }
    }

    trigger OnClosePage()
    begin
        Error('bc-linux close page error');
    end;
}

codeunit 70084 "BC Linux Close Page Error"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure OnClosePageErrorTextUsesBackslashes()
    var
        Row: Record "BC Linux Windows Text Blob";
        Card: TestPage "BC Linux Close Error Card";
    begin
        Row.Id := 70084;
        Row.Insert();
        Card.OpenEdit();
        Card.GoToRecord(Row);
        asserterror Card.Close();
        LibraryAssert.AreEqual(
            'One or more errors occurred while closing the page.\\bc-linux close page error',
            GetLastErrorText(), 'OnClosePage error text (Windows: CRLF CRLF becomes two backslashes)');
    end;
}
