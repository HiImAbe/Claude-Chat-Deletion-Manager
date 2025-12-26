#requires -Version 7.0
<#
.SYNOPSIS
    Uninstall Claude Chat Manager
.DESCRIPTION
    Removes runtime data created by Claude Chat Manager.
    
.PARAMETER Force
    Skip confirmation prompts
    
.PARAMETER IncludeConfig
    Also delete config.json (user settings)
    
.EXAMPLE
    .\Uninstall.ps1
    Interactive - removes cache, credentials, webview2, windowstate
    
.EXAMPLE
    .\Uninstall.ps1 -Force -IncludeConfig
    Remove everything including config
#>

param(
    [switch]$Force,
    [switch]$IncludeConfig
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "Claude Chat Manager - Uninstall" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

$app_root    = $PSScriptRoot
$appdata_dir = Join-Path $app_root "_AppData"

# Items in _AppData to remove (runtime data)
$runtime_items = @(
    @{ Path = Join-Path $appdata_dir "cache";       Name = "Cache" }
    @{ Path = Join-Path $appdata_dir "webview2";    Name = "WebView2 SDK" }
    @{ Path = Join-Path $appdata_dir "credentials"; Name = "Credentials" }
    @{ Path = Join-Path $appdata_dir "windowstate"; Name = "Window state" }
)

# Legacy locations
$legacy_items = @(
    @{ Path = Join-Path $app_root ".cache";       Name = ".cache" }
    @{ Path = Join-Path $app_root ".credentials"; Name = ".credentials" }
    @{ Path = Join-Path $app_root ".windowstate"; Name = ".windowstate" }
    @{ Path = Join-Path $app_root ".webview2";    Name = ".webview2" }
    @{ Path = Join-Path $app_root ".data";        Name = ".data" }
    @{ Path = Join-Path $app_root "_Config";      Name = "_Config" }
    @{ Path = Join-Path $env:APPDATA "ClaudeChatManager"; Name = "AppData legacy" }
)

$items_to_remove = @()

Write-Host "Scanning..." -ForegroundColor Yellow
Write-Host ""

# Runtime data in _AppData
foreach ($item in $runtime_items)
{
    if (Test-Path $item.Path)
    {
        $size = ""
        if (Test-Path $item.Path -PathType Container)
        {
            $bytes = (Get-ChildItem $item.Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($bytes -gt 1MB) { $size = " ({0:N1} MB)" -f ($bytes / 1MB) }
            elseif ($bytes -gt 1KB) { $size = " ({0:N0} KB)" -f ($bytes / 1KB) }
        }
        
        Write-Host "  [X] $($item.Name)$size" -ForegroundColor White
        $items_to_remove += $item
    }
}

# Config (only if requested)
$config_file = Join-Path $appdata_dir "config.json"
if (Test-Path $config_file)
{
    if ($IncludeConfig) {
        Write-Host "  [X] config.json" -ForegroundColor White
        $items_to_remove += @{ Path = $config_file; Name = "config.json" }
    } else {
        Write-Host "  [KEEP] config.json (use -IncludeConfig to remove)" -ForegroundColor DarkGray
    }
}

# Legacy items
$found_legacy = $false
foreach ($item in $legacy_items)
{
    if (Test-Path $item.Path)
    {
        if (-not $found_legacy) {
            Write-Host ""
            Write-Host "  Legacy locations:" -ForegroundColor Yellow
            $found_legacy = $true
        }
        Write-Host "  [X] $($item.Name)" -ForegroundColor White
        $items_to_remove += $item
    }
}

Write-Host ""

if ($items_to_remove.Count -eq 0)
{
    Write-Host "Nothing to remove - already clean!" -ForegroundColor Green
    Write-Host ""
    exit 0
}

# Confirm
if (-not $Force)
{
    $confirm = Read-Host "Remove these items? (y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Remove
Write-Host ""
Write-Host "Removing..." -ForegroundColor Cyan

foreach ($item in $items_to_remove)
{
    try {
        Remove-Item $item.Path -Recurse -Force -ErrorAction Stop
        Write-Host "  Removed: $($item.Name)" -ForegroundColor Green
    }
    catch {
        Write-Host "  Failed: $($item.Name) - $_" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host ""
Write-Host "To fully remove, delete: $app_root" -ForegroundColor Yellow
Write-Host ""
