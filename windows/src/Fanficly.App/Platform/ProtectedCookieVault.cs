using System.Runtime.InteropServices;
using System.Text;
using Fanficly.Core;

namespace Fanficly.App.Platform;

/// <summary>
/// Keeps the AO3 session cookie and username encrypted with Windows' Data
/// Protection API (DPAPI, the user's own key), one file per key in the app's
/// data folder — the Keychain's role on iOS. Only this Windows user account can
/// decrypt them, and uninstalling the packaged app removes them.
/// </summary>
public sealed partial class ProtectedCookieVault(string directory) : KeyedCookieVault
{
    private static readonly byte[] Entropy = "io.github.yennster.fanficly.ao3"u8.ToArray();

    private string PathFor(string key) => Path.Combine(directory, key.Replace('.', '_') + ".bin");

    protected override string? Read(string key)
    {
        try
        {
            var path = PathFor(key);
            if (!File.Exists(path)) return null;
            var plain = Unprotect(File.ReadAllBytes(path));
            return plain is null ? null : Encoding.UTF8.GetString(plain);
        }
        catch (Exception e)
        {
            AppHost.Log($"Credential read failed: {e.Message}");
            return null;
        }
    }

    protected override void Write(string key, string value)
    {
        Directory.CreateDirectory(directory);
        var data = Protect(Encoding.UTF8.GetBytes(value));
        var path = PathFor(key);
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, overwrite: true);
    }

    protected override void Delete(string key)
    {
        try { File.Delete(PathFor(key)); } catch { }
    }

    // MARK: - DPAPI (crypt32)

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public IntPtr Data;
    }

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptProtectData(ref DataBlob dataIn, IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptUnprotectData(ref DataBlob dataIn, IntPtr description, ref DataBlob entropy,
        IntPtr reserved, IntPtr prompt, int flags, out DataBlob dataOut);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr LocalFree(IntPtr mem);

    private const int UiForbidden = 0x1;

    private static byte[] Protect(byte[] plain) =>
        Transform(plain, encrypt: true) ?? throw new InvalidOperationException($"CryptProtectData failed ({Marshal.GetLastPInvokeError()}).");

    private static byte[]? Unprotect(byte[] cipher) => Transform(cipher, encrypt: false);

    private static byte[]? Transform(byte[] input, bool encrypt)
    {
        var inHandle = GCHandle.Alloc(input, GCHandleType.Pinned);
        var entHandle = GCHandle.Alloc(Entropy, GCHandleType.Pinned);
        try
        {
            var inBlob = new DataBlob { Size = input.Length, Data = inHandle.AddrOfPinnedObject() };
            var entBlob = new DataBlob { Size = Entropy.Length, Data = entHandle.AddrOfPinnedObject() };
            var ok = encrypt
                ? CryptProtectData(ref inBlob, IntPtr.Zero, ref entBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, out var outBlob)
                : CryptUnprotectData(ref inBlob, IntPtr.Zero, ref entBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, out outBlob);
            if (!ok) return null;
            try
            {
                var result = new byte[outBlob.Size];
                Marshal.Copy(outBlob.Data, result, 0, outBlob.Size);
                return result;
            }
            finally
            {
                LocalFree(outBlob.Data);
            }
        }
        finally
        {
            inHandle.Free();
            entHandle.Free();
        }
    }
}
