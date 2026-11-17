using System.IO;
using System.IO.Pipes;
using System.Text;

namespace Velinshot;

/// <summary>Single-instance entry point. A second launch forwards its arguments (files to open,
/// --capture, --capture-display, --quick-copy) to the running copy and exits.</summary>
public static class Program
{
    internal static readonly string Identity = $"Velinshot-{Environment.UserDomainName}-{Environment.UserName}".Replace('\\', '-');

    [STAThread]
    public static int Main(string[] args)
    {
        using var mutex = new Mutex(true, $"Local\\{Identity}", out var first);
        if (!first)
        {
            Forward(args);
            return 0;
        }
        var app = new App { StartupArguments = args };
        app.InitializeComponent();
        return app.Run();
    }

    private static void Forward(string[] args)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", Identity, PipeDirection.Out);
            pipe.Connect(2000);
            var payload = Encoding.UTF8.GetBytes(string.Join("\n", args.Select(NormalizeArgument).DefaultIfEmpty("")));
            pipe.Write(payload);
        }
        catch (Exception) { /* The running copy may be closing; nothing else to do. */ }
    }

    internal static string NormalizeArgument(string argument) => argument.StartsWith("--", StringComparison.Ordinal) ? argument : Path.GetFullPath(argument);
}
