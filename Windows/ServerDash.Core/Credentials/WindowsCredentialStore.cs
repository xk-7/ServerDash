using System.Runtime.InteropServices;

namespace ServerDash.Credentials;

/// <summary>
/// Windows Credential Manager, local persist only (does not roam).
/// </summary>
public sealed class WindowsCredentialStore : ICredentialStore
{
    public const string TargetPrefix = "ServerDash/";

    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;

    public WindowsCredentialStore()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows Credential Manager is only available on Windows.");
        }
    }

    public bool HasSecret(string account) => TryGetSecret(account, out _);

    public bool TryGetSecret(string account, out string secret)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        secret = "";
        if (!CredRead(Target(account), CredTypeGeneric, 0, out var pointer))
        {
            return false;
        }

        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return false;
            }

            secret = Marshal.PtrToStringUni(credential.CredentialBlob, (int)credential.CredentialBlobSize / 2)
                ?? "";
            return true;
        }
        finally
        {
            CredFree(pointer);
        }
    }

    public void SetSecret(string account, string secret)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        ArgumentNullException.ThrowIfNull(secret);

        var blob = Marshal.StringToHGlobalUni(secret);
        try
        {
            var size = (uint)(secret.Length * 2);
            var credential = new NativeCredential
            {
                Flags = 0,
                Type = CredTypeGeneric,
                TargetName = Target(account),
                Comment = "ServerDash credential (local, non-roaming)",
                LastWritten = default,
                CredentialBlobSize = size,
                CredentialBlob = blob,
                Persist = CredPersistLocalMachine,
                AttributeCount = 0,
                Attributes = IntPtr.Zero,
                TargetAlias = null,
                UserName = account
            };

            if (!CredWrite(ref credential, 0))
            {
                throw new InvalidOperationException(
                    $"Credential Manager write failed (0x{Marshal.GetLastWin32Error():X8}).");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public void DeleteSecret(string account)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        CredDelete(Target(account), CredTypeGeneric, 0);
    }

    public static string Target(string account) => TargetPrefix + account;

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref NativeCredential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }
}
