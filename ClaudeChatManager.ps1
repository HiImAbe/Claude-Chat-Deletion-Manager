#requires -Version 7.0
<#
.SYNOPSIS
    Claude Chat Manager - Entry Point
.DESCRIPTION
    Loads STREAM layers and starts the application.
    
    STREAM Architecture:
    S_Structures  - What things ARE (data shapes)
    T_Tasks       - What you DO (operations)
    R_Records     - What's happening NOW (state)
    E_Events      - What happens WHEN (orchestration)
    A_Adapters    - Interface to outside (ViewModel-like)
    M_Markup      - Presentation (XAML)
    _Auxiliaries  - Domain-agnostic utilities
    _AppData      - Configuration and runtime data
#>

param([switch]$ShowUI = $true)

$ErrorActionPreference = 'Stop'

#region Assembly Loading

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsFormsIntegration

#endregion

#region Layer Loading

$script_root = $PSScriptRoot

# AppData (config + runtime) - load first
. "$script_root\_AppData\Defaults.ps1"
. "$script_root\_AppData\ConfigManager.ps1"

Write-Host "Claude Chat Manager v3.0 (STREAM)" -ForegroundColor Cyan
[void](Initialize-Config -AppRoot $script_root)

# Structures (Layer 1)
. "$script_root\S_Structures\Constants.ps1"
. "$script_root\S_Structures\ChatItem.ps1"
Initialize-Constants

# Auxiliaries (sideways)
. "$script_root\_Auxiliaries\GeneralUtility.ps1"
. "$script_root\_Auxiliaries\SearchUtility.ps1"
. "$script_root\_Auxiliaries\CredentialUtility.ps1"
. "$script_root\_Auxiliaries\WindowUtility.ps1"
. "$script_root\_Auxiliaries\WebView2Utility.ps1"
. "$script_root\_Auxiliaries\CacheUtility.ps1"

# Records (Layer 3)
. "$script_root\R_Records\AppState.ps1"
. "$script_root\R_Records\UIState.ps1"

# Tasks (Layer 2)
. "$script_root\T_Tasks\WebViewTasks.ps1"
. "$script_root\T_Tasks\LoginTasks.ps1"
. "$script_root\T_Tasks\FetchTasks.ps1"
. "$script_root\T_Tasks\ExportTasks.ps1"
. "$script_root\T_Tasks\DeleteTasks.ps1"
. "$script_root\T_Tasks\IndexTasks.ps1"

# Events (Layer 4)
. "$script_root\E_Events\ChatEvents.ps1"
. "$script_root\E_Events\UIWiring.ps1"

# Adapters (Layer 5)
. "$script_root\A_Adapters\ChatAdapter.ps1"

#endregion

#region Main Application

function Start-ClaudeChatManager
{
    # Initialize WebView2 SDK
    if (-not (Initialize-WebView2Sdk)) { return }
    
    # Load cached index
    $script:_index_cache = Get-IndexCache
    if ($script:_index_cache.Count -gt 0) {
        Write-Host "  Index cache: $($script:_index_cache.Count) items" -ForegroundColor DarkGray
    }
    
    # Load Markup (Layer 6)
    $xaml_path = Join-Path $script_root "M_Markup\MainWindow.xaml"
    $window = [System.Windows.Markup.XamlReader]::Parse((Get-Content $xaml_path -Raw))
    
    # Create Adapter (Layer 5)
    $adapter = [ChatAdapter]::new()
    $adapter.InitializeUI($window)
    
    # Wire all events (Layer 4)
    Initialize-UIEvents -Window $window -Adapter $adapter
    
    # Show window
    [void]$window.ShowDialog()
    
    # Cleanup
    $script:_main_window  = $null
    $script:_main_adapter = $null
    $script:_index_cache  = $null
}

#endregion

if ($ShowUI) { Start-ClaudeChatManager }
