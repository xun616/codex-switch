#Requires -Version 5.1
<#
.SYNOPSIS
    One-click toggle for Codex between the official (OpenAI) configuration and
    the DeepSeek model provider, without running the interactive CDN installer.

.DESCRIPTION
    Replaces the usual:  irm https://cdn.deepseek.com/api-docs/codex-deepseek-setup-en.ps1 | iex

    It surgically edits %CODEX_HOME%\config.toml so your own settings (trusted
    project directories, MCP servers, plugins, desktop options, etc.) are
    preserved. Only the DeepSeek-specific keys and the [model_providers.deepseek]
    section are added/removed.

    The DeepSeek model catalog (models.json) is kept in a private
    codex-switch\models.json folder and restored on every switch, so the model
    always resolves without re-downloading anything.

.PARAMETER Target
    ds | deepseek   -> switch to DeepSeek
    off | official | restore -> switch back to the official configuration
    status          -> show the current state (no changes)
    help            -> show this help
    (empty)         -> interactive menu

.PARAMETER Model
    For "ds": flash | pro | vision. Defaults to vision
    (deepseek-v4-flash-vision-exp).

.EXAMPLE
    .\codex-switch.ps1 ds            # switch to DeepSeek (vision)
    .\codex-switch.ps1 ds pro        # switch to DeepSeek pro
    .\codex-switch.ps1 off           # switch back to official
    .\codex-switch.ps1 status        # print what is currently configured
