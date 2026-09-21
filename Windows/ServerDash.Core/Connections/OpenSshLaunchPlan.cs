using ServerDash.Models;

namespace ServerDash.Connections;

public sealed record OpenSshLaunchPlan(
    string Executable,
    IReadOnlyList<string> Arguments,
    string KnownHostsPath)
{
    public IReadOnlyDictionary<string, string> Environment { get; init; } =
        new Dictionary<string, string>();

    public IReadOnlyList<string> CleanupPaths { get; init; } = [];

    public IReadOnlyList<string> OptionValues =>
        Arguments
            .Select((value, index) => index > 0 && Arguments[index - 1] is "-o" or "-F" ? value : null)
            .Where(value => value is not null)
            .Cast<string>()
            .ToArray();
}

public static class OpenSshArgumentBuilder
{
    public static readonly HashSet<string> ForbiddenHostKeyChecking = new(StringComparer.OrdinalIgnoreCase)
    {
        "no",
        "accept-new",
        "off",
        "false"
    };

    public static OpenSshLaunchPlan Build(
        OpenSshInstall install,
        ServerConnectionConfig config,
        string knownHostsPath,
        string? identityFile = null,
        IEnumerable<string>? extraArguments = null)
    {
        ArgumentNullException.ThrowIfNull(install);
        ArgumentNullException.ThrowIfNull(config);
        ArgumentException.ThrowIfNullOrWhiteSpace(knownHostsPath);

        if (string.IsNullOrWhiteSpace(config.Host))
        {
            throw new ArgumentException("Host is required.", nameof(config));
        }

        if (config.Port is < 1 or > 65535)
        {
            throw new ArgumentOutOfRangeException(nameof(config), config.Port, "Port must be 1-65535.");
        }

        var nullDevice = OperatingSystem.IsWindows() ? "NUL" : "/dev/null";
        var configFile = OperatingSystem.IsWindows() ? "NUL" : "none";
        var arguments = new List<string>
        {
            "-F", configFile,
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no",
            "-o", $"UserKnownHostsFile={knownHostsPath}",
            "-o", $"GlobalKnownHostsFile={nullDevice}",
            "-o", "IdentitiesOnly=yes",
            "-p", config.Port.ToString()
        };

        if (config.Authentication is AuthenticationMethod.Password)
        {
            arguments.Add("-o");
            arguments.Add("PreferredAuthentications=password,keyboard-interactive");
            arguments.Add("-o");
            arguments.Add("PubkeyAuthentication=no");
        }
        else
        {
            arguments.Add("-o");
            arguments.Add("PreferredAuthentications=publickey");
            var identity = identityFile ?? config.PrivateKeyPath;
            if (!string.IsNullOrWhiteSpace(identity))
            {
                arguments.Add("-i");
                arguments.Add(identity);
            }
        }

        var target = string.IsNullOrWhiteSpace(config.Username)
            ? config.Host
            : $"{config.Username}@{config.Host}";
        arguments.Add(target);
        if (extraArguments is not null)
        {
            arguments.AddRange(extraArguments);
        }

        var plan = new OpenSshLaunchPlan(install.SshPath, arguments, knownHostsPath);
        RejectWeakHostKeyChecking(plan);
        return plan;
    }

    public static OpenSshLaunchPlan BuildSftp(
        OpenSshInstall install,
        ServerConnectionConfig config,
        string knownHostsPath,
        string batchPath,
        string? identityFile = null)
    {
        var ssh = Build(install, config, knownHostsPath, identityFile);
        var arguments = ssh.Arguments.ToList();
        var portIndex = arguments.IndexOf("-p");
        if (portIndex >= 0)
        {
            arguments[portIndex] = "-P";
        }

        arguments.Insert(0, "-b");
        arguments.Insert(1, batchPath);
        var plan = new OpenSshLaunchPlan(install.SftpPath, arguments, knownHostsPath);
        RejectWeakHostKeyChecking(plan);
        return plan;
    }

    public static void RejectWeakHostKeyChecking(OpenSshLaunchPlan plan)
    {
        foreach (var option in plan.OptionValues)
        {
            if (!option.StartsWith("StrictHostKeyChecking=", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var value = option["StrictHostKeyChecking=".Length..].Trim();
            if (ForbiddenHostKeyChecking.Contains(value))
            {
                throw new InvalidOperationException(
                    "StrictHostKeyChecking cannot be disabled or set to accept-new.");
            }
        }

        var checking = plan.OptionValues.FirstOrDefault(option =>
            option.StartsWith("StrictHostKeyChecking=", StringComparison.OrdinalIgnoreCase));
        if (checking is null ||
            !checking.Equals("StrictHostKeyChecking=yes", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("StrictHostKeyChecking=yes is required.");
        }
    }
}
