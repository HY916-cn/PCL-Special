using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("PCL 单文件启动入口")]
[assembly: AssemblyProduct("PCL特别版")]
[assembly: AssemblyCompany("Haoyu Huang")]
[assembly: AssemblyVersion("2.99.99.0")]
[assembly: AssemblyFileVersion("2.99.99.0")]
[assembly: TargetFramework(".NETFramework,Version=v4.8")]

public static class PclSingleFileLauncher {
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("PCL-SINGLE-V1\0\0\0");
    private static readonly string[] Mutable = { "PCL/Setup.ini", ".minecraft/PCL.ini", ".minecraft/versions/26.3/PCL/Setup.ini" };
    public sealed class Metadata {
        public string edition { get; set; }
        public string folder { get; set; }
        public string launcher { get; set; }
        public string archiveSha256 { get; set; }
        public string launcherSha256 { get; set; }
        public string[] files { get; set; }
        public long uncompressedBytes { get; set; }
    }

    // Seekable view keeps ZipArchive and SHA-256 inside the appended payload.
    private sealed class PayloadStream : Stream {
        private readonly Stream file;
        private readonly long start, length;
        private long position;
        public PayloadStream(Stream file, long start, long length) { this.file = file; this.start = start; this.length = length; }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return true; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { return length; } }
        public override long Position { get { return position; } set { Seek(value, SeekOrigin.Begin); } }
        public override int Read(byte[] buffer, int offset, int count) {
            file.Position = start + position;
            int read = file.Read(buffer, offset, (int)Math.Min(count, length - position));
            position += read;
            return read;
        }
        public override long Seek(long offset, SeekOrigin origin) {
            long target = checked((origin == SeekOrigin.Begin ? 0 : origin == SeekOrigin.Current ? position : origin == SeekOrigin.End ? length : throwOrigin()) + offset);
            if (target < 0 || target > length) throw new IOException("数据包定位超出范围。");
            return position = target;
        }
        private static long throwOrigin() { throw new ArgumentException("Invalid seek origin."); }
        public override void Flush() { }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    }

    private static string Hash(Stream stream) {
        using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }
    private static string HashFile(string path) { using (FileStream file = File.OpenRead(path)) return Hash(file); }
    private static string Relative(string name) {
        string normalized = name.Replace('\\', '/');
        if (String.IsNullOrWhiteSpace(normalized) || normalized.StartsWith("/") || normalized.EndsWith("/")) throw new InvalidDataException("文件路径无效。");
        foreach (string part in normalized.Split('/')) {
            string stem = part.Split('.')[0].ToUpperInvariant();
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".") || part.EndsWith(" ") || part.Any(c => c < 32 || Path.GetInvalidFileNameChars().Contains(c)) ||
                new string[] { "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }.Contains(stem))
                throw new InvalidDataException("数据包包含无效文件路径。");
        }
        return normalized;
    }
    private static string Destination(string root, string relative) {
        string path = Path.GetFullPath(Path.Combine(root, Relative(relative).Replace('/', Path.DirectorySeparatorChar)));
        if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("文件路径超出目标目录。");
        return path;
    }
    private static void GuardPath(string root, string destination) {
        string current = destination;
        while (current.Length >= root.Length) {
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("目标目录中存在链接，请将本程序放入独立文件夹后重试。");
            if (String.Equals(current, root, StringComparison.OrdinalIgnoreCase)) break;
            current = Path.GetDirectoryName(current);
        }
    }
    private static void ReplaceFile(string temporary, string destination) {
        if (File.Exists(destination)) File.Replace(temporary, destination, null);
        else File.Move(temporary, destination);
    }
    private static Metadata ReadMetadata(FileStream file, out long start, out long length) {
        if (file.Length < 32) throw new InvalidDataException("单文件数据包不完整，请重新获取。");
        file.Position = file.Length - 32;
        BinaryReader reader = new BinaryReader(file, Encoding.UTF8, true);
        ulong payloadLength = reader.ReadUInt64(), metadataLength = reader.ReadUInt64();
        if (!reader.ReadBytes(16).SequenceEqual(Magic) || payloadLength == 0 || metadataLength == 0 || metadataLength > 2 * 1024 * 1024 ||
            metadataLength > (ulong)(file.Length - 32) || payloadLength > (ulong)(file.Length - 32) - metadataLength)
            throw new InvalidDataException("单文件数据包校验信息无效，请重新获取。");
        length = (long)payloadLength;
        start = file.Length - 32 - (long)metadataLength - length;
        if (start < 512) throw new InvalidDataException("单文件程序头无效。");
        file.Position = start + length;
        byte[] bytes = reader.ReadBytes((int)metadataLength);
        Metadata metadata = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 }.Deserialize<Metadata>(Encoding.UTF8.GetString(bytes));
        if (metadata == null || String.IsNullOrWhiteSpace(metadata.edition) || metadata.edition.Length > 80 ||
            metadata.folder == null || Relative(metadata.folder).Contains("/") || metadata.launcher == null ||
            !Relative(metadata.launcher).EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || metadata.files == null || metadata.files.Length == 0 ||
            metadata.files.Length > 100000 || metadata.uncompressedBytes < 0 || !IsHash(metadata.archiveSha256) || !IsHash(metadata.launcherSha256))
            throw new InvalidDataException("单文件配置信息无效。");
        if (!metadata.files.Select(Relative).Contains(metadata.launcher, StringComparer.OrdinalIgnoreCase) ||
            metadata.files.Distinct(StringComparer.OrdinalIgnoreCase).Count() != metadata.files.Length)
            throw new InvalidDataException("单文件文件清单无效。");
        return metadata;
    }
    private static bool IsHash(string value) { return value != null && value.Length == 64 && value.All(c => c >= '0' && c <= '9' || c >= 'a' && c <= 'f'); }

    private static string Prepare(FileStream file, Metadata metadata, long start, long length, Action<int, string> progress) {
        string root = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), metadata.folder);
        GuardPath(root, root);
        string launcher = Destination(root, metadata.launcher), marker = Path.Combine(root, ".pcl-package.sha256");
        GuardPath(root, marker);
        GuardPath(root, launcher);
        if (File.Exists(marker) && File.ReadAllText(marker).Trim() == metadata.archiveSha256 && File.Exists(launcher) && HashFile(launcher) == metadata.launcherSha256 &&
            metadata.files.All(p => File.Exists(Destination(root, p)))) return launcher;
        progress(0, "正在校验随附文件……");
        using (PayloadStream payload = new PayloadStream(file, start, length)) {
            if (Hash(payload) != metadata.archiveSha256) throw new InvalidDataException("随附数据校验失败，请重新获取完整 EXE。");
            Directory.CreateDirectory(root);
            GuardPath(root, root);
            payload.Position = 0;
            using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read, true, Encoding.UTF8)) {
                ZipArchiveEntry[] entries = archive.Entries.Where(e => !e.FullName.EndsWith("/") && !e.FullName.EndsWith("\\")).ToArray();
                if (entries.Length != metadata.files.Length || !entries.Select(e => Relative(e.FullName)).OrderBy(p => p, StringComparer.Ordinal).SequenceEqual(metadata.files.OrderBy(p => p, StringComparer.Ordinal)) ||
                    entries.Sum(e => e.Length) != metadata.uncompressedBytes)
                    throw new InvalidDataException("随附文件清单与数据包不一致。");
                long done = 0;
                // ponytail: repair re-extracts distribution files; use per-file repair if this becomes a measured bottleneck.
                foreach (ZipArchiveEntry entry in entries) {
                    string relative = Relative(entry.FullName), target = Destination(root, relative);
                    GuardPath(root, target);
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    if (!Mutable.Contains(relative, StringComparer.OrdinalIgnoreCase) || !File.Exists(target)) {
                        string temporary = target + "." + Guid.NewGuid().ToString("N") + ".part";
                        try {
                            using (Stream input = entry.Open())
                            using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) input.CopyTo(output, 131072);
                            if (new FileInfo(temporary).Length != entry.Length) throw new InvalidDataException("释放的文件不完整：" + relative);
                            ReplaceFile(temporary, target);
                        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
                    }
                    done += entry.Length;
                    progress((int)Math.Min(99, done * 100 / Math.Max(1, metadata.uncompressedBytes)), "正在准备本地文件……");
                }
            }
        }
        if (HashFile(launcher) != metadata.launcherSha256) throw new InvalidDataException("启动器校验失败。");
        string markerPart = marker + "." + Guid.NewGuid().ToString("N") + ".part";
        try { File.WriteAllText(markerPart, metadata.archiveSha256, Encoding.ASCII); ReplaceFile(markerPart, marker); }
        finally { if (File.Exists(markerPart)) File.Delete(markerPart); }
        progress(100, "准备完成，正在打开启动器……");
        return launcher;
    }

    [STAThread]
    public static int Main(string[] args) {
        bool extractOnly = args.Length == 1 && args[0] == "--extract-only";
        AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling", false);
        AppContext.SetSwitch("Switch.System.IO.BlockLongPaths", false);
        try {
            using (FileStream file = new FileStream(Assembly.GetExecutingAssembly().Location, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                long start, length;
                Metadata metadata = ReadMetadata(file, out start, out length);
                string root = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), metadata.folder);
                string mutexId;
                using (MemoryStream name = new MemoryStream(Encoding.UTF8.GetBytes(root.ToUpperInvariant()))) mutexId = Hash(name).Substring(0, 24);
                using (Mutex mutex = new Mutex(false, "Local\\PCLPackage-" + mutexId)) {
                    bool acquired;
                    try { acquired = mutex.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
                    if (!acquired) throw new IOException("该版本正在准备或启动，请稍候再试。");
                    try {
                        if (extractOnly) { Prepare(file, metadata, start, length, delegate { }); return 0; }
                        Application.EnableVisualStyles();
                        Application.SetCompatibleTextRenderingDefault(false);
                        using (Form form = new Form { Text = metadata.edition, ClientSize = new Size(440, 116), FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false, StartPosition = FormStartPosition.CenterScreen }) {
                            form.Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
                            Label label = new Label { Text = "正在检查本地文件……", AutoSize = false, Bounds = new Rectangle(20, 20, 400, 28) };
                            ProgressBar bar = new ProgressBar { Bounds = new Rectangle(20, 62, 400, 20) };
                            form.Controls.Add(label); form.Controls.Add(bar);
                            bool complete = false;
                            Exception failure = null;
                            form.FormClosing += delegate(object sender, FormClosingEventArgs e) { e.Cancel = !complete; };
                            form.Shown += async delegate {
                                try {
                                    string launcher = await Task.Run(() => Prepare(file, metadata, start, length, delegate(int percent, string message) {
                                        form.BeginInvoke(new Action(delegate { label.Text = message; bar.Value = percent; }));
                                    }));
                                    Process.Start(new ProcessStartInfo { FileName = launcher, WorkingDirectory = root, UseShellExecute = true });
                                } catch (Exception ex) { failure = ex; }
                                finally { complete = true; form.Close(); }
                            };
                            Application.Run(form);
                            if (failure != null) throw failure;
                        }
                        return 0;
                    } finally { mutex.ReleaseMutex(); }
                }
            }
        } catch (Exception ex) {
            if (extractOnly) Console.Error.WriteLine(ex.ToString());
            else MessageBox.Show("无法准备或打开启动器。请确认当前文件夹可写、磁盘空间充足，并关闭该目录内正在运行的启动器后重试。\r\n\r\n" + ex.Message, "PCL 单文件启动入口", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
