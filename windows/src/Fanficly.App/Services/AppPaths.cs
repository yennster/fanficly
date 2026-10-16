namespace Fanficly.App.Services;

/// <summary>
/// Where the app keeps its files. Packaged (Store) installs use the package's
/// own app-data folder, which Windows removes on uninstall; a developer run
/// from the build folder uses %LOCALAPPDATA%\Fanficly.
/// </summary>
public static class AppPaths
{
    private static string? _local;

    public static bool IsPackaged { get; } = DetectPackaged();

    public static string LocalData => _local ??= Resolve();

    public static string Database => Path.Combine(LocalData, "library.sqlite");
    public static string Settings => Path.Combine(LocalData, "settings.json");
    public static string Downloads => Ensure(Path.Combine(LocalData, "Downloads"));
    public static string Exports => Ensure(Path.Combine(Path.GetTempPath(), "Fanficly", "Exports"));
    public static string Logs => Ensure(Path.Combine(LocalData, "Logs"));

    /// <summary>Shared with the widget provider and background task (same package).</summary>
    public static string Shared => Ensure(Path.Combine(LocalData, "Shared"));

    private static string Resolve()
    {
        string path;
        try
        {
            path = IsPackaged
                ? Windows.Storage.ApplicationData.Current.LocalFolder.Path
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Fanficly");
        }
        catch
        {
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Fanficly");
        }
        return Ensure(path);
    }

    private static bool DetectPackaged()
    {
        try { return Windows.ApplicationModel.Package.Current is not null; }
        catch { return false; }
    }

    private static string Ensure(string dir)
    {
        Directory.CreateDirectory(dir);
        return dir;
    }
}
