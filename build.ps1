#Requires -Version 5.1
<#
.SYNOPSIS
    Build the single-file CodexSwitcher.exe (WinForms, .NET Framework 4.x).
.EXAMPLE
    .\build.ps1                      # -> .\CodexSwitcher.exe
    .\build.ps1 -OutDir .\release    # -> .\release\CodexSwitcher.exe
#>
param(
    [string]$OutDir = '.'
)

$ErrorActionPreference = 'Stop'

$repo   = $PSScriptRoot
$srcDir = Join-Path $repo 'src'
$assets = Join-Path $repo 'assets'
$resJson = Join-Path $assets 'deepseek-models.json'

if (-not (Test-Path -LiteralPath $resJson)) {
    throw "Missing model catalog: $resJson"
}

$csc = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $csc) {
    throw 'csc.exe not found. This machine needs the .NET Framework 4.x (built into Windows).'
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exe = Join-Path $OutDir 'CodexSwitcher.exe'

Write-Host 'Compiling...'
& $csc /nologo /target:winexe /codepage:65001 `
    /out:"$exe" `
    /resource:"$resJson,deepseek-models.json" `
    /r:System.dll /r:System.Core.dll `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    /r:Microsoft.VisualBasic.dll `
    (Join-Path $srcDir 'codex-switcher.cs') `
    (Join-Path $srcDir 'mainform.cs')

if ($LASTEXITCODE -ne 0) { throw "Build failed (exit $LASTEXITCODE)." }

Write-Host ''
Write-Host "[OK] Built: $exe ($('{0:N0}' -f (Get-Item -LiteralPath $exe).Length) bytes)"
