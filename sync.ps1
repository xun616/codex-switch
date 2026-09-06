#Requires -Version 5.1
<#
.SYNOPSIS
    Stage all changes, commit, then pull --rebase and push to origin.
    Use this to keep the local repo in sync with GitHub in one command.

.EXAMPLE
    .\sync.ps1
    .\sync.ps1 "docs: update usage"
#>
param(
    [string]$Message = "update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

git add -A
$dirty = git diff --cached --quiet 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host 'No local changes to commit.'
} else {
    git commit -q -m $Message
    Write-Host "[OK] committed: $Message"
}

git pull --rebase origin main 2>&1 | Out-Host
git push origin main 2>&1 | Out-Host
Write-Host ''
Write-Host 'Sync done.'
