param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$WorkDirectory
)

$ErrorActionPreference = 'Stop'
$executable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) {
    if (@(Get-ChildItem -LiteralPath $work -Force).Count -gt 0) {
        throw "Smoke test directory must be empty: $work"
    }
} else {
    New-Item -ItemType Directory -Path $work | Out-Null
}
$testExecutable = Join-Path $work 'Plain Craft Launcher 2.exe'
Copy-Item -LiteralPath $executable -Destination $testExecutable
if (Test-Path -LiteralPath "$executable.config") {
    Copy-Item -LiteralPath "$executable.config" -Destination "$testExecutable.config"
}

# A separate Framework process makes Paths.Base and the HTTP cache local to this test.
$source = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Resources;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Threading;

public static class PclSmokeRunner {
    private static Assembly pcl;
    private static ResourceManager resources;
    private static readonly Dictionary<string, Assembly> libraries = new Dictionary<string, Assembly>();
    private const BindingFlags StaticMembers = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;

    private static object Invoke(Type type, string name, params object[] arguments) {
        MethodInfo method = type.GetMethods(StaticMembers).Single(m =>
            m.Name == name && !m.IsGenericMethod && m.GetParameters().Length == arguments.Length &&
            (arguments.Length == 0 || arguments[0] == null || m.GetParameters()[0].ParameterType.IsInstanceOfType(arguments[0])));
        try { return method.Invoke(null, arguments); }
        catch (TargetInvocationException ex) { throw ex.InnerException ?? ex; }
    }

    private static Assembly ResolveLibrary(object sender, ResolveEventArgs args) {
        string name = new AssemblyName(args.Name).Name;
        lock (libraries) {
            Assembly result;
            if (libraries.TryGetValue(name, out result)) return result;
            byte[] bytes = resources.GetObject(name) as byte[];
            if (bytes == null) return null;
            result = Assembly.Load(bytes);
            libraries.Add(name, result);
            return result;
        }
    }

    private static void Require(bool value, string message) {
        if (!value) throw new InvalidOperationException(message);
    }

    private static void RequireNoOp(Type type, string name) {
        MethodInfo method = type.GetMethod(name, StaticMembers);
        Require(method != null, "Missing update method: " + name);
        byte[] instructions = method.GetMethodBody().GetILAsByteArray().Where(b => b != 0).ToArray();
        Require(instructions.Length == 1 && instructions[0] == 0x2a,
            "Update method must have no executable work: " + name);
    }

    private static void IsolateSettings() {
        Type settings = pcl.GetType("PCL.Settings", true);
        IDictionary entries = (IDictionary)settings.GetField("Entries", StaticMembers).GetValue(null);
        foreach (DictionaryEntry entry in entries) {
            object setting = entry.Value;
            Type type = setting.GetType();
            FieldInfo source = type.GetField("Source");
            if (source.GetValue(setting).ToString() == "Instance") continue;
            // Redirect registry settings to this fresh test's local Setup.ini and seed defaults.
            source.SetValue(setting, Enum.Parse(source.FieldType, "Normal"));
            object defaultValue = type.GetField("DefaultValue").GetValue(setting);
            type.GetMethod("Set").Invoke(setting, new object[] { defaultValue, null });
        }
    }

    private static void CheckFixedSettings() {
        Type settings = pcl.GetType("PCL.Settings", true);
        Invoke(settings, "Set", "SystemSystemUpdate", 0, null);
        Require(Convert.ToInt32(Invoke(settings, "Get", "SystemSystemUpdate", null)) == 3,
            "Changing settings re-enabled launcher updates.");
        Invoke(settings, "Reset", "SystemSystemUpdate", null);
        Require(Convert.ToInt32(Invoke(settings, "Get", "SystemSystemUpdate", null)) == 3,
            "Resetting settings re-enabled launcher updates.");
        Invoke(settings, "Set", "SystemSystemActivity", 0, null);
        Require(Convert.ToInt32(Invoke(settings, "Get", "SystemSystemActivity", null)) == 2,
            "Changing settings re-enabled remote announcements.");
        Invoke(settings, "Reset", "SystemSystemActivity", null);
        Require(Convert.ToInt32(Invoke(settings, "Get", "SystemSystemActivity", null)) == 2,
            "Resetting settings re-enabled remote announcements.");
    }

