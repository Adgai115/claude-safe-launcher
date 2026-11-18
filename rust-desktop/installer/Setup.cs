using Microsoft.Win32;
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;

internal sealed class Setup
{
    private const string Product = "Claude 环境检查器";
    private const string PreviousProduct = "Claude 安全启动 (Rust)";
    private const string Binary = "claude-safe-launcher-rust.exe";
    private const string RegistryPrefix = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\";
    private static readonly Assembly Resources = typeof(Setup).Assembly;

    private readonly Window window;
    private string installPath;
    private readonly bool hasPreviousInstall;
    private readonly bool migrating;
    private readonly bool upgrade;
    private readonly CheckBox consent;
    private readonly Button next;
    private readonly Button cancel;
    private readonly Button back;
    private readonly TextBlock heading;
    private readonly TextBlock description;
    private readonly TextBlock error;
    private readonly ProgressBar progress;
    private readonly FlowDocumentScrollViewer reader;
    private readonly TextBox destination;
    private bool onAgreement = true;
    private bool installing;
    private bool installed;

    [STAThread]
    private static void Main()
    {
        bool first;
        using (var instance = new Mutex(true, @"Local\ClaudeEnvironmentChecker.Setup", out first))
        {
            if (!first)
            {
                MessageBox.Show("安装程序已经打开。", Product, MessageBoxButton.OK);
                return;
            }
            try
            {
                var application = new Application();
                application.Run(new Setup().window);
            }
            catch (Exception exception)
            {
                MessageBox.Show("无法打开安装程序。\n" + exception.Message,
                    Product, MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }

    private Setup()
    {
        using (var xaml = Resources.GetManifestResourceStream("Setup.View"))
            window = (Window)XamlReader.Load(xaml);
        var existing = RegisteredPath(Product);
        var legacy = existing == null ? RegisteredPath(PreviousProduct) : null;
        migrating = legacy != null && File.Exists(Path.Combine(legacy, Binary))
            && File.Exists(Path.Combine(legacy, "uninstall.exe"));
        hasPreviousInstall = existing != null || migrating;
        installPath = existing ?? (migrating ? legacy : Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Product));
        upgrade = hasPreviousInstall && IsOlderInstallation(installPath);

        using (var icon = Resources.GetManifestResourceStream("Setup.Icon"))
        {
            var frames = new IconBitmapDecoder(icon, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames;
            BitmapFrame chosen = frames[0];
            foreach (var frame in frames)
                if (Math.Abs(frame.PixelWidth - 64) < Math.Abs(chosen.PixelWidth - 64)) chosen = frame;
            Find<Image>("BrandIcon").Source = chosen;
            window.Icon = chosen;
        }

        consent = Find<CheckBox>("Consent");
        next = Find<Button>("NextButton");
        cancel = Find<Button>("CancelButton");
        back = Find<Button>("BackButton");
        heading = Find<TextBlock>("Heading");
        description = Find<TextBlock>("Description");
        error = Find<TextBlock>("InstallError");
        progress = Find<ProgressBar>("Progress");
        reader = Find<FlowDocumentScrollViewer>("LicenseReader");
        destination = Find<TextBox>("InstallPath");
        destination.Text = installPath;
        destination.IsReadOnly = hasPreviousInstall;

        Find<RadioButton>("Chinese").Checked += delegate { ShowLicense(true); };
        Find<RadioButton>("English").Checked += delegate { ShowLicense(false); };
        consent.Checked += delegate { next.IsEnabled = true; };
        consent.Unchecked += delegate { next.IsEnabled = false; };
        next.Click += Continue;
        back.Click += delegate { ShowStep(true); };
        cancel.Click += delegate { window.Close(); };
        window.Closing += delegate(object sender, System.ComponentModel.CancelEventArgs args) { args.Cancel = installing; };
        window.PreviewKeyDown += delegate(object sender, System.Windows.Input.KeyEventArgs args)
        {
            if (args.Key == System.Windows.Input.Key.Escape && !installing)
            {
                args.Handled = true;
                window.Close();
            }
        };

        window.MaxHeight = SystemParameters.WorkArea.Height;
        window.MaxWidth = SystemParameters.WorkArea.Width;
        ShowLicense(true);
    }

    private T Find<T>(string name) where T : FrameworkElement
    {
        return (T)window.FindName(name);
    }

    private void ShowLicense(bool chinese)
    {
        var title = chinese ? "署名—非商业性使用 4.0 协议国际版" : "Attribution-NonCommercial 4.0 International";
        var resource = chinese ? "Setup.License.Zh" : "Setup.License.En";
        string text;
        using (var source = new StreamReader(Resources.GetManifestResourceStream(resource), Encoding.UTF8))
            text = source.ReadToEnd().Replace("\r\n", "\n").Trim();
        if (text.StartsWith(title + "\n", StringComparison.Ordinal))
            text = text.Substring(title.Length).TrimStart();

        var document = new FlowDocument
        {
            FontFamily = window.FontFamily,
            FontSize = 14,
            LineHeight = 22,
            PagePadding = new Thickness(14, 12, 16, 12),
            Foreground = (Brush)window.Resources["Ink"]
        };
        document.Blocks.Add(new Paragraph(new Run(title))
        {
            FontSize = 18, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 3)
        });
        document.Blocks.Add(new Paragraph(new Run("CC BY-NC 4.0"))
        {
            FontSize = 13, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 13),
            Foreground = (Brush)window.Resources["Green"]
        });
        foreach (var block in Regex.Split(text, "\n[ \\t]*\n"))
        {
            var body = block.Trim('\n', '\r');
            if (body.Length == 0 || Regex.IsMatch(body, "^=+$")) continue;
            bool headingLine = body.IndexOf('\n') < 0 && (
                Regex.IsMatch(body, "^(第[一二三四五六七八]条|Section [1-8] )")
                || body == "关于许可协议和知识共享组织"
                || body == "知识共享公共许可协议(CCPL)的使用");
            document.Blocks.Add(new Paragraph(new Run(body))
            {
                Margin = new Thickness(0, 0, 0, 10),
                FontWeight = headingLine ? FontWeights.SemiBold : FontWeights.Normal
            });
        }
        reader.Document = document;
    }

    private void ShowStep(bool agreement)
    {
        onAgreement = agreement;
        Find<Grid>("AgreementPanel").Visibility = agreement ? Visibility.Visible : Visibility.Collapsed;
        Find<StackPanel>("LocationPanel").Visibility = agreement ? Visibility.Collapsed : Visibility.Visible;
        back.Visibility = agreement ? Visibility.Collapsed : Visibility.Visible;
        heading.Text = agreement ? "许可协议" : upgrade ? "升级环境检查器" : "安装环境检查器";
        description.Text = agreement ? "请阅读协议并确认同意后继续。"
            : hasPreviousInstall ? "将沿用原有安装位置和应用数据。" : "为当前 Windows 用户安装。";
        next.Content = agreement ? "下一步" : upgrade ? "升级" : "安装";
        next.IsEnabled = consent.IsChecked == true;
        error.Text = "";

        SetStage("Agreement", agreement);
        SetStage("Install", !agreement);
    }

    private void SetStage(string stage, bool active)
    {
        var green = (Brush)window.Resources["Green"];
        var muted = (Brush)window.Resources["Muted"];
        Find<Border>(stage + "Stage").Background = active ? (Brush)window.Resources["Selection"] : Brushes.Transparent;
        Find<Border>(stage + "Number").Background = active ? green : Brushes.Transparent;
        Find<Border>(stage + "Number").BorderBrush = active ? green : muted;
        Find<TextBlock>(stage + "Digit").Foreground = active ? Brushes.White : muted;
    }

    private async void Continue(object sender, RoutedEventArgs args)
    {
        if (installing || consent.IsChecked != true) return;
        if (onAgreement)
        {
            ShowStep(false);
            return;
        }
        if (installed)
        {
            try
            {
                Process.Start(new ProcessStartInfo(Path.Combine(installPath, Binary)) { WorkingDirectory = installPath });
                window.Close();
            }
            catch (Exception exception)
            {
                error.Text = "无法打开环境检查器。\n" + exception.Message;
            }
            return;
        }

        var path = NormalizeInstallPath(destination.Text);
        if (path == null)
        {
            error.Text = "请填写本地磁盘上的完整文件夹路径。";
            destination.Focus();
            return;
        }
        installPath = path;
        destination.Text = path;
        destination.IsReadOnly = true;
        installing = true;
        next.IsEnabled = cancel.IsEnabled = back.IsEnabled = false;
        heading.Text = upgrade ? "正在升级" : "正在安装";
        description.Text = "正在写入程序文件和快捷方式。";
        progress.Visibility = Visibility.Visible;
        error.Text = "";
        try
        {
            await Task.Run((Action)Install);
            installed = true;
            heading.Text = upgrade ? "升级完成" : "安装完成";
            description.Text = "Claude 环境检查器已可使用。";
            next.Content = "打开环境检查器";
            cancel.Content = "关闭";
            back.Visibility = Visibility.Collapsed;
        }
        catch (Exception exception)
        {
            heading.Text = upgrade ? "升级未完成" : "安装未完成";
            description.Text = "处理下方问题后，可以重试。";
            error.Text = exception.Message;
        }
        finally
        {
            installing = false;
            destination.IsReadOnly = installed || hasPreviousInstall;
            progress.Visibility = Visibility.Collapsed;
            next.IsEnabled = cancel.IsEnabled = back.IsEnabled = true;
        }
    }

    private void Install()
    {
        foreach (var name in new[] { "claude-safe-launcher-rust", "Claude-Environment-Checker" })
        {
            var processes = Process.GetProcessesByName(name);
            foreach (var process in processes) process.Dispose();
            if (processes.Length != 0)
                throw new InvalidOperationException("请先从托盘退出正在运行的环境检查器，再继续安装。");
        }

        var directory = Path.Combine(Path.GetTempPath(), "ClaudeEnvironmentChecker-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var payload = Path.Combine(directory, "install.exe");
        try
        {
            using (var embedded = Resources.GetManifestResourceStream("Setup.Payload"))
            using (var file = new FileStream(payload, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                embedded.CopyTo(file);

            // NSIS takes /D as the final argument, with the unquoted path consuming the rest of the line.
            using (var process = Process.Start(new ProcessStartInfo(payload)
            {
                Arguments = "/S /D=" + installPath,
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true
            }))
            {
                process.WaitForExit();
                if (process.ExitCode != 0)
                    throw new InvalidOperationException("安装程序未完成，错误代码 " + process.ExitCode + "。");
            }

            var executable = Path.Combine(installPath, Binary);
            if (!File.Exists(executable)
                || FileVersionInfo.GetVersionInfo(executable).ProductVersion != PackageVersion()
                || !string.Equals(RegisteredPath(Product), installPath, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("未确认本次安装的文件和注册信息，请重试。");
            if (migrating && string.Equals(RegisteredPath(PreviousProduct), installPath, StringComparison.OrdinalIgnoreCase))
                Registry.CurrentUser.DeleteSubKeyTree(RegistryPrefix + PreviousProduct, false);
        }
        finally
        {
            try { File.Delete(payload); Directory.Delete(directory); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static string PackageVersion()
    {
        return Resources.GetCustomAttribute<AssemblyInformationalVersionAttribute>().InformationalVersion;
    }

    private static bool IsOlderInstallation(string path)
    {
        var executable = Path.Combine(path, Binary);
        Version oldVersion;
        return File.Exists(executable)
            && Version.TryParse(FileVersionInfo.GetVersionInfo(executable).ProductVersion, out oldVersion)
            && oldVersion < new Version(PackageVersion());
    }

    private static string RegisteredPath(string product)
    {
        using (var key = Registry.CurrentUser.OpenSubKey(RegistryPrefix + product))
        {
            var location = key == null ? null : key.GetValue("InstallLocation") as string;
            return NormalizeInstallPath(location == null ? null : location.Trim().Trim('"'));
        }
    }

    private static string NormalizeInstallPath(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var path = value.Trim();
        if (!Regex.IsMatch(path, @"^[A-Za-z]:\\") || path.IndexOfAny(Path.GetInvalidPathChars()) >= 0)
            return null;
        try
        {
            path = Path.GetFullPath(path).TrimEnd('\\');
            return path.Length > 2 ? path : null;
        }
        catch (ArgumentException) { return null; }
        catch (NotSupportedException) { return null; }
        catch (PathTooLongException) { return null; }
    }
}
