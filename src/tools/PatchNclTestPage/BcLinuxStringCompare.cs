using System;
using System.Globalization;

/// <summary>
/// Sorting Code and Text values in a temporary table (issue #222). Cloned into Nav.Ncl.dll by
/// HelperCloner, so the same rules apply as for BcLinuxCulture: framework calls only, no lambdas,
/// closures, static fields or try/catch.
///
/// Temporary tables and their filters compare keys with CollationAwareStringComparer, which uses
/// the CompareInfo of the database collation's culture: NLS on Windows, ICU on Linux. The two
/// order ASCII punctuation differently, and NLS gives the hyphen and the apostrophe no weight at
/// the first level, as SQL Server does for a normal table:
///
///   Windows (NLS)  space ! " # $ % &amp; ( ) * , . / : ; ? @ [ \ ] ^ _ ` { | } ~ + &lt; = &gt;   (' and - ignored)
///   Linux (ICU)    space _ - , ; : ! ? . ' " ( ) [ ] { } @ * / \ &amp; # % ` ^ + &lt; = &gt; | ~ $
///
/// Both orders were measured with corpus codeunit 95572 (KeyPunctuationOrder.al) on Windows BC
/// 27.5/29.0 and on this container. All of these sort before digits and letters on both sides.
///
/// Values with no ASCII punctuation are compared exactly as before. Otherwise each value is
/// compared without its hyphens and apostrophes and with every other punctuation character
/// replaced by the ICU character that has its Windows rank, so ICU produces the Windows order.
/// On a tie, the value whose apostrophe or hyphen comes first sorts after the other one, and an
/// apostrophe before a hyphen, as on Windows. Letters, digits and everything outside ASCII keep
/// ICU's order.
/// </summary>
internal static class BcLinuxStringCompare
{
    // Replaces compareInfo.Compare(left, right, options) in CollationAwareStringComparer.Compare:
    // the instance and the arguments are on the stack in the same order.
    public static int CollationCompare(CompareInfo compareInfo, ReadOnlySpan<char> left, ReadOnlySpan<char> right, CompareOptions options)
    {
        string l = new string(left);
        string r = new string(right);
        if (!HasPunctuation(l) && !HasPunctuation(r))
            return compareInfo.Compare(l, r, options);

        int primary = compareInfo.Compare(Key(l), Key(r), options);
        if (primary != 0) return primary;

        // Tie: the apostrophe and the hyphen decide, by position. A position where one value has
        // one of them and the other value has another character sorts that value after.
        int length = l.Length < r.Length ? l.Length : r.Length;
        for (int i = 0; i < length; i++)
        {
            int li = IgnoredRank(l[i]);
            int ri = IgnoredRank(r[i]);
            if (li != ri)
            {
                if (li == 0) return -1;
                if (ri == 0) return 1;
                return li < ri ? -1 : 1;
            }
        }
        if (l.Length != r.Length) return l.Length < r.Length ? -1 : 1;
        return compareInfo.Compare(l, r, options);
    }

    // 0 for any other character, 1 for the apostrophe, 2 for the hyphen.
    static int IgnoredRank(char c)
    {
        if (c == '\'') return 1;
        if (c == '-') return 2;
        return 0;
    }

    static bool HasPunctuation(string value)
    {
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c > ' ' && c < '0') return true;
            if (c > '9' && c < 'A') return true;
            if (c > 'Z' && c < 'a') return true;
            if (c > 'z' && c < (char)127) return true;
        }
        return false;
    }

    // The value without apostrophes and hyphens, each other ASCII punctuation character replaced
    // by the ICU character at its Windows rank.
    static string Key(string value)
    {
        string windows = "!\"#$%&()*,./:;?@[\\]^_`{|}~+<=>";
        string icu = "_,;:!?.\"()[]{}@*/\\&#%`^+<=>|~$";
        char[] chars = new char[value.Length];
        int n = 0;
        for (int i = 0; i < value.Length; i++)
        {
            char c = value[i];
            if (c == '\'' || c == '-') continue;
            int rank = windows.IndexOf(c);
            chars[n++] = rank >= 0 ? icu[rank] : c;
        }
        return new string(chars, 0, n);
    }
}
