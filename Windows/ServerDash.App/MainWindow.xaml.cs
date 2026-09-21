using System.IO;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using ServerDash.Catalog;
using ServerDash.Connections;
using ServerDash.Credentials;
using ServerDash.Models;
using ServerDash.Monitoring;

namespace ServerDash.App;

public sealed partial class MainWindow : Window
{
    private readonly ApplicationPaths _paths = ApplicationPaths.WindowsDefault();
    private readonly JsonHostCatalog _catalog;
    private readonly ICredentialStore _credentials;
    private readonly OpenSshConnectionEngine _engine;
    private IRemoteSession? _session;
    private IRemoteShellSession? _shell;
    private IRemoteFileClient? _sftp;
    private ServerRecord? _selected;

    public MainWindow()
    {
        InitializeComponent();
        Title = "ServerDash";
        _paths.EnsureCreated();
        _catalog = JsonHostCatalog.Open(_paths);
        _credentials = OperatingSystem.IsWindows()
            ? new WindowsCredentialStore()
            : new InMemoryCredentialStore();
        var locator = OpenSshLocator.System;
        var runner = new OpenSshProcessRunner();
        _engine = new OpenSshConnectionEngine(
            locator,
            new ServerDash.Trust.KnownHostsStore(_paths.KnownHostsPath),
            _credentials,
            _paths,
            new ServerDash.Trust.HostKeyScanner(locator, runner),
            runner);
        DescribeOpenSsh();
        ReloadHosts();
    }

    private void DescribeOpenSsh()
    {
        var install = OpenSshLocator.System.Find();
        StatusText.Text = install is null ? "未找到 OpenSSH（fail-closed）" : "已找到系统 OpenSSH";
    }

    private void ReloadHosts()
    {
        HostList.Items.Clear();
        foreach (var host in _catalog.List())
        {
            HostList.Items.Add(new HostItem(host));
        }
    }

