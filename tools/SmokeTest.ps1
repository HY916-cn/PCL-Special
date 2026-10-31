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
$testExecutable = Join-Path $work ([IO.Path]::GetFileName($executable))
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
using System.Windows.Media;
using System.Windows.Threading;

[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]

public static class PclSmokeRunner {
    private static Assembly pcl;
    private static ResourceManager resources;
    private static readonly Dictionary<string, Assembly> libraries = new Dictionary<string, Assembly>();
    private static Dictionary<string, object> themeResult;
    private static Dictionary<string, object> toolboxResult;
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
        if (name.EndsWith(".resources", StringComparison.OrdinalIgnoreCase)) return null;
        lock (libraries) {
            Assembly result;
            if (libraries.TryGetValue(name, out result)) return result;
            byte[] bytes = resources.GetObject(name, System.Globalization.CultureInfo.InvariantCulture) as byte[];
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
        Invoke(settings, "Set", "SystemSystemTelemetry", true, null);
        Require(!Convert.ToBoolean(Invoke(settings, "Get", "SystemSystemTelemetry", null)),
            "Changing settings re-enabled telemetry.");
        Invoke(settings, "Reset", "SystemSystemTelemetry", null);
        Require(!Convert.ToBoolean(Invoke(settings, "Get", "SystemSystemTelemetry", null)),
            "Resetting settings re-enabled telemetry.");
        RequireNoOp(pcl.GetType("PCL.ModMain", true), "Telemetry");
        Type secret = pcl.GetType("PCL.ModSecret", true);
        FieldInfo clientId = secret.GetField("OAuthClientId", StaticMembers);
        object savedClientId = clientId.GetValue(null);
        try {
            clientId.SetValue(null, "");
            bool rejected = false;
            try { Invoke(pcl.GetType("PCL.ModLaunch", true), "MsLoginStep1New", new object[] { null }); }
            catch (Exception ex) { rejected = ex.Message.Contains("Client ID"); }
            Require(rejected, "Missing Microsoft Client ID was not rejected before authentication.");
            rejected = false;
            try { Invoke(pcl.GetType("PCL.ModLaunch", true), "MsLoginStep1Refresh", "smoke-test-not-a-token"); }
            catch (Exception ex) { rejected = ex.Message.Contains("Client ID"); }
            Require(rejected, "Missing Microsoft Client ID was not rejected before refresh.");
        } finally { clientId.SetValue(null, savedClientId); }
    }

    private static string PrimaryThemeColor() {
        SolidColorBrush brush = Application.Current.Resources["ColorBrush3"] as SolidColorBrush;
        Require(brush != null && brush.Color.A > 0, "Theme did not supply a visible primary color brush.");
        return brush.Color.ToString();
    }

    private static int ThemeField(Type theme, string name) {
        return Convert.ToInt32(theme.GetField(name, StaticMembers).GetValue(null));
    }

