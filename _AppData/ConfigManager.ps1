#requires -Version 7.0
<#
.SYNOPSIS
    Configuration management
.DESCRIPTION
    Loads, saves, and merges configuration with defaults.
    
    All app data is stored in _AppData/:
    - config.json      - User-editable settings
    - cache/           - Metadata and index cache
    - webview2/        - WebView2 SDK and browser data  
    - credentials      - Encrypted session
    - windowstate      - Window position/size
#>

function Initialize-Config
{
    <#
    .SYNOPSIS
        Loads config from file and merges with defaults
    #>
    param(
        [Parameter(Mandatory)]
        [string]$AppRoot
    )
    
    $appdata_root = Join-Path $AppRoot "_AppData"
    $config_path  = Join-Path $appdata_root "config.json"
    
    # Start with defaults
    $config = Copy-HashtableDeep -Source $script:CONFIG_DEFAULTS
    
    # Define all paths (all in _AppData)
    $config.Paths = @{
        AppDataRoot     = $appdata_root
        ConfigFile      = $config_path
        CacheDir        = Join-Path $appdata_root "cache"
        WebView2Data    = Join-Path $appdata_root "webview2"
        CredentialsFile = Join-Path $appdata_root "credentials"
        WindowStateFile = Join-Path $appdata_root "windowstate"
    }
    
    # Load user config if exists (only override non-path settings)
    if (Test-Path $config_path)
    {
        try
        {
            $user_config = Get-Content $config_path -Raw | ConvertFrom-Json -AsHashtable
            
            # Merge each section except Paths
            foreach ($section in @('Api', 'UI', 'Cache', 'Export'))
            {
                if ($user_config.ContainsKey($section) -and $user_config[$section] -is [hashtable])
                {
                    $config[$section] = Merge-Hashtables -Base $config[$section] -Override $user_config[$section]
                }
            }
            
            Write-Host "  Config loaded" -ForegroundColor DarkGray
        }
        catch
        {
            Write-Host "  Warning: Could not parse config.json, using defaults" -ForegroundColor Yellow
        }
    }
    else
    {
        # Create default config file
        Save-Config -Config $config -Path $config_path
        Write-Host "  Created default config" -ForegroundColor DarkGray
    }
    
    # Ensure required directories exist
    foreach ($dir in @($config.Paths.CacheDir, $config.Paths.WebView2Data))
    {
        if (-not (Test-Path $dir))
        {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
    }
    
    # Migrate legacy files from old locations
    Move-LegacyData -AppRoot $AppRoot -Config $config
    
    # Store in script scope for global access
    $script:CONFIG = $config
    
    return $config
}

function Move-LegacyData
{
    <#
    .SYNOPSIS
        Migrates data from old scattered locations to _AppData/
    #>
    param(
        [string]$AppRoot,
        [hashtable]$Config
    )
    
    # Old locations -> new locations
    $migrations = @(
        @{ Old = ".credentials";  New = $Config.Paths.CredentialsFile }
        @{ Old = ".windowstate";  New = $Config.Paths.WindowStateFile }
        @{ Old = ".cache";        New = $Config.Paths.CacheDir;       IsDir = $true }
        @{ Old = ".webview2";     New = $Config.Paths.WebView2Data;   IsDir = $true }
    )
    
    # Also check .data folder from intermediate version
    $dot_data = Join-Path $AppRoot ".data"
    if (Test-Path $dot_data)
    {
        $migrations += @(
            @{ Old = ".data\credentials";  New = $Config.Paths.CredentialsFile }
            @{ Old = ".data\windowstate";  New = $Config.Paths.WindowStateFile }
            @{ Old = ".data\cache";        New = $Config.Paths.CacheDir;       IsDir = $true }
            @{ Old = ".data\webview2";     New = $Config.Paths.WebView2Data;   IsDir = $true }
        )
    }
    
    foreach ($m in $migrations)
    {
        $old_path = Join-Path $AppRoot $m.Old
        
        if (Test-Path $old_path)
        {
            # Don't overwrite if new location already has data
            $new_has_data = (Test-Path $m.New) -and (-not $m.IsDir -or (Get-ChildItem $m.New -ErrorAction SilentlyContinue).Count -gt 0)
            
            if (-not $new_has_data)
            {
                try
                {
                    if ($m.IsDir)
                    {
                        if (-not (Test-Path $m.New)) { New-Item -Path $m.New -ItemType Directory -Force | Out-Null }
                        Copy-Item "$old_path\*" $m.New -Recurse -Force
                        Remove-Item $old_path -Recurse -Force
                    }
                    else
                    {
                        Move-Item $old_path $m.New -Force
                    }
                    Write-Host "  Migrated: $($m.Old)" -ForegroundColor DarkGray
                }
                catch
                {
                    Write-Host "  Warning: Could not migrate $($m.Old): $_" -ForegroundColor Yellow
                }
            }
            else
            {
                # New location has data, just remove old
                Remove-Item $old_path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    
    # Clean up empty .data folder if it exists
    if ((Test-Path $dot_data) -and (Get-ChildItem $dot_data -ErrorAction SilentlyContinue).Count -eq 0)
    {
        Remove-Item $dot_data -Force -ErrorAction SilentlyContinue
    }
    
    # Clean up old _Config folder if it exists and is empty (or just has config.json we can move)
    $old_config = Join-Path $AppRoot "_Config"
    if (Test-Path $old_config)
    {
        $old_config_json = Join-Path $old_config "config.json"
        if ((Test-Path $old_config_json) -and -not (Test-Path $Config.Paths.ConfigFile))
        {
            Move-Item $old_config_json $Config.Paths.ConfigFile -Force -ErrorAction SilentlyContinue
            Write-Host "  Migrated: _Config/config.json" -ForegroundColor DarkGray
        }
        
        # Remove old _Config if only .ps1 files remain (those are now in _AppData)
        $remaining = Get-ChildItem $old_config -Exclude "*.ps1" -ErrorAction SilentlyContinue
        if ($remaining.Count -eq 0)
        {
            Remove-Item $old_config -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Remove legacy AppData folder
    $appdata_legacy = Join-Path $env:APPDATA "ClaudeChatManager"
    if (Test-Path $appdata_legacy)
    {
        Remove-Item $appdata_legacy -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Save-Config
{
    param(
        [hashtable]$Config,
        [string]$Path
    )
    
    try
    {
        # Only save user-editable sections
        $save_config = @{
            Api    = $Config.Api
            UI     = $Config.UI
            Cache  = $Config.Cache
            Export = $Config.Export
        }
        
        $json = $save_config | ConvertTo-Json -Depth 4
        Set-Content -Path $Path -Value $json -Encoding UTF8
    }
    catch
    {
        Write-Host "  Warning: Could not save config: $_" -ForegroundColor Yellow
    }
}

function Get-ConfigValue
{
    param([string]$Path)
    
    $parts  = $Path -split '\.'
    $result = $script:CONFIG
    
    foreach ($part in $parts)
    {
        if ($result -is [hashtable] -and $result.ContainsKey($part))
        {
            $result = $result[$part]
        }
        else
        {
            return $null
        }
    }
    
    return $result
}

function Copy-HashtableDeep
{
    param([hashtable]$Source)
    
    $copy = @{}
    foreach ($key in $Source.Keys)
    {
        if ($Source[$key] -is [hashtable])
        {
            $copy[$key] = Copy-HashtableDeep -Source $Source[$key]
        }
        else
        {
            $copy[$key] = $Source[$key]
        }
    }
    return $copy
}

function Merge-Hashtables
{
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )
    
    $result = Copy-HashtableDeep -Source $Base
    
    foreach ($key in $Override.Keys)
    {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable])
        {
            $result[$key] = Merge-Hashtables -Base $result[$key] -Override $Override[$key]
        }
        else
        {
            $result[$key] = $Override[$key]
        }
    }
    
    return $result
}
