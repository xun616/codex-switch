# Changelog

## v0.1.0 - 2026-09-06

- 首个发布版本。
- 提供单文件 GUI 版 `CodexSwitcher.exe`（WinForms，.NET Framework 4.x）。
- 提供 CLI 版 `codex-switch.ps1`（PowerShell 5.1/7）。
- 支持官方 <-> DeepSeek 一键切换，保留用户原有配置。
- 切换前自动备份 `config.toml`，模型目录 `models.json` 自动归档/恢复。
- API Key 不写死，首次缺人时提示输入并保存到本机。