    private static void CheckThemes() {
        Type theme = pcl.GetType("PCL.ModSecret", true);
        Type settings = pcl.GetType("PCL.Settings", true);
        HashSet<string> staticColors = new HashSet<string>();
        try {
            Require(!(bool)Invoke(theme, "ThemeCheckOne", -1) && !(bool)Invoke(theme, "ThemeCheckOne", 15),
                "Theme IDs outside 0..14 were accepted.");
            for (int id = 0; id <= 14; id++) {
                Require((bool)Invoke(theme, "ThemeCheckOne", id), "Theme ID was rejected: " + id);
                Invoke(theme, "ThemeRefresh", id);
                Require(ThemeField(theme, "ThemeNow") == id, "Theme selection was not applied: " + id);
                string color = PrimaryThemeColor();
                if (id <= 11) staticColors.Add(color);
            }
            Require(staticColors.Count == 12, "Static themes did not produce 12 distinct primary colors.");

            Invoke(settings, "Set", "UiLauncherHue", 73, null);
            Invoke(settings, "Set", "UiLauncherSat", 44, null);
            Invoke(settings, "Set", "UiLauncherLight", 31, null);
            Invoke(settings, "Set", "UiLauncherDelta", 110, null);
            Invoke(theme, "ThemeRefresh", 14);
            Require(ThemeField(theme, "ColorHue") == 73 && ThemeField(theme, "ColorSat") == 44 &&
                ThemeField(theme, "ColorLightAdjust") == 11, "Custom theme did not apply its color settings.");
            string customColor = PrimaryThemeColor();
            Invoke(settings, "Set", "UiLauncherHue", 190, null);
            Invoke(theme, "ThemeRefresh", 14);
            Require(ThemeField(theme, "ColorHue") == 190 && PrimaryThemeColor() != customColor,
                "Refreshing the same custom theme did not apply the changed hue.");

            // Reference values cross-checked against two published snapshot implementations.
            int[,] reference = new int[,] {
                {210,85,0}, {180,50,0}, {130,40,0}, {75,50,0},
                {35,30,0}, {225,10,-20}, {345,70,15}, {285,50,0},
                {50,65,10}, {25,75,5}, {5,70,-5}, {230,60,-5}
            };
            for (int id = 0; id < 12; id++) {
                Invoke(theme, "ThemeRefresh", id);
                Require(ThemeField(theme, "ColorHue") == reference[id,0] &&
                    ThemeField(theme, "ColorSat") == reference[id,1] &&
                    ThemeField(theme, "ColorLightAdjust") == reference[id,2],
                    "Theme palette differs from the published snapshot reference: " + id);
            }
            Invoke(theme, "ThemeRefresh", 2);
            object greenDelta = theme.GetField("ColorHueTopbarDelta", StaticMembers).GetValue(null);
            Require(((int[])greenDelta.GetType().GetMethod("AsT2").Invoke(greenDelta, null)).SequenceEqual(new int[] {5,-5,5}),
                "Green theme gradient differs from the published reference.");
            Invoke(theme, "ThemeRefresh", 13);
            Require(ThemeField(theme, "ColorHue") == 290 && ThemeField(theme, "ColorSat") == 50 && ThemeField(theme, "ColorLightAdjust") == 0,
                "Rainbow gradient palette differs from the published reference.");
            object rainbowDelta = theme.GetField("ColorHueTopbarDelta", StaticMembers).GetValue(null);
            Require(((int[])rainbowDelta.GetType().GetMethod("AsT2").Invoke(rainbowDelta, null)).SequenceEqual(new int[] {-30,10,50}),
                "Rainbow theme gradient differs from the published reference.");
            Invoke(theme, "ThemeRefresh", 12);
            int firstHue = ThemeField(theme, "ColorHue");
            Invoke(theme, "ThemeRefresh", -1);
            int hueChange = (ThemeField(theme, "ColorHue") - firstHue + 360) % 360;
            Require((hueChange == 4 || hueChange == 356) && ThemeField(theme, "ColorSat") == 45,
                "Color cycling does not follow the published four-degree step.");
            themeResult = new Dictionary<string, object> {
                { "passed", true }, { "themeCount", 15 }, { "distinctStaticPrimaryColors", staticColors.Count },
                { "invalidIdsRejected", true }, { "customSettingsApplied", true },
                { "sameCustomThemeRefresh", true }, { "animatedThemeIds", new int[] { 12 } }, { "snapshotPaletteReference", true }, { "fixedGradientThemeId", 13 }
            };
            Console.WriteLine("PASS: 15 themes, 12 distinct static colors, custom color changes, and animated hue refresh.");
        } finally {
            Invoke(theme, "ThemeRefresh", 0);
        }
    }

