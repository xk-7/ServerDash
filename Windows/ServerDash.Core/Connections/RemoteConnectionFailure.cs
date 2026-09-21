namespace ServerDash.Connections;

public enum RemoteConnectionFailureKind
{
    Unsupported,
    IndirectRouteNotImplemented,
    MissingOpenSsh,
    MissingKeyscan,
    MissingCredential,
    InvalidPrivateKey,
    HostKeyRejected,
    SessionClosed,
    OutputLimitExceeded,
    TimedOut,
    AuthenticationTimedOut,
    AuthenticationFailed,
    Transport
}

public sealed class RemoteConnectionFailure : Exception
{
    public RemoteConnectionFailure(RemoteConnectionFailureKind kind, string? detail = null)
        : base(Describe(kind, detail))
    {
        Kind = kind;
        Detail = detail;
    }

    public RemoteConnectionFailureKind Kind { get; }
    public string? Detail { get; }

    public static RemoteConnectionFailure Unsupported(string feature) =>
        new(RemoteConnectionFailureKind.Unsupported, feature);

    public static RemoteConnectionFailure MissingOpenSsh() =>
        new(RemoteConnectionFailureKind.MissingOpenSsh);

    public static RemoteConnectionFailure MissingKeyscan() =>
        new(RemoteConnectionFailureKind.MissingKeyscan);

    public static RemoteConnectionFailure MissingCredential() =>
        new(RemoteConnectionFailureKind.MissingCredential);

    public static RemoteConnectionFailure HostKeyRejected() =>
        new(RemoteConnectionFailureKind.HostKeyRejected);

    private static string Describe(RemoteConnectionFailureKind kind, string? detail) => kind switch
    {
        RemoteConnectionFailureKind.Unsupported =>
            string.IsNullOrWhiteSpace(detail)
                ? "当前阶段尚未实现该能力。"
                : $"当前阶段尚未实现{detail}。",
        RemoteConnectionFailureKind.IndirectRouteNotImplemented =>
            "跳板、代理与转发已列入 Windows 对齐范围，但尚未实现。",
        RemoteConnectionFailureKind.MissingOpenSsh =>
            "未找到系统 OpenSSH 的 ssh 与 sftp。请安装 Windows OpenSSH Client。",
        RemoteConnectionFailureKind.MissingKeyscan =>
            "未找到 ssh-keyscan，无法校验未知主机密钥。",
        RemoteConnectionFailureKind.MissingCredential =>
            "本机凭据库中缺少连接凭据。",
        RemoteConnectionFailureKind.InvalidPrivateKey =>
            "私钥格式或口令无效；支持导入 OpenSSH Ed25519 与 RSA 私钥。",
        RemoteConnectionFailureKind.HostKeyRejected =>
            "主机密钥未被信任，连接已关闭。",
        RemoteConnectionFailureKind.SessionClosed =>
            "SSH 会话已关闭。",
        RemoteConnectionFailureKind.OutputLimitExceeded =>
            "远程输出超过安全上限。",
        RemoteConnectionFailureKind.TimedOut =>
            "连接或命令执行超时。",
        RemoteConnectionFailureKind.AuthenticationTimedOut =>
            "网络已连接，但主机确认或身份认证超时。",
        RemoteConnectionFailureKind.AuthenticationFailed =>
            "服务器未接受当前用户名或凭据。",
        RemoteConnectionFailureKind.Transport =>
            string.IsNullOrWhiteSpace(detail) ? "SSH 连接失败。" : detail,
        _ => "SSH 连接失败。"
    };
}
