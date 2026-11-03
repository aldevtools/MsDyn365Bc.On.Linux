// Regression guard for issue #214: GetUrl for the web client has the same shape as on Windows.
//
// BC builds this URL from PublicWebBaseUrl. With that setting empty the URL is
// http://<host>:<port>/BC/?company=X, as on a Windows container. BC_WEBCLIENT=1 sets it to
// http://localhost:8080/, and the URL becomes http://localhost:8080/?company=X. BC_WEBCLIENT=1 was
// in the tracked .env from 2026-10-28, so every CI run started the web client and got that URL.
//
// This codeunit therefore fails on a stack started with BC_WEBCLIENT=1. That is expected.
codeunit 70079 "BC Linux GetUrl Web Client"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        LibraryAssert: Codeunit "Library Assert";

    [Test]
    procedure CompanyUrlHasPathAndSlash()
    var
        Url: Text;
    begin
        Url := GetUrl(ClientType::Web, CompanyName());
        LibraryAssert.IsTrue(Url.Contains('/BC/?company='), Url);
    end;

    [Test]
    procedure PageUrlHasPathAndSlash()
    var
        Url: Text;
    begin
        Url := GetUrl(ClientType::Web, '', ObjectType::Page, 21);
        LibraryAssert.IsTrue(Url.Contains('/BC/?page=21'), Url);
    end;

    [Test]
    procedure UrlWithoutArgumentsEndsWithPath()
    var
        Url: Text;
    begin
        Url := GetUrl(ClientType::Web);
        LibraryAssert.IsTrue(Url.EndsWith('/BC'), Url);
    end;
}