    private static void CheckToolbox(string work) {
        Type toolbox = pcl.GetType("PCL.PageOtherTest", true);
        DateTime day = new DateTime(2026, 10, 31);
        int score = Convert.ToInt32(Invoke(toolbox, "GetDailyScore", day, "PCL-Smoke-Test"));
        Require(score >= 0 && score <= 100, "Daily score is outside 0..100.");
        for (int i = 0; i < 10; i++)
            Require(Convert.ToInt32(Invoke(toolbox, "GetDailyScore", day, "PCL-Smoke-Test")) == score,
                "Daily score changed for the same date and local key.");
        for (int i = 0; i < 128; i++)
            Require(!String.IsNullOrWhiteSpace((string)Invoke(toolbox, "GetRandomCave")), "Random cave text was empty.");
        foreach (string method in new string[] { "Jrrp", "RubbishClear", "MemoryOptimize", "MemoryOptimizeInternal", "StartCustomDownload" })
            Require(toolbox.GetMethod(method, StaticMembers) != null, "Missing original toolbox entry: " + method);
        foreach (string method in new string[] { "BtnClick_Click", "CardCave_MouseLeftButtonUp", "BtnCave_Click", "DownloadState", "SaveCacheDownloadFolder" })
            Require(toolbox.GetMethod(method, StaticMembers | BindingFlags.Instance) != null, "Missing original toolbox interaction: " + method);
        string hints = Path.Combine(work, "PCL", "hints.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(hints));
        File.WriteAllText(hints, "\r\nOriginal custom hint fixture\r\n\r\n");
        try {
            Require((string)Invoke(toolbox, "GetRandomHint") == "Original custom hint fixture", "Custom hints were not read by the original flow.");
        } finally { File.Delete(hints); }
        for (int i = 0; i < 128; i++)
            Require(!String.IsNullOrWhiteSpace((string)Invoke(toolbox, "GetRandomPresetHint")), "Original preset hint was empty.");
        Type theme = pcl.GetType("PCL.ModSecret", true);
        FieldInfo mode = theme.GetField("ThemeDontClick", StaticMembers);
        try {
            mode.SetValue(null, 1);
            Invoke(theme, "ThemeRefresh", -1);
            Require(ThemeField(theme, "ColorLightAdjust") == 999, "Original white color effect was not applied.");
            mode.SetValue(null, 2);
            for (int i = 0; i < 10; i++) {
                Invoke(theme, "ThemeRefresh", -1);
                Require(ThemeField(theme, "ColorHue") >= 0 && ThemeField(theme, "ColorHue") <= 359 &&
                    ThemeField(theme, "ColorSat") >= 40 && ThemeField(theme, "ColorSat") <= 70 &&
                    ThemeField(theme, "ColorLightAdjust") >= -20 && ThemeField(theme, "ColorLightAdjust") <= 20,
                    "Original randomized color effect was not applied.");
            }
        } finally { mode.SetValue(null, 0); Invoke(theme, "ThemeRefresh", 0); }
        toolboxResult = new Dictionary<string, object> {
            { "passed", true }, { "referenceEdition", "public PCL 2.99.0.1" },
            { "dailyScoreStable", true }, { "dailyScore", score }, { "randomCaveNonEmpty", true },
            { "customHintFile", true }, { "presetHintsNonEmpty", true }, { "colorEffectsApplied", true },
            { "cleanupExecuted", false }, { "memoryOptimizationExecuted", false }, { "windowPranksExecuted", false }
        };
        Console.WriteLine("PASS: original toolbox entries, daily score, cave text, custom/preset hints, and prank color effects.");
    }

    private static void CheckMicrosoftPollingRules() {
        Type login = pcl.GetType("PCL.MyMsgLogin", true);
        MethodInfo initial = login.GetMethod("GetPollingIntervalSeconds", StaticMembers);
        Require(Convert.ToInt32(initial.Invoke(null, new object[] { null })) == 5, "Missing polling interval must default to five seconds.");
        Require(Convert.ToInt32(initial.Invoke(null, new object[] { 0 })) == 5, "Invalid polling interval must use the default.");
        Require(Convert.ToInt32(initial.Invoke(null, new object[] { 7 })) == 7, "Microsoft polling interval was not preserved.");
        Require(Convert.ToInt32(Invoke(login, "GetNextPollingIntervalSeconds", 7, "authorization_pending")) == 7, "Pending must preserve the polling interval.");
        Require(Convert.ToInt32(Invoke(login, "GetNextPollingIntervalSeconds", 7, "slow_down")) == 12, "slow_down must permanently add five seconds.");
        Require(Convert.ToInt32(Invoke(login, "GetNextPollingIntervalSeconds", 7, "timeout")) == 14, "Timeout must back off polling.");
        Require(Convert.ToInt64(Invoke(login, "GetPollingDelayMilliseconds", 5, 2000L)) == 3000L, "Polling must wait for the remaining interval.");
        Require(Convert.ToInt64(Invoke(login, "GetPollingDelayMilliseconds", 5, 6000L)) == 0L, "Completed interval must not delay again.");
        Require(!(bool)Invoke(login, "HasDeviceCodeExpired", 1000L, 900, 900999L), "Device code expired too early.");
        Require((bool)Invoke(login, "HasDeviceCodeExpired", 1000L, 900, 901000L), "Device code expiry deadline was ignored.");
        Type launch = pcl.GetType("PCL.ModLaunch", true);
        Require((string)Invoke(launch, "MsLoginGetOAuthError", "{\"error\":\"invalid_grant\"}") == "invalid_grant", "OAuth error was not parsed.");
        Require((string)Invoke(launch, "MsLoginGetOAuthError", "not JSON") == "", "Legacy OAuth error text was not supported.");
        Console.WriteLine("PASS: Microsoft polling intervals, slowdown, timeout backoff, device-code expiry, and OAuth error parsing.");
    }

    private static Dictionary<string, object> CheckMicrosoftDeviceCode() {
        Type secret = pcl.GetType("PCL.ModSecret", true);
        string clientId = (string)secret.GetField("OAuthClientId", StaticMembers).GetValue(null);
        Require(clientId == "fe72edc2-3a6f-4280-90e8-e2beb64ce7e1", "Public edition Client ID was not configured by default.");
        Type network = pcl.GetType("PCL.ModNet", true);
        MethodInfo request = network.GetMethod("NetRequestByClient", StaticMembers);
        object post = request.GetParameters()[1].ParameterType.GetProperty("Post", StaticMembers).GetValue(null, null);
        string deviceEndpoint = "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode";
        string tokenEndpoint = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token";
        string body = "client_id=" + Uri.EscapeDataString(clientId) + "&scope=XboxLive.signin%20offline_access";
        string response = (string)Invoke(network, "NetRequestByClient", deviceEndpoint, post, body,
            "application/x-www-form-urlencoded", "*/*", 20000, null, true, null, false, false);
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        Dictionary<string, object> device = serializer.Deserialize<Dictionary<string, object>>(response);
        Require(device.ContainsKey("device_code") && !String.IsNullOrWhiteSpace((string)device["device_code"]),
            "Microsoft did not issue a device code.");
        int interval = device.ContainsKey("interval") ? Convert.ToInt32(device["interval"]) : 5;
        Require(Convert.ToInt32(device["expires_in"]) > 0 && interval > 0, "Invalid device code lifetime or polling interval.");
        // Never display, log, persist, or authorize either returned code in this test.
        Thread.Sleep(interval * 1000);
        bool pending = false;
        try {
            Invoke(network, "NetRequestByClient", tokenEndpoint, post,
                "client_id=" + Uri.EscapeDataString(clientId) + "&grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=" + Uri.EscapeDataString((string)device["device_code"]),
                "application/x-www-form-urlencoded", "*/*", 20000, null, true, null, false, false);
        } catch (Exception ex) {
            PropertyInfo payload = ex.GetType().GetProperty("Response");
            if (payload != null) {
                Dictionary<string, object> error = serializer.Deserialize<Dictionary<string, object>>((string)payload.GetValue(ex, null));
                pending = error.ContainsKey("error") && (string)error["error"] == "authorization_pending";
            }
            if (!pending) throw new InvalidOperationException("Microsoft token endpoint did not return the expected authorization_pending result.");
        }
        Require(pending, "Device authorization must remain pending without account sign-in.");
        Console.WriteLine("PASS: Microsoft issued a device code and token polling remained authorization_pending without account access.");
        return new Dictionary<string, object> {
            { "deviceCodeIssued", true }, { "tokenPollingPending", true }, { "pollIntervalSeconds", interval }, { "pollingRules", "interval, slow_down, timeout backoff and local expiry verified" },
            { "accountAuthorizationPerformed", false }, { "endToEndAccountLoginVerified", false }, { "codesPersisted", false }
        };
    }

    private static void DownloadTest(string work) {
        Dictionary<string, object> loginResult = CheckMicrosoftDeviceCode();
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
            { "fixedSettings", "Set and Reset preserve updates=3, announcements=2, telemetry=false" },
            { "themes", themeResult }, { "toolbox", toolboxResult }, { "microsoftLogin", loginResult }
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
            Environment.SetEnvironmentVariable("PCL_MS_CLIENT_ID", null);
            pcl = Assembly.LoadFrom(args[0]);
            resources = new ResourceManager("PCL.Resources", pcl);
            AppDomain.CurrentDomain.AssemblyResolve += ResolveLibrary;
            Console.WriteLine("INIT: embedded core dependencies");
            Assembly core = ResolveLibrary(null, new ResolveEventArgs("MeloongCore"));
            Invoke(core.GetType("MeloongCore.Main", true), "Init", "PCLSmokeTest");
            Console.WriteLine("INIT: WPF application");
            Application app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Assembly wpf = ResolveLibrary(null, new ResolveEventArgs("MeloongCore.Wpf"));
            Invoke(wpf.GetType("MeloongCore.Wpf.Main", true), "Init");
            Console.WriteLine("INIT: isolated settings");
            IsolateSettings();
            CheckFixedSettings();
            Console.WriteLine("VERIFY: download restriction and update settings");
            Type secret = pcl.GetType("PCL.ModSecret", true);
            Require(!(bool)secret.GetField("RestrictMcDownload", StaticMembers).GetRawConstantValue(),
                "Minecraft download restriction is enabled.");
            RequireNoOp(secret, "UpdateRestart");
            RequireNoOp(secret, "UpdateReplace");
            RequireNoOp(secret, "DownloadLatestPCL");
            // Initialize UiThreadId on the dispatcher thread before any network worker starts.
            Console.WriteLine("INIT: PCL modules");
            RuntimeHelpers.RunClassConstructor(pcl.GetType("PCL.ModBase", true).TypeHandle);
            Console.WriteLine("VERIFY: theme palettes and refresh behavior");
            CheckThemes();
            Console.WriteLine("VERIFY: original toolbox behavior");
            CheckToolbox(work);
            CheckMicrosoftPollingRules();
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
if ($env:GITHUB_ACTIONS -eq 'true') {
    if (Test-Path 'HKCU:\Software\PCLHY916Fixed') {
        throw 'GUI smoke test requires a fresh disposable Windows profile.'
    }
    $gui = Start-Process -FilePath $testExecutable -WorkingDirectory $work -PassThru
    try {
        $loaded = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline -and -not $gui.HasExited) {
            $gui.Refresh()
            $logPath = Join-Path $work 'PCLHY916Fixed/Log1.txt'
            $log = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 } else { '' }
            if ($gui.MainWindowHandle -ne [IntPtr]::Zero -and $gui.MainWindowTitle -eq 'PCL特别版' -and $log.Contains('第三阶段加载用时')) {
                $loaded = $true
                break
            }
            Start-Sleep -Milliseconds 250
        }
        if (-not $loaded) { throw ("Launcher startup check failed. Title='{0}', Handle={1}, HasExited={2}." -f $gui.MainWindowTitle, $gui.MainWindowHandle, $gui.HasExited) }
        $report | Add-Member -NotePropertyName guiStartup -NotePropertyValue 'main window displayed and third startup stage completed; EULA left untouched'
    } finally {
        if (-not $gui.HasExited) { $gui.Kill(); $gui.WaitForExit() }
    }
}
$report.passed = $true
$report | Add-Member -NotePropertyName updateCommand -NotePropertyValue 'exited as Cancel (4); executable SHA-256 unchanged'
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host 'PASS: --update exits as Cancel (4) and leaves the executable unchanged.'
