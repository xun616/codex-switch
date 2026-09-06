# NOTICE

## DeepSeek model catalog (`assets/deepseek-models.json`)

`assets/deepseek-models.json` is **not** original work of this project. It is
the model catalog that the official DeepSeek Codex setup script writes locally
so that Codex can resolve the `deepseek-*` model slugs.

- Source: `https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1`
  (the embedded `models.json` payload).
- It is redistributed here **only** so the switcher remains self-contained and
  works offline. The catalog contains model metadata (context window, reasoning
  levels, display name, etc.) and an `instructions_template` string.

Please review DeepSeek's own terms before redistributing or relying on this
file. If you prefer, you can regenerate it yourself by running the official
script:

```powershell
irm https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1 | iex
```

## Affiliation

This project is an independent convenience tool. It is **not** affiliated with,
endorsed by, or sponsored by OpenAI or DeepSeek. All product names and model
names belong to their respective owners.
