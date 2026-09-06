# Codex Switcher -- Official <-> DeepSeek, one click

A small Windows tool that flips your local Codex config between the **official
(OpenAI)** provider and the **DeepSeek** model provider, without re-running the
interactive install script every time:

```powershell
irm https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1 | iex
```

It surgically edits `%CODEX_HOME%\config.toml` (default
`C:\Users\<you>\.codex\config.toml`) so **your own settings are kept**: trusted
project folders, MCP servers, plugins, desktop options, etc. Only the
DeepSeek-specific keys and the `[model_providers.deepseek]` block are added or
removed.

## Features

- **GUI exe** (`CodexSwitcher.exe`) -- status bar, model picker (Flash / Pro /
  Vision), one-click "switch to DeepSeek" and "switch back to official", and a
  live log.
- **CLI script** (`codex-switch.ps1`) -- for scripts/automation.
- Switches are **reversible**: every switch backs up `config.toml` to
  `codex-switch\config.toml.prev-<timestamp>`. The DeepSeek model catalog
  (`models.json`) is archived to `codex-switch\models.json` while on official and
  restored on switch back.
- **No secrets baked in**: the API key is never hardcoded. It is read from
  `[model_providers.deepseek]`, then `codex-switch\api-key.txt`, then the
  `DEEPSEEK_API_KEY` environment variable, and prompted once if none exist.
- **Self-contained**: the DeepSeek model catalog is embedded into the exe, so no
  companion file is needed at runtime.

## Requirements

- Windows 10/11 (the .NET Framework 4.x runtime is built in).
- PowerShell 5.1 or 7 for the CLI / build script.

## GUI usage

Double-click `CodexSwitcher.exe`:

1. Read the current state at the top.
2. Pick a DeepSeek model (default: Vision).
3. Click **Switch to DeepSeek** or **Switch back to official**.
4. Watch the log, then **fully quit and reopen the ChatGPT desktop app** (tray
   icon -> Quit), or restart the Codex CLI, for the change to take effect.

## CLI usage

```powershell
.\codex-switch.ps1 ds            # DeepSeek (vision)
.\codex-switch.ps1 ds pro        # DeepSeek Pro
.\codex-switch.ps1 ds flash      # DeepSeek Flash
.\codex-switch.ps1 off           # back to official (gpt-6-astra)
.\codex-switch.ps1 status        # show current state
.\codex-switch.ps1               # interactive menu
```

## Build the exe

```powershell
.\build.ps1                      # -> .\CodexSwitcher.exe
.\build.ps1 -OutDir .\release    # -> .\release\CodexSwitcher.exe
```

The build uses the .NET Framework C# compiler (`csc.exe`) that ships with
Windows -- no SDK or NuGet needed.

## Safety notes

- This tool only rewrites `config.toml` and moves/restores `models.json`. It does
  **not** talk to the network or modify anything else.
- Because the exe is unsigned, Windows SmartScreen may warn "unknown publisher"
  on first run (More info -> Run anyway).
- Switch requires a restart of the ChatGPT desktop app or CLI to take effect.

## Disclaimer

This project is an independent helper and is **not** affiliated with or endorsed
by OpenAI or DeepSeek. The `assets/deepseek-models.json` catalog is provided by
DeepSeek's official setup for compatibility; see [NOTICE.md](NOTICE.md).

## License

MIT -- see [LICENSE](LICENSE).
