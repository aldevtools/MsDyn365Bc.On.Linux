using System;

// Package entries are URI paths, not host filesystem paths (issue #216).
// Return the containing package directory without a leading/trailing separator.
static class BcLinuxPackagePaths
{
    public static string PackageDirectoryName(string path)
    {
        string normalized = path.Replace('\\', '/');
        int separator = normalized.LastIndexOf('/');
        return separator < 0 ? string.Empty : normalized.Substring(0, separator).Trim('/');
    }
}
