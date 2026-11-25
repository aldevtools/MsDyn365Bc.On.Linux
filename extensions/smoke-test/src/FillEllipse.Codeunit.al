// Regression guard: System.Drawing.Graphics.FillEllipse and DrawEllipse.
//
// The Base Application's "O365 Brand Color".MakePicture() draws each brand colour with
// Graphics.FillEllipse(Brush, Int32, Int32, Int32, Int32). Contoso's Foundation module reaches
// it (CreateCompanyInformation calls CreateDefaultBrandColors), so the Contoso Demo Tool and a
// new company with evaluation data both stopped with "A call to
// System.Drawing.Graphics.FillEllipse failed with this message: The type of one or more
// arguments does not match the method's parameter type." DrawingStub had no FillEllipse. A
// Windows container draws the circle and returns.
//
// The stub's Graphics does not draw, so the test checks only that the calls return. It uses
// Brushes and Pens rather than Color or Rectangle: those live in System.Drawing.Primitives,
// which the AL 16/17 compilers of the BC 27/28 legs cannot resolve on Linux (AL0451).
dotnet
{
    assembly("System.Drawing.Common")
    {
        type("System.Drawing.Bitmap"; BcLinuxEllipseBitmap) { }
        type("System.Drawing.Graphics"; BcLinuxEllipseGraphics) { }
        type("System.Drawing.Brushes"; BcLinuxEllipseBrushes) { }
        type("System.Drawing.Pens"; BcLinuxEllipsePens) { }
    }
}

codeunit 70085 "BC Linux Fill Ellipse"
{
    Subtype = Test;
    TestPermissions = Disabled;

    [Test]
    procedure FillEllipseWithIntegersReturns()
    var
        Bitmap: DotNet BcLinuxEllipseBitmap;
        Graphics: DotNet BcLinuxEllipseGraphics;
        Brushes: DotNet BcLinuxEllipseBrushes;
    begin
        // The call "O365 Brand Color".MakePicture() makes.
        Bitmap := Bitmap.Bitmap(100, 100);
        Graphics := Graphics.FromImage(Bitmap);
        Graphics.FillEllipse(Brushes.Black, 0, 0, 100, 100);
        Graphics.Dispose();
        Bitmap.Dispose();
    end;

    [Test]
    procedure DrawEllipseWithIntegersReturns()
    var
        Bitmap: DotNet BcLinuxEllipseBitmap;
        Graphics: DotNet BcLinuxEllipseGraphics;
        Pens: DotNet BcLinuxEllipsePens;
    begin
        Bitmap := Bitmap.Bitmap(100, 100);
        Graphics := Graphics.FromImage(Bitmap);
        Graphics.DrawEllipse(Pens.Black, 0, 0, 100, 100);
        Graphics.Dispose();
        Bitmap.Dispose();
    end;
}
