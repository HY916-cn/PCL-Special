param(
    [Parameter(Mandatory = $true)][string]$ExecutablePath,
    [Parameter(Mandatory = $true)][string]$WorkDirectory
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -eq 'true' -and (Test-Path 'HKCU:\Software\PCLHY916Fixed')) {
    throw 'GUI smoke test requires a fresh disposable Windows profile.'
}
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
$moduleBundle = Join-Path (Split-Path $executable -Parent) 'LinkModules'
if (Test-Path -LiteralPath $moduleBundle) {
    Copy-Item -LiteralPath $moduleBundle -Destination (Join-Path $work 'LinkModules') -Recurse
}

# A separate Framework process makes Paths.Base and the HTTP cache local to this test.
$source = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Reflection;
using System.Resources;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
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
    private static Dictionary<string, object> sourcePolicyResult;
    private static Dictionary<string, object> curseForgeResult;
    private static Dictionary<string, object> multiplayerResult;
    private static Dictionary<string, object> downloadPerformanceResult;
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

    private static void CheckDeviceIdentity() {
        Type secret = pcl.GetType("PCL.ModSecret", true);
        Type basis = pcl.GetType("PCL.ModBase", true);
        Type settings = pcl.GetType("PCL.Settings", true);
        string code = (string)basis.GetField("Identify", StaticMembers).GetValue(null);
        Require(code != "0000-0000-0000-0000" && code.Length == 19,
            "Device identity must be a real local code in the original format.");
        Require((string)Invoke(secret, "GetIdentify") == code && (string)Invoke(secret, "GetIdentify") == code,
            "Device identity changed for the same device and persisted local seed.");
        string board;
        try {
            object boardValue;
            try { boardValue = Microsoft.Win32.Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\HardwareConfig", "LastConfig", "Unknown") ?? "Unknown"; }
            catch { boardValue = "Unknown"; }
            board = boardValue.ToString() == "__NULL__" ? "Unknown" : boardValue.ToString().ToUpperInvariant().Trim('{', '}');
        } catch { board = "Unknown"; }
        string seed = (string)Invoke(settings, "Get", "Identify", null);
        Require(seed.Length >= 3, "Device identity did not persist its local seed.");
        ulong hash = 5381;
        unchecked { foreach (char value in board + seed) hash = (hash << 5) ^ hash ^ value; }
        string raw = (hash ^ 0xA98F501BC684032FUL).ToString("X").PadLeft(16, '7');
        string expected = raw.Substring(4, 4) + "-" + raw.Substring(12, 4) + "-" + raw.Substring(0, 4) + "-" + raw.Substring(8, 4);
        Require(code == expected, "Device identity differs from the original public 2.99.0.1 algorithm.");

        const string key = "LoginLegacyName";
        const string fixture = "PCL migration fixture";
        string oldCipher = (string)Invoke(settings, "DesEncrypt", fixture, "PCL0000-0000-0000-0000");
        Invoke(basis, "WriteIni", "Setup", key, oldCipher);
        IDictionary entries = (IDictionary)settings.GetField("Entries", StaticMembers).GetValue(null);
        object entry = entries[key];
        object cache = entry.GetType().GetField("ValueCache").GetValue(entry);
        cache.GetType().GetMethod("Clear").Invoke(cache, null);
        Require((string)Invoke(settings, "Get", key, null) == fixture,
            "Encrypted settings from the previous device identity were not preserved.");
        string newCipher = (string)Invoke(basis, "ReadIni", "Setup", key, "");
        const string prefix = "PCLDevice1:";
        Require(newCipher.StartsWith(prefix, StringComparison.Ordinal) && (string)Invoke(settings, "DesDecrypt", newCipher.Substring(prefix.Length), "PCL" + code) == fixture,
            "Legacy encrypted settings were not migrated to the current device identity.");
        cache.GetType().GetMethod("Clear").Invoke(cache, null);
        Require((string)Invoke(settings, "Get", key, null) == fixture,
            "Migrated settings were not readable on a fresh load.");
        // This synthetic identity accepts legacy DES padding with the wrong key; migration must still choose the legacy format.
        FieldInfo identity = basis.GetField("Identify", StaticMembers);
        const string ambiguousIdentity = "6EDE-0E9F-46BB-673C";
        Require((string)Invoke(settings, "DesDecrypt", oldCipher, "PCL" + ambiguousIdentity) != fixture,
            "The ambiguous legacy fixture must decrypt without an exception using the wrong key.");
        try {
            identity.SetValue(null, ambiguousIdentity);
            Invoke(basis, "WriteIni", "Setup", key, oldCipher);
            cache.GetType().GetMethod("Clear").Invoke(cache, null);
            Require((string)Invoke(settings, "Get", key, null) == fixture,
                "Legacy settings were read with the wrong key despite their unversioned format.");
            newCipher = (string)Invoke(basis, "ReadIni", "Setup", key, "");
            Require(newCipher.StartsWith(prefix, StringComparison.Ordinal) &&
                (string)Invoke(settings, "DesDecrypt", newCipher.Substring(prefix.Length), "PCL" + ambiguousIdentity) == fixture,
                "Ambiguous legacy ciphertext was not migrated to the versioned format.");
            cache.GetType().GetMethod("Clear").Invoke(cache, null);
            Require((string)Invoke(settings, "Get", key, null) == fixture,
                "The versioned migration fixture could not be reloaded.");
        } finally {
            identity.SetValue(null, code);
            Invoke(settings, "Reset", key, null);
        }
        Console.WriteLine("PASS: original local device identity, persistent seed, and encrypted-settings migration.");
    }

    private static void CheckToolbox(string work) {
        CheckDeviceIdentity();
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
            { "localDeviceIdentity", true }, { "publicIdentityAlgorithm", true }, { "legacyEncryptedSettingsMigrated", true },
            { "ambiguousLegacyCiphertextMigrated", true },
            { "customHintFile", true }, { "presetHintsNonEmpty", true }, { "colorEffectsApplied", true },
            { "cleanupExecuted", false }, { "memoryOptimizationExecuted", false }, { "windowPranksExecuted", false }
        };
        Console.WriteLine("PASS: original toolbox entries, daily score, cave text, custom/preset hints, and prank color effects.");
    }

    private static void CheckCurseForge() {
        Type secret = pcl.GetType("PCL.ModSecret", true);
        FieldInfo key = secret.GetField("CurseForgeAPIKey", StaticMembers);
        string saved = (string)key.GetValue(null);
        bool embedded = !String.IsNullOrWhiteSpace((string)secret.GetField("DefaultCurseForgeAPIKey", StaticMembers).GetRawConstantValue());
        if (Environment.GetEnvironmentVariable("PCL_EXPECT_CURSEFORGE_KEY") == "true")
            Require(embedded, "The release build is missing its shared CurseForge API key.");
        MethodInfo sign = secret.GetMethod("SecretHeadersSign", StaticMembers);
        try {
            key.SetValue(null, "pcl-smoke-key");
            foreach (string url in new string[] {
                "https://api.curseforge.com/v1/mods/238222",
                "https://API.CURSEFORGE.COM/v1/mods/238222",
                "https://edge.forgecdn.net/files/1/test.jar" }) {
                using (HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, url)) {
                    sign.Invoke(null, new object[] { url, request, false });
                    Require(request.Headers.GetValues("x-api-key").Single() == "pcl-smoke-key", "CurseForge authentication header was not applied.");
                }
            }
            foreach (string url in new string[] {
                "http://api.curseforge.com/v1/mods/238222",
                "https://api.curseforge.com.example.org/v1/mods/238222",
                "https://example.org/?url=api.curseforge.com",
                "https://example.org/forgecdn.net/test.jar",
                "https://mod.mcimirror.top/curseforge/v1/mods/238222" }) {
                using (HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, url)) {
                    sign.Invoke(null, new object[] { url, request, false });
                    Require(!request.Headers.Contains("x-api-key"), "CurseForge key was attached to an unrelated or insecure URL.");
                }
            }
            key.SetValue(null, "");
            using (HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, "https://api.curseforge.com/v1/mods/238222")) {
                sign.Invoke(null, new object[] { request.RequestUri.AbsoluteUri, request, false });
                Require(!request.Headers.Contains("x-api-key"), "An empty API key was sent.");
            }
        } finally { key.SetValue(null, saved); }
        bool officialVerified = false;
        if (embedded) {
            using (HttpClientHandler handler = new HttpClientHandler { AllowAutoRedirect = false })
            using (HttpClient client = new HttpClient(handler))
            using (HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, "https://api.curseforge.com/v1/mods/238222")) {
                client.Timeout = TimeSpan.FromSeconds(30);
                sign.Invoke(null, new object[] { request.RequestUri.AbsoluteUri, request, false });
                using (HttpResponseMessage response = client.SendAsync(request).GetAwaiter().GetResult()) {
                    Require(response.StatusCode == HttpStatusCode.OK, "CurseForge official API returned HTTP " + (int)response.StatusCode + ".");
                    JavaScriptSerializer serializer = new JavaScriptSerializer();
                    Dictionary<string, object> body = serializer.Deserialize<Dictionary<string, object>>(response.Content.ReadAsStringAsync().GetAwaiter().GetResult());
                    Require(Convert.ToInt32(((Dictionary<string, object>)body["data"])["id"]) == 238222, "CurseForge returned the wrong mod.");
                    officialVerified = true;
                }
            }
        }
        curseForgeResult = new Dictionary<string, object> {
            { "embeddedSharedKey", embedded }, { "headerHostAndTlsChecks", true },
            { "officialApiVerified", officialVerified }, { "testModId", 238222 }, { "keyDisclosed", false }
        };
        Console.WriteLine(officialVerified ? "PASS: CurseForge credential routing and official API verification." :
            "PASS: CurseForge credential routing; official API verification skipped without an embedded key.");
    }

    private static int FreeLinkPort() {
        while (true) {
            TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            if (port < 65534) return port;
        }
    }

    private static Process StartLinkCore(string file, string arguments, string log) {
        Process process = new Process { StartInfo = new ProcessStartInfo {
            FileName = file, Arguments = arguments, WorkingDirectory = Path.GetDirectoryName(file),
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        }};
        object gate = new object();
        DataReceivedEventHandler handler = delegate(object sender, DataReceivedEventArgs e) {
            if (e.Data != null) lock (gate) File.AppendAllText(log, e.Data + Environment.NewLine);
        };
        process.OutputDataReceived += handler;
        process.ErrorDataReceived += handler;
        Require(process.Start(), "EasyTier native process did not start.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }

    private static List<Dictionary<string, object>> LinkPeers(string file, int rpc, int timeoutMilliseconds = 5000) {
        using (Process process = new Process { StartInfo = new ProcessStartInfo {
            FileName = file, Arguments = "-o json -p 127.0.0.1:" + rpc + " peer",
            WorkingDirectory = Path.GetDirectoryName(file), UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        }}) {
            process.Start();
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeoutMilliseconds)) { process.Kill(); process.WaitForExit(); throw new TimeoutException("EasyTier CLI timed out."); }
            Require(process.ExitCode == 0, "EasyTier CLI returned an error.");
            errors.GetAwaiter().GetResult();
            return new JavaScriptSerializer().Deserialize<List<Dictionary<string, object>>>(output.GetAwaiter().GetResult());
        }
    }

    private static void CheckMultiplayer(string work) {
        Type link = pcl.GetType("PCL.PageLinkMain", true);
        Type settings = pcl.GetType("PCL.Settings", true);
        IDictionary settingEntries = (IDictionary)settings.GetField("Entries", StaticMembers).GetValue(null);
        foreach (string settingKey in new string[] { "UiHiddenPageLink", "UiHiddenSetupLink" }) {
            object entry = settingEntries[settingKey];
            object cache = entry.GetType().GetField("ValueCache").GetValue(entry);
            cache.GetType().GetMethod("Clear").Invoke(cache, null);
        }
        Require(!Convert.ToBoolean(Invoke(settings, "Get", "UiHiddenPageLink", null)) &&
            !Convert.ToBoolean(Invoke(settings, "Get", "UiHiddenSetupLink", null)), "Multiplayer entry is hidden by default.");
        foreach (string code in new string[] { "P63DD-ABCDE-12345-0205E", "P63DD-ABCDE-12345", "【P63DD-ABCDE-12345-0205E】" })
            Require(Invoke(link, "ValidateCodeFormat", code) == null, "A supported original invitation was rejected.");
        foreach (string code in new string[] { "", "P0001-A-B", "P63DD-ABCDE-12345-99FFF", "P0001-ABCDE-12345-0205E", "P63DD-ABCDE-12345-02GGG", "P63DD-ABCDE-12345-0205E --bad" })
            Require(Invoke(link, "ValidateCodeFormat", code) != null, "A malformed invitation was accepted.");

        string module = Path.Combine(work, "EasyTier-2.6.4");
        string bundle = Path.Combine(work, "LinkModules");
        string archive = Path.Combine(bundle, "easytier-windows-x86_64-v2.6.4.zip");
        Require((bool)Invoke(link, "TryInstallBundledModule", "x86_64", bundle, module), "The supplied module was not installed offline.");
        string archiveHash;
        using (SHA256 sha = SHA256.Create())
        using (FileStream stream = File.OpenRead(archive))
            archiveHash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        Require(archiveHash == "27af91e270e554709b048bd32327fefd2dfce5062ae1e8701af7550c6f525f84", "Native module archive failed its pinned SHA-256.");
        string corrupt = Path.Combine(work, "corrupt-link.zip");
        File.WriteAllText(corrupt, "PCL invalid module test");
        bool rejected = false;
        try { Invoke(link, "InstallModule", corrupt, Path.Combine(work, "rejected-link"), "x86_64"); }
        catch { rejected = true; }
        Require(rejected, "An unverified multiplayer module was installed.");
        string core = Path.Combine(module, "联机模块.exe");
        string cli = Path.Combine(module, "联机模块 CLI.exe");
        Require(File.Exists(core) && File.Exists(cli), "Native module executables were not installed.");

        TcpListener echo = new TcpListener(IPAddress.Loopback, 0);
        echo.Start();
        int game = ((IPEndPoint)echo.LocalEndpoint).Port;
        UdpClient udpEcho = new UdpClient(new IPEndPoint(IPAddress.Loopback, game));
        Thread tcpThread = new Thread(delegate() {
            try { while (true) using (TcpClient client = echo.AcceptTcpClient()) {
                try {
                    client.ReceiveTimeout = 8000;
                    byte[] data = new byte[1024];
                    NetworkStream stream = client.GetStream();
                    int count;
                    while ((count = stream.Read(data, 0, data.Length)) > 0) stream.Write(data, 0, count);
                } catch (IOException) {}
            }} catch (SocketException) {} catch (ObjectDisposedException) {}
        });
        tcpThread.IsBackground = true;
        tcpThread.Start();
        Thread udpThread = new Thread(delegate() {
            try { while (true) { IPEndPoint sender = null; byte[] data = udpEcho.Receive(ref sender); udpEcho.Send(data, data.Length, sender); } }
            catch (SocketException) {} catch (ObjectDisposedException) {}
        });
        udpThread.IsBackground = true;
        udpThread.Start();
        HashSet<int> ports = new HashSet<int> { game };
        Func<int> nextPort = delegate() { int port; do { port = FreeLinkPort(); } while (!ports.Add(port)); return port; };
        int hostRpc = nextPort(), clientRpc = nextPort(), hostListen = nextPort(), clientListen = nextPort(), forward = nextPort();
        string room = "P" + game.ToString("X4") + "-ABCDE";
        string hostArgs = (string)Invoke(link, "BuildLinkArguments", true, game, forward, hostRpc, hostListen, room, "12345", "Server-SMOKE",
            new string[] { "tcp://127.0.0.1:" + clientListen }, false);
        string clientArgs = (string)Invoke(link, "BuildLinkArguments", false, game, forward, clientRpc, clientListen, room, "12345", "Client-SMOKE",
            new string[] { "tcp://127.0.0.1:" + hostListen }, false);
        foreach (string peer in new string[] { "tcp://127.0.0.1:1\" --bad", "http://example.org:80", "tcp://127.0.0.1:1\r\n--bad" }) {
            rejected = false;
            try { Invoke(link, "BuildLinkArguments", true, game, forward, hostRpc, hostListen, room, "12345", "Server-SMOKE", new string[] { peer }, false); }
            catch { rejected = true; }
            Require(rejected, "Unsafe custom peer arguments were accepted.");
        }
        Require(hostArgs.Contains("--rpc-portal 127.0.0.1:") && hostArgs.Contains("--bind-device false") && clientArgs.Contains("--tcp-whitelist=0") &&
            clientArgs.Contains("--port-forward udp://127.0.0.1:"), "Original no-TUN restricted forwarding arguments were not built.");
        // Keep the transport test on loopback and avoid public STUN traffic.
        hostArgs = hostArgs.Replace("--listeners " + hostListen, "--listeners tcp://127.0.0.1:" + hostListen) + " --stun-servers --stun-servers-v6";
        clientArgs = clientArgs.Replace("--listeners " + clientListen, "--listeners tcp://127.0.0.1:" + clientListen) + " --stun-servers --stun-servers-v6";
        Process host = null, guest = null;
        try {
            host = StartLinkCore(core, hostArgs, Path.Combine(work, "link-host.log"));
            guest = StartLinkCore(core, clientArgs, Path.Combine(work, "link-client.log"));
            bool ready = false;
            DateTime deadline = DateTime.UtcNow.AddSeconds(60);
            while (DateTime.UtcNow < deadline) {
                Require(!host.HasExited && !guest.HasExited, "A native multiplayer peer exited early.");
                try {
                    List<Dictionary<string, object>> peers = LinkPeers(cli, clientRpc);
                    ready = peers.Any(p => Convert.ToString(p["cost"]) == "Local" && !String.IsNullOrEmpty(Convert.ToString(p["ipv4"]))) &&
                        peers.Any(p => Convert.ToString(p["ipv4"]) == "10.114.114.114" && Convert.ToString(p["cost"]) != "Local");
                    if (ready) break;
                } catch (InvalidOperationException) {}
                Thread.Sleep(250);
            }
            if (!ready) {
                foreach (string log in new string[] { "link-host.log", "link-client.log" }) {
                    string path = Path.Combine(work, log);
                    if (File.Exists(path)) Console.Error.WriteLine(log + ":\n" + String.Join("\n", File.ReadLines(path).Reverse().Take(12).Reverse()));
                }
            }
            Require(ready, "Native peers did not discover the host and obtain a client IPv4.");
            byte[] payload = Encoding.UTF8.GetBytes("PCL native multiplayer forwarding check");
            using (TcpClient client = new TcpClient()) {
                client.SendTimeout = client.ReceiveTimeout = 5000;
                client.Connect(IPAddress.Loopback, forward);
                NetworkStream stream = client.GetStream();
                stream.Write(payload, 0, payload.Length);
                byte[] response = new byte[payload.Length];
                int received = 0;
                while (received < response.Length) { int count = stream.Read(response, received, response.Length - received); Require(count > 0, "TCP forwarded echo was truncated."); received += count; }
                Require(payload.SequenceEqual(response), "TCP forwarded data differed from its payload.");
            }
            using (UdpClient client = new UdpClient()) {
                client.Client.ReceiveTimeout = 5000;
                client.Send(payload, payload.Length, new IPEndPoint(IPAddress.Loopback, forward));
                IPEndPoint sender = null;
                Require(payload.SequenceEqual(client.Receive(ref sender)), "UDP forwarded data differed from its payload.");
            }
            string[] publicPeers = ((IEnumerable)Invoke(link, "GetDefaultPeers")).Cast<string>().ToArray();
            Require(publicPeers.Length > 0 && publicPeers.Length <= 2, "The public relay test requires one or two configured nodes.");
            List<Dictionary<string, object>> publicRelayResults = new List<Dictionary<string, object>>();
            foreach (string peerAddress in publicPeers) {
                int relayHostRpc = nextPort(), relayClientRpc = nextPort(), relayHostListen = nextPort(), relayClientListen = nextPort(), relayForward = nextPort();
                string relayRoom = "P" + game.ToString("X4") + "-" + Guid.NewGuid().ToString("N").Substring(0, 5).ToUpperInvariant();
                string relaySecret = Guid.NewGuid().ToString("N").Substring(0, 5).ToUpperInvariant();
                bool relayDhcpReady = false, hostDiscovered = false, relayVerified = false, tcpVerified = false, udpVerified = false;
                string hostCost = "", failureReason = "", stage = "process startup";
                Process relayHost = null, relayGuest = null;
                try {
                    string relayHostArgs = (string)Invoke(link, "BuildLinkArguments", true, game, relayForward, relayHostRpc, relayHostListen,
                        relayRoom, relaySecret, "Server-RELAY", new string[] { peerAddress }, false);
                    string relayClientArgs = (string)Invoke(link, "BuildLinkArguments", false, game, relayForward, relayClientRpc, relayClientListen,
                        relayRoom, relaySecret, "Client-RELAY", new string[] { peerAddress }, false);
                    // Disable P2P and STUN so the fixture payload must travel through this public relay.
                    relayHostArgs = relayHostArgs.Replace("--listeners " + relayHostListen, "--listeners tcp://127.0.0.1:" + relayHostListen) +
                        " --stun-servers --stun-servers-v6 --disable-p2p";
                    relayClientArgs = relayClientArgs.Replace("--listeners " + relayClientListen, "--listeners tcp://127.0.0.1:" + relayClientListen) +
                        " --stun-servers --stun-servers-v6 --disable-p2p";
                    int relayIndex = publicRelayResults.Count;
                    relayHost = StartLinkCore(core, relayHostArgs, Path.Combine(work, "link-public-" + relayIndex + "-host.log"));
                    relayGuest = StartLinkCore(core, relayClientArgs, Path.Combine(work, "link-public-" + relayIndex + "-client.log"));
                    stage = "relay discovery";
                    DateTime relayDeadline = DateTime.UtcNow.AddSeconds(30);
                    while (DateTime.UtcNow < relayDeadline) {
                        Require(!relayHost.HasExited && !relayGuest.HasExited, "A public relay peer exited early.");
                        try {
                            int remaining = Math.Max(1, (int)Math.Min(5000, (relayDeadline - DateTime.UtcNow).TotalMilliseconds));
                            List<Dictionary<string, object>> peers = LinkPeers(cli, relayClientRpc, remaining);
                            relayDhcpReady = peers.Any(p => Convert.ToString(p["cost"]) == "Local" && !String.IsNullOrEmpty(Convert.ToString(p["ipv4"])));
                            Dictionary<string, object> hostPeer = peers.FirstOrDefault(p => Convert.ToString(p["ipv4"]) == "10.114.114.114" && Convert.ToString(p["cost"]) != "Local");
                            hostDiscovered = hostPeer != null;
                            string cost = hostDiscovered ? Convert.ToString(hostPeer["cost"]) : "";
                            hostCost = new string(cost.Where(c => c >= ' ' && c <= '~').Take(80).ToArray());
                            relayVerified = cost.IndexOf("relay", StringComparison.OrdinalIgnoreCase) >= 0;
                            if (relayDhcpReady && hostDiscovered && relayVerified) break;
                        } catch (InvalidOperationException) {} catch (TimeoutException) {}
                        int delay = (int)Math.Min(250, (relayDeadline - DateTime.UtcNow).TotalMilliseconds);
                        if (delay > 0) Thread.Sleep(delay);
                    }
                    Require(relayDhcpReady && hostDiscovered && relayVerified, "Public relay discovery timed out.");
                    stage = "TCP echo";
                    try {
                        Require(!relayHost.HasExited && !relayGuest.HasExited, "A public relay peer exited early.");
                        using (TcpClient client = new TcpClient()) {
                            client.SendTimeout = client.ReceiveTimeout = 8000;
                            Require(client.ConnectAsync(IPAddress.Loopback, relayForward).Wait(8000), "TCP relay connection timed out.");
                            NetworkStream stream = client.GetStream();
                            stream.Write(payload, 0, payload.Length);
                            byte[] response = new byte[payload.Length];
                            int received = 0;
                            while (received < response.Length) { int count = stream.Read(response, received, response.Length - received); Require(count > 0, "TCP relay echo was truncated."); received += count; }
                            Require(payload.SequenceEqual(response), "TCP relay echo differed from its payload.");
                            tcpVerified = true;
                        }
                    } catch (Exception ex) { failureReason = stage + ": " + ex.GetType().Name; }
                    stage = "UDP echo";
                    try {
                        Require(!relayHost.HasExited && !relayGuest.HasExited, "A public relay peer exited early.");
                        using (UdpClient client = new UdpClient()) {
                            client.Client.SendTimeout = client.Client.ReceiveTimeout = 8000;
                            client.Send(payload, payload.Length, new IPEndPoint(IPAddress.Loopback, relayForward));
                            IPEndPoint sender = null;
                            Require(payload.SequenceEqual(client.Receive(ref sender)), "UDP relay echo differed from its payload.");
                            udpVerified = true;
                        }
                    } catch (Exception ex) { failureReason += (failureReason.Length == 0 ? "" : "; ") + stage + ": " + ex.GetType().Name; }
                    stage = "peer liveness";
                    Require(!relayHost.HasExited && !relayGuest.HasExited, "A public relay peer exited early.");
                } catch (Exception ex) { failureReason += (failureReason.Length == 0 ? "" : "; ") + stage + ": " + ex.GetType().Name; }
                finally {
                    foreach (Process process in new Process[] { relayGuest, relayHost }) if (process != null) {
                        try {
                            if (!process.HasExited) process.Kill();
                            Require(process.WaitForExit(5000), "A public relay peer did not stop.");
                        } catch (Exception ex) { failureReason += (failureReason.Length == 0 ? "" : "; ") + "process cleanup: " + ex.GetType().Name; }
                        finally { process.Dispose(); }
                    }
                }
                bool relayPassed = relayVerified && tcpVerified && udpVerified && failureReason.Length == 0;
                publicRelayResults.Add(new Dictionary<string, object> {
                    { "endpoint", peerAddress }, { "clientDhcpReady", relayDhcpReady }, { "hostDiscovered", hostDiscovered },
                    { "hostCost", hostCost }, { "relayVerified", relayVerified }, { "tcpForwardEcho", tcpVerified },
                    { "udpForwardEcho", udpVerified }, { "passed", relayPassed }, { "failureReason", failureReason }
                });
                Console.WriteLine("PUBLIC RELAY: " + peerAddress + " discovery=" + (relayDhcpReady && hostDiscovered) +
                    " relay=" + relayVerified + " TCP=" + tcpVerified + " UDP=" + udpVerified +
                    (failureReason.Length == 0 ? "" : " reason=" + failureReason));
            }
            bool publicRelayConnectionTested = publicRelayResults.Any(p => (bool)p["clientDhcpReady"] && (bool)p["hostDiscovered"] && (bool)p["relayVerified"]);
            bool publicRelayTcpUdpVerified = publicRelayResults.Any(p => (bool)p["passed"]);
            multiplayerResult = new Dictionary<string, object> {
                { "passed", publicRelayTcpUdpVerified }, { "easyTierVersion", "2.6.4" }, { "moduleSha256", archiveHash },
                { "bundledModuleInstalled", true }, { "initialModuleDownloadRequired", false }, { "invalidArchiveRejected", true },
                { "invitationValidation", true }, { "customPeerValidation", true }, { "localRpcOnly", true },
                { "clientDhcpReady", true }, { "nativeCliSchema", true }, { "tcpForwardEcho", true }, { "udpForwardEcho", true },
                { "transport", "two native processes over loopback TCP using production argument builder" },
                { "wanNatTraversalTested", false }, { "publicRelayResults", publicRelayResults },
                { "publicRelayConnectionTested", publicRelayConnectionTested }, { "publicRelayTcpUdpVerified", publicRelayTcpUdpVerified }
            };
            Require(publicRelayTcpUdpVerified, "No configured public relay passed both TCP and UDP forwarding.");
            Console.WriteLine("PASS: pinned multiplayer module installation, native CLI, local TCP/UDP forwarding, and public relay TCP/UDP forwarding.");
        } finally {
            foreach (Process process in new Process[] { guest, host }) if (process != null) {
                try { if (!process.HasExited) process.Kill(); process.WaitForExit(); } finally { process.Dispose(); }
            }
            echo.Stop();
            udpEcho.Close();
            tcpThread.Join(2000);
            udpThread.Join(2000);
        }
    }

    private static void CheckPortableLaunch() {
        Type page = pcl.GetType("PCL.PageLaunchLeft", true);
        Require((bool)Invoke(page, "CanAutoLaunch", new string[] { "PCL.exe", "--launch=26.3" }, "26.3", ""), "Portable startup request was rejected.");
        foreach (string[] args in new string[][] {
            new string[] { "PCL.exe" }, new string[] { "--launch=" }, new string[] { "--launch=26.2" },
            new string[] { "--launch=26.3", "--launch=26.3" }, new string[] { "--launch=26.3/../other" }
        }) Require(!(bool)Invoke(page, "CanAutoLaunch", args, "26.3", ""), "An ambiguous or mismatched portable startup request was accepted.");
        Require(!(bool)Invoke(page, "CanAutoLaunch", new string[] { "--launch=26.3" }, "26.3", "login required"), "Portable startup ignored missing login information.");
        Require(!(bool)Invoke(page, "CanAutoLaunch", new string[] { "--launch=26.3" }, "26.3", null), "Portable startup accepted an unknown login state.");
        Require(!(bool)Invoke(page, "CanAutoLaunch", new string[] { "--launch=26.3" }, null, ""), "Portable startup accepted a missing instance.");
        Console.WriteLine("PASS: portable startup requires an exact installed-instance request and available login information.");
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

    private static string[] Urls(object value) {
        return ((IEnumerable)value).Cast<string>().ToArray();
    }

    private static void CheckSourcePolicy(string work) {
        Type download = pcl.GetType("PCL.ModDownload", true);
        Type settings = pcl.GetType("PCL.Settings", true);
        object official = download.GetField("DlClientListMojangLoader", StaticMembers).GetValue(null);
        object mirror = download.GetField("DlClientListBmclapiLoader", StaticMembers).GetValue(null);
        MethodInfo planner = download.GetMethod("DlGetSourceLoaders", StaticMembers).MakeGenericMethod(official.GetType().GetGenericArguments());
        try {
            for (int mode = 0; mode <= 2; mode++) {
                Invoke(settings, "Set", "ToolDownloadSource", mode, null);
                Invoke(settings, "Set", "ToolDownloadVersion", mode, null);
                string[] expected = mode == 2 ? new string[] { "official", "mirror" } : new string[] { "mirror", "official" };
                Require(Urls(Invoke(download, "DlSourceOrder", new string[] { "official", "official" }, new string[] { "mirror", "mirror" })).SequenceEqual(expected),
                    "File source priority/deduplication is incorrect for mode " + mode);
                Require(Urls(Invoke(download, "DlVersionListOrder", new string[] { "official", "official" }, new string[] { "mirror", "mirror" })).SequenceEqual(expected),
                    "Version-list source priority/deduplication is incorrect for mode " + mode);
                object[] plan = ((IEnumerable)planner.Invoke(null, new object[] { official, mirror })).Cast<object>().ToArray();
                int firstWait = mode == 2 ? 10 : mode == 0 ? 5 : 1;
                Require(plan.Length == 2 && Object.ReferenceEquals(plan[0].GetType().GetProperty("Key").GetValue(plan[0], null), mode == 2 ? official : mirror) &&
                    Object.ReferenceEquals(plan[1].GetType().GetProperty("Key").GetValue(plan[1], null), mode == 2 ? mirror : official),
                    "Version-list loader order is incorrect for mode " + mode);
                Require(Convert.ToInt32(plan[0].GetType().GetProperty("Value").GetValue(plan[0], null)) == firstWait &&
                    Convert.ToInt32(plan[1].GetType().GetProperty("Value").GetValue(plan[1], null)) == firstWait + 30,
                    "Version-list fallback timing is incorrect for mode " + mode);

                string asset = "https://resources.download.minecraft.net/ab/abcdef";
                string assetMirror = "https://bmclapi2.bangbang93.com/assets/ab/abcdef";
                Require(Urls(Invoke(download, "DlSourceAssetsGet", asset)).SequenceEqual(mode == 2 ? new string[] { asset, assetMirror } : new string[] { assetMirror, asset }),
                    "Asset source priority or official fallback is incorrect for mode " + mode);
                string library = "https://libraries.minecraft.net/org/example/test/1/test-1.jar";
                string mavenMirror = "https://bmclapi2.bangbang93.com/maven/org/example/test/1/test-1.jar";
                string libraryMirror = "https://bmclapi2.bangbang93.com/libraries/org/example/test/1/test-1.jar";
                Require(Urls(Invoke(download, "DlSourceLibraryGet", library)).SequenceEqual(mode == 2 ? new string[] { library, mavenMirror, libraryMirror } : new string[] { mavenMirror, libraryMirror, library }),
                    "Library source priority or official fallback is incorrect for mode " + mode);
                foreach (string host in new string[] { "maven.fabricmc.net", "maven.minecraftforge.net", "maven.neoforged.net" }) {
                    string path = "/org/example/tool/1/tool-1.jar?test=1#fragment";
                    string original = "https://" + host + (host == "maven.neoforged.net" ? "/releases" : "") + path;
                    string mirrored = "https://bmclapi2.bangbang93.com/maven" + path;
                    Require(Urls(Invoke(download, "DlSourceLibraryGet", original)).SequenceEqual(mode == 2 ? new string[] { original, mirrored } : new string[] { mirrored, original }),
                        "Vendor Maven mapping lost its path, priority, or official fallback: " + host);
                }
                foreach (string host in new string[] { "piston-data.mojang.com", "piston-meta.mojang.com", "launcher.mojang.com", "launchermeta.mojang.com" }) {
                    string original = "https://" + host + "/v1/objects/abcdef/client.jar?test=1";
                    string mirrored = "https://bmclapi2.bangbang93.com/v1/objects/abcdef/client.jar?test=1";
                    Require(Urls(Invoke(download, "DlSourceLauncherOrMetaGet", original)).SequenceEqual(mode == 2 ? new string[] { original, mirrored } : new string[] { mirrored, original }),
                        "Launcher/meta source mapping lost URL data, priority, or fallback for " + host);
                }
                string[] unknown = { "https://libraries.minecraft.net.example.invalid/test.jar",
                    "https://resources.download.minecraft.net.example.invalid/ab/abcdef",
                    "https://piston-meta.mojang.com.example.invalid/v1/test.json",
                    "https://example.invalid/path/https://libraries.minecraft.net/test.jar?source=https://piston-data.mojang.com/test",
                    "https://example.invalid/file.jar?source=https://resources.download.minecraft.net/ab/abcdef" };
                foreach (string helper in new string[] { "DlSourceAssetsGet", "DlSourceLibraryGet", "DlSourceLauncherOrMetaGet" })
                    foreach (string original in unknown)
                        Require(Urls(Invoke(download, helper, original)).SequenceEqual(new string[] { original }),
                            "Unrecognized URL was rewritten or duplicated by " + helper + ": " + original);
                string customMaven = "https://maven.example.invalid/org/example/test/1/test-1.jar";
                string[] mixed = { library, mavenMirror, customMaven, libraryMirror, library, mavenMirror };
                string[] ordered = Urls(Invoke(pcl.GetType("PCL.ModMinecraft", true), "McLibSourceOrder", new object[] { mixed }));
                Require(ordered.SequenceEqual(mode == 2 ? new string[] { library, customMaven, mavenMirror, libraryMirror } : new string[] { mavenMirror, libraryMirror, library, customMaven }),
                    "Final library source order lost candidates, priority, or deduplication for mode " + mode);
                Type minecraft = pcl.GetType("PCL.ModMinecraft", true);
                Type tokenType = pcl.GetType("PCL.ModMinecraft+McLibEntry", true);
                object token = Activator.CreateInstance(tokenType);
                string folder = Path.Combine(work, "SourcePolicyGame") + Path.DirectorySeparatorChar;
                tokenType.GetField("LocalPath").SetValue(token, folder + @"libraries\org\example\test\1\test-1.jar");
                tokenType.GetField("OriginalName").SetValue(token, "org.example:test:1");
                tokenType.GetProperty("Url").SetValue(token, library, null);
                IList tokens = (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(tokenType));
                tokens.Add(token);
                object file = ((IEnumerable)Invoke(minecraft, "McLibNetFilesFromTokens", tokens, folder)).Cast<object>().Single();
                string[] fileSources = ((IEnumerable)file.GetType().GetField("Sources").GetValue(file)).Cast<object>()
                    .Select(source => (string)source.GetType().GetField("Url").GetValue(source)).ToArray();
                Require(fileSources.SequenceEqual(mode == 2 ? new string[] { library, mavenMirror, libraryMirror } : new string[] { mavenMirror, libraryMirror, library }),
                    "Production library NetFile still bypasses the selected source priority for mode " + mode);
                string apachePath = "/org/apache/maven/maven-artifact/3.9.0/maven-artifact-3.9.0.jar";
                string apacheOfficial = "https://libraries.minecraft.net" + apachePath;
                string apacheMaven = "https://bmclapi2.bangbang93.com/maven" + apachePath;
                string apacheLibrary = "https://bmclapi2.bangbang93.com/libraries" + apachePath;
                tokenType.GetField("LocalPath").SetValue(token, folder + "libraries" + apachePath.Replace('/', Path.DirectorySeparatorChar));
                tokenType.GetField("OriginalName").SetValue(token, "org.apache.maven:maven-artifact:3.9.0");
                tokenType.GetProperty("Url").SetValue(token, apacheOfficial, null);
                file = ((IEnumerable)Invoke(minecraft, "McLibNetFilesFromTokens", tokens, folder)).Cast<object>().Single();
                fileSources = ((IEnumerable)file.GetType().GetField("Sources").GetValue(file)).Cast<object>()
                    .Select(source => (string)source.GetType().GetField("Url").GetValue(source)).ToArray();
                Require(fileSources.SequenceEqual(mode == 2 ? new string[] { apacheOfficial, apacheMaven, apacheLibrary } : new string[] { apacheMaven, apacheLibrary, apacheOfficial }),
                    "A normal library path containing org/apache/maven was truncated or misrouted for mode " + mode);
            }
            sourcePolicyResult = new Dictionary<string, object> {
                { "passed", true }, { "modesVerified", new int[] { 0, 1, 2 } }, { "mirrorPreferredInAutomaticMode", true },
                { "manualOfficialPriorityPreserved", true }, { "sourceDeduplication", true }, { "versionLoaderPlan", true },
                { "assetLibraryMetaMappings", true }, { "unknownUrlsPreserved", true }, { "finalLibraryOrder", true },
                { "productionLibraryNetFileOrder", true }, { "vendorMavenMappings", true },
                { "apacheMavenLibraryPathPreserved", true }, { "officialFallbackPreserved", true }
            };
        } finally {
            Invoke(settings, "Set", "ToolDownloadSource", 1, null);
            Invoke(settings, "Set", "ToolDownloadVersion", 1, null);
        }
    }

    private static object NewChecker(long size, string hash, bool isJson) {
        Type type = libraries["MeloongCore"].GetType("MeloongCore.FileChecker", true);
        object checker = Activator.CreateInstance(type);
        type.GetField("ActualSize").SetValue(checker, size);
        type.GetField("Hash").SetValue(checker, hash);
        type.GetField("IsJson").SetValue(checker, isJson);
        return checker;
    }

    private static string Sha1(byte[] bytes) {
        using (SHA1 sha = SHA1.Create())
            return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
    }

    private static Dictionary<string, object> CheckLocalFallback(string work) {
        TcpListener server = new TcpListener(IPAddress.Loopback, 0);
        server.Start();
        string root = "http://127.0.0.1:" + ((IPEndPoint)server.LocalEndpoint).Port;
        byte[] good = Encoding.ASCII.GetBytes(new String('G', 4096));
        byte[] bad = Encoding.ASCII.GetBytes(new String('B', good.Length));
        Dictionary<string, int> requests = new Dictionary<string, int>();
        bool running = true;
        Thread responder = new Thread(delegate() {
            while (Volatile.Read(ref running)) {
                try {
                    using (TcpClient client = server.AcceptTcpClient())
                    using (NetworkStream stream = client.GetStream())
                    using (StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 8192, true)) {
                        client.ReceiveTimeout = 10000;
                        string request = reader.ReadLine();
                        if (String.IsNullOrEmpty(request)) continue;
                        string path = request.Split(' ')[1];
                        string line;
                        while (!String.IsNullOrEmpty(line = reader.ReadLine())) { }
                        lock (requests) { requests[path] = requests.ContainsKey(path) ? requests[path] + 1 : 1; }
                        byte[] body = path == "/missing" ? new byte[0] : path == "/corrupt" ? bad : good;
                        string status = path == "/missing" ? "404 Not Found" : "200 OK";
                        byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n");
                        stream.Write(header, 0, header.Length);
                        stream.Write(body, 0, body.Length);
                    }
                } catch (SocketException) { if (Volatile.Read(ref running)) throw; }
                  catch (ObjectDisposedException) { if (Volatile.Read(ref running)) throw; }
                  catch (IOException) { }
            }
        });
        responder.IsBackground = true;
        responder.Start();
        try {
            Type network = pcl.GetType("PCL.ModNet", true);
            string hash = Sha1(good);
            foreach (string first in new string[] { "missing", "corrupt" }) {
                string second = "/valid-" + first;
                string path = Path.Combine(work, "fallback-" + first + ".bin");
                Invoke(network, "NetDownloadByLoader", new string[] { root + "/" + first, root + second }, path, null, NewChecker(good.Length, hash, false), false);
                Require(File.ReadAllBytes(path).SequenceEqual(good), "Fallback produced incorrect bytes after " + first);
                lock (requests) {
                    Require(requests.ContainsKey("/" + first) && requests.ContainsKey(second),
                        "Fallback did not attempt both sources after " + first);
                }
            }
            Console.WriteLine("PASS: PCL switched sources after local HTTP 404 and SHA-1 mismatch.");
            return new Dictionary<string, object> { { "http404Fallback", true }, { "sha1MismatchFallback", true }, { "loopbackOnly", true } };
        } finally {
            Volatile.Write(ref running, false);
            server.Stop();
            responder.Join(2000);
        }
    }

    private sealed class DownloadFixture : IDisposable {
        private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        private readonly Thread acceptor;
        private bool running = true;
        internal readonly byte[] Body = new byte[2 * 1024 * 1024];
        internal readonly Dictionary<string, List<long>> Requests = new Dictionary<string, List<long>>();
        internal readonly string Root;
        internal DownloadFixture() {
            new Random(716).NextBytes(Body);
            listener.Start();
            Root = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port;
            acceptor = new Thread(delegate() {
                while (Volatile.Read(ref running)) {
                    try {
                        TcpClient client = listener.AcceptTcpClient();
                        ThreadPool.QueueUserWorkItem(delegate { Respond(client); });
                    } catch (SocketException) { if (Volatile.Read(ref running)) throw; }
                      catch (ObjectDisposedException) { if (Volatile.Read(ref running)) throw; }
                }
            });
            acceptor.IsBackground = true;
            acceptor.Start();
        }
        private void Respond(TcpClient client) {
            try {
                using (client)
                using (NetworkStream stream = client.GetStream())
                using (StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 8192, true)) {
                    client.ReceiveTimeout = 15000;
                    client.SendTimeout = 15000;
                    string request = reader.ReadLine();
                    if (String.IsNullOrEmpty(request)) return;
                    string path = request.Split(' ')[1];
                    long start = 0;
                    bool ranged = false;
                    string line;
                    while (!String.IsNullOrEmpty(line = reader.ReadLine())) {
                        if (!line.StartsWith("Range: bytes=", StringComparison.OrdinalIgnoreCase)) continue;
                        start = Int64.Parse(line.Substring("Range: bytes=".Length).Split('-')[0]);
                        ranged = true;
                    }
                    lock (Requests) {
                        if (!Requests.ContainsKey(path)) Requests[path] = new List<long>();
                        Requests[path].Add(ranged ? start : -1);
                    }
                    if (path.StartsWith("/headers-", StringComparison.Ordinal)) Thread.Sleep(6500);
                    string header = "HTTP/1.1 " + (ranged ? "206 Partial Content" : "200 OK") +
                        "\r\nContent-Length: " + (Body.Length - start) + "\r\nAccept-Ranges: bytes\r\nConnection: close\r\n";
                    if (ranged) header += "Content-Range: bytes " + start + "-" + (Body.Length - 1) + "/" + Body.Length + "\r\n";
                    byte[] headers = Encoding.ASCII.GetBytes(header + "\r\n");
                    stream.Write(headers, 0, headers.Length);
                    int position = (int)start;
                    if (path.StartsWith("/body-", StringComparison.Ordinal)) {
                        stream.Write(Body, position, 65536);
                        position += 65536;
                        Thread.Sleep(6500);
                    }
                    if (path.StartsWith("/trickle-", StringComparison.Ordinal)) {
                        int chunks = path.Contains("competing") ? 75 : 65;
                        for (int i = 0; i < chunks && Volatile.Read(ref running); i++) {
                            stream.Write(Body, position, 1024);
                            position += 1024;
                            Thread.Sleep(100);
                        }
                    }
                    if (Volatile.Read(ref running)) stream.Write(Body, position, Body.Length - position);
                }
            } catch (IOException) { }
              catch (SocketException) { }
              catch (ObjectDisposedException) { }
        }
        internal long[] Starts(string path) {
            lock (Requests) return Requests.ContainsKey(path) ? Requests[path].ToArray() : new long[0];
        }
        public void Dispose() {
            Volatile.Write(ref running, false);
            listener.Stop();
            acceptor.Join(2000);
        }
    }

    private static void CheckOfficialRedirectPredicate() {
        Type network = pcl.GetType("PCL.ModNet", true);
        string source = "https://bmclapi2.bangbang93.com/test.jar";
        Func<string, string, bool, bool, long, bool> accepts = delegate(string original, string target, bool ranges, bool partial, long size) {
            using (HttpResponseMessage response = new HttpResponseMessage(partial ? HttpStatusCode.PartialContent : HttpStatusCode.OK)) {
                response.RequestMessage = new HttpRequestMessage(HttpMethod.Get, target);
                response.Content = new ByteArrayContent(new byte[0]);
                response.Content.Headers.ContentLength = partial ? 900 : 1000;
                if (ranges) response.Headers.AcceptRanges.Add("bytes");
                if (partial) response.Content.Headers.ContentRange = new System.Net.Http.Headers.ContentRangeHeaderValue(100, 999, 1000);
                return (bool)Invoke(network, "NetCanSplitOfficialRedirect", original, response, size, partial ? 100L : 0L);
            }
        };
        foreach (string host in new string[] { "piston-data.mojang.com", "launcher.mojang.com", "libraries.minecraft.net", "resources.download.minecraft.net" }) {
            Require(accepts(source, "https://" + host + "/test.jar", true, false, 1000), "Trusted CDN byte-range response was rejected: " + host);
            Require(accepts(source, "https://" + host + "/test.jar", false, true, 1000), "Trusted CDN valid 206 was rejected: " + host);
        }
        foreach (string target in new string[] {
            "https://piston-data.mojang.com.example.invalid/test.jar", "https://example.invalid/test.jar?host=piston-data.mojang.com",
            "https://user@piston-data.mojang.com/test.jar", "http://piston-data.mojang.com/test.jar",
            "https://piston-data.mojang.com:444/test.jar", "https://bmclapi2.bangbang93.com/test.jar", "https://bmclapi.hurtmc.com/test.jar" })
            Require(!accepts(source, target, true, false, 1000), "Untrusted redirect enabled segmentation: " + target);
        foreach (string original in new string[] { "https://bmclapi2.bangbang93.com.example.invalid/test.jar", "http://bmclapi2.bangbang93.com/test.jar",
            "https://user@bmclapi2.bangbang93.com/test.jar", "https://bmclapi2.bangbang93.com:444/test.jar" })
            Require(!accepts(original, "https://piston-data.mojang.com/test.jar", true, false, 1000), "Untrusted original URL enabled segmentation.");
        Require(!accepts(source, "https://piston-data.mojang.com/test.jar", false, false, 1000), "Missing range evidence enabled segmentation.");
        Require(!accepts(source, "https://piston-data.mojang.com/test.jar", true, false, -1), "Unknown file size enabled segmentation.");
        Require(!accepts(source, "https://piston-data.mojang.com/test.jar", false, true, 1001), "Mismatched Content-Range total enabled segmentation.");
        Require(accepts("https://BMCLAPI2.BANGBANG93.COM/test.jar", "https://PISTON-DATA.MOJANG.COM/test.jar", true, false, 1000), "Case-insensitive exact hosts were rejected.");
        using (HttpResponseMessage malformed = new HttpResponseMessage(HttpStatusCode.PartialContent)) {
            malformed.RequestMessage = new HttpRequestMessage(HttpMethod.Get, "https://piston-data.mojang.com/test.jar");
            malformed.Content = new ByteArrayContent(new byte[0]);
            malformed.Headers.AcceptRanges.Add("bytes");
            Require(!(bool)Invoke(network, "NetCanSplitOfficialRedirect", source, malformed, 1000L, 100L), "Malformed 206 bypassed Content-Range validation.");
            malformed.Content.Headers.ContentLength = 900;
            malformed.Content.Headers.ContentRange = new System.Net.Http.Headers.ContentRangeHeaderValue(99, 998, 1000);
            Require(!(bool)Invoke(network, "NetCanSplitOfficialRedirect", source, malformed, 1000L, 100L), "Wrong Range start enabled segmentation.");
            malformed.Content.Headers.ContentRange = new System.Net.Http.Headers.ContentRangeHeaderValue(100, 999, 1000);
            malformed.Content.Headers.ContentLength = 899;
            Require(!(bool)Invoke(network, "NetCanSplitOfficialRedirect", source, malformed, 1000L, 100L), "Wrong Range body length enabled segmentation.");
        }
    }

    private static Dictionary<string, object> CheckDownloadPerformance(string work) {
        CheckOfficialRedirectPredicate();
        Type network = pcl.GetType("PCL.ModNet", true);
        Type settings = pcl.GetType("PCL.Settings", true);
        object savedThreads = Invoke(settings, "Get", "ToolDownloadThread", null);
        object savedSpeed = Invoke(settings, "Get", "ToolDownloadSpeed", null);
        string folder = Path.Combine(work, "DownloadPerformance");
        Directory.CreateDirectory(folder);
        List<object> results = new List<object>();
        using (DownloadFixture fixture = new DownloadFixture()) {
            string hash = Sha1(fixture.Body);
            Action<string, string[], bool, bool> run = delegate(string name, string[] sources, bool fallback, bool resumed) {
                string destination = Path.Combine(folder, name + ".bin");
                Stopwatch timer = Stopwatch.StartNew();
                Exception transferFailure = null;
                Thread transfer = new Thread(delegate() {
                    try { Invoke(network, "NetDownloadByLoader", sources.Select(path => fixture.Root + path).ToArray(), destination, null, NewChecker(fixture.Body.Length, hash, false), false); }
                    catch (Exception ex) { transferFailure = ex; }
                });
                transfer.IsBackground = true;
                transfer.Start();
                Require(transfer.Join(20000), "Performance fixture exceeded 20 seconds: " + name);
                if (transferFailure != null) throw transferFailure;
                timer.Stop();
                Require(File.ReadAllBytes(destination).SequenceEqual(fixture.Body), "Performance fixture bytes/hash differ: " + name);
                long[] secondary = sources.Length > 1 ? fixture.Starts(sources[1]) : new long[0];
                Require((secondary.Length > 0) == fallback, "Unexpected source switching: " + name);
                if (resumed) Require(secondary.Any(start => start > 0), "Fallback discarded partial data instead of resuming Range: " + name);
                if (fallback) Require(timer.Elapsed.TotalSeconds < 14, "Fallback exceeded its bounded latency: " + name);
                results.Add(new Dictionary<string, object> { { "case", name }, { "elapsedMs", timer.ElapsedMilliseconds }, { "fallback", secondary.Length > 0 }, { "rangeResumed", secondary.Any(start => start > 0) }, { "secondaryRangeStarts", secondary }, { "sha1Verified", true } });
            };
            try {
                Invoke(settings, "Set", "ToolDownloadThread", 0, null);
                Invoke(settings, "Set", "ToolDownloadSpeed", 42, null);
                Invoke(network, "UpdateNetTaskSpeedLimitHigh", 42);
                run("headers-stall", new string[] { "/headers-stall", "/fast-headers" }, true, false);
                run("body-stall", new string[] { "/body-stall", "/fast-body" }, true, true);
                run("trickle-fallback", new string[] { "/trickle-slow", "/fast-trickle" }, true, true);
                run("sole-trickle", new string[] { "/trickle-sole" }, false, false);
                run("last-viable-trickle", new string[] { "/trickle-all-first", "/trickle-all-last" }, true, true);
                Invoke(settings, "Set", "ToolDownloadSpeed", 40, null);
                Invoke(network, "UpdateNetTaskSpeedLimitHigh", 40);
                run("capped-trickle", new string[] { "/trickle-capped", "/fast-capped" }, false, false);
                Invoke(settings, "Set", "ToolDownloadSpeed", 42, null);
                Invoke(network, "UpdateNetTaskSpeedLimitHigh", 42);
                Invoke(settings, "Set", "ToolDownloadThread", 1, null);
                Exception competitorFailure = null;
                Thread competitor = new Thread(delegate() {
                    try {
                        string destination = Path.Combine(folder, "competitor.bin");
                        Invoke(network, "NetDownloadByLoader", new string[] { fixture.Root + "/trickle-competing" }, destination, null, NewChecker(fixture.Body.Length, hash, false), false);
                        Require(File.ReadAllBytes(destination).SequenceEqual(fixture.Body), "Competing transfer hash differs.");
                    } catch (Exception ex) { competitorFailure = ex; }
                });
                competitor.IsBackground = true;
                competitor.Start();
                Stopwatch wait = Stopwatch.StartNew();
                while (fixture.Starts("/trickle-competing").Length == 0 && wait.ElapsedMilliseconds < 3000) Thread.Sleep(10);
                Require(fixture.Starts("/trickle-competing").Length > 0, "Competing transfer did not start.");
                try { run("shared-trickle", new string[] { "/trickle-shared", "/fast-shared" }, false, false); }
                finally { Require(competitor.Join(15000), "Competing transfer did not finish."); }
                if (competitorFailure != null) throw competitorFailure;
            } finally {
                Invoke(settings, "Set", "ToolDownloadThread", savedThreads, null);
                Invoke(settings, "Set", "ToolDownloadSpeed", savedSpeed, null);
                Invoke(network, "UpdateNetTaskSpeedLimitHigh", Convert.ToInt32(savedSpeed));
            }
        }
        Console.WriteLine("PASS: stalled/trickle source fallback, Range resume, capped/shared/sole transfers, and official redirect trust boundaries.");
        return new Dictionary<string, object> { { "passed", true }, { "loopbackOnly", true }, { "officialRedirectPredicate", true }, { "cases", results } };
    }

    private static void DownloadTest(string work) {
        Invoke(pcl.GetType("PCL.Settings", true), "Set", "SystemDebugSkipCopy", true, null);
        Dictionary<string, object> fallbackResult = CheckLocalFallback(work);
        downloadPerformanceResult = CheckDownloadPerformance(work);
        Dictionary<string, object> loginResult = CheckMicrosoftDeviceCode();
        Type download = pcl.GetType("PCL.ModDownload", true);
        Type network = pcl.GetType("PCL.ModNet", true);
        string jsonUrl = (string)Invoke(download, "DlClientListGet", "1.0");
        Require(!String.IsNullOrEmpty(jsonUrl), "PCL could not resolve Minecraft 1.0 from its version list.");
        string jsonPath = Path.Combine(work, "1.0.json");
        string[] jsonSources = Urls(Invoke(download, "DlSourceLauncherOrMetaGet", jsonUrl));
        Invoke(network, "NetDownloadByLoader", jsonSources, jsonPath, null, NewChecker(-1, null, true), false);

        JavaScriptSerializer serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = Int32.MaxValue;
        Dictionary<string, object> manifest = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(jsonPath));
        Require((string)manifest["id"] == "1.0", "Downloaded the wrong version manifest.");
        Dictionary<string, object> client = (Dictionary<string, object>)((Dictionary<string, object>)manifest["downloads"])["client"];
        string jarUrl = (string)client["url"];
        string expectedHash = (string)client["sha1"];
        long expectedSize = Convert.ToInt64(client["size"]);
        string jarPath = Path.Combine(work, "1.0.jar");
        string[] jarSources = Urls(Invoke(download, "DlSourceLauncherOrMetaGet", jarUrl));
        Invoke(network, "NetDownloadByLoader", jarSources, jarPath, null, NewChecker(expectedSize, expectedHash, false), false);
        string actualHash;
        using (SHA1 sha = SHA1.Create())
        using (FileStream stream = File.OpenRead(jarPath))
            actualHash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        Require(new FileInfo(jarPath).Length == expectedSize, "Minecraft client size does not match its manifest.");
        Require(actualHash == expectedHash, "Minecraft client SHA-1 does not match its manifest.");
        Dictionary<string, object> report = new Dictionary<string, object> {
            { "passed", false }, { "downloadPassed", true }, { "version", "1.0" }, { "manifestUrl", jsonUrl },
            { "clientUrl", jarUrl }, { "clientBytes", expectedSize }, { "clientSha1", actualHash },
            { "downloadEngine", "PCL.ModNet.NetDownloadByLoader with production sources and FileChecker" },
            { "manifestSources", jsonSources }, { "clientSources", jarSources },
            { "sourcePolicy", sourcePolicyResult }, { "localFallback", fallbackResult },
            { "downloadPerformance", downloadPerformanceResult },
            { "portableLaunchRules", true },
            { "settingsStorage", "isolated default settings in local Setup.ini" },
            { "downloadRestriction", false }, { "updateMethods", "verified no-op IL" },
            { "fixedSettings", "Set and Reset preserve updates=3, announcements=2, telemetry=false" },
            { "themes", themeResult }, { "toolbox", toolboxResult }, { "microsoftLogin", loginResult },
            { "curseForge", curseForgeResult }, { "multiplayer", multiplayerResult }
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
            Environment.SetEnvironmentVariable("PCL_CURSEFORGE_API_KEY", null);
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
            CheckPortableLaunch();
            Console.WriteLine("VERIFY: download source ordering and fallback plan");
            CheckSourcePolicy(work);
            Exception failure = null;
            bool finished = false;
            Thread worker = new Thread(delegate() {
                try { CheckCurseForge(); CheckMultiplayer(work); DownloadTest(work); }
                catch (Exception ex) { failure = ex; }
                finally { Volatile.Write(ref finished, true); }
            });
            worker.IsBackground = true;
            worker.Start();
            DateTime deadline = DateTime.UtcNow.AddMinutes(8);
            while (!Volatile.Read(ref finished) && DateTime.UtcNow < deadline) {
                DispatcherFrame frame = new DispatcherFrame();
                Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(delegate { frame.Continue = false; }));
                Dispatcher.PushFrame(frame);
                Thread.Sleep(10);
            }
            Require(finished, "Minecraft download smoke test timed out after eight minutes.");
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
& $compiler /nologo /target:exe "/out:$runner" "/reference:$reference\PresentationFramework.dll" "/reference:$reference\PresentationCore.dll" "/reference:$reference\WindowsBase.dll" "/reference:$reference\System.Xaml.dll" "/reference:$reference\System.Net.Http.dll" $sourcePath
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
    # The --update launch can initialize and persist its local identity before exiting.
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