#>
param(
    [Parameter(Position = 0)][string]$Target = '',
    [Parameter(Position = 1)][string]$Model = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- constants
$PROVIDER_ID        = 'deepseek'
$DEFAULT_BASE_URL   = 'https://api.deepseek.com/'
$OFFICIAL_MODEL     = 'gpt-6-astra'
$OFFICIAL_EFFORT    = 'low'
$OFFICIAL_SERVICE   = 'default'
$DEFAULT_DS_MODEL   = 'deepseek-v4-flash-vision-exp'

$DS_MODELS = @{
    flash  = 'deepseek-v4-flash'
    pro    = 'deepseek-v4-pro'
    vision = 'deepseek-v4-flash-vision-exp'
}
$DS_SLUG_TO_NAME = @{
    'deepseek-v4-flash'             = 'DeepSeek-V4-Flash'
    'deepseek-v4-pro'               = 'DeepSeek-V4-Pro'
    'deepseek-v4-flash-vision-exp'  = 'DeepSeek-V4-Flash-Vision'
}

# Top-level keys the DeepSeek install writes/overrides.
$DS_KEYS = @(
    'model', 'model_provider', 'preferred_auth_method', 'forced_login_method',
    'model_reasoning_effort', 'model_catalog_json'
)

# Top-level keys that must exist only in the official config and are removed
# when switching to DeepSeek.
$DEL_ON_DS = @(
    'profile', 'oss_provider', 'openai_base_url',
    'model_context_window', 'model_auto_compact_token_limit',
    'model_auto_compact_token_limit_scope', 'base_instructions',
    'model_instructions_file', 'compact_prompt',
    'experimental_compact_prompt_file', 'service_tier', 'model_verbosity',
    'model_reasoning_summary', 'plan_mode_reasoning_effort',
    'experimental_use_unified_exec_tool'
)

# Top-level keys the DeepSeek install would have added; removed when returning
# to the official configuration.
$REMOVE_ON_OFFICIAL = @(
    'model_provider', 'preferred_auth_method', 'forced_login_method',
    'model_catalog_json'
) + $DEL_ON_DS

# ---------------------------------------------------------------- paths
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$ConfigPath   = Join-Path $CodexHome 'config.toml'
$ModelsPath   = Join-Path $CodexHome 'models.json'
$SwitchDir    = Join-Path $CodexHome 'codex-switch'
$SwitchModels = Join-Path $SwitchDir 'models.json'
$SwitchKey    = Join-Path $SwitchDir 'api-key.txt'
$SwitchState  = Join-Path $SwitchDir 'state.txt'

# On-disk models.json is referenced by config.toml with forward slashes.
$CatalogValue = $ModelsPath -replace '\\', '/'

# ---------------------------------------------------------------- output helpers
function Write-Ok    { param($m) Write-Host '[OK] ' -ForegroundColor Green -NoNewline; Write-Host $m }
function Write-Warn  { param($m) Write-Host '[!]  ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Head  { param($m) Write-Host ''; Write-Host $m -ForegroundColor White }
function Write-Dim   { param($m) Write-Host $m -ForegroundColor DarkGray }
function Die {
    param($m)
    Write-Host ''
    Write-Host "[X] $m" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- TOML scanner
# Track bracket depth and multi-line strings so section headers can be told
# apart from array/table content inside normal key/value lines.
$script:Depth   = 0
$script:MlState = ''

function Update-ScanState {
    param([string]$Line)
    $n = $Line.Length
    $i = 0
    $instr = ''
    while ($i -lt $n) {
        $c   = $Line[$i]
        $c3  = if ($i + 3 -le $n) { $Line.Substring($i, 3) } else { '' }

        if ($script:MlState) {
            if ($script:MlState -eq 'basic'   -and $c3 -eq '"""') { $script:MlState = ''; $i += 3; continue }
            if ($script:MlState -eq 'literal' -and $c3 -eq "'''") { $script:MlState = ''; $i += 3; continue }
            if ($script:MlState -eq 'basic'   -and $c -eq '\')    { $i += 2; continue }
            $i++; continue
        }
        if ($instr) {
            if ($instr -eq 'basic') {
                if ($c -eq '\') { $i += 2; continue }
                if ($c -eq '"') { $instr = '' }
            } else {
                if ($c -eq "'") { $instr = '' }
            }
            $i++; continue
        }
        if ($c3 -eq '"""') { $script:MlState = 'basic';   $i += 3; continue }
        if ($c3 -eq "'''") { $script:MlState = 'literal'; $i += 3; continue }

        switch ($c) {
            '#' { return }
            '"' { $instr = 'basic' }
            "'" { $instr = 'literal' }
            '[' { $script:Depth++ }
            ']' { if ($script:Depth -gt 0) { $script:Depth-- } }
        }
        $i++
    }
}

function Get-TomlKey {
    param([string]$Line)
    $l = $Line.Trim()
    if ($l -eq '' -or $l.StartsWith('#')) { return '' }
    $eq = $l.IndexOf('=')
    if ($eq -lt 1) { return '' }
    return $l.Substring(0, $eq).Trim().Trim('"').Trim("'")
}

function Get-TomlValue {
    param([string]$Line)
    $l = $Line.Trim()
    $eq = $l.IndexOf('=')
    if ($eq -lt 0) { return '' }
    return $l.Substring($eq + 1).Trim()
}

function Get-SectionName {
    param([string]$Line)
    $h = $Line.Trim()
    $close = $h.IndexOf(']')
    if ($close -gt 0) { $h = $h.Substring(0, $close + 1) }
    return $h.TrimStart('[').TrimEnd(']').Trim().Replace('"', '').Replace("'", '')
}

function Read-ConfigLines {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Die "config.toml not found: $ConfigPath. Run the Codex CLI / ChatGPT desktop app once to create it."
    }
    $raw = [System.IO.File]::ReadAllText($ConfigPath)
    $raw = $raw -replace "`r`n", "`n"
    $raw = $raw.TrimEnd("`n")
    if ($raw -eq '') { return @() } else { return $raw -split "`n" }
}

function Write-ConfigText {
    param([string[]]$Lines)
    $tmp = $ConfigPath + '.switch-tmp'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, (($Lines -join "`n") + "`n"), $utf8)

    # Duplicate top-level keys prevent Codex from starting; verify before commit.
    $dup = @{}
    $d = 0; $ml = ''; $inLead = $true
    foreach ($l in $Lines) {
        $t = $l.Trim()
        if (-not $ml -and $d -eq 0 -and $t.StartsWith('[')) { $inLead = $false }
        if ($inLead) {
            $k = Get-TomlKey $l
            if ($k) {
                if ($dup.Contains($k)) {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    Die "The generated config.toml would contain a duplicate top-level key: $k. Aborted (the original file was not modified)."
                }
                $dup[$k] = $true
            }
        }
        $script:MlState = $ml; $script:Depth = $d
        Update-ScanState $l
        $ml = $script:MlState; $d = $script:Depth
    }
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
}

function Backup-Config {
    New-Item -ItemType Directory -Force -Path $SwitchDir | Out-Null
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $SwitchDir "config.toml.prev-$stamp"
    Copy-Item -LiteralPath $ConfigPath -Destination $target -Force
    Write-Dim "   (backup of the current config: codex-switch\config.toml.prev-$stamp)"
}

# Swallow one complete assignment (incl. multi-line arrays/strings).
function Consume-Block {
    param([string[]]$Lines, [ref]$Idx)
    while ($Idx.Value -lt $Lines.Count) {
        Update-ScanState $Lines[$Idx.Value]
        $Idx.Value++
        if (-not $script:MlState -and $script:Depth -eq 0) { break }
    }
}

# ---------------------------------------------------------------- DeepSeek side
function Get-ProviderKeyFromConfig {
    # Return the experimental_bearer_token from the current
    # [model_providers.deepseek] block, if the config still has one.
    $lines = Read-ConfigLines
    $inSection = $false
    $depth = 0; $ml = ''
    $found = ''
    foreach ($l in $lines) {
        $t = $l.Trim()
        $script:MlState = $ml; $script:Depth = $depth
        $isHeader = (-not $script:MlState) -and ($script:Depth -eq 0) -and $t.StartsWith('[')
        if ($isHeader) {
            $inSection = (Get-SectionName $l) -eq "model_providers.$PROVIDER_ID"
        }
        if ($inSection -and (Get-TomlKey $l) -eq 'experimental_bearer_token') {
            $found = (Get-TomlValue $l).Trim('"').Trim("'")
        }
        Update-ScanState $l
        $ml = $script:MlState; $depth = $script:Depth
    }
    return $found
}

function Get-DeepSeekApiKey {
    # 1) key already configured in the current [model_providers.deepseek] block
    # 2) stored key from a previous switch
    # 3) DEEPSEEK_API_KEY environment variable
    # 4) prompt once and remember
    $fromConfig = Get-ProviderKeyFromConfig
    if ($fromConfig) { return $fromConfig }
    if (Test-Path -LiteralPath $SwitchKey) {
        $s = (Get-Content -LiteralPath $SwitchKey -Raw -Encoding UTF8).Trim()
        if ($s) { return $s }
    }
    if ($env:DEEPSEEK_API_KEY) { return $env:DEEPSEEK_API_KEY.Trim() }

    Write-Head 'DeepSeek API key'
    Write-Dim 'No key was found in the current config, in codex-switch\api-key.txt,'
    Write-Dim 'nor in the DEEPSEEK_API_KEY environment variable.'
    Write-Dim "Create one at https://platform.deepseek.com/api_keys if needed."
    $key = Read-Host 'Enter your DeepSeek API key (starts with sk-)'
    $key = if ($key) { $key.Trim() } else { '' }
    if ($key -cnotlike 'sk-*') { Die 'A valid API key is required (it must start with sk-).' }
    return $key
}

function Save-DeepSeekKey {
    param([string]$Key)
    if ($Key) {
        New-Item -ItemType Directory -Force -Path $SwitchDir | Out-Null
        [System.IO.File]::WriteAllText($SwitchKey, $Key, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Ensure-ModelsJson {
    # Make sure $ModelsPath holds the DeepSeek catalog, seeding from a private
    # copy or a sibling file shipped next to this script.
    New-Item -ItemType Directory -Force -Path $SwitchDir | Out-Null
    if (Test-Path -LiteralPath $ModelsPath) {
        # already present (and it is DeepSeek-owned) -> refresh the private copy
        Copy-Item -LiteralPath $ModelsPath -Destination $SwitchModels -Force
        return $true
    }
    $source = $null
    if (Test-Path -LiteralPath $SwitchModels) { $source = $SwitchModels }
    else {
        $candidates = @(
            (Join-Path $PSScriptRoot 'deepseek-models.json'),
            (Join-Path $PSScriptRoot 'assets\deepseek-models.json')
        )
        foreach ($sibling in $candidates) {
            if (Test-Path -LiteralPath $sibling) { $source = $sibling; break }
        }
    }
    if (-not $source) {
        Write-Warn 'models.json was not found and could not be restored. The DeepSeek model may fall back to metadata.'
        Write-Dim '   Fix: switch to official once then back to DeepSeek, or re-run the CDN setup once.'
        return $false
    }
    Copy-Item -LiteralPath $source -Destination $ModelsPath -Force
    if ($source -ne $SwitchModels) {
        Copy-Item -LiteralPath $source -Destination $SwitchModels -Force
    }
    return $true
}

function Write-DeepSeekConfig {
    param([string]$ModelSlug, [string]$ApiKey, [string]$BaseUrl, [string]$CatalogValue)

    $Lines = Read-ConfigLines
    $Out   = New-Object System.Collections.Generic.List[string]
    $seen  = @{}
    $script:idx = 0
    $curSection = ''
    $skipSection = $false
    $insAt = 0
    $script:Depth = 0; $script:MlState = ''

    while ($script:idx -lt $Lines.Count) {
        $line = $Lines[$script:idx]
        $trimmed = $line.Trim()
        $isHeader = (-not $script:MlState) -and ($script:Depth -eq 0) -and $trimmed.StartsWith('[')

        if ($isHeader) {
            $hdr = Get-SectionName $line
            $curSection = $hdr
            $skipSection = ($hdr -eq "model_providers.$PROVIDER_ID") -or
                           ($hdr -like "model_providers.$PROVIDER_ID.*") -or
                           ($hdr -eq 'profiles') -or ($hdr -like 'profiles.*')
            Update-ScanState $line
            $script:idx++
            if (-not $skipSection) { $Out.Add($line) }
            continue
        }

        if ($curSection) {
            if ($skipSection) { Update-ScanState $line; $script:idx++; continue }
            # Keep node_repl / mcp / plugin sections verbatim.
            $Out.Add($line)
            Update-ScanState $line
            $script:idx++
            continue
        }

        # ---- leading area (top-level keys)
        $k = Get-TomlKey $line
        if ($k -and $DS_KEYS -contains $k) {
            $oldv = Get-TomlValue $line
            Consume-Block $Lines ([ref]$script:idx)
            $Out.Add("$k = $(Get-DsTargetValue $k $ModelSlug $CatalogValue)")
            $insAt = $Out.Count
            $seen[$k] = $true
            continue
        }
        if ($k -and $DEL_ON_DS -contains $k) {
            Consume-Block $Lines ([ref]$script:idx)
            continue
        }
        $Out.Add($line)
        if ($k) { $insAt = $Out.Count }
        Update-ScanState $line
        $script:idx++
    }

    # insert any missing target keys right before the first section header
    $missing = @($DS_KEYS | Where-Object { -not $seen.Contains($_) })
    $final = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Out.Count; $i++) {
        if ($i -eq $insAt -and $missing.Count -gt 0) {
            foreach ($k in $missing) { $final.Add("$k = $(Get-DsTargetValue $k $ModelSlug $CatalogValue)") }
            $missing = @()
            if ($Out[$i].Trim().StartsWith('[')) { $final.Add('') }
        }
        $final.Add($Out[$i])
    }
    foreach ($k in $missing) { $final.Add("$k = $(Get-DsTargetValue $k $ModelSlug $CatalogValue)") }

    $final.Add('')
    $final.Add("[model_providers.$PROVIDER_ID]")
    $final.Add("name = `"$PROVIDER_ID`"")
    $final.Add("base_url = `"$BaseUrl`"")
    $final.Add('wire_api = "responses"')
    $final.Add("experimental_bearer_token = `"$ApiKey`"")

    Write-ConfigText $final.ToArray()
}

function Get-DsTargetValue {
    param([string]$Key, [string]$ModelSlug, [string]$CatalogValue)
    switch ($Key) {
        'model'                  { return "`"$ModelSlug`"" }
        'model_provider'         { return "`"$PROVIDER_ID`"" }
        'preferred_auth_method'  { return '"apikey"' }
        'forced_login_method'    { return '"api"' }
        'model_reasoning_effort' { return '"high"' }
        'model_catalog_json'     { return "`"$CatalogValue`"" }
        default                  { return '""' }
    }
}

function Invoke-DeepSeekSwitch {
    param([string]$ModelSlug)

    Write-Head "Switching Codex to DeepSeek ($($DS_SLUG_TO_NAME[$ModelSlug]) / $ModelSlug)"
    $key = Get-DeepSeekApiKey
    Save-DeepSeekKey $key

    Backup-Config
    Write-DeepSeekConfig -ModelSlug $ModelSlug -ApiKey $key -BaseUrl $DEFAULT_BASE_URL -CatalogValue $CatalogValue
    $ok = Ensure-ModelsJson

    $state = @(
        "state=deepseek"
        "model_slug=$ModelSlug"
        "official_model=$OFFICIAL_MODEL"
        "switched_at=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    )
    [System.IO.File]::WriteAllText($SwitchState, (($state -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Ok "config.toml updated: model = `"$ModelSlug`""
    if ($ok) { Write-Ok 'models.json ready' } else { Write-Warn 'models.json could not be restored (see note above)' }
    Write-Ok "API key remembered in codex-switch\api-key.txt"
    Write-Host ''
    Write-Warn 'Fully quit the ChatGPT desktop app and reopen it, or the change will not take effect'
    Write-Host '   (right-click the taskbar tray icon and choose Quit; closing the window leaves it running)'
    Write-Host ''
}

# ---------------------------------------------------------------- official side
function Write-OfficialConfig {
    $Lines = Read-ConfigLines
    $Out   = New-Object System.Collections.Generic.List[string]
    $seen  = @{}
    $script:idx = 0
    $curSection = ''
    $skipSection = $false
    $insAt = 0
    $script:Depth = 0; $script:MlState = ''

    while ($script:idx -lt $Lines.Count) {
        $line = $Lines[$script:idx]
        $trimmed = $line.Trim()
        $isHeader = (-not $script:MlState) -and ($script:Depth -eq 0) -and $trimmed.StartsWith('[')

        if ($isHeader) {
            $hdr = Get-SectionName $line
            $curSection = $hdr
            $skipSection = ($hdr -eq "model_providers.$PROVIDER_ID") -or
                           ($hdr -like "model_providers.$PROVIDER_ID.*") -or
                           ($hdr -eq 'profiles') -or ($hdr -like 'profiles.*')
            Update-ScanState $line
            $script:idx++
            if (-not $skipSection) { $Out.Add($line) }
            continue
        }

        if ($curSection) {
            if ($skipSection) { Update-ScanState $line; $script:idx++; continue }
            $Out.Add($line)
            Update-ScanState $line
            $script:idx++
            continue
        }

        $k = Get-TomlKey $line
        if ($k -eq 'model' -or $k -eq 'model_reasoning_effort' -or $k -eq 'service_tier') {
            $newv = switch ($k) {
                'model'                  { "`"$OFFICIAL_MODEL`"" }
                'model_reasoning_effort' { "`"$OFFICIAL_EFFORT`"" }
                'service_tier'           { "`"$OFFICIAL_SERVICE`"" }
            }
            Consume-Block $Lines ([ref]$script:idx)
            $Out.Add("$k = $newv")
            $insAt = $Out.Count
            $seen[$k] = $true
            continue
        }
        if ($k -and $REMOVE_ON_OFFICIAL -contains $k) {
            Consume-Block $Lines ([ref]$script:idx)
            continue
        }
        $Out.Add($line)
        if ($k) { $insAt = $Out.Count }
        Update-ScanState $line
        $script:idx++
    }

    $desired = @('model', 'model_reasoning_effort', 'service_tier')
    $missing = @($desired | Where-Object { -not $seen.Contains($_) })
    $final = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Out.Count; $i++) {
        if ($i -eq $insAt -and $missing.Count -gt 0) {
            foreach ($k in $missing) {
                $newv = switch ($k) {
                    'model'                  { "`"$OFFICIAL_MODEL`"" }
                    'model_reasoning_effort' { "`"$OFFICIAL_EFFORT`"" }
                    'service_tier'           { "`"$OFFICIAL_SERVICE`"" }
                }
                $final.Add("$k = $newv")
            }
            $missing = @()
            if ($Out[$i].Trim().StartsWith('[')) { $final.Add('') }
        }
        $final.Add($Out[$i])
    }
    foreach ($k in $missing) {
        $newv = switch ($k) {
            'model'                  { "`"$OFFICIAL_MODEL`"" }
            'model_reasoning_effort' { "`"$OFFICIAL_EFFORT`"" }
            'service_tier'           { "`"$OFFICIAL_SERVICE`"" }
        }
        $final.Add("$k = $newv")
    }

    Write-ConfigText $final.ToArray()
}

function Resolve-DsModel {
    param([string]$M)
    $m = $M.Trim().ToLower()
    if (-not $m) { return $DEFAULT_DS_MODEL }
    if ($DS_MODELS.ContainsKey($m)) { return $DS_MODELS[$m] }
    if ($DS_MODELS.Values -contains $m) { return $m }
    Die "Unknown DeepSeek model '$M'. Use flash, pro, vision, or a full slug such as deepseek-v4-pro."
}

function Invoke-OfficialSwitch {
    Write-Head "Switching Codex back to the official configuration ($OFFICIAL_MODEL)"

    # Remember the DeepSeek key before we strip the provider block, so the next
    # switch back to DeepSeek is still one command.
    $dsKey = Get-ProviderKeyFromConfig
    if ($dsKey) { Save-DeepSeekKey $dsKey }

    Backup-Config
    Write-OfficialConfig

    # Hide the DeepSeek model catalog while on official; keep a private copy.
    New-Item -ItemType Directory -Force -Path $SwitchDir | Out-Null
    if (Test-Path -LiteralPath $ModelsPath) {
        Copy-Item -LiteralPath $ModelsPath -Destination $SwitchModels -Force
        Remove-Item -LiteralPath $ModelsPath -Force
        Write-Ok "DeepSeek catalog archived to codex-switch\models.json (removed from active use)"
    } else {
        Write-Dim '   models.json was not present; nothing to archive'
    }

    $state = @(
        "state=official"
        "official_model=$OFFICIAL_MODEL"
        "switched_at=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    )
    [System.IO.File]::WriteAllText($SwitchState, (($state -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Ok "config.toml restored: model = `"$OFFICIAL_MODEL`""
    Write-Host ''
    Write-Warn 'Fully quit the ChatGPT desktop app and reopen it, or the change will not take effect'
    Write-Host '   (right-click the taskbar tray icon and choose Quit; closing the window leaves it running)'
    Write-Host ''
}

# ---------------------------------------------------------------- status
function Invoke-Status {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Warn "config.toml not found: $ConfigPath"
        return
    }
    $content = [System.IO.File]::ReadAllText($ConfigPath)
    $isDs = $content -match '(?m)^\s*model_provider\s*=\s*"deepseek"' -or
            $content -match '(?m)^\s*model\s*=\s*"deepseek-'

    $model    = (($content -split "`n") | Where-Object { $_ -match '^\s*model\s*=' } | Select-Object -First 1)
    $provider = (($content -split "`n") | Where-Object { $_ -match '^\s*model_provider\s*=' } | Select-Object -First 1)
    if ($model) { $model = $model.Trim() }
    if ($provider) { $provider = $provider.Trim() }

    Write-Head "Current Codex configuration  ($CodexHome)"
    if ($isDs) {
        Write-Ok 'Profile: DeepSeek'
    } else {
        Write-Ok 'Profile: official (OpenAI)'
    }
    if ($model)    { Write-Host "  $model" }
    if ($provider) { Write-Host "  $provider" }
    Write-Host ('  models.json present: ' + (Test-Path -LiteralPath $ModelsPath))
    Write-Host ('  archived catalog:    ' + (Test-Path -LiteralPath $SwitchModels))
    Write-Host ('  stored API key:      ' + (Test-Path -LiteralPath $SwitchKey))
}

# ---------------------------------------------------------------- menu
function Invoke-Menu {
    Write-Head 'Codex provider switcher'
    Write-Dim "Codex directory: $CodexHome"
    Write-Dim "Official model : $OFFICIAL_MODEL"
    Write-Host ''
    Write-Host '  d. Switch to DeepSeek (vision)'
    Write-Host '     .\codex-switch.ps1 ds [flash|pro|vision]'
    Write-Host '  o. Switch back to official'
    Write-Host '     .\codex-switch.ps1 off'
    Write-Host '  s. Show current state'
    Write-Host '  q. Quit'
    Write-Host ''
    $ans = (Read-Host 'Choice [d/o/s]').Trim().ToLower()
    switch ($ans) {
        'd' { Invoke-DeepSeekSwitch -ModelSlug $DEFAULT_DS_MODEL }
        'o' { Invoke-OfficialSwitch }
        's' { Invoke-Status }
        default { Write-Dim 'Nothing done.' }
    }
}

# ---------------------------------------------------------------- main
$t = $Target.Trim().ToLower()
if (-not $t) { Invoke-Menu; return }

switch ($t) {
    'ds'  { Invoke-DeepSeekSwitch -ModelSlug (Resolve-DsModel $Model) }
    'deepseek' { Invoke-DeepSeekSwitch -ModelSlug (Resolve-DsModel $Model) }
    'off' { Invoke-OfficialSwitch }
    'official' { Invoke-OfficialSwitch }
    'restore' { Invoke-OfficialSwitch }
    'status' { Invoke-Status }
    'help' { Get-Help $PSCommandPath -Full }
    default { Die "Unknown target '$Target'." }
}
