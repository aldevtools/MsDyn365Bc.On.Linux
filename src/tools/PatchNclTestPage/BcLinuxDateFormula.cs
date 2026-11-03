using System.Globalization;

/// <summary>
/// Comparing two DateFormula values (issue #207). Cloned into Nav.Ncl.dll by HelperCloner, so the
/// same rules apply as for BcLinuxCulture: framework calls only, no lambdas, closures, static
/// fields or try/catch.
///
/// BC stores the unit of a formula as a control character: 1D is "1\u0002", 1W is "1\u0004", 1M
/// is "1\u0005". NavStringValue.CompareTo uses the session culture, and ICU ignores control
/// characters, so all of them compare equal to each other and to "1". BC then treats the filter
/// '1M|1D' as '1M|1M' and matches only the 1M rows. A Windows tier matches both. When the culture
/// comparison says two different values are equal, the ordinal comparison decides.
/// </summary>
internal static class BcLinuxDateFormula
{
    public static int DateFormulaCompare(string left, string right, bool ignoreCase, CultureInfo culture)
    {
        int result = string.Compare(left, right, ignoreCase, culture);
        return result != 0 ? result : string.CompareOrdinal(left, right);
    }
}