    private static void DownloadTest(string work) {
        Type download = pcl.GetType("PCL.ModDownload", true);
        Type network = pcl.GetType("PCL.ModNet", true);
        string jsonUrl = (string)Invoke(download, "DlClientListGet", "1.0");
        Require(!String.IsNullOrEmpty(jsonUrl), "PCL could not resolve Minecraft 1.0 from its version list.");
        string jsonPath = Path.Combine(work, "1.0.json");
        Invoke(network, "NetDownloadByClient", jsonUrl, jsonPath, false);

        JavaScriptSerializer serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = Int32.MaxValue;
        Dictionary<string, object> manifest = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(jsonPath));
        Require((string)manifest["id"] == "1.0", "Downloaded the wrong version manifest.");
        Dictionary<string, object> client = (Dictionary<string, object>)((Dictionary<string, object>)manifest["downloads"])["client"];
        string jarUrl = (string)client["url"];
        string expectedHash = (string)client["sha1"];
        long expectedSize = Convert.ToInt64(client["size"]);
        string jarPath = Path.Combine(work, "1.0.jar");
        // No local-file checker: this forces a network download and avoids scanning existing MC folders.
        Invoke(network, "NetDownloadByLoader", jarUrl, jarPath, null, null, false);
        string actualHash;
        using (SHA1 sha = SHA1.Create())
        using (FileStream stream = File.OpenRead(jarPath))
            actualHash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        Require(new FileInfo(jarPath).Length == expectedSize, "Minecraft client size does not match its manifest.");
        Require(actualHash == expectedHash, "Minecraft client SHA-1 does not match its manifest.");
        Dictionary<string, object> report = new Dictionary<string, object> {
            { "passed", false }, { "downloadPassed", true }, { "version", "1.0" }, { "manifestUrl", jsonUrl },
            { "clientUrl", jarUrl }, { "clientBytes", expectedSize }, { "clientSha1", actualHash },
            { "downloadEngine", "PCL.ModNet.NetDownloadByLoader" },
            { "settingsStorage", "isolated default settings in local Setup.ini" },
            { "downloadRestriction", false }, { "updateMethods", "verified no-op IL" },
            { "fixedSettings", "Set and Reset preserve updates=3, announcements=2" }
        };
        File.WriteAllText(Path.Combine(work, "smoke-result.json"), serializer.Serialize(report));
        Console.WriteLine("PASS: PCL resolved Minecraft 1.0, downloaded JSON and client JAR, and verified size/SHA-1.");
        Console.WriteLine("PASS: download restriction is false and all executable replacement/update methods are empty.");
    }

    [STAThread]
    public static int Main(string[] args) {
        int result = 1;
        try {
            string work = AppDomain.CurrentDomain.BaseDirectory;
            Directory.SetCurrentDirectory(work);
            string temp = Path.Combine(work, "Temp");
            Directory.CreateDirectory(temp);
            Environment.SetEnvironmentVariable("TEMP", temp);
            Environment.SetEnvironmentVariable("TMP", temp);
            pcl = Assembly.LoadFrom(args[0]);
            resources = new ResourceManager("PCL.Resources", pcl);
            AppDomain.CurrentDomain.AssemblyResolve += ResolveLibrary;
            Assembly core = ResolveLibrary(null, new ResolveEventArgs("MeloongCore"));
            Invoke(core.GetType("MeloongCore.Main", true), "Init", "PCLSmokeTest");
            Application app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Assembly wpf = ResolveLibrary(null, new ResolveEventArgs("MeloongCore.Wpf"));
            Invoke(wpf.GetType("MeloongCore.Wpf.Main", true), "Init");
            IsolateSettings();
            CheckFixedSettings();
            Type secret = pcl.GetType("PCL.ModSecret", true);
            Require(!(bool)secret.GetField("RestrictMcDownload", StaticMembers).GetRawConstantValue(),
                "Minecraft download restriction is enabled.");
            RequireNoOp(secret, "UpdateRestart");
            RequireNoOp(secret, "UpdateReplace");
            RequireNoOp(secret, "DownloadLatestPCL");
            // Initialize UiThreadId on the dispatcher thread before any network worker starts.
            RuntimeHelpers.RunClassConstructor(pcl.GetType("PCL.ModBase", true).TypeHandle);
            Exception failure = null;
            bool finished = false;
            Thread worker = new Thread(delegate() {
                try { DownloadTest(work); }
                catch (Exception ex) { failure = ex; }
                finally { Volatile.Write(ref finished, true); }
            });
            worker.IsBackground = true;
            worker.Start();
            DateTime deadline = DateTime.UtcNow.AddMinutes(5);
            while (!Volatile.Read(ref finished) && DateTime.UtcNow < deadline) {
                DispatcherFrame frame = new DispatcherFrame();
                Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(delegate { frame.Continue = false; }));
                Dispatcher.PushFrame(frame);
                Thread.Sleep(10);
            }
            Require(finished, "Minecraft download smoke test timed out after five minutes.");
            if (failure != null) throw failure;
            result = 0;
        } catch (Exception ex) {
            Console.Error.WriteLine(ex.ToString());
        }
        // PCL's download manager owns foreground threads; terminate the isolated test process.
        Environment.Exit(result);
        return result;
    }
}
'@
$sourcePath = Join-Path $work 'SmokeRunner.cs'
$source | Set-Content -LiteralPath $sourcePath -Encoding UTF8
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$reference = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8'
$compiler = Join-Path $framework 'csc.exe'
$runner = Join-Path $work 'SmokeRunner.exe'
& $compiler /nologo /target:exe "/out:$runner" "/reference:$reference\PresentationFramework.dll" "/reference:$reference\PresentationCore.dll" "/reference:$reference\WindowsBase.dll" "/reference:$reference\System.Xaml.dll" $sourcePath
if ($LASTEXITCODE -ne 0) { throw 'Smoke test runner compilation failed.' }
& $runner $testExecutable
if ($LASTEXITCODE -ne 0) { throw "PCL smoke test failed with exit code $LASTEXITCODE." }
if (-not (Test-Path -LiteralPath (Join-Path $work 'smoke-result.json'))) {
    throw 'Smoke test did not produce its verification report.'
}
$beforeHash = (Get-FileHash -LiteralPath $testExecutable -Algorithm SHA256).Hash
$process = Start-Process -FilePath $testExecutable -ArgumentList '--update' -WorkingDirectory $work -PassThru
if (-not $process.WaitForExit(15000)) {
    $process.Kill()
    throw 'Launcher --update command did not exit within 15 seconds.'
}
if ($process.ExitCode -ne 4) {
    throw "Launcher --update must exit as Cancel (4), got $($process.ExitCode)."
}
if ((Get-FileHash -LiteralPath $testExecutable -Algorithm SHA256).Hash -ne $beforeHash) {
    throw 'Launcher executable changed during the --update test.'
}
$reportPath = Join-Path $work 'smoke-result.json'
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$report.passed = $true
$report | Add-Member -NotePropertyName updateCommand -NotePropertyValue 'exited as Cancel (4); executable SHA-256 unchanged'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host 'PASS: --update exits as Cancel (4) and leaves the executable unchanged.'
