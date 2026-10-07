// ============================================================================
//  ChaoxingRunner - 超星学习通自动连播工具 · 图形界面
//
//  设计说明
//  ---------------------------------------------------------------------------
//  · 目标框架 .NET Framework 4.0：所有 Windows 10/11 自带，无需安装运行时
//  · 用 Windows 自带的 csc.exe 编译，不依赖 .NET SDK
//  · PowerShell 脚本以 base64 内嵌（见 build.py），运行时释放到临时目录执行
//    —— 用 base64 而不是字符串字面量，避免源码编码与转义问题
//  · 通过 PowerShell 引擎（System.Management.Automation）在独立 runspace 中
//    执行 Run.ps1，复用已完成的全部逻辑，不重写核心代码
//
//  为什么把脚本释放到临时目录而不是直接执行字符串：
//    Run.ps1 用 $PSScriptRoot 定位 lib\ 与 config.psd1，
//    必须有真实的目录结构。
// ============================================================================

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ChaoxingRunner
{
    // ------------------------------------------------------------------
    //  主窗口
    // ------------------------------------------------------------------
    class MainForm : Form
    {
        // 内嵌资源表：每项为 "相对路径|base64内容"，由 build.py 生成
        /*__EMBEDDED__*/

        const string APP_TITLE = "超星学习通 · 自动连播工具";
        const string APP_AUTHOR = "liusida <1102271746@qq.com>";

        // 控件
        Button btnLaunch;
        Button btnStart;
        Button btnStop;
        Button btnCache;
        Button btnDiagnose;
        Label lblStatus;
        Label lblLesson;
        ProgressBar bar;
        RichTextBox txtLog;
        StatusStrip statusStrip;
        ToolStripStatusLabel statusLabel;

        // 运行状态
        string workDir;
        PowerShell ps;
        IAsyncResult psAsync;
        volatile bool running;

        public MainForm()
        {
            BuildUi();
            ExtractScripts();
        }

        // --------------------------------------------------------------
        //  界面
        // --------------------------------------------------------------
        void BuildUi()
        {
            Text = APP_TITLE;
            ClientSize = new Size(880, 600);
            MinimumSize = new Size(700, 480);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Color.FromArgb(250, 250, 250);

            // ---- 顶部标题 ----
            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 62;
            header.BackColor = Color.FromArgb(38, 38, 44);
            Controls.Add(header);

            Label title = new Label();
            title.Text = APP_TITLE;
            title.ForeColor = Color.White;
            title.Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new Point(18, 10);
            header.Controls.Add(title);

            Label author = new Label();
            author.Text = "by " + APP_AUTHOR + "    github.com/2008liusida/chaoxing-course-runner";
            author.ForeColor = Color.FromArgb(160, 160, 170);
            author.AutoSize = true;
            author.Location = new Point(20, 37);
            header.Controls.Add(author);

            // ---- 按钮区 ----
            Panel toolbar = new Panel();
            toolbar.Dock = DockStyle.Top;
            toolbar.Height = 54;
            toolbar.BackColor = Color.FromArgb(245, 245, 247);
            toolbar.Padding = new Padding(12, 10, 12, 10);
            Controls.Add(toolbar);
            toolbar.BringToFront();

            btnLaunch = MakeButton("① 启动浏览器", 0);
            btnLaunch.Click += delegate { LaunchBrowser(); };
            toolbar.Controls.Add(btnLaunch);

            btnStart = MakeButton("② 开始刷课", 1);
            btnStart.Click += delegate { StartPlay(); };
            toolbar.Controls.Add(btnStart);

            btnStop = MakeButton("停止", 2);
            btnStop.Enabled = false;
            btnStop.Click += delegate { StopPlay(); };
            toolbar.Controls.Add(btnStop);

            btnCache = MakeButton("清理缓存", 3);
            btnCache.Click += delegate { ClearCache(); };
            toolbar.Controls.Add(btnCache);

            btnDiagnose = MakeButton("环境自检", 4);
            btnDiagnose.Click += delegate { RunDiagnose(); };
            toolbar.Controls.Add(btnDiagnose);

            // ---- 状态区 ----
            Panel status = new Panel();
            status.Dock = DockStyle.Top;
            status.Height = 78;
            status.BackColor = Color.White;
            status.Padding = new Padding(16, 8, 16, 8);
            Controls.Add(status);
            status.BringToFront();

            lblStatus = new Label();
            lblStatus.Text = "准备就绪。先点「① 启动浏览器」并在浏览器里登录。";
            lblStatus.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
            lblStatus.ForeColor = Color.FromArgb(40, 40, 40);
            lblStatus.AutoSize = true;
            lblStatus.Location = new Point(16, 8);
            status.Controls.Add(lblStatus);

            lblLesson = new Label();
            lblLesson.Text = "";
            lblLesson.ForeColor = Color.FromArgb(90, 90, 100);
            lblLesson.AutoSize = true;
            lblLesson.Location = new Point(18, 32);
            status.Controls.Add(lblLesson);

            bar = new ProgressBar();
            bar.Location = new Point(18, 52);
            bar.Size = new Size(830, 8);
            bar.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            bar.Style = ProgressBarStyle.Continuous;
            status.Controls.Add(bar);

            // ---- 日志区 ----
            txtLog = new RichTextBox();
            txtLog.Dock = DockStyle.Fill;
            txtLog.ReadOnly = true;
            txtLog.BackColor = Color.FromArgb(28, 28, 32);
            txtLog.ForeColor = Color.FromArgb(220, 220, 225);
            txtLog.Font = new Font("Consolas", 9.5F);
            txtLog.BorderStyle = BorderStyle.None;
            txtLog.WordWrap = false;
            txtLog.ScrollBars = RichTextBoxScrollBars.Both;
            Controls.Add(txtLog);
            txtLog.BringToFront();

            // ---- 底部状态栏 ----
            statusStrip = new StatusStrip();
            statusLabel = new ToolStripStatusLabel("尚未启动浏览器");
            statusStrip.Items.Add(statusLabel);
            statusStrip.SizingGrip = false;
            Controls.Add(statusStrip);

            FormClosing += delegate(object s, FormClosingEventArgs e) { StopPlay(); };
        }

        Button MakeButton(string text, int index)
        {
            Button b = new Button();
            b.Text = text;
            b.Size = new Size(132, 34);
            b.Location = new Point(12 + index * 140, 10);
            b.FlatStyle = FlatStyle.System;
            b.Font = new Font("Microsoft YaHei UI", 9.5F);
            return b;
        }

        // --------------------------------------------------------------
        //  释放内嵌脚本到临时目录
        // --------------------------------------------------------------
        // 选一个可写的工作目录。
        // 不能只用 Path.GetTempPath() —— 有些机器上临时目录被组策略或安全软件
        // 限制写入，那样程序会在启动时直接失败。逐个候选试写，用第一个成功的。
        // 也支持环境变量 CCR_WORKDIR 显式指定（便于排查或特殊部署）。
        string ChooseWorkDir()
        {
            string tag = "ChaoxingRunner_" + Guid.NewGuid().ToString("N").Substring(0, 8);
            List<string> bases = new List<string>();

            string env = Environment.GetEnvironmentVariable("CCR_WORKDIR");
            if (!string.IsNullOrEmpty(env)) bases.Add(env);

            try { bases.Add(Path.GetTempPath()); } catch { }
            string localApp = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (!string.IsNullOrEmpty(localApp)) bases.Add(localApp);
            string appData = Environment.GetEnvironmentVariable("APPDATA");
            if (!string.IsNullOrEmpty(appData)) bases.Add(appData);
            try { bases.Add(Path.GetDirectoryName(Application.ExecutablePath)); } catch { }

            List<string> tried = new List<string>();
            foreach (string b in bases)
            {
                if (string.IsNullOrEmpty(b)) continue;
                string cand = Path.Combine(b, tag);
                try
                {
                    Directory.CreateDirectory(cand);
                    // 真正写一个文件确认可写 —— 只建目录不够，
                    // 某些策略允许建目录但拒绝写文件。
                    string probe = Path.Combine(cand, ".writetest");
                    File.WriteAllText(probe, "ok");
                    File.Delete(probe);
                    return cand;
                }
                catch (Exception ex)
                {
                    tried.Add(b + "  (" + ex.GetType().Name + ")");
                }
            }

            throw new Exception(
                "找不到可写的工作目录，已尝试：\n  " + string.Join("\n  ", tried.ToArray()) +
                "\n\n可设置环境变量 CCR_WORKDIR 指定一个可写目录后重试。");
        }

        void ExtractScripts()
        {
            workDir = ChooseWorkDir();
            AppendLog("[界面] 工作目录：" + workDir + "\n", Color.FromArgb(130, 200, 255));

            int n = 0;
            foreach (string item in EMBEDDED)
            {
                int sep = item.IndexOf('|');
                if (sep <= 0) continue;
                string rel = item.Substring(0, sep);
                string data = item.Substring(sep + 1);

                string full = Path.Combine(workDir, rel);
                string dir = Path.GetDirectoryName(full);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                    Directory.CreateDirectory(dir);

                File.WriteAllBytes(full, Convert.FromBase64String(data));
                n++;
            }

            // 日志目录（Run.ps1 会往里写）
            Directory.CreateDirectory(Path.Combine(workDir, "logs"));

            AppendLog("[界面] 已准备运行环境：" + n + " 个文件\n", Color.FromArgb(130, 200, 255));

            // 退出时清理临时目录
            FormClosing += delegate
            {
                try { if (Directory.Exists(workDir)) Directory.Delete(workDir, true); }
                catch { }
            };
        }

        // --------------------------------------------------------------
        //  日志输出
        // --------------------------------------------------------------
        void AppendLog(string text, Color color)
        {
            if (txtLog.IsDisposed) return;
            if (txtLog.InvokeRequired)
            {
                txtLog.BeginInvoke(new Action<string, Color>(AppendLog), text, color);
                return;
            }
            txtLog.SelectionStart = txtLog.TextLength;
            txtLog.SelectionLength = 0;
            txtLog.SelectionColor = color;
            txtLog.AppendText(text);
            txtLog.SelectionColor = txtLog.ForeColor;
            txtLog.ScrollToCaret();
        }

        void SetStatus(string text)
        {
            if (lblStatus.IsDisposed) return;
            if (lblStatus.InvokeRequired)
            {
                lblStatus.BeginInvoke(new Action<string>(SetStatus), text);
                return;
            }
            lblStatus.Text = text;
        }

        void SetLesson(string text)
        {
            if (lblLesson.IsDisposed) return;
            if (lblLesson.InvokeRequired)
            {
                lblLesson.BeginInvoke(new Action<string>(SetLesson), text);
                return;
            }
            lblLesson.Text = text;
        }

        void SetBar(int percent)
        {
            if (bar.IsDisposed) return;
            if (bar.InvokeRequired)
            {
                bar.BeginInvoke(new Action<int>(SetBar), percent);
                return;
            }
            if (percent < 0) percent = 0;
            if (percent > 100) percent = 100;
            bar.Value = percent;
        }

        // --------------------------------------------------------------
        //  PowerShell 执行
        // --------------------------------------------------------------
        void RunScript(string scriptPath, string arguments, bool longRunning)
        {
            if (running)
            {
                MessageBox.Show("已有任务在运行，请先停止。", APP_TITLE,
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            string full = Path.Combine(workDir, scriptPath);
            if (!File.Exists(full))
            {
                AppendLog("[错误] 找不到脚本: " + full + "\n", Color.Salmon);
                return;
            }

            running = true;
            btnStart.Enabled = false;
            btnLaunch.Enabled = false;
            btnCache.Enabled = false;
            btnDiagnose.Enabled = false;
            btnStop.Enabled = longRunning;

            ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    // 必须显式放宽执行策略。
                    // 释放到临时目录的脚本会被判为不受信任来源，本机默认策略
                    // （Restricted / AllSigned / RemoteSigned）会直接拒绝执行，
                    // 报"未对文件进行数字签名"。bat 版靠 -ExecutionPolicy Bypass，
                    // 内嵌 runspace 没有命令行参数，只能在这里设。
                    // 这里的脚本来自本程序内嵌资源，不是外部下载物。
                    // 告诉脚本层"我在图形界面里"：进度行不要补位、不要回车，
                    // 控制台输出改走管道由界面捕获。
                    Environment.SetEnvironmentVariable("CCR_GUI", "1");

                    // 把 TMP/TEMP 指向已验证可写的工作目录。
                    // 图形界面进程的临时目录可能被策略限制（本程序启动时就是靠
                    // ChooseWorkDir 回退才找到可写位置的），而 PowerShell 的
                    // Add-Type 会在 TMP/TEMP 下编译临时程序集 ——
                    // 指不过去的话，Win32 声明编译失败，窗口可见性与布局会静默失效。
                    Environment.SetEnvironmentVariable("TMP", workDir);
                    Environment.SetEnvironmentVariable("TEMP", workDir);
                    InitialSessionState iss = InitialSessionState.CreateDefault();
                    iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                    Runspace rs = RunspaceFactory.CreateRunspace(iss);
                    rs.Open();
                    ps = PowerShell.Create();
                    ps.Runspace = rs;
                    ps.AddScript("& '" + full.Replace("'", "''") + "' " + arguments);

                    ps.Streams.Information.DataAdded += delegate(object s, DataAddedEventArgs e)
                    {
                        PSDataCollection<InformationRecord> col = (PSDataCollection<InformationRecord>)s;
                        HandleLine(col[e.Index].MessageData.ToString());
                    };
                    ps.Streams.Warning.DataAdded += delegate(object s, DataAddedEventArgs e)
                    {
                        PSDataCollection<WarningRecord> col = (PSDataCollection<WarningRecord>)s;
                        HandleLine(col[e.Index].Message);
                    };
                    ps.Streams.Error.DataAdded += delegate(object s, DataAddedEventArgs e)
                    {
                        PSDataCollection<ErrorRecord> col = (PSDataCollection<ErrorRecord>)s;
                        ErrorRecord er = col[e.Index];
                        // 带上脚本位置：没有它只能看到"拒绝访问"这类消息，
                        // 无法判断是哪一行触发的。
                        string where = "";
                        try
                        {
                            if (er.InvocationInfo != null && er.InvocationInfo.ScriptLineNumber > 0)
                                where = " @ " + System.IO.Path.GetFileName(er.InvocationInfo.ScriptName) +
                                        ":" + er.InvocationInfo.ScriptLineNumber;
                        }
                        catch { }
                        HandleLine("[错误]" + where + " " + er.ToString());
                    };
                    ps.Streams.Verbose.DataAdded += delegate(object s, DataAddedEventArgs e)
                    {
                        PSDataCollection<VerboseRecord> col = (PSDataCollection<VerboseRecord>)s;
                        HandleLine(col[e.Index].Message);
                    };

                    PSDataCollection<PSObject> output = new PSDataCollection<PSObject>();
                    output.DataAdded += delegate(object s, DataAddedEventArgs e)
                    {
                        PSDataCollection<PSObject> col = (PSDataCollection<PSObject>)s;
                        object v = col[e.Index] == null ? null : col[e.Index].BaseObject;
                        if (v != null) HandleLine(v.ToString());
                    };

                    psAsync = ps.BeginInvoke<PSObject, PSObject>(null, output);
                    ps.EndInvoke(psAsync);
                }
                catch (Exception ex)
                {
                    HandleLine("[错误] " + ex.Message);
                }
                finally
                {
                    try { if (ps != null) { ps.Dispose(); ps = null; } } catch { }
                    running = false;
                    if (!IsDisposed)
                    {
                        BeginInvoke(new Action(delegate
                        {
                            btnStart.Enabled = true;
                            btnLaunch.Enabled = true;
                            btnCache.Enabled = true;
                            btnDiagnose.Enabled = true;
                            btnStop.Enabled = false;
                        }));
                    }
                }
            });
        }

        // --------------------------------------------------------------
        //  输出解析
        // --------------------------------------------------------------
        void HandleLine(string raw)
        {
            if (raw == null) return;

            // 每一项输出就是一行。脚本层在图形界面模式下不再发 `r 就地刷新
            // （见 lib\Logging.psm1 的 Write-ConsoleLine 与 Write-ProgressLine），
            // 所以这里不需要再做流式切分 —— 那样做反而会把所有行挤在一起。
            string[] parts = raw.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            foreach (string line in parts)
            {
                if (line.Trim().Length == 0) continue;
                EmitLine(line);
            }
        }

        void EmitLine(string line)
        {
            // 进度行：形如 "████░░░░  68%   12:34 / 18:20"
            int pct = ExtractPercent(line);
            if (pct >= 0 && line.IndexOf('█') >= 0)
            {
                SetBar(pct);
                SetLesson(CleanProgress(line));
                return;
            }
            AppendLog(line + Environment.NewLine, ClassifyColor(line));
            UpdateStepFrom(line);
        }

        int ExtractPercent(string s)
        {
            int i = s.IndexOf('%');
            if (i < 1) return -1;
            int j = i - 1;
            while (j >= 0 && (char.IsDigit(s[j]) || s[j] == ' ')) j--;
            string num = s.Substring(j + 1, i - j - 1).Trim();
            int v;
            if (int.TryParse(num, out v)) return v;
            return -1;
        }

        string CleanProgress(string s)
        {
            // 去掉方块与多余空白，只留百分比与时间
            StringBuilder sb = new StringBuilder();
            foreach (char c in s)
                if (c != '█' && c != '░') sb.Append(c);
            return sb.ToString().Trim();
        }

        Color ClassifyColor(string s)
        {
            if (s.IndexOf("[错误]") >= 0 || s.IndexOf("错误") >= 0 || s.IndexOf("失败") >= 0)
                return Color.FromArgb(255, 130, 130);
            if (s.IndexOf("警告") >= 0 || s.IndexOf("跳过") >= 0 || s.IndexOf("不可见") >= 0)
                return Color.FromArgb(255, 210, 120);
            if (s.IndexOf("完成") >= 0 || s.IndexOf("已登记") >= 0 || s.IndexOf("登上了") >= 0)
                return Color.FromArgb(140, 235, 150);
            if (s.IndexOf("[界面]") >= 0)
                return Color.FromArgb(130, 200, 255);
            return Color.FromArgb(215, 215, 220);
        }

        void UpdateStepFrom(string s)
        {
            if (s.IndexOf("去登录学习通") >= 0)
                SetStatus("请在浏览器里登录学习通（账号密码或 App 扫码）");
            else if (s.IndexOf("去登陆吧") >= 0)
                SetStatus("请在浏览器里登录学习通");
            else if (s.IndexOf("行，登上了") >= 0 || s.Trim() == "行")
                SetStatus("登录成功。请在浏览器里打开课程的「学生学习页面」");
            else if (s.IndexOf("去点进你要刷的课") >= 0)
                SetStatus("请在浏览器里打开你要刷的课程");
            else if (s.IndexOf("开始自动连播") >= 0)
                SetStatus("正在自动连播，可以离开不管了");
            else if (s.IndexOf("结束：完成") >= 0)
                SetStatus("已结束。" + s.Trim());
        }

        // --------------------------------------------------------------
        //  按钮动作
        // --------------------------------------------------------------
        void LaunchBrowser()
        {
            SetStatus("正在启动浏览器…");
            AppendLog("\n=== 启动浏览器 ===\n", Color.FromArgb(130, 200, 255));
            // -LaunchOnly：只开浏览器并给指引，不刷课
            RunScript("Run.ps1", "-LaunchOnly -NoClearScreen -NoArrangeWindows", false);
        }

        void StartPlay()
        {
            SetStatus("正在开始…");
            AppendLog("\n=== 开始自动连播 ===\n", Color.FromArgb(130, 200, 255));
            RunScript("Run.ps1", "-NoClearScreen -NoArrangeWindows", true);
        }

        void StopPlay()
        {
            if (ps != null)
            {
                try
                {
                    ps.Stop();
                    AppendLog("\n[界面] 已请求停止。已完成的课节不会重刷。\n", Color.FromArgb(255, 210, 120));
                }
                catch { }
            }
        }

        void ClearCache()
        {
            DialogResult r = MessageBox.Show(
                "将清理浏览器缓存（保留配置）。\n\n" +
                "注意：清理前会关闭工具专用的浏览器窗口，正在播的课会中断。\n\n继续？",
                APP_TITLE, MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (r != DialogResult.Yes) return;

            SetStatus("正在清理缓存…");
            AppendLog("\n=== 清理缓存 ===\n", Color.FromArgb(130, 200, 255));
            RunScript(@"scripts\Clear-Cache.ps1", "-Yes", false);
        }

        void RunDiagnose()
        {
            // 自检脚本不在内嵌清单里（它只在 tests\ 下，面向排错）
            MessageBox.Show(
                "环境自检请运行命令行版本：\n\n" +
                "Diagnose.bat（在完整包里）\n\n" +
                "图形界面版本已内嵌全部运行所需文件，通常不需要自检。",
                APP_TITLE, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        // --------------------------------------------------------------
        [STAThread]
        static void Main(string[] args)
        {
            // 自检模式：不开界面，只验证资源与 PowerShell 引擎是否可用。
            // 用于排查"窗口没出来"这类问题 —— 直接运行看输出即可。
            if (args.Length > 0 && args[0] == "--diag")
            {
                // 诊断模式：跑一次 Run.ps1 -LaunchOnly，把所有流的内容落盘。
                // 用于排查"界面日志里出现奇怪错误"这类问题。
                string dir = Path.Combine(Path.GetDirectoryName(Application.ExecutablePath), "diag");
                Directory.CreateDirectory(dir);
                string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
                string src = Path.Combine(exeDir, "..");
                // 直接用仓库里的脚本跑，避免依赖内嵌资源
                string script = Path.Combine(src, "Run.ps1");
                if (!File.Exists(script)) { Console.WriteLine("找不到 " + script); return; }
                Environment.SetEnvironmentVariable("CCR_GUI", "1");
                // 与图形界面一致：临时目录重定向到已验证可写的位置。
                // 诊断的目的就是复现界面的真实条件，少了这一步结果不可信。
                string wd = Path.Combine(exeDir, "diag", "work");
                Directory.CreateDirectory(wd);
                Environment.SetEnvironmentVariable("TMP", wd);
                Environment.SetEnvironmentVariable("TEMP", wd);
                Console.WriteLine("TMP -> " + wd);
                InitialSessionState iss = InitialSessionState.CreateDefault();
                iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                Runspace rs = RunspaceFactory.CreateRunspace(iss);
                rs.Open();
                PowerShell p = PowerShell.Create();
                p.Runspace = rs;
                p.AddScript("& '" + script.Replace("'", "''") + "' -LaunchOnly -NoClearScreen -NoArrangeWindows");
                PSDataCollection<PSObject> outp = new PSDataCollection<PSObject>();
                IAsyncResult ar = p.BeginInvoke<PSObject, PSObject>(null, outp);
                p.EndInvoke(ar);
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("=== 输出流 (" + outp.Count + ") ===");
                foreach (PSObject o in outp) sb.AppendLine("  [" + (o == null ? "null" : o.ToString()) + "]");
                sb.AppendLine("=== 错误流 (" + p.Streams.Error.Count + ") ===");
                for (int i = 0; i < p.Streams.Error.Count; i++)
                {
                    ErrorRecord er = p.Streams.Error[i];
                    sb.AppendLine("  [" + i + "] " + er.ToString());
                    sb.AppendLine("      CategoryInfo : " + er.CategoryInfo);
                    if (er.InvocationInfo != null)
                    {
                        sb.AppendLine("      ScriptName   : " + er.InvocationInfo.ScriptName);
                        sb.AppendLine("      Line         : " + er.InvocationInfo.ScriptLineNumber);
                        sb.AppendLine("      PositionMessage: " + er.InvocationInfo.PositionMessage);
                    }
                    if (er.Exception != null)
                        sb.AppendLine("      StackTrace   : " + er.Exception.StackTrace);
                }
                sb.AppendLine("=== 警告流 (" + p.Streams.Warning.Count + ") ===");
                for (int i = 0; i < p.Streams.Warning.Count; i++) sb.AppendLine("  " + p.Streams.Warning[i].Message);
                File.WriteAllText(Path.Combine(dir, "diag.txt"), sb.ToString(), Encoding.UTF8);
                Console.WriteLine("诊断结果写入 " + Path.Combine(dir, "diag.txt"));
                return;
            }
            if (args.Length > 0 && args[0] == "--selftest")
            {
                Console.WriteLine("ChaoxingRunner self-test");
                Console.WriteLine("  内嵌文件数: " + EMBEDDED.Length);
                int decoded = 0;
                long bytes = 0;
                foreach (string item in EMBEDDED)
                {
                    int sep = item.IndexOf('|');
                    if (sep <= 0) continue;
                    byte[] data = Convert.FromBase64String(item.Substring(sep + 1));
                    decoded++;
                    bytes += data.Length;
                    Console.WriteLine(string.Format("    {0,-34} {1,7} B", item.Substring(0, sep), data.Length));
                }
                Console.WriteLine("  解码成功: " + decoded + " 个，共 " + bytes + " 字节");
                try
                {
                    Runspace rs = RunspaceFactory.CreateRunspace();
                    rs.Open();
                    PowerShell p = PowerShell.Create();
                    p.Runspace = rs;
                    p.AddScript("$PSVersionTable.PSVersion.ToString()");
                    System.Collections.ObjectModel.Collection<PSObject> res = p.Invoke();
                    Console.WriteLine("  PowerShell 引擎可用，版本 " + res[0].ToString());
                    p.Commands.Clear();
                    p.AddScript("$ExecutionContext.SessionState.LanguageMode.ToString()");
                    System.Collections.ObjectModel.Collection<PSObject> lm = p.Invoke();
                    Console.WriteLine("  语言模式: " + lm[0].ToString());
                Console.WriteLine("  TMP        : " + Path.GetTempPath());
                    rs.Close();
                }
                catch (Exception ex)
                {
                    Console.WriteLine("  PowerShell 引擎不可用: " + ex.Message);
                    return;
                }
                Console.WriteLine("  自检通过");
                return;
            }

            // 注意：必须把 MainForm 的构造也放进 try ——
            // 构造函数里会释放内嵌脚本、建临时目录，出错时异常在
            // new MainForm() 求值阶段就抛了，包不住的话程序会静默退出，
            // 使用者只看到"窗口没出来"，没有任何线索。
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                MainForm form = new MainForm();
                Application.Run(form);
            }
            catch (Exception ex)
            {
                string detail = ex.ToString();
                // 错误信息要落到"一定能写"的地方。
                // 不能只写临时目录 —— 本程序要处理的正是"临时目录不可写"这种情况，
                // 那样连错误都留不下，使用者只看到窗口一闪而过，毫无线索。
                string[] spots = new string[] {
                    Path.GetTempPath(),
                    Path.GetDirectoryName(Application.ExecutablePath)
                };
                foreach (string spot in spots)
                {
                    try
                    {
                        string logPath = Path.Combine(spot, "ChaoxingRunner-error.txt");
                        File.WriteAllText(logPath, detail, Encoding.UTF8);
                        detail += "\n\n详细信息已写入：\n" + logPath;
                        break;
                    }
                    catch { }
                }
                MessageBox.Show("启动失败：\n\n" + detail, APP_TITLE,
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }
    }
}
