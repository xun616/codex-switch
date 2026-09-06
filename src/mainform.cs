using Microsoft.VisualBasic;
using System;
using System.IO;
using System.Drawing;
using System.Windows.Forms;

public class MainForm : Form
{
    Label lblStatus;
    GroupBox gbModel;
    RadioButton rbFlash, rbPro, rbVision;
    Button btnDs, btnOfficial, btnRefresh, btnOpenDir;
    TextBox txtLog;
    string Home;

    public MainForm()
    {
        Home = Switcher.GetCodexHome();
        BuildUi();
        RefreshStatus();
        Log("Codex 目录: " + Home);
        Log("开始使用前请确保已退出 ChatGPT 桌面应用。");
    }

    void BuildUi()
    {
        Text = "Codex 切换器（官方 / DeepSeek）";
        ClientSize = new Size(560, 480);
        MinimumSize = new Size(560, 420);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft YaHei UI", 9F);

        lblStatus = new Label();
        lblStatus.AutoSize = false;
        lblStatus.Location = new Point(16, 14);
        lblStatus.Size = new Size(520, 30);
        lblStatus.Font = new Font(Font, FontStyle.Bold);
        lblStatus.TextAlign = ContentAlignment.MiddleLeft;
        Controls.Add(lblStatus);

        gbModel = new GroupBox();
        gbModel.Text = "DeepSeek 模型";
        gbModel.Location = new Point(16, 52);
        gbModel.Size = new Size(260, 60);

        rbFlash = new RadioButton { Text = "Flash", Location = new Point(12, 22), Size = new Size(60, 24) };
        rbPro   = new RadioButton { Text = "Pro",   Location = new Point(88, 22), Size = new Size(60, 24) };
        rbVision= new RadioButton { Text = "Vision",Location = new Point(150, 22), Size = new Size(90, 24), Checked = true };
        gbModel.Controls.AddRange(new Control[] { rbFlash, rbPro, rbVision });
        Controls.Add(gbModel);

        btnDs = new Button { Text = "切换到 DeepSeek", Location = new Point(292, 52), Size = new Size(120, 36), BackColor = Color.FromArgb(230, 240, 255) };
        btnOfficial = new Button { Text = "切换回官方", Location = new Point(420, 52), Size = new Size(120, 36), BackColor = Color.FromArgb(255, 240, 230) };
        btnDs.Click += (s, e) => { RunBusy(() => SwitchToDs()); };
        btnOfficial.Click += (s, e) => { RunBusy(() => SwitchToOfficial()); };
        Controls.Add(btnDs);
        Controls.Add(btnOfficial);

        btnRefresh = new Button { Text = "刷新状态", Location = new Point(16, 120), Size = new Size(90, 30) };
        btnRefresh.Click += (s, e) => { RefreshStatus(); };
        Controls.Add(btnRefresh);

        btnOpenDir = new Button { Text = "打开配置目录", Location = new Point(112, 120), Size = new Size(110, 30) };
        btnOpenDir.Click += (s, e) => {
            try { System.Diagnostics.Process.Start("explorer.exe", Home); }
            catch (Exception ex) { Log("打开目录失败: " + ex.Message); }
        };
        Controls.Add(btnOpenDir);

        txtLog = new TextBox();
        txtLog.Location = new Point(16, 160);
        txtLog.Size = new Size(524, 296);
        txtLog.Multiline = true;
        txtLog.ReadOnly = true;
        txtLog.ScrollBars = ScrollBars.Both;
        txtLog.WordWrap = false;
        txtLog.Font = new Font("Consolas", 9F);
        txtLog.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom;
        Controls.Add(txtLog);
    }

    string SelectedSlug()
    {
        if (rbFlash.Checked) return "deepseek-v4-flash";
        if (rbPro.Checked)   return "deepseek-v4-pro";
        return "deepseek-v4-flash-vision-exp";
    }

    void RunBusy(Action action)
    {
        btnDs.Enabled = false; btnOfficial.Enabled = false;
        Cursor = Cursors.WaitCursor;
        try { action(); }
        catch (Exception ex) { Log("[错误] " + ex.Message); }
        finally { Cursor = Cursors.Default; btnDs.Enabled = true; btnOfficial.Enabled = true; RefreshStatus(); }
    }

    void SwitchToDs()
    {
        string slug = SelectedSlug();
        Log(">> 切换到 DeepSeek: " + slug);
        string cfg = File.ReadAllText(Switcher.ConfigPath(Home));
        string key = Switcher.ResolveApiKey(Home, cfg);
        if (string.IsNullOrEmpty(key))
        {
            string inp = Interaction.InputBox("没有找到 DeepSeek API Key（配置、存档、环境变量都没有）。\n请输入以 sk- 开头的 Key：", "需要 DeepSeek API Key", "");
            if (!string.IsNullOrEmpty(inp) && inp.Trim().StartsWith("sk-")) key = inp.Trim();
            else { Log("未提供有效 API Key，已取消。"); return; }
        }
        Switcher.DoSwitch(Home, true, slug, key);
        Log("[OK] 已切换到 DeepSeek (" + slug + ")");
        Log("请彻底退出并重开 ChatGPT 桌面应用（托盘图标->Quit）。");
        MessageBox.Show("已切换到 DeepSeek (" + slug + ")。\n请彻底退出并重开 ChatGPT 桌面应用后生效。", "完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    void SwitchToOfficial()
    {
        Log(">> 切换回官方配置");
        Switcher.DoSwitch(Home, false, "", null);
        Log("[OK] 已切换回官方 (gpt-6-astra)");
        Log("请彻底退出并重开 ChatGPT 桌面应用（托盘图标->Quit）。");
        MessageBox.Show("已切换回官方 (gpt-6-astra)。\n请彻底退出并重开 ChatGPT 桌面应用后生效。", "完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    void RefreshStatus()
    {
        string s = "状态：" + Switcher.Status(Home);
        lblStatus.Text = s;
        Log("*** " + s);
    }

    void Log(string m)
    {
        if (txtLog.InvokeRequired) { txtLog.BeginInvoke(new Action<string>(Log), m); return; }
        txtLog.AppendText(m + Environment.NewLine);
        txtLog.SelectionStart = txtLog.TextLength;
        txtLog.ScrollToCaret();
    }
}