    private void HostList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        _selected = (HostList.SelectedItem as HostItem)?.Record;
        ConnectButton.IsEnabled = _selected is not null;
    }

    private async void AddHost_Click(object sender, RoutedEventArgs e)
    {
        var name = new TextBox { PlaceholderText = "名称" };
        var host = new TextBox { PlaceholderText = "主机" };
        var port = new TextBox { PlaceholderText = "端口", Text = "22" };
        var user = new TextBox { PlaceholderText = "用户名" };
        var password = new PasswordBox { PlaceholderText = "密码（可选）" };
        var key = new TextBox { PlaceholderText = "私钥路径（可选）" };
        var stack = new StackPanel { Spacing = 8 };
        foreach (var item in new UIElement[] { name, host, port, user, password, key })
        {
            stack.Children.Add(item);
        }

        var dialog = new ContentDialog
        {
            Title = "添加主机",
            Content = stack,
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            XamlRoot = Content.XamlRoot
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }

        if (!int.TryParse(port.Text, out var parsedPort) || parsedPort is < 1 or > 65535)
        {
            parsedPort = 22;
        }

        var record = new ServerRecord
        {
            Name = name.Text.Trim(),
            Host = host.Text.Trim(),
            Port = parsedPort,
            Username = user.Text.Trim(),
            Authentication = string.IsNullOrWhiteSpace(key.Text)
                ? AuthenticationMethod.Password
                : AuthenticationMethod.PrivateKey,
            PrivateKeyPath = key.Text.Trim()
        };
        record.IdentityId = record.Id;
        if (!string.IsNullOrWhiteSpace(password.Password))
        {
            _credentials.SetSecret(record.Id.ToString("D"), password.Password);
        }

        _catalog.Upsert(record);
        ReloadHosts();
    }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is null)
        {
            return;
        }

        try
        {
            await CloseSessionAsync();
            var config = JsonHostCatalog.ToConnectionConfig(_selected);
            _session = await _engine.ConnectAsync(config, ConfirmTrustAsync);
            StatusText.Text = "已连接 " + _selected.DisplayName;
            var capabilities = await MonitoringResponseParser.ProbeAsync(_session);
            var snapshot = await MonitoringResponseParser.CollectAsync(_session);
            MonitorText.Text = FormatSnapshot(capabilities, snapshot);
            _shell = await _session.OpenShellAsync(RemoteShellDimensions.Standard);
            _ = PumpTerminalAsync(_shell);
            _sftp = await _session.OpenSftpAsync();
            await RefreshSftpAsync("/");
        }
        catch (Exception ex)
        {
            StatusText.Text = ex.Message;
        }
    }

    private async Task<RemoteHostTrustDecision> ConfirmTrustAsync(
        RemoteHostKeyPresentation presentation,
        CancellationToken cancellationToken)
    {
        var dialog = new ContentDialog
        {
            Title = "确认主机密钥",
            Content = $"{presentation.Host}:{presentation.Port}\n{presentation.Algorithm}\n{presentation.Fingerprint}\n未知或变化的密钥必须明确确认。没有“接受所有主机”。",
            PrimaryButtonText = "信任并保存",
            SecondaryButtonText = "仅本次",
            CloseButtonText = "拒绝",
            XamlRoot = Content.XamlRoot
        };
        var result = await dialog.ShowAsync();
        return result switch
        {
            ContentDialogResult.Primary => RemoteHostTrustDecision.TrustAndStore,
            ContentDialogResult.Secondary => RemoteHostTrustDecision.TrustOnce,
            _ => RemoteHostTrustDecision.Reject
        };
    }

    private async Task PumpTerminalAsync(IRemoteShellSession shell)
    {
        try
        {
            await foreach (var chunk in shell.Events)
            {
                TerminalOutput.Text += Encoding.UTF8.GetString(chunk);
            }
        }
        catch (Exception ex)
        {
            TerminalOutput.Text += "\n" + ex.Message;
        }
    }

    private async void TerminalSend_Click(object sender, RoutedEventArgs e) => await SendTerminalAsync();

    private async void TerminalInput_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            await SendTerminalAsync();
        }
    }

    private async Task SendTerminalAsync()
    {
        if (_shell is null)
        {
            return;
        }

        var line = TerminalInput.Text + "\n";
        TerminalInput.Text = "";
        await _shell.WriteAsync(Encoding.UTF8.GetBytes(line));
    }

    private async void SftpList_Click(object sender, RoutedEventArgs e) =>
        await RefreshSftpAsync(string.IsNullOrWhiteSpace(SftpPath.Text) ? "/" : SftpPath.Text);

    private async void SftpDownload_Click(object sender, RoutedEventArgs e)
    {
        if (_sftp is null || SftpList.SelectedItem is not SftpItem item)
        {
            return;
        }

        var destination = string.IsNullOrWhiteSpace(SftpLocalPath.Text)
            ? Path.Combine(_paths.TemporaryDirectory, item.File.Name)
            : SftpLocalPath.Text;
        try
        {
            await _sftp.DownloadAsync(item.File.Path, item.File.Size, destination, null);
            StatusText.Text = "已下载 " + item.File.Name;
        }
        catch (Exception ex)
        {
            StatusText.Text = ex.Message;
        }
    }

    private async void SftpUpload_Click(object sender, RoutedEventArgs e)
    {
        if (_sftp is null || string.IsNullOrWhiteSpace(SftpLocalPath.Text))
        {
            return;
        }

        var name = Path.GetFileName(SftpLocalPath.Text);
        var remote = RemotePath.Child(name, string.IsNullOrWhiteSpace(SftpPath.Text) ? "/" : SftpPath.Text);
        try
        {
            await _sftp.UploadAsync(SftpLocalPath.Text, remote, null);
            await RefreshSftpAsync(SftpPath.Text);
        }
        catch (Exception ex)
        {
            StatusText.Text = ex.Message;
        }
    }

    private async Task RefreshSftpAsync(string path)
    {
        if (_sftp is null)
        {
            return;
        }

        var listing = await _sftp.ListAsync(path);
        SftpPath.Text = listing.Path;
        SftpList.Items.Clear();
        foreach (var item in listing.Items)
        {
            SftpList.Items.Add(new SftpItem(item));
        }
    }

    private async Task CloseSessionAsync()
    {
        if (_shell is not null) await _shell.CloseAsync();
        if (_sftp is not null) await _sftp.CloseAsync();
        if (_session is not null) await _session.CloseAsync();
        _shell = null;
        _sftp = null;
        _session = null;
    }

    private static string FormatSnapshot(ServerCapabilities capabilities, ServerSnapshot snapshot)
    {
        var builder = new StringBuilder();
        builder.AppendLine(capabilities.Summary);
        builder.AppendLine($"{snapshot.Distribution} · {snapshot.Kernel}");
        builder.AppendLine($"CPU {snapshot.CpuUsage:0.0}% · {snapshot.CoreCount} 核 · 负载 {snapshot.Load1:0.00} {snapshot.Load5:0.00} {snapshot.Load15:0.00}");
        builder.AppendLine($"内存 {FormatBytes(snapshot.MemoryUsedBytes)} / {FormatBytes(snapshot.MemoryTotalBytes)}");
        builder.AppendLine($"磁盘 {FormatBytes(snapshot.DiskUsedBytes)} / {FormatBytes(snapshot.DiskTotalBytes)}");
        builder.AppendLine($"网络 ↓{FormatBytes(snapshot.NetworkReceivedBytes)} ↑{FormatBytes(snapshot.NetworkSentBytes)}");
        builder.AppendLine($"运行时间 {snapshot.Uptime} · 进程 {snapshot.ProcessCount}");
        foreach (var process in snapshot.TopProcesses)
        {
            builder.AppendLine($"  {process.Pid} {process.Name} CPU {process.Cpu:0.0}% MEM {process.Memory:0.0}%");
        }

        return builder.ToString();
    }

    private static string FormatBytes(double value)
    {
        if (value < 1024) return $"{value:0} B";
        if (value < 1024 * 1024) return $"{value / 1024:0.0} KB";
        if (value < 1024 * 1024 * 1024) return $"{value / (1024 * 1024):0.0} MB";
        return $"{value / (1024 * 1024 * 1024):0.0} GB";
    }

    private sealed class HostItem
    {
        public HostItem(ServerRecord record) => Record = record;
        public ServerRecord Record { get; }
        public override string ToString() => $"{Record.DisplayName}  {Record.Host}:{Record.Port}";
    }

    private sealed class SftpItem
    {
        public SftpItem(RemoteFileItem file) => File = file;
        public RemoteFileItem File { get; }
        public override string ToString() => (File.IsDirectory ? "[目录] " : "") + File.Name;
    }
}
