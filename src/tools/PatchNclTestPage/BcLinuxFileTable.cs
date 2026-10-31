using System;
using System.IO;

/// <summary>
/// The File virtual table's folder, found the way NTFS finds it (issue #199). Cloned into
/// Nav.Ncl.dll by HelperCloner, so the same rules apply as for BcLinuxCulture: framework calls
/// only, no lambdas, closures, static fields or try/catch.
///
/// The table's Path field is Code[98], so BC upper-cases the filter value: AL's '/tmp/' reaches
/// FileDataProvider as '/TMP/'. NTFS ignores case and Windows lists the folder; on Linux the
/// folder does not exist and the table is empty. A path that exists as given is used as it is.
/// Otherwise each part is matched against the folders on disk ignoring case, and when two
/// folders differ only in case the first in ordinal order wins. A part with no match leaves the
/// path as it was, so BC reports a missing folder the same way as before.
/// The Path field keeps BC's upper-cased value, as it does on Windows.
/// </summary>
internal static class BcLinuxFileTable
{
    /// <summary>Replaces <c>new DirectoryInfo(path)</c> in FileDataProvider.GetItemsInTheDirectory.</summary>
    public static DirectoryInfo FileTableDirectory(string path)
    {
        return new DirectoryInfo(ResolveDirectory(path));
    }

    /// <summary>Replaces <c>Path.Combine(path, name)</c> in FileDataProvider.GetBlobContent.</summary>
    public static string FileTableFilePath(string path, string name)
    {
        return Path.Combine(ResolveDirectory(path), name);
    }

    static string ResolveDirectory(string path)
    {
        if (string.IsNullOrEmpty(path) || Directory.Exists(path))
            return path;
        string full = Path.GetFullPath(path);
        string root = Path.GetPathRoot(full);
        if (string.IsNullOrEmpty(root))
            return path;
        string[] parts = full.Substring(root.Length).Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries);
        string current = root;
        for (int i = 0; i < parts.Length; i++)
        {
            string next = Path.Combine(current, parts[i]);
            if (!Directory.Exists(next))
            {
                string[] folders = Directory.GetDirectories(current);
                string found = null;
                for (int j = 0; j < folders.Length; j++)
                {
                    string folder = Path.GetFileName(folders[j]);
                    if (string.Equals(folder, parts[i], StringComparison.OrdinalIgnoreCase)
                        && (found == null || string.CompareOrdinal(folder, found) < 0))
                        found = folder;
                }
                if (found == null)
                    return path;
                next = Path.Combine(current, found);
            }
            current = next;
        }
        return current;
    }
}
