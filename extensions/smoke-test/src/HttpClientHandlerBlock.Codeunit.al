// Regression guard for issue #192: an [HttpClientHandler] under BlockOutboundRequests.
//
// Windows BC 27.5, 28.5 and 29.0 call the handler, and Get returns its status and body.
// BC only calls the handler when IServiceTopology.IsServiceRunningInLocalEnvironment is true.
// Patch #9 answers false for that on Linux, so on BC 27 and 28 the handler was never called
// and Get failed with TestCodeunitUnhandledHttpRequest.
codeunit 70076 "BC Linux Http Handler Block"
{
    Subtype = Test;
    TestPermissions = Disabled;
    TestHttpRequestPolicy = BlockOutboundRequests;

    var
        LibraryAssert: Codeunit "Library Assert";
        HandlerCalls: Integer;
        HandlerBodyTxt: Label 'handled by bc-linux', Locked = true;

    [Test]
    [HandlerFunctions('MockedHttpHandler')]
    procedure HandlerAnswersGet()
    var
        Client: HttpClient;
        Response: HttpResponseMessage;
        Body: Text;
    begin
        HandlerCalls := 0;
        LibraryAssert.IsTrue(Client.Get('https://example.com/bc-linux', Response), 'Get result');
        LibraryAssert.AreEqual(1, HandlerCalls, 'handler calls');
        LibraryAssert.AreEqual(200, Response.HttpStatusCode(), 'status code');
        Response.Content.ReadAs(Body);
        LibraryAssert.AreEqual(HandlerBodyTxt, Body, 'body');
    end;

    [Test]
    procedure GetWithoutHandlerIsBlocked()
    var
        Client: HttpClient;
        Response: HttpResponseMessage;
    begin
        asserterror Client.Get('https://example.com/bc-linux', Response);
        LibraryAssert.AreEqual('TestCodeunitUnhandledHttpRequest', GetLastErrorCode(), 'error code');
    end;

    [HttpClientHandler]
    procedure MockedHttpHandler(Request: TestHttpRequestMessage; var Response: TestHttpResponseMessage): Boolean
    begin
        HandlerCalls += 1;
        Response.HttpStatusCode := 200;
        Response.Content.WriteFrom(HandlerBodyTxt);
        exit(false);
    end;
}
