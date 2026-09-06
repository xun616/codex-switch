# Codex 切换器 —— 官方 / DeepSeek 一键切换

> English | [README.en.md](README.en.md)

一个 Windows 小工具，用来在 **官方（OpenAI）** 和 **DeepSeek** 模型之间一键切换本机
Codex 的配置，不再每次都要跑一遍官方交互式安装脚本：

```powershell
irm https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1 | iex
```

它只会 **改动与 DeepSeek 相关的配置**，你原来的信任目录、MCP 服务、插件、桌面设置等都会原样保留。

## 功能

- **图形界面 exe**（`CodexSwitcher.exe`）：状态栏、模型选择（Flash / Pro / Vision）、
  「切换到 DeepSeek」「切换回官方」一键按钮、实时日志。
- **命令行脚本**（`codex-switch.ps1`）：适合脚本化和自动化。
- **可逆切换**：每次切换都会把 `config.toml` 备份到
  `codex-switch\config.toml.prev-<时间戳>`。切回官方时会把 DeepSeek 模型目录
  `models.json` 归档到 `codex-switch\models.json`，切回 DeepSeek 时再恢复。
- **不写死密钥**：API Key 永不硬编码。按以下顺序获取：
  1. `config.toml` 里 `[model_providers.deepseek]` 的 `experimental_bearer_token`
  2. `codex-switch\api-key.txt`（切回官方时自动归档）
  3. 环境变量 `DEEPSEEK_API_KEY`
  4. 都没有时弹窗让你输入一次，并保存到本机
- **自包含**：DeepSeek 模型目录已内嵌到 exe，运行时不需要额外文件。

## 运行环境

- Windows 10/11（系统自带 .NET Framework 4.x 运行时）。
- CLI / 构建脚本需要 PowerShell 5.1 或 7。

> 首次使用前请先运行过一次 Codex（CLI 或 ChatGPT 桌面应用），它会创建 `config.toml`。

## 图形界面用法

双击 `CodexSwitcher.exe`：

1. 顶部查看当前状态。
2. 选择 DeepSeek 模型（默认 Vision）。
3. 点 **切换到 DeepSeek** 或 **切换回官方**。
4. 看日志，然后 **彻底退出并重开 ChatGPT 桌面应用**（托盘图标 -> Quit），或重启 Codex CLI，
   配置才会生效。

## 命令行用法

```powershell
.\codex-switch.ps1 ds            # 切到 DeepSeek（vision）
.\codex-switch.ps1 ds pro        # 切到 DeepSeek Pro
.\codex-switch.ps1 ds flash      # 切到 DeepSeek Flash
.\codex-switch.ps1 off           # 切回官方（gpt-6-astra）
.\codex-switch.ps1 status        # 查看当前状态
.\codex-switch.ps1               # 交互菜单
```

## 从源码构建 exe

```powershell
.\build.ps1                      # -> .\CodexSwitcher.exe
.\build.ps1 -OutDir .\release    # -> .\release\CodexSwitcher.exe
```

构建使用 Windows 自带的 .NET Framework C# 编译器（`csc.exe`），不需要 SDK 或 NuGet。

## 安全说明

- 本工具只改写 `config.toml` 并移动/恢复 `models.json`，**不联网**、不改其它文件。
- 因为 exe 未签名，首次运行 Windows SmartScreen 可能提示“未知发布者”（更多信息 -> 仍要运行）。
- 切换需要重启 ChatGPT 桌面应用或 CLI 才生效。

## 免责声明

本项目是独立工具，**与 OpenAI 或 DeepSeek 均无关联、无背书**。
`assets/deepseek-models.json` 来自 DeepSeek 官方安装脚本，仅用于兼容；详见
[NOTICE.md](NOTICE.md)。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
