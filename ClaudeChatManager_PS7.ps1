using namespace System.ComponentModel
using namespace System.Collections.ObjectModel

#requires -Version 7.0

<#
.SYNOPSIS
    Claude Chat Manager v3 - WebView2 
.DESCRIPTION
    Manage Claude.ai conversations
.NOTES
    Version: 3.0
    Requires: PowerShell 7+, WebView2 Runtime
#>

#region Version Check and Bootstrap

if ($PSVersionTable.PSVersion.Major -lt 7)
{
    $Host.UI.WriteErrorLine("PowerShell 7+ required. Current version: $($PSVersionTable.PSVersion)")
    $powershell_path = Get-Command pwsh -ErrorAction SilentlyContinue
    
    if ($powershell_path)
    {
        Write-Host "Relaunching with PowerShell 7..." -ForegroundColor Yellow
        Start-Process pwsh -ArgumentList "-NoExit", "-File", "`"$PSCommandPath`""
    }
    else
    {
        Write-Host @"

Install PowerShell 7:
  winget install Microsoft.PowerShell

Then run: pwsh "$PSCommandPath"
"@ -ForegroundColor Red
        Read-Host "Press Enter to exit"
    }
    exit 1
}

#endregion

#region Assembly Loading

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsFormsIntegration

#endregion

#region Constants

$script:CONSTANTS = @{
    # Timing
    SEARCH_DEBOUNCE_MS       = 150
    WEBVIEW_INIT_DELAY_MS    = 1500
    SELECTION_POLL_MS        = 250
    SESSION_CHECK_MINUTES    = 15
    POLL_INTERVAL_MS         = 100
    POLL_WAIT_MS             = 5
    API_REQUEST_DELAY_MS     = 80
    DELETE_REQUEST_DELAY_MS  = 150
    EXPORT_REQUEST_DELAY_MS  = 100
    INDEX_REQUEST_DELAY_MS   = 50
    
    # Limits
    MAX_PAGINATION_PAGES     = 200
    MAX_CONTENT_LENGTH       = 50000
    FETCH_TIMEOUT_SECONDS    = 180
    EXPORT_TIMEOUT_MINUTES   = 10
    INDEX_TIMEOUT_MINUTES    = 10
    API_CHECK_TIMEOUT_MS     = 10000
    
    # UI
    SNIPPET_CONTEXT_CHARS    = 50
    TITLE_SNIPPET_CHARS      = 30
    CONTENT_SNIPPET_CHARS    = 60
    
    # WebView2
    WEBVIEW2_SDK_VERSION     = "1.0.2592.51"
    WEBVIEW2_NUGET_URL       = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2"
}

#endregion

#region Configuration

$script:config = @{
    path            = Join-Path $env:APPDATA "ClaudeChatManager"
    settings_file   = $null  # Set after path
    webview2_path   = Join-Path $env:LOCALAPPDATA "ClaudeChatManager\WebView2"
    webview2_data   = $null  # Set after path
}

$script:config.settings_file = Join-Path $script:config.path "settings.json"
$script:config.webview2_data = Join-Path $script:config.path "WebView2Data"

# Ensure directories exist
foreach ($path in @($script:config.path, $script:config.webview2_data))
{
    if (-not (Test-Path $path))
    {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

Write-Host "`nClaude Chat Manager v3" -ForegroundColor Cyan
Write-Host "======================" -ForegroundColor Cyan
Write-Host "Config: $($script:config.path)" -ForegroundColor DarkGray

#endregion

#region Application State

$script:app_state = @{
    org_id          = $null
    cookie          = $null
    all_chats       = $null  # ObservableCollection - initialized later
    has_loaded_once = $false
    webview2_ready  = $false
    is_busy         = $false
    deleted_buffer  = @()    # Recently deleted items for undo
}

$script:ui_cache = @{
    collection_view      = $null
    match_column         = $null
    header_checkbox      = $null
    current_search       = ""
    current_search_mode  = $null
    sidebar_width        = 180
    sidebar_collapsed    = $false
}

$script:ui_state = @{
    showing_selected_only = $false
    sort_column           = "Updated"
    sort_direction        = "Descending"
}

$script:window_state = @{
    file = Join-Path $script:config.path "window_state.json"
}

#endregion

#region ChatItem Class with INotifyPropertyChanged

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;

public class ChatItem : INotifyPropertyChanged
{
    private string _id;
    private string _name;
    private string _nameLower;
    private DateTime _updated;
    private bool _selected;
    private string _content;
    private string _contentLower;
    private bool _contentIndexed;
    private string _matchType;
    private string _matchPreview;

    public event PropertyChangedEventHandler PropertyChanged;

    protected virtual void OnPropertyChanged(string propertyName)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    public string Id
    {
        get { return _id ?? ""; }
        set { _id = value; OnPropertyChanged("Id"); }
    }

    public string Name
    {
        get { return _name ?? ""; }
        set 
        { 
            _name = value; 
            _nameLower = value?.ToLowerInvariant() ?? "";
            OnPropertyChanged("Name"); 
            OnPropertyChanged("NameLower");
        }
    }

    // Pre-computed lowercase for fast filtering
    public string NameLower
    {
        get { return _nameLower ?? ""; }
    }

    public DateTime Updated
    {
        get { return _updated; }
        set { _updated = value; OnPropertyChanged("Updated"); }
    }

    public bool Selected
    {
        get { return _selected; }
        set 
        { 
            if (_selected != value)
            {
                _selected = value; 
                OnPropertyChanged("Selected"); 
            }
        }
    }

    public string Content
    {
        get { return _content ?? ""; }
        set 
        { 
            _content = value; 
            _contentLower = value?.ToLowerInvariant() ?? "";
            OnPropertyChanged("Content"); 
            OnPropertyChanged("ContentLower");
        }
    }

    // Pre-computed lowercase for fast filtering
    public string ContentLower
    {
        get { return _contentLower ?? ""; }
    }

    public bool ContentIndexed
    {
        get { return _contentIndexed; }
        set { _contentIndexed = value; OnPropertyChanged("ContentIndexed"); }
    }

    public string MatchType
    {
        get { return _matchType ?? ""; }
        set { _matchType = value; OnPropertyChanged("MatchType"); }
    }

    public string MatchPreview
    {
        get { return _matchPreview ?? ""; }
        set { _matchPreview = value; OnPropertyChanged("MatchPreview"); }
    }
}
'@ -ReferencedAssemblies 'System.ComponentModel.Primitives', 'System.ObjectModel'

#endregion

#region WebView2 Runtime Check

function Test-WebView2Runtime
{
    <#
    .SYNOPSIS
        Checks if WebView2 Runtime is installed
    .OUTPUTS
        Boolean indicating if runtime is available
    #>
    
    # Check for Evergreen WebView2 Runtime
    $runtime_paths = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    )
    
    foreach ($path in $runtime_paths)
    {
        if (Test-Path $path)
        {
            $version = Get-ItemProperty -Path $path -Name "pv" -ErrorAction SilentlyContinue
            if ($version -and $version.pv)
            {
                Write-Host "WebView2 Runtime found: $($version.pv)" -ForegroundColor DarkGray
                return $true
            }
        }
    }
    
    # Also check if Edge is installed (can serve as WebView2 host)
    $edge_path = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (Test-Path $edge_path)
    {
        Write-Host "Microsoft Edge found (can host WebView2)" -ForegroundColor DarkGray
        return $true
    }
    
    return $false
}

function Show-WebView2RuntimeError
{
    $message = @"
WebView2 Runtime is required but not installed.

Please install one of the following:
1. Microsoft Edge (recommended)
2. WebView2 Runtime from:
   https://developer.microsoft.com/en-us/microsoft-edge/webview2/

After installing, restart this application.
"@
    
    [System.Windows.MessageBox]::Show($message, "WebView2 Runtime Required", 'OK', 'Error')
}

#endregion

#region WebView2 SDK Bootstrap

function Initialize-WebView2Sdk
{
    <#
    .SYNOPSIS
        Downloads and loads WebView2 SDK if needed
    .OUTPUTS
        Boolean indicating success
    #>
    
    # First check runtime
    if (-not (Test-WebView2Runtime))
    {
        Show-WebView2RuntimeError
        return $false
    }
    
    $extract_path = Join-Path $script:config.webview2_path "extracted"
    
    # Find existing DLLs
    $dll_info = Find-WebView2Dlls -BasePath $extract_path
    
    if (-not $dll_info)
    {
        # Clean up any partial installation
        if (Test-Path $extract_path)
        {
            Remove-Item $extract_path -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        $result = [System.Windows.MessageBox]::Show(
            "WebView2 SDK required for browser integration.`n`nDownload from nuget.org (~5MB)?",
            "Download WebView2 SDK?", 'YesNo', 'Question')
        
        if ($result -ne 'Yes')
        {
            return $false
        }
        
        Write-Host "Downloading WebView2 SDK..." -ForegroundColor Cyan
        
        try
        {
            New-Item -ItemType Directory -Path $script:config.webview2_path -Force | Out-Null
            
            $nuget_url    = "$($script:CONSTANTS.WEBVIEW2_NUGET_URL)/$($script:CONSTANTS.WEBVIEW2_SDK_VERSION)"
            $package_path = Join-Path $script:config.webview2_path "package.zip"
            
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            
            $progress_preference_backup = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'  # Speed up download
            
            Invoke-WebRequest -Uri $nuget_url -OutFile $package_path -UseBasicParsing
            
            $ProgressPreference = $progress_preference_backup
            
            Write-Host "Extracting SDK..." -ForegroundColor Cyan
            Expand-Archive -Path $package_path -DestinationPath $extract_path -Force
            Remove-Item $package_path -Force
            
            # Copy to lib_manual for consistent path
            $source_path = Join-Path $extract_path "lib\netcoreapp3.0"
            $dest_path   = Join-Path $extract_path "lib_manual\netcoreapp3.0"
            
            if (Test-Path $source_path)
            {
                New-Item -ItemType Directory -Path $dest_path -Force | Out-Null
                Copy-Item "$source_path\*" $dest_path -Force
            }
            
            $dll_info = Find-WebView2Dlls -BasePath $extract_path
        }
        catch
        {
            Write-Host "Download failed: $_" -ForegroundColor Red
            [System.Windows.MessageBox]::Show(
                "Failed to download WebView2 SDK:`n`n$($_.Exception.Message)",
                "Download Error", 'OK', 'Error')
            return $false
        }
    }
    
    if (-not $dll_info)
    {
        Write-Host "WebView2 DLLs not found after extraction" -ForegroundColor Red
        return $false
    }
    
    # Load assemblies
    Write-Host "Loading WebView2 from: $($dll_info.lib_path)" -ForegroundColor DarkGray
    
    try
    {
        Add-Type -Path $dll_info.core_dll
        Add-Type -Path $dll_info.winforms_dll
        Write-Host "WebView2 SDK loaded successfully" -ForegroundColor Green
        $script:app_state.webview2_ready = $true
        return $true
    }
    catch
    {
        Write-Host "Failed to load WebView2 assemblies: $_" -ForegroundColor Red
        [System.Windows.MessageBox]::Show(
            "Failed to load WebView2 SDK:`n`n$($_.Exception.Message)",
            "Load Error", 'OK', 'Error')
        return $false
    }
}

function Find-WebView2Dlls
{
    param([string]$BasePath)
    
    $search_paths = @(
        "lib_manual\netcoreapp3.0",
        "lib\netcoreapp3.0",
        "lib\net462",
        "lib\net45"
    )
    
    foreach ($relative_path in $search_paths)
    {
        $test_path = Join-Path $BasePath $relative_path
        $core_dll  = Join-Path $test_path "Microsoft.Web.WebView2.Core.dll"
        
        if (Test-Path $core_dll)
        {
            return @{
                lib_path     = $test_path
                core_dll     = $core_dll
                winforms_dll = Join-Path $test_path "Microsoft.Web.WebView2.WinForms.dll"
            }
        }
    }
    
    return $null
}

#endregion

#region Credential Storage

function Save-Credentials
{
    param(
        [Parameter(Mandatory)]
        [string]$OrgId,
        
        [Parameter(Mandatory)]
        [string]$Cookie
    )
    
    try
    {
        $secure_cookie = $Cookie | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString
        
        @{
            OrgId   = $OrgId
            Cookie  = $secure_cookie
            SavedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content $script:config.settings_file -Force
        
        return $true
    }
    catch
    {
        Write-Host "Failed to save credentials: $_" -ForegroundColor Red
        return $false
    }
}

function Get-SavedCredentials
{
    if (-not (Test-Path $script:config.settings_file))
    {
        return $null
    }
    
    try
    {
        $data = Get-Content $script:config.settings_file -Raw -ErrorAction Stop | ConvertFrom-Json
        
        if (-not $data.OrgId -or -not $data.Cookie)
        {
            Write-Host "Invalid credentials file format" -ForegroundColor Yellow
            return $null
        }
        
        $secure_string = $data.Cookie | ConvertTo-SecureString -ErrorAction Stop
        $cookie = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure_string))
        
        return @{
            org_id = $data.OrgId
            cookie = $cookie
        }
    }
    catch
    {
        Write-Host "Failed to read credentials: $_" -ForegroundColor Yellow
        return $null
    }
}

function Clear-Credentials
{
    if (Test-Path $script:config.settings_file)
    {
        Remove-Item $script:config.settings_file -Force -ErrorAction SilentlyContinue
    }
    
    # Also clear WebView2 cookies
    $cookies_path = Join-Path $script:config.webview2_data "EBWebView"
    if (Test-Path $cookies_path)
    {
        Remove-Item $cookies_path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region Reusable WebView2 Dialog Factory

function New-WebView2Operation
{
    <#
    .SYNOPSIS
        Creates a WebView2-based dialog for async operations
    .DESCRIPTION
        Factory function that standardizes WebView2 dialog creation with proper
        initialization, error handling, cancellation support, and cleanup.
    .PARAMETER Title
        Dialog window title
    .PARAMETER Owner
        Parent window
    .PARAMETER StatusText
        Initial status message
    .PARAMETER ShowProgress
        Whether to show a progress bar
    .PARAMETER ProgressIndeterminate
        Whether progress bar is indeterminate
    .PARAMETER ProgressColor
        Progress bar color
    .PARAMETER TimeoutSeconds
        Operation timeout in seconds
    .PARAMETER ShowCancel
        Whether to show cancel button
    .PARAMETER OnWebViewReady
        Scriptblock called when WebView2 is initialized and navigated to Claude
    .PARAMETER OnCancelled
        Scriptblock called if user cancels
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        
        [System.Windows.Window]$Owner,
        
        [string]$StatusText = "Initializing...",
        
        [bool]$ShowProgress = $true,
        
        [bool]$ProgressIndeterminate = $true,
        
        [string]$ProgressColor = "#3498db",
        
        [int]$TimeoutSeconds = 180,
        
        [bool]$ShowCancel = $true,
        
        [Parameter(Mandatory)]
        [scriptblock]$OnWebViewReady,
        
        [scriptblock]$OnCancelled
    )
    
    if (-not $script:app_state.webview2_ready)
    {
        [System.Windows.MessageBox]::Show("WebView2 not initialized.", "Error", 'OK', 'Error')
        return $null
    }
    
    # Build XAML dynamically
    $cancel_button_xaml = if ($ShowCancel) {
        '<Button x:Name="CancelBtn" Content="Cancel" Width="70" Height="24" HorizontalAlignment="Right" 
                 Margin="0,8,0,0" Background="#2a2a2a" Foreground="#888" BorderBrush="#3a3a3a" 
                 BorderThickness="1" FontSize="10"/>'
    } else { "" }
    
    $progress_xaml = if ($ShowProgress) {
        if ($ProgressIndeterminate) {
            "<ProgressBar Height=`"2`" Margin=`"0,12,0,0`" IsIndeterminate=`"True`" Foreground=`"$ProgressColor`" Background=`"#333`"/>"
        } else {
            "<ProgressBar x:Name=`"ProgressBar`" Height=`"2`" Margin=`"0,12,0,0`" Minimum=`"0`" Maximum=`"100`" Value=`"0`" Foreground=`"$ProgressColor`" Background=`"#333`"/>"
        }
    } else { "" }
    
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title" Height="140" Width="380" WindowStartupLocation="CenterOwner"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True">
    <Border Background="#1a1a1a" CornerRadius="8" BorderBrush="#333" BorderThickness="1">
        <Grid Margin="16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            
            <TextBlock Text="$Title" Foreground="#888" FontSize="11" FontWeight="SemiBold"/>
            
            <StackPanel Grid.Row="1" VerticalAlignment="Center" Margin="0,12,0,0">
                <TextBlock x:Name="StatusTxt" Text="$StatusText" Foreground="#aaa" FontSize="12"/>
                $progress_xaml
            </StackPanel>
            
            <StackPanel Grid.Row="2">
                $cancel_button_xaml
            </StackPanel>
            
            <Border x:Name="WebViewHost" Visibility="Collapsed" Width="1" Height="1"/>
        </Grid>
    </Border>
</Window>
"@
    
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    
    if ($Owner)
    {
        $window.Owner = $Owner
    }
    
    # Create operation state container
    $operation = @{
        window           = $window
        webview          = $null
        status_text      = $window.FindName('StatusTxt')
        progress_bar     = $window.FindName('ProgressBar')
        cancel_button    = $window.FindName('CancelBtn')
        webview_host     = $window.FindName('WebViewHost')
        is_cancelled     = $false
        is_complete      = $false
        result           = $null
        timers           = [System.Collections.ArrayList]::new()
        on_ready         = $OnWebViewReady
        on_cancelled     = $OnCancelled
    }
    
    # Store reference for event handlers
    $script:_current_operation = $operation
    
    # Setup WebView2
    $webview = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
    $creation_props = [Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties]::new()
    $creation_props.UserDataFolder = $script:config.webview2_data
    $webview.CreationProperties    = $creation_props
    $webview.Width                 = 1
    $webview.Height                = 1
    
    $forms_host       = [System.Windows.Forms.Integration.WindowsFormsHost]::new()
    $forms_host.Child = $webview
    $operation.webview_host.Child = $forms_host
    $operation.webview = $webview
    
    # Cancel button handler
    if ($operation.cancel_button)
    {
        $operation.cancel_button.Add_Click({
            $op = $script:_current_operation
            $op.is_cancelled = $true
            $op.status_text.Text = "Cancelling..."
            
            if ($op.on_cancelled)
            {
                & $op.on_cancelled
            }
            
            # Stop all timers
            foreach ($timer in $op.timers)
            {
                $timer.Stop()
            }
            
            $op.window.DialogResult = $false
            $op.window.Close()
        })
    }
    
    # WebView2 initialization
    $webview.Add_CoreWebView2InitializationCompleted({
        param($sender, $event_args)
        
        $op = $script:_current_operation
        
        if ($event_args.IsSuccess)
        {
            $op.status_text.Text = "Connecting..."
            $op.webview.CoreWebView2.Navigate("https://claude.ai/recents")
        }
        else
        {
            $op.status_text.Text = "Initialization failed"
            Write-Host "WebView2 init failed: $($event_args.InitializationException)" -ForegroundColor Red
        }
    })
    
    # Navigation complete - trigger the actual operation
    $webview.Add_NavigationCompleted({
        param($sender, $event_args)
        
        $op = $script:_current_operation
        
        if ($op.is_cancelled -or $op.is_complete)
        {
            return
        }
        
        if (-not $event_args.IsSuccess)
        {
            $op.status_text.Text = "Navigation failed"
            Write-Host "  Navigation failed!" -ForegroundColor Red
            return
        }
        
        $url = $op.webview.Source
        Write-Host "  Navigated to: $url" -ForegroundColor DarkGray
        
        if ($url.Host -eq 'claude.ai' -and $url.AbsolutePath -match 'recents|chat')
        {
            Write-Host "  URL matched, waiting for page load..." -ForegroundColor DarkGray
            
            # Delay slightly for page to fully load
            $delay_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $delay_timer.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.WEBVIEW_INIT_DELAY_MS)
            $op.timers.Add($delay_timer) | Out-Null
            
            $delay_timer.Add_Tick({
                param($sender, $event_args)
                
                $sender.Stop()
                $op = $script:_current_operation
                
                if ($op -and -not $op.is_cancelled)
                {
                    Write-Host "  Page ready, starting operation..." -ForegroundColor DarkGray
                    & $op.on_ready $op
                }
            })
            
            $delay_timer.Start()
        }
        else
        {
            Write-Host "  URL did not match expected pattern (recents|chat)" -ForegroundColor Yellow
            $op.status_text.Text = "Unexpected page - may need to login"
        }
    })
    
    # Timeout timer
    $timeout_timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timeout_timer.Interval = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $operation.timers.Add($timeout_timer) | Out-Null
    
    $timeout_timer.Add_Tick({
        param($sender, $event_args)
        
        $sender.Stop()
        $op = $script:_current_operation
        
        if ($op -and -not $op.is_complete)
        {
            $op.status_text.Text = "Operation timed out"
            Write-Host "Operation timed out after $TimeoutSeconds seconds" -ForegroundColor Yellow
            
            Start-Sleep -Milliseconds 500
            $op.window.DialogResult = $false
            $op.window.Close()
        }
    })
    
    # Window loaded - start WebView2
    $window.Add_Loaded({
        $op = $script:_current_operation
        
        try
        {
            $op.status_text.Text = "Initializing browser..."
            $init_task = $op.webview.EnsureCoreWebView2Async($null)
            
            while (-not $init_task.IsCompleted)
            {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
            
            # Start timeout after initialization
            $op.timers[-1].Start()  # Timeout timer is last
        }
        catch
        {
            $op.status_text.Text = "Browser init error"
            Write-Host "WebView2 init error: $_" -ForegroundColor Red
        }
    })
    
    # Window closing - cleanup
    $window.Add_Closing({
        $op = $script:_current_operation
        
        # Stop all timers
        foreach ($timer in $op.timers)
        {
            if ($timer) { $timer.Stop() }
        }
        
        # Dispose WebView2
        if ($op.webview)
        {
            try { $op.webview.Dispose() } catch { }
            $op.webview = $null
        }
        
        $script:_current_operation = $null
    })
    
    return $operation
}

function Complete-WebView2Operation
{
    <#
    .SYNOPSIS
        Marks operation as complete and closes dialog
    #>
    param(
        [Parameter(Mandatory)]
        $Operation,
        
        [bool]$Success = $true,
        
        $Result = $null
    )
    
    $Operation.is_complete = $true
    $Operation.result      = $Result
    
    # Stop all timers
    foreach ($timer in $Operation.timers)
    {
        if ($timer) { $timer.Stop() }
    }
    
    Start-Sleep -Milliseconds 300
    $Operation.window.DialogResult = $Success
    $Operation.window.Close()
}

#endregion

#region Helper Functions

function Invoke-WithDoEvents
{
    <#
    .SYNOPSIS
        Waits for async task while keeping UI responsive
    #>
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task]$Task,
        
        [int]$PollMs = 10
    )
    
    while (-not $Task.IsCompleted)
    {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds $PollMs
    }
    
    return $Task.Result
}

function Get-MatchSnippet
{
    <#
    .SYNOPSIS
        Extracts a snippet around a search match
    #>
    param(
        [string]$Text,
        [string]$SearchTerm,
        [int]$ContextChars = 50
    )
    
    if (-not $Text -or -not $SearchTerm)
    {
        return ""
    }
    
    $index = $Text.IndexOf($SearchTerm, [StringComparison]::OrdinalIgnoreCase)
    
    if ($index -lt 0)
    {
        return ""
    }
    
    $start = [Math]::Max(0, $index - $ContextChars)
    $end   = [Math]::Min($Text.Length, $index + $SearchTerm.Length + $ContextChars)
    
    $snippet = $Text.Substring($start, $end - $start)
    
    $prefix = if ($start -gt 0) { "..." } else { "" }
    $suffix = if ($end -lt $Text.Length) { "..." } else { "" }
    
    return "$prefix$snippet$suffix"
}

function ConvertFrom-JsonSafe
{
    <#
    .SYNOPSIS
        Safely parses JSON with error handling
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Json,
        
        [switch]$AsHashtable
    )
    
    try
    {
        if ($AsHashtable)
        {
            return $Json | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        else
        {
            return $Json | ConvertFrom-Json -ErrorAction Stop
        }
    }
    catch
    {
        Write-Host "JSON parse error: $_" -ForegroundColor Red
        Write-Host "JSON content (first 500 chars): $($Json.Substring(0, [Math]::Min(500, $Json.Length)))" -ForegroundColor DarkGray
        return $null
    }
}

function Update-ButtonState
{
    <#
    .SYNOPSIS
        Updates button to show loading state
    #>
    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.Button]$Button,
        
        [string]$Text,
        
        [bool]$Enabled = $true
    )
    
    $Button.Content   = $Text
    $Button.IsEnabled = $Enabled
}

function Get-SearchMode
{
    <#
    .SYNOPSIS
        Parses search text to determine search mode and extract pattern
    .OUTPUTS
        Hashtable with Mode, Pattern, Terms (for OR), Ids (for ID search), Exclusions
    #>
    param([string]$SearchText)
    
    $search_text = $SearchText.Trim()
    
    if (-not $search_text)
    {
        return @{ Mode = 'None'; Exclusions = @() }
    }
    
    # Extract exclusions first: not:word or not:word1,word2,word3
    $exclusions = @()
    $remaining_text = $search_text
    
    # Find all not: patterns
    $not_matches = [regex]::Matches($search_text, 'not:([^\s]+)')
    foreach ($match in $not_matches)
    {
        $exclude_part = $match.Groups[1].Value
        # Split by comma for multiple exclusions in one not:
        $exclude_terms = @($exclude_part -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
        $exclusions += $exclude_terms
        # Remove from search text
        $remaining_text = $remaining_text.Replace($match.Value, '')
    }
    
    $remaining_text = $remaining_text.Trim()
    
    # If only exclusions were provided, match everything except exclusions
    if (-not $remaining_text)
    {
        return @{
            Mode       = 'All'
            Exclusions = $exclusions
        }
    }
    
    # ID search: id:value or ids:val1,val2,val3
    if ($remaining_text -match '^ids?:(.+)$')
    {
        $id_part = $Matches[1].Trim()
        $ids = @($id_part -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        return @{
            Mode       = 'Id'
            Ids        = $ids
            Exclusions = $exclusions
        }
    }
    
    # Regex search: /pattern/
    if ($remaining_text -match '^/(.+)/$')
    {
        $pattern = $Matches[1]
        try
        {
            # Validate regex
            [void][regex]::new($pattern, 'IgnoreCase')
            return @{
                Mode       = 'Regex'
                Pattern    = $pattern
                Exclusions = $exclusions
            }
        }
        catch
        {
            # Invalid regex, fall back to literal
            return @{
                Mode       = 'Contains'
                Pattern    = $remaining_text.ToLowerInvariant()
                Exclusions = $exclusions
            }
        }
    }
    
    # OR search: term1|term2|term3
    if ($remaining_text.Contains('|'))
    {
        $terms = @($remaining_text -split '\|' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
        if ($terms.Count -gt 1)
        {
            return @{
                Mode       = 'Or'
                Terms      = $terms
                Exclusions = $exclusions
            }
        }
    }
    
    # Default: substring contains
    return @{
        Mode       = 'Contains'
        Pattern    = $remaining_text.ToLowerInvariant()
        Exclusions = $exclusions
    }
}

function Test-SearchMatch
{
    <#
    .SYNOPSIS
        Tests if text matches the search criteria (including exclusions)
    .OUTPUTS
        Boolean indicating match
    #>
    param(
        [string]$Text,
        [string]$TextLower,
        [hashtable]$SearchMode
    )
    
    # Check exclusions first - if any exclusion matches, return false
    if ($SearchMode.Exclusions -and $SearchMode.Exclusions.Count -gt 0)
    {
        foreach ($exclusion in $SearchMode.Exclusions)
        {
            if ($TextLower.Contains($exclusion))
            {
                return $false
            }
        }
    }
    
    # Now check positive matches
    switch ($SearchMode.Mode)
    {
        'None' { return $true }
        
        'All' {
            # Match everything (used when only exclusions are specified)
            return $true
        }
        
        'Contains' {
            return $TextLower.Contains($SearchMode.Pattern)
        }
        
        'Or' {
            foreach ($term in $SearchMode.Terms)
            {
                if ($TextLower.Contains($term)) { return $true }
            }
            return $false
        }
        
        'Regex' {
            try
            {
                return [regex]::IsMatch($Text, $SearchMode.Pattern, 'IgnoreCase')
            }
            catch
            {
                return $false
            }
        }
        
        'Id' {
            # This mode is handled separately (matches against Id property)
            return $false
        }
        
        default { return $false }
    }
}

function Get-SearchMatchSnippet
{
    <#
    .SYNOPSIS
        Gets a snippet showing the match for complex search modes
    #>
    param(
        [string]$Text,
        [hashtable]$SearchMode,
        [int]$ContextChars = 50
    )
    
    if (-not $Text) { return "" }
    
    switch ($SearchMode.Mode)
    {
        'Contains' {
            return Get-MatchSnippet -Text $Text -SearchTerm $SearchMode.Pattern -ContextChars $ContextChars
        }
        
        'Or' {
            # Find first matching term
            $text_lower = $Text.ToLowerInvariant()
            foreach ($term in $SearchMode.Terms)
            {
                $index = $text_lower.IndexOf($term)
                if ($index -ge 0)
                {
                    return Get-MatchSnippet -Text $Text -SearchTerm $term -ContextChars $ContextChars
                }
            }
            return ""
        }
        
        'Regex' {
            try
            {
                $match = [regex]::Match($Text, $SearchMode.Pattern, 'IgnoreCase')
                if ($match.Success)
                {
                    return Get-MatchSnippet -Text $Text -SearchTerm $match.Value -ContextChars $ContextChars
                }
            }
            catch { }
            return ""
        }
        
        default { return "" }
    }
}

function Save-WindowState
{
    <#
    .SYNOPSIS
        Saves window position, size, and sidebar state to config file
    #>
    param([System.Windows.Window]$Window)
    
    try
    {
        $state = @{
            Left             = $Window.Left
            Top              = $Window.Top
            Width            = $Window.Width
            Height           = $Window.Height
            Maximized        = ($Window.WindowState -eq 'Maximized')
            SidebarCollapsed = $script:ui_cache.sidebar_collapsed
        }
        
        $state | ConvertTo-Json | Set-Content -Path $script:window_state.file -Encoding UTF8
    }
    catch
    {
        Write-Host "Failed to save window state: $_" -ForegroundColor Yellow
    }
}

function Restore-WindowState
{
    <#
    .SYNOPSIS
        Restores window position, size, and sidebar state from config file
    #>
    param([System.Windows.Window]$Window)
    
    if (-not (Test-Path $script:window_state.file))
    {
        return $false
    }
    
    try
    {
        $state = Get-Content -Path $script:window_state.file -Raw | ConvertFrom-Json
        
        # Validate that position is on a visible screen
        $screens = [System.Windows.Forms.Screen]::AllScreens
        $on_screen = $false
        
        foreach ($screen in $screens)
        {
            if ($state.Left -ge $screen.Bounds.Left -and 
                $state.Left -lt $screen.Bounds.Right -and
                $state.Top -ge $screen.Bounds.Top -and 
                $state.Top -lt $screen.Bounds.Bottom)
            {
                $on_screen = $true
                break
            }
        }
        
        if ($on_screen)
        {
            $Window.Left   = $state.Left
            $Window.Top    = $state.Top
            $Window.Width  = $state.Width
            $Window.Height = $state.Height
            
            if ($state.Maximized)
            {
                $Window.WindowState = 'Maximized'
            }
        }
        
        $script:ui_cache.sidebar_collapsed = $state.SidebarCollapsed -eq $true
        
        return $true
    }
    catch
    {
        Write-Host "Failed to restore window state: $_" -ForegroundColor Yellow
        return $false
    }
}

function Update-StatsDisplay
{
    <#
    .SYNOPSIS
        Updates the statistics panel with chat data
    #>
    
    $chats = $script:app_state.all_chats
    
    if (-not $chats -or $chats.Count -eq 0)
    {
        $script:ui['StatsSummary'].Text = "Load chats to see stats"
        return
    }
    
    # Group by month
    $by_month = @{}
    
    foreach ($chat in $chats)
    {
        $month_key = $chat.Updated.ToString("yyyy-MM")
        
        if (-not $by_month.ContainsKey($month_key))
        {
            $by_month[$month_key] = 0
        }
        $by_month[$month_key]++
    }
    
    # Sort by date descending, take last 6 months
    $sorted = $by_month.GetEnumerator() | Sort-Object Name -Descending | Select-Object -First 6
    
    # Build text-based bar chart
    $max_count = ($sorted | ForEach-Object { $_.Value } | Measure-Object -Maximum).Maximum
    if ($max_count -eq 0) { $max_count = 1 }
    
    $lines = @("$($chats.Count) total conversations`n")
    
    foreach ($item in $sorted)
    {
        $bar_length = [Math]::Round(($item.Value / $max_count) * 10)
        $bar        = "█" * $bar_length
        $month_name = [datetime]::ParseExact($item.Name, "yyyy-MM", $null).ToString("MMM yy")
        $lines     += "$month_name  $bar $($item.Value)"
    }
    
    $script:ui['StatsSummary'].Text = $lines -join "`n"
}

function Update-DeletedBufferUI
{
    <#
    .SYNOPSIS
        Updates the recently deleted UI based on buffer state
    #>
    
    $count = $script:app_state.deleted_buffer.Count
    
    if ($count -gt 0)
    {
        $script:ui['RecentlyDeletedLabel'].Text       = "RECENTLY DELETED ($count)"
        $script:ui['RecentlyDeletedLabel'].Visibility = 'Visible'
        $script:ui['UndoDeleteBtn'].Visibility        = 'Visible'
        $script:ui['ClearDeletedBtn'].Visibility      = 'Visible'
    }
    else
    {
        $script:ui['RecentlyDeletedLabel'].Visibility = 'Collapsed'
        $script:ui['UndoDeleteBtn'].Visibility        = 'Collapsed'
        $script:ui['ClearDeletedBtn'].Visibility      = 'Collapsed'
    }
}

#endregion

#region Login Window

function Show-LoginDialog
{
    param([System.Windows.Window]$Owner)
    
    if (-not $script:app_state.webview2_ready)
    {
        [System.Windows.MessageBox]::Show("WebView2 not initialized.", "Error", 'OK', 'Error')
        return $null
    }
    
    Write-Host "Opening login window..." -ForegroundColor Cyan
    
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Login" Height="750" Width="1000" WindowStartupLocation="CenterOwner"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent">
    <Border Background="#111" CornerRadius="8" BorderBrush="#333" BorderThickness="1">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="40"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="36"/>
            </Grid.RowDefinitions>
            
            <Border x:Name="TitleBar" Background="#1a1a1a" CornerRadius="8,8,0,0">
                <Grid>
                    <TextBlock Text="Sign in to Claude" VerticalAlignment="Center" Margin="16,0" 
                               Foreground="#888" FontSize="12"/>
                    <Button x:Name="CloseBtn" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" 
                            Width="40" Height="40" HorizontalAlignment="Right" 
                            Background="Transparent" Foreground="#666" BorderThickness="0" FontSize="10"/>
                </Grid>
            </Border>
            
            <Border x:Name="WebViewHost" Grid.Row="1" Background="#0a0a0a"/>
            
            <Border Grid.Row="2" Background="#1a1a1a" CornerRadius="0,0,8,8">
                <Grid Margin="16,0">
                    <TextBlock x:Name="StatusTxt" Text="Loading..." VerticalAlignment="Center" 
                               Foreground="#555" FontSize="11"/>
                    <Button x:Name="CancelBtn" Content="Cancel" HorizontalAlignment="Right"
                            Width="70" Height="24" Background="#2a2a2a" Foreground="#888"
                            BorderBrush="#3a3a3a" BorderThickness="1" FontSize="10"/>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
'@
    
    $window = [System.Windows.Markup.XamlReader]::Parse($xaml)
    
    if ($Owner)
    {
        $window.Owner = $Owner
    }
    
    $title_bar    = $window.FindName('TitleBar')
    $webview_host = $window.FindName('WebViewHost')
    $status_text  = $window.FindName('StatusTxt')
    $close_button = $window.FindName('CloseBtn')
    $cancel_button = $window.FindName('CancelBtn')
    
    # Login state
    $script:_login = @{
        window   = $window
        webview  = $null
        status   = $status_text
        result   = $null
        timer    = $null
    }
    
    # Window drag
    $title_bar.Add_MouseLeftButtonDown({
        param($sender, $event_args)
        if ($event_args.LeftButton -eq 'Pressed')
        {
            $script:_login.window.DragMove()
        }
    })
    
    # Close/Cancel handlers
    $close_handler = {
        $script:_login.window.DialogResult = $false
        $script:_login.window.Close()
    }
    
    $close_button.Add_Click($close_handler)
    $cancel_button.Add_Click($close_handler)
    
    # Setup WebView2
    $webview = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
    $creation_props = [Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties]::new()
    $creation_props.UserDataFolder = $script:config.webview2_data
    $webview.CreationProperties    = $creation_props
    $webview.Dock                  = [System.Windows.Forms.DockStyle]::Fill
    
    $forms_host       = [System.Windows.Forms.Integration.WindowsFormsHost]::new()
    $forms_host.Child = $webview
    $webview_host.Child = $forms_host
    $script:_login.webview = $webview
    
    # Poll timer for login detection
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $script:_login.timer = $timer
    
    $timer.Add_Tick({
        try
        {
            $login = $script:_login
            $url   = $login.webview.Source
            
            if ($url -and $url.Host -eq 'claude.ai' -and $url.AbsolutePath -notmatch 'login|oauth|auth')
            {
                $login.status.Text = "Verifying session..."
                
                $task    = $login.webview.CoreWebView2.CookieManager.GetCookiesAsync("https://claude.ai")
                $cookies = Invoke-WithDoEvents -Task $task
                
                if ($cookies.Count -gt 0)
                {
                    $parts  = @()
                    $org_id = $null
                    
                    foreach ($cookie in $cookies)
                    {
                        $parts += "$($cookie.Name)=$($cookie.Value)"
                        
                        if ($cookie.Name -eq 'lastActiveOrg')
                        {
                            $org_id = $cookie.Value
                        }
                    }
                    
                    $has_session = $cookies | Where-Object { $_.Name -match 'session' }
                    
                    if ($has_session -and $org_id)
                    {
                        $login.timer.Stop()
                        $login.result = @{
                            org_id = $org_id
                            cookie = ($parts -join '; ')
                        }
                        $login.status.Text = "Login successful!"
                        Write-Host "Login successful! OrgId: $org_id" -ForegroundColor Green
                        
                        Start-Sleep -Milliseconds 500
                        $login.window.DialogResult = $true
                        $login.window.Close()
                    }
                }
            }
        }
        catch
        {
            $script:_login.status.Text = "Error: $($_.Exception.Message)"
        }
    })
    
    # WebView2 initialized
    $webview.Add_CoreWebView2InitializationCompleted({
        param($sender, $event_args)
        
        if ($event_args.IsSuccess)
        {
            $script:_login.status.Text = "Ready - Please sign in"
            $script:_login.webview.CoreWebView2.Navigate("https://claude.ai/login")
            $script:_login.timer.Start()
        }
        else
        {
            $script:_login.status.Text = "Browser initialization failed"
            Write-Host "WebView2 init failed: $($event_args.InitializationException)" -ForegroundColor Red
        }
    })
    
    # Window loaded
    $window.Add_Loaded({
        try
        {
            $script:_login.status.Text = "Initializing browser..."
            $init_task = $script:_login.webview.EnsureCoreWebView2Async($null)
            Invoke-WithDoEvents -Task $init_task -PollMs 50
        }
        catch
        {
            $script:_login.status.Text = "Initialization error"
            Write-Host "Login init error: $_" -ForegroundColor Red
        }
    })
    
    # Cleanup on close
    $window.Add_Closing({
        if ($script:_login.timer) { $script:_login.timer.Stop() }
        if ($script:_login.webview) 
        { 
            try { $script:_login.webview.Dispose() } catch { }
        }
        $script:_login.webview = $null
        $script:_login.timer   = $null
    })
    
    # Show dialog
    if ($window.ShowDialog())
    {
        return $script:_login.result
    }
    
    return $null
}

#endregion

#region Fetch Chats

function Get-AllChats
{
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner,
        
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [ObservableCollection[ChatItem]]$TargetCollection,
        
        [scriptblock]$OnProgress
    )
    
    Write-Host "Fetching all conversations..." -ForegroundColor Cyan
    
    $fetch_result = $null
    
    $operation = New-WebView2Operation `
        -Title "Fetching Conversations" `
        -Owner $Owner `
        -StatusText "Connecting to Claude..." `
        -ShowProgress $true `
        -ProgressIndeterminate $true `
        -ProgressColor "#3498db" `
        -TimeoutSeconds $script:CONSTANTS.FETCH_TIMEOUT_SECONDS `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            Write-Host "  WebView ready, injecting fetch script..." -ForegroundColor DarkGray
            $op.status_text.Text = "Loading conversations..."
            
            $fetch_js = @"
// Set markers synchronously FIRST
window._fetchResult = null;
window._fetchDone = false;
window._fetchProgress = 0;
window._fetchStarted = false;
window._fetchError = null;

// Start async fetch
(async () => {
    window._fetchStarted = true;
    try {
        const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
        window._fetchOrgId = orgId || 'NOT_FOUND';
        
        if (!orgId) {
            window._fetchError = 'No organization ID in cookies';
            window._fetchResult = {success: false, error: 'No organization ID found'};
            window._fetchDone = true;
            return;
        }
        
        let allChats = [];
        let seenIds = new Set();
        let cursor = null;
        let lastCursor = null;
        let page = 0;
        const maxPages = $($script:CONSTANTS.MAX_PAGINATION_PAGES);
        
        while (page < maxPages) {
            page++;
            window._fetchPage = page;
            
            const url = cursor 
                ? 'https://claude.ai/api/organizations/' + orgId + '/chat_conversations?cursor=' + cursor
                : 'https://claude.ai/api/organizations/' + orgId + '/chat_conversations';
            
            window._fetchUrl = url;
            
            const resp = await fetch(url, {credentials: 'include'});
            window._fetchStatus = resp.status;
            
            if (!resp.ok) {
                if (resp.status === 401 || resp.status === 403) {
                    window._fetchError = 'Auth failed: ' + resp.status;
                    window._fetchResult = {success: false, error: 'Session expired - please login again'};
                    window._fetchDone = true;
                    return;
                }
                window._fetchError = 'HTTP error: ' + resp.status;
                break;
            }
            
            const data = await resp.json();
            if (!data || !Array.isArray(data) || data.length === 0) break;
            
            let newCount = 0;
            for (const chat of data) {
                if (chat.uuid && !seenIds.has(chat.uuid)) {
                    seenIds.add(chat.uuid);
                    allChats.push({
                        uuid: chat.uuid,
                        name: chat.name || 'Untitled',
                        updated_at: chat.updated_at
                    });
                    newCount++;
                }
            }
            
            window._fetchProgress = allChats.length;
            
            if (newCount === 0) break;
            
            cursor = data[data.length - 1]?.uuid;
            if (!cursor || cursor === lastCursor) break;
            lastCursor = cursor;
            
            if (data.length < 50) break;
            
            await new Promise(r => setTimeout(r, $($script:CONSTANTS.API_REQUEST_DELAY_MS)));
        }
        
        window._fetchResult = {success: true, count: allChats.length, chats: allChats};
    } catch(e) {
        window._fetchError = e.message;
        window._fetchResult = {success: false, error: e.message};
    }
    window._fetchDone = true;
})();

// Return marker that script was injected
'INJECTED';
"@
            
            try
            {
                $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($fetch_js)
                $result = Invoke-WithDoEvents -Task $start_task
                Write-Host "  Script injection result: $result" -ForegroundColor DarkGray
            }
            catch
            {
                Write-Host "  Failed to inject fetch script: $_" -ForegroundColor Red
                $op.status_text.Text = "Script injection failed"
                Complete-WebView2Operation -Operation $op -Success $false
                return
            }
            
            Write-Host "  Polling for results..." -ForegroundColor DarkGray
            
            # Poll for progress
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.POLL_INTERVAL_MS)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_fetch_last_progress = 0
            $script:_fetch_target = $TargetCollection
            $script:_fetch_on_progress = $OnProgress
            $script:_fetch_poll_count = 0
            
            $poll_timer.Add_Tick({
                param($sender, $event_args)
                
                $op = $script:_current_operation
                
                # Safety checks - stop if cancelled or webview disposed
                if (-not $op -or $op.is_cancelled -or -not $op.webview -or -not $op.webview.CoreWebView2)
                { 
                    $sender.Stop()
                    return 
                }
                
                $script:_fetch_poll_count++
                
                try
                {
                    # Every 50 polls (~5 seconds), show debug state
                    if ($script:_fetch_poll_count % 50 -eq 1)
                    {
                        $debug_task = $op.webview.CoreWebView2.ExecuteScriptAsync(
                            "JSON.stringify({started: window._fetchStarted, done: window._fetchDone, progress: window._fetchProgress, orgId: window._fetchOrgId, page: window._fetchPage, status: window._fetchStatus, error: window._fetchError})")
                        $debug_json = Invoke-WithDoEvents -Task $debug_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        Write-Host "  Poll #$($script:_fetch_poll_count) state: $debug_json" -ForegroundColor DarkGray
                    }
                    
                    # Check progress
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._fetchProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    if ($progress -gt $script:_fetch_last_progress)
                    {
                        $op.status_text.Text = "$progress conversations found..."
                        $script:_fetch_last_progress = $progress
                        Write-Host "  Progress: $progress" -ForegroundColor DarkGray
                        
                        if ($script:_fetch_on_progress)
                        {
                            & $script:_fetch_on_progress $progress
                        }
                    }
                    
                    # Check if done
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._fetchDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                        Write-Host "  Fetch complete, parsing results..." -ForegroundColor DarkGray
                        
                        # Get results
                        $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._fetchResult)")
                        $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        
                        # Parse JSON (comes back as escaped string)
                        $unescaped = ConvertFrom-JsonSafe -Json $result_json
                        
                        if ($unescaped)
                        {
                            $result = ConvertFrom-JsonSafe -Json $unescaped
                            
                            if ($result)
                            {
                                if ($result.error)
                                {
                                    Write-Host "Fetch error: $($result.error)" -ForegroundColor Red
                                    $op.status_text.Text = "Error: $($result.error)"
                                    Start-Sleep -Milliseconds 1500
                                }
                                elseif ($result.success -and $result.chats)
                                {
                                    # Populate collection
                                    foreach ($chat_data in $result.chats)
                                    {
                                        $item = [ChatItem]::new()
                                        $item.Id       = $chat_data.uuid
                                        $item.Name     = $chat_data.name
                                        $item.Selected = $false
                                        
                                        # Parse date safely
                                        try 
                                        {
                                            $item.Updated = [datetime]$chat_data.updated_at
                                        }
                                        catch 
                                        {
                                            $item.Updated = [datetime]::Now
                                        }
                                        
                                        $script:_fetch_target.Add($item)
                                    }
                                    
                                    $op.status_text.Text = "$($result.count) conversations loaded"
                                    Write-Host "Fetched $($result.count) conversations" -ForegroundColor Green
                                }
                            }
                        }
                        
                        Complete-WebView2Operation -Operation $op -Success $true
                    }
                }
                catch
                {
                    Write-Host "  Poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation)
    {
        return 0
    }
    
    [void]$operation.window.ShowDialog()
    
    return $TargetCollection.Count
}

#endregion

#region Export Chats

function Export-ChatsWithContent
{
    param(
        [Parameter(Mandatory)]
        [array]$Chats,
        
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner
    )
    
    Write-Host "Exporting $($Chats.Count) conversations with content..." -ForegroundColor Cyan
    
    $chat_ids = @($Chats | ForEach-Object { $_.Id })
    $ids_json = ConvertTo-Json -InputObject $chat_ids -Compress
    $total    = $chat_ids.Count
    
    $operation = New-WebView2Operation `
        -Title "Exporting Conversations" `
        -Owner $Owner `
        -StatusText "Preparing export..." `
        -ShowProgress $true `
        -ProgressIndeterminate $false `
        -ProgressColor "#2ecc71" `
        -TimeoutSeconds ($script:CONSTANTS.EXPORT_TIMEOUT_MINUTES * 60) `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            if ($op.progress_bar)
            {
                $op.progress_bar.Maximum = $total
            }
            
            $export_js = @"
window._exportResult = null;
window._exportDone = false;
window._exportProgress = 0;

(async () => {
    try {
        const ids = $ids_json;
        const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
        let results = [];
        
        for (const id of ids) {
            try {
                const resp = await fetch(
                    'https://claude.ai/api/organizations/' + orgId + '/chat_conversations/' + id + '?tree=True',
                    {credentials: 'include'}
                );
                
                if (resp.ok) {
                    const data = await resp.json();
                    results.push({id: id, success: true, data: data});
                } else {
                    results.push({id: id, success: false, error: 'HTTP ' + resp.status});
                }
            } catch (e) {
                results.push({id: id, success: false, error: e.message});
            }
            
            window._exportProgress++;
            await new Promise(r => setTimeout(r, $($script:CONSTANTS.EXPORT_REQUEST_DELAY_MS)));
        }
        
        window._exportResult = {success: true, chats: results};
    } catch(e) {
        window._exportResult = {success: false, error: e.message};
    }
    window._exportDone = true;
})();
"@
            
            $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($export_js)
            Invoke-WithDoEvents -Task $start_task | Out-Null
            
            # Poll for progress
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds(200)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_export_output = $OutputPath
            $script:_export_total  = $total
            
            $poll_timer.Add_Tick({
                param($sender, $event_args)
                
                $op = $script:_current_operation
                
                if (-not $op -or $op.is_cancelled -or -not $op.webview -or -not $op.webview.CoreWebView2)
                {
                    $sender.Stop()
                    return
                }
                
                try
                {
                    # Update progress
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._exportProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    $op.status_text.Text = "Exporting... $progress / $script:_export_total"
                    if ($op.progress_bar) { $op.progress_bar.Value = $progress }
                    
                    # Check if done
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._exportDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                    
                    $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._exportResult)")
                    $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                    
                    $unescaped = ConvertFrom-JsonSafe -Json $result_json
                    $result    = if ($unescaped) { ConvertFrom-JsonSafe -Json $unescaped } else { $null }
                    
                    if ($result -and $result.success)
                    {
                        # Build export document
                        $export_data = [PSCustomObject]@{
                            export_date         = (Get-Date).ToString('o')
                            export_version      = "3.0"
                            export_type         = "full"
                            total_conversations = $result.chats.Count
                            conversations       = @($result.chats | ForEach-Object {
                                if ($_.success -and $_.data)
                                {
                                    [PSCustomObject]@{
                                        id            = $_.id
                                        name          = $_.data.name
                                        created_at    = $_.data.created_at
                                        updated_at    = $_.data.updated_at
                                        model         = $_.data.model
                                        chat_messages = @($_.data.chat_messages | ForEach-Object {
                                            [PSCustomObject]@{
                                                uuid        = $_.uuid
                                                sender      = $_.sender
                                                text        = $_.text
                                                created_at  = $_.created_at
                                                attachments = $_.attachments
                                            }
                                        })
                                    }
                                }
                                else
                                {
                                    [PSCustomObject]@{
                                        id    = $_.id
                                        error = $_.error
                                    }
                                }
                            })
                        }
                        
                        try
                        {
                            $export_data | ConvertTo-Json -Depth 20 | Set-Content $script:_export_output -Encoding UTF8
                            $success_count = ($result.chats | Where-Object { $_.success }).Count
                            Write-Host "Exported $success_count conversations to: $script:_export_output" -ForegroundColor Green
                            $op.status_text.Text = "Exported $success_count conversations"
                        }
                        catch
                        {
                            Write-Host "Failed to write export file: $_" -ForegroundColor Red
                            $op.status_text.Text = "Failed to save file"
                        }
                    }
                    else
                    {
                        $op.status_text.Text = "Export failed"
                    }
                    
                    Complete-WebView2Operation -Operation $op -Success $true
                }
                }
                catch
                {
                    Write-Host "Export poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation)
    {
        return
    }
    
    [void]$operation.window.ShowDialog()
}

#endregion

#region Index Chat Content

function Update-ChatContentIndex
{
    param(
        [Parameter(Mandatory)]
        [array]$Chats,
        
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner
    )
    
    Write-Host "Indexing content for $($Chats.Count) conversations..." -ForegroundColor Cyan
    
    $chat_ids = @($Chats | ForEach-Object { $_.Id })
    $ids_json = ConvertTo-Json -InputObject $chat_ids -Compress
    $total    = $chat_ids.Count
    
    $operation = New-WebView2Operation `
        -Title "Indexing Content" `
        -Owner $Owner `
        -StatusText "Preparing..." `
        -ShowProgress $true `
        -ProgressIndeterminate $false `
        -ProgressColor "#9b59b6" `
        -TimeoutSeconds ($script:CONSTANTS.INDEX_TIMEOUT_MINUTES * 60) `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            if ($op.progress_bar)
            {
                $op.progress_bar.Maximum = $total
            }
            
            $index_js = @"
window._indexDone = false;
window._indexProgress = 0;
window._indexResults = [];

(async () => {
    const ids = $ids_json;
    const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
    const maxLen = $($script:CONSTANTS.MAX_CONTENT_LENGTH);
    
    for (const id of ids) {
        try {
            const resp = await fetch(
                'https://claude.ai/api/organizations/' + orgId + '/chat_conversations/' + id + '?tree=True',
                {credentials: 'include'}
            );
            
            if (resp.ok) {
                const data = await resp.json();
                let content = '';
                if (data.chat_messages) {
                    content = data.chat_messages.map(m => m.text || '').join(' ');
                }
                window._indexResults.push({id: id, content: content.substring(0, maxLen)});
            } else {
                window._indexResults.push({id: id, content: ''});
            }
        } catch (e) {
            window._indexResults.push({id: id, content: ''});
        }
        
        window._indexProgress++;
        await new Promise(r => setTimeout(r, $($script:CONSTANTS.INDEX_REQUEST_DELAY_MS)));
    }
    
    window._indexDone = true;
})();
"@
            
            $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($index_js)
            Invoke-WithDoEvents -Task $start_task | Out-Null
            
            # Poll
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds(200)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_index_total = $total
            
            $poll_timer.Add_Tick({
                param($sender, $event_args)
                
                $op = $script:_current_operation
                
                if (-not $op -or $op.is_cancelled -or -not $op.webview -or -not $op.webview.CoreWebView2)
                {
                    $sender.Stop()
                    return
                }
                
                try
                {
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._indexProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    $op.status_text.Text = "Indexing... $progress / $script:_index_total"
                    if ($op.progress_bar) { $op.progress_bar.Value = $progress }
                    
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._indexDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                        
                        $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._indexResults)")
                        $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        
                        $unescaped = ConvertFrom-JsonSafe -Json $result_json
                        $results   = if ($unescaped) { ConvertFrom-JsonSafe -Json $unescaped } else { @() }
                        
                        if ($results)
                        {
                            foreach ($result_item in $results)
                            {
                                $chat = $script:app_state.all_chats | Where-Object { $_.Id -eq $result_item.id } | Select-Object -First 1
                                
                                if ($chat)
                                {
                                    $chat.Content        = $result_item.content
                                    $chat.ContentIndexed = $true
                                }
                            }
                            
                            Write-Host "Indexed $($results.Count) conversations" -ForegroundColor Green
                            $op.status_text.Text = "Indexed $($results.Count) conversations"
                        }
                        
                        Complete-WebView2Operation -Operation $op -Success $true
                    }
                }
                catch
                {
                    Write-Host "Index poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation)
    {
        return
    }
    
    [void]$operation.window.ShowDialog()
}

#endregion

#region Delete Chats

function Remove-SelectedChats
{
    param(
        [Parameter(Mandatory)]
        [array]$Chats,
        
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner
    )
    
    Write-Host "Deleting $($Chats.Count) conversations..." -ForegroundColor Yellow
    
    $chat_ids = @($Chats | ForEach-Object { $_.Id })
    $ids_json = ConvertTo-Json -InputObject $chat_ids -Compress
    $total    = $chat_ids.Count
    
    $script:_delete_success_count = 0
    
    $operation = New-WebView2Operation `
        -Title "Deleting Conversations" `
        -Owner $Owner `
        -StatusText "Preparing..." `
        -ShowProgress $true `
        -ProgressIndeterminate $false `
        -ProgressColor "#e74c3c" `
        -TimeoutSeconds 300 `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            if ($op.progress_bar)
            {
                $op.progress_bar.Maximum = $total
            }
            
            $delete_js = @"
window._deleteResult = null;
window._deleteDone = false;
window._deleteProgress = 0;

(async () => {
    const ids = $ids_json;
    const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
    let deleted = 0;
    let failed = 0;
    
    for (const id of ids) {
        try {
            const resp = await fetch(
                'https://claude.ai/api/organizations/' + orgId + '/chat_conversations/' + id,
                {method: 'DELETE', credentials: 'include'}
            );
            
            if (resp.ok || resp.status === 204) {
                deleted++;
            } else {
                failed++;
            }
        } catch (e) {
            failed++;
        }
        
        window._deleteProgress++;
        await new Promise(r => setTimeout(r, $($script:CONSTANTS.DELETE_REQUEST_DELAY_MS)));
    }
    
    window._deleteResult = {deleted: deleted, failed: failed};
    window._deleteDone = true;
})();
"@
            
            $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($delete_js)
            Invoke-WithDoEvents -Task $start_task | Out-Null
            
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds(200)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_delete_total = $total
            $script:_delete_ids   = $chat_ids
            
            $poll_timer.Add_Tick({
                param($sender, $event_args)
                
                $op = $script:_current_operation
                
                if (-not $op -or $op.is_cancelled -or -not $op.webview -or -not $op.webview.CoreWebView2)
                {
                    $sender.Stop()
                    return
                }
                
                try
                {
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._deleteProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    $op.status_text.Text = "Deleting... $progress / $script:_delete_total"
                    if ($op.progress_bar) { $op.progress_bar.Value = $progress }
                    
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._deleteDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                        
                        $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._deleteResult)")
                        $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        
                        $unescaped = ConvertFrom-JsonSafe -Json $result_json
                        $result    = if ($unescaped) { ConvertFrom-JsonSafe -Json $unescaped } else { $null }
                        
                        if ($result)
                        {
                            # Remove from collection
                            $items_to_remove = @($script:app_state.all_chats | Where-Object { $script:_delete_ids -contains $_.Id })
                            
                            foreach ($item in $items_to_remove)
                            {
                                $script:app_state.all_chats.Remove($item)
                            }
                            
                            $script:_delete_success_count = $result.deleted
                            
                            $color = if ($result.failed -gt 0) { "Yellow" } else { "Green" }
                            Write-Host "Deleted $($result.deleted), failed $($result.failed)" -ForegroundColor $color
                            $op.status_text.Text = "Deleted $($result.deleted) conversations"
                        }
                        
                        Complete-WebView2Operation -Operation $op -Success $true
                    }
                }
                catch
                {
                    Write-Host "Delete poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation)
    {
        return 0
    }
    
    [void]$operation.window.ShowDialog()
    
    return $script:_delete_success_count
}

#endregion

#region Main Window XAML

$script:main_xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Chat Manager" Height="700" Width="1100" 
        MinHeight="400" MinWidth="600"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="8"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
        <!-- Dark Tooltip Style -->
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#aaa"/>
            <Setter Property="BorderBrush" Value="#333"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>
        
        <!-- Window Control Buttons -->
        <Style x:Key="WindowControlBtn" TargetType="Button">
            <Setter Property="Width" Value="44"/>
            <Setter Property="Height" Value="44"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#555"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
            <Setter Property="FontSize" Value="9"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2a2a2a"/>
                                <Setter Property="Foreground" Value="#999"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#1a1a1a"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Close Button (red hover) -->
        <Style x:Key="CloseControlBtn" TargetType="Button" BasedOn="{StaticResource WindowControlBtn}">
            <Setter Property="Foreground" Value="#666"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#c42b1c"/>
                                <Setter Property="Foreground" Value="#fff"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#9a2315"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Minimal Scrollbar -->
        <Style x:Key="MinimalScrollBar" TargetType="ScrollBar">
            <Setter Property="Width" Value="6"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track x:Name="PART_Track" IsDirectionReversed="true">
                            <Track.Thumb>
                                <Thumb>
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb">
                                            <Border Background="#3a3a3a" CornerRadius="3" Margin="1,0"/>
                                        </ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Track.Thumb>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Checkbox -->
        <Style x:Key="GridCheckBox" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Border x:Name="border" Width="14" Height="14" Background="#252525" 
                                BorderBrush="#3a3a3a" BorderThickness="1" CornerRadius="2">
                            <Path x:Name="check" Data="M2,4 L5,7 L10,1" Stroke="#3498db" StrokeThickness="1.5"
                                  HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" Margin="1"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="check" Property="Visibility" Value="Visible"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#3498db"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="#4a4a4a"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Sidebar Button -->
        <Style x:Key="SidebarButton" TargetType="Button">
            <Setter Property="Height" Value="34"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#999"/>
            <Setter Property="BorderBrush" Value="#2a2a2a"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" 
                                BorderBrush="{TemplateBinding BorderBrush}" 
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#252525"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#151515"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#3a3a3a"/>
                                <Setter TargetName="border" Property="Background" Value="#151515"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#1f1f1f"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Small Sidebar Button -->
        <Style x:Key="SmallSidebarButton" TargetType="Button" BasedOn="{StaticResource SidebarButton}">
            <Setter Property="Height" Value="28"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="Foreground" Value="#666"/>
            <Setter Property="BorderBrush" Value="#252525"/>
        </Style>
        
        <!-- Footer Button -->
        <Style x:Key="FooterButton" TargetType="Button" BasedOn="{StaticResource SidebarButton}">
            <Setter Property="Height" Value="26"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="Foreground" Value="#666"/>
            <Setter Property="Padding" Value="16,0"/>
        </Style>
        
        <!-- Delete Button -->
        <Style x:Key="DeleteButton" TargetType="Button">
            <Setter Property="Height" Value="26"/>
            <Setter Property="FontSize" Value="10"/>
            <Setter Property="Background" Value="#3a1a1a"/>
            <Setter Property="Foreground" Value="#a66"/>
            <Setter Property="BorderBrush" Value="#4a2a2a"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,0"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}" 
                                BorderBrush="{TemplateBinding BorderBrush}" 
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#4a2020"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#2a1010"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#553333"/>
                                <Setter TargetName="border" Property="Background" Value="#251515"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="#301818"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Sort Indicator Style for Headers -->
        <Style x:Key="SortableHeader" TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#555"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="9"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderBrush" Value="#252525"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridColumnHeader">
                        <Border Background="{TemplateBinding Background}" 
                                BorderBrush="{TemplateBinding BorderBrush}" 
                                BorderThickness="{TemplateBinding BorderThickness}"
                                Padding="{TemplateBinding Padding}">
                            <Grid>
                                <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
                                <Path x:Name="SortArrow" HorizontalAlignment="Right" VerticalAlignment="Center"
                                      Width="8" Height="6" Margin="4,0" Fill="#555" Visibility="Collapsed"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="SortDirection" Value="Ascending">
                                <Setter TargetName="SortArrow" Property="Visibility" Value="Visible"/>
                                <Setter TargetName="SortArrow" Property="Data" Value="M0,4 L4,0 L8,4 Z"/>
                                <Setter Property="Foreground" Value="#888"/>
                            </Trigger>
                            <Trigger Property="SortDirection" Value="Descending">
                                <Setter TargetName="SortArrow" Property="Visibility" Value="Visible"/>
                                <Setter TargetName="SortArrow" Property="Data" Value="M0,0 L4,4 L8,0 Z"/>
                                <Setter Property="Foreground" Value="#888"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="#888"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        
        <!-- Dark Calendar Styles for DatePicker -->
        <Style TargetType="Calendar">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#aaa"/>
            <Setter Property="BorderBrush" Value="#333"/>
        </Style>
        <Style TargetType="CalendarDayButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#aaa"/>
            <Style.Triggers>
                <Trigger Property="IsToday" Value="True">
                    <Setter Property="Background" Value="#2a4a6a"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#3498db"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#333"/>
                </Trigger>
                <Trigger Property="IsBlackedOut" Value="True">
                    <Setter Property="Foreground" Value="#444"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="CalendarButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#aaa"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#333"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="CalendarItem">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#aaa"/>
        </Style>
    </Window.Resources>
    
    <Border Background="#111" CornerRadius="8" BorderBrush="#2a2a2a" BorderThickness="1" ClipToBounds="True">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="44"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="44"/>
            </Grid.RowDefinitions>
            
            <!-- Title Bar -->
            <Border x:Name="TitleBar" Background="#161616" CornerRadius="8,8,0,0">
                <Grid>
                    <StackPanel Orientation="Horizontal" Margin="8,0,16,0">
                        <Button x:Name="HamburgerBtn" Width="32" Height="32" Background="Transparent" BorderThickness="0" 
                                Cursor="Hand" ToolTip="Toggle sidebar (Ctrl+B)" VerticalAlignment="Center"
                                WindowChrome.IsHitTestVisibleInChrome="True">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="Transparent" CornerRadius="4" Padding="6">
                                        <Grid x:Name="IconGrid" RenderTransformOrigin="0.5,0.5">
                                            <Grid.RenderTransform>
                                                <RotateTransform x:Name="IconRotation" Angle="0"/>
                                            </Grid.RenderTransform>
                                            <!-- Hamburger lines (visible when expanded) -->
                                            <StackPanel x:Name="HamburgerLines" VerticalAlignment="Center" Opacity="1">
                                                <Border Height="2" Width="16" Background="#666" Margin="0,1.5"/>
                                                <Border Height="2" Width="16" Background="#666" Margin="0,1.5"/>
                                                <Border Height="2" Width="16" Background="#666" Margin="0,1.5"/>
                                            </StackPanel>
                                            <!-- Arrow (visible when collapsed) -->
                                            <TextBlock x:Name="ArrowIcon" Text="»" FontSize="16" Foreground="#666" 
                                                       HorizontalAlignment="Center" VerticalAlignment="Center" 
                                                       Opacity="0" FontWeight="Bold"/>
                                        </Grid>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#252525"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                        <TextBlock Text="Claude Chat Manager" VerticalAlignment="Center" Foreground="#ccc" 
                                   FontSize="12" FontWeight="Medium" Margin="8,0,0,0"/>
                        <Border CornerRadius="10" Padding="8,3" Margin="16,0" VerticalAlignment="Center" Background="#1a1a1a">
                            <StackPanel Orientation="Horizontal">
                                <Ellipse x:Name="StatusDot" Width="6" Height="6" Fill="#555" Margin="0,0,6,0"/>
                                <TextBlock x:Name="StatusTxt" Text="Disconnected" Foreground="#555" FontSize="10"/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="MinBtn" Content="&#xE921;" Style="{StaticResource WindowControlBtn}" WindowChrome.IsHitTestVisibleInChrome="True"/>
                        <Button x:Name="MaxBtn" Content="&#xE922;" Style="{StaticResource WindowControlBtn}" WindowChrome.IsHitTestVisibleInChrome="True"/>
                        <Button x:Name="CloseBtn" Content="&#xE8BB;" Style="{StaticResource CloseControlBtn}" WindowChrome.IsHitTestVisibleInChrome="True"/>
                    </StackPanel>
                </Grid>
            </Border>
            
            <!-- Content -->
            <Grid Grid.Row="1" Margin="16,12,16,12" ClipToBounds="True">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="SidebarColumn" Width="180"/>
                    <ColumnDefinition Width="16"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                
                <!-- Sidebar with ScrollViewer -->
                <ScrollViewer x:Name="SidebarScroller" VerticalScrollBarVisibility="Auto" 
                              HorizontalScrollBarVisibility="Disabled"
                              PanningMode="VerticalOnly">
                    <ScrollViewer.Resources>
                        <Style TargetType="ScrollBar">
                            <Setter Property="Width" Value="6"/>
                            <Setter Property="Background" Value="Transparent"/>
                            <Setter Property="Template">
                                <Setter.Value>
                                    <ControlTemplate TargetType="ScrollBar">
                                        <Track x:Name="PART_Track" IsDirectionReversed="true">
                                            <Track.Thumb>
                                                <Thumb>
                                                    <Thumb.Template>
                                                        <ControlTemplate TargetType="Thumb">
                                                            <Border Background="#3a3a3a" CornerRadius="3" Margin="1,0"/>
                                                        </ControlTemplate>
                                                    </Thumb.Template>
                                                </Thumb>
                                            </Track.Thumb>
                                        </Track>
                                    </ControlTemplate>
                                </Setter.Value>
                            </Setter>
                        </Style>
                    </ScrollViewer.Resources>
                    <StackPanel x:Name="SidebarPanel">
                        <Button x:Name="LoginBtn" Content="Login" Style="{StaticResource SidebarButton}" Margin="0,0,0,6"/>
                        <Button x:Name="LoadBtn" Content="Load Chats" Style="{StaticResource SidebarButton}" Margin="0,0,0,20" IsEnabled="False"/>
                    
                    <TextBlock Foreground="#444" FontSize="9" FontWeight="SemiBold" Margin="0,0,0,6">
                        <Run Text="FILTER"/><Run Text="  Ctrl+F" Foreground="#333" FontWeight="Normal"/>
                    </TextBlock>
                    <Grid>
                        <TextBox x:Name="SearchBox" Height="30" Background="#1a1a1a" Foreground="#aaa" 
                                 BorderBrush="#2a2a2a" BorderThickness="1" Padding="8,0,24,0" FontSize="11" 
                                 VerticalContentAlignment="Center" CaretBrush="#666">
                            <TextBox.ToolTip>
                                <ToolTip MaxWidth="320" Padding="10,8">
                                    <StackPanel>
                                        <TextBlock Text="Search Syntax" FontWeight="SemiBold" Foreground="#aaa" Margin="0,0,0,6"/>
                                        <TextBlock Text="text" Foreground="#3498db" FontFamily="Consolas"/>
                                        <TextBlock Text="  Substring match" Foreground="#888" Margin="0,0,0,4"/>
                                        <TextBlock Text="foo|bar|baz" Foreground="#3498db" FontFamily="Consolas"/>
                                        <TextBlock Text="  OR search (any term)" Foreground="#888" Margin="0,0,0,4"/>
                                        <TextBlock Text="/regex pattern/" Foreground="#3498db" FontFamily="Consolas"/>
                                        <TextBlock Text="  Regular expression" Foreground="#888" Margin="0,0,0,4"/>
                                        <TextBlock Text="id:abc123" Foreground="#3498db" FontFamily="Consolas"/>
                                        <TextBlock Text="  Search by ID" Foreground="#888" Margin="0,0,0,4"/>
                                        <TextBlock Text="ids:abc,def,ghi" Foreground="#3498db" FontFamily="Consolas"/>
                                        <TextBlock Text="  Multiple IDs (comma-sep)" Foreground="#888" Margin="0,0,0,6"/>
                                        <TextBlock Text="Exclusions" FontWeight="SemiBold" Foreground="#aaa" Margin="0,0,0,4"/>
                                        <TextBlock Text="foo not:bar" Foreground="#e74c3c" FontFamily="Consolas"/>
                                        <TextBlock Text="  Match foo, exclude bar" Foreground="#888" Margin="0,0,0,4"/>
                                        <TextBlock Text="foo|bar not:baz,qux" Foreground="#e74c3c" FontFamily="Consolas"/>
                                        <TextBlock Text="  Exclude multiple (comma-sep)" Foreground="#888" Margin="0,0,0,6"/>
                                        <TextBlock Text="Date filtering:" Foreground="#2ecc71" FontSize="9"/>
                                        <TextBlock Text="  Use DATE FILTER in sidebar" Foreground="#666" FontSize="9"/>
                                    </StackPanel>
                                </ToolTip>
                            </TextBox.ToolTip>
                        </TextBox>
                        <Button x:Name="SearchClearBtn" Content="✕" Width="20" Height="20" 
                                HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,4,0"
                                Background="Transparent" BorderThickness="0" Foreground="#555" 
                                FontSize="10" Cursor="Hand" Visibility="Collapsed">
                            <Button.Style>
                                <Style TargetType="Button">
                                    <Setter Property="Template">
                                        <Setter.Value>
                                            <ControlTemplate TargetType="Button">
                                                <Border x:Name="border" Background="Transparent" CornerRadius="2">
                                                    <TextBlock Text="✕" Foreground="#555" FontSize="11" 
                                                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                </Border>
                                                <ControlTemplate.Triggers>
                                                    <Trigger Property="IsMouseOver" Value="True">
                                                        <Setter TargetName="border" Property="Background" Value="#333"/>
                                                    </Trigger>
                                                </ControlTemplate.Triggers>
                                            </ControlTemplate>
                                        </Setter.Value>
                                    </Setter>
                                </Style>
                            </Button.Style>
                        </Button>
                    </Grid>
                    
                    <Border Background="#181818" BorderBrush="#252525" BorderThickness="1" Margin="0,8,0,0" Padding="8,6">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Grid>
                                <CheckBox x:Name="SearchContentChk" IsEnabled="False" VerticalAlignment="Center">
                                    <CheckBox.Style>
                                        <Style TargetType="CheckBox">
                                            <Setter Property="Foreground" Value="#555"/>
                                            <Setter Property="Template">
                                                <Setter.Value>
                                                    <ControlTemplate TargetType="CheckBox">
                                                        <StackPanel Orientation="Horizontal">
                                                            <Border x:Name="box" Width="12" Height="12" Background="#222" BorderBrush="#444" BorderThickness="1" CornerRadius="2" VerticalAlignment="Center">
                                                                <TextBlock x:Name="check" Text="✓" Foreground="#9b59b6" FontSize="9" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" Margin="0,-1,0,0"/>
                                                            </Border>
                                                            <TextBlock Text="Include content" Foreground="{TemplateBinding Foreground}" FontSize="10" Margin="6,0,0,0" VerticalAlignment="Center"/>
                                                        </StackPanel>
                                                        <ControlTemplate.Triggers>
                                                            <Trigger Property="IsChecked" Value="True">
                                                                <Setter TargetName="check" Property="Visibility" Value="Visible"/>
                                                                <Setter TargetName="box" Property="BorderBrush" Value="#9b59b6"/>
                                                            </Trigger>
                                                            <Trigger Property="IsEnabled" Value="True">
                                                                <Setter Property="Foreground" Value="#888"/>
                                                                <Setter TargetName="box" Property="BorderBrush" Value="#555"/>
                                                            </Trigger>
                                                            <Trigger Property="IsMouseOver" Value="True">
                                                                <Setter TargetName="box" Property="Background" Value="#2a2a2a"/>
                                                            </Trigger>
                                                        </ControlTemplate.Triggers>
                                                    </ControlTemplate>
                                                </Setter.Value>
                                            </Setter>
                                        </Style>
                                    </CheckBox.Style>
                                </CheckBox>
                                <TextBlock x:Name="IndexedTxt" Text="" HorizontalAlignment="Right" Foreground="#555" FontSize="9" VerticalAlignment="Center"/>
                            </Grid>
                            <Button x:Name="IndexBtn" Grid.Row="1" Content="Index Chats" Style="{StaticResource SmallSidebarButton}" 
                                    Margin="0,8,0,0" Height="24" FontSize="10" ToolTip="Fetch content to enable deep search"/>
                        </Grid>
                    </Border>
                    
                    <TextBlock Text="STATISTICS" Foreground="#444" FontSize="9" FontWeight="SemiBold" Margin="0,16,0,6"/>
                    <Border Background="#1a1a1a" BorderBrush="#222" BorderThickness="1" Padding="6,4">
                        <StackPanel>
                            <Border x:Name="TotalRow" Background="Transparent" Padding="4" Margin="-4,0" Cursor="Hand" ToolTip="Click to show all">
                                <Grid>
                                    <TextBlock Text="Total" Foreground="#555" FontSize="10"/>
                                    <TextBlock x:Name="TotalTxt" Text="0" HorizontalAlignment="Right" Foreground="#3498db" FontSize="10" FontWeight="SemiBold"/>
                                </Grid>
                            </Border>
                            <Border Background="Transparent" Padding="4" Margin="-4,0">
                                <Grid>
                                    <TextBlock Text="Showing" Foreground="#555" FontSize="10"/>
                                    <TextBlock x:Name="ShowingTxt" Text="0" HorizontalAlignment="Right" Foreground="#2ecc71" FontSize="10" FontWeight="SemiBold"/>
                                </Grid>
                            </Border>
                            <Border x:Name="SelectedRow" Background="Transparent" Padding="4" Margin="-4,0" Cursor="Hand" ToolTip="Click to filter selected">
                                <Grid>
                                    <TextBlock Text="Selected" Foreground="#555" FontSize="10"/>
                                    <TextBlock x:Name="SelectedTxt" Text="0" HorizontalAlignment="Right" Foreground="#e67e22" FontSize="10" FontWeight="SemiBold"/>
                                </Grid>
                            </Border>
                        </StackPanel>
                    </Border>
                    
                    <TextBlock Text="SELECTION" Foreground="#444" FontSize="9" FontWeight="SemiBold" Margin="0,20,0,6"/>
                    <Button x:Name="SelectAllBtn" Content="Select All Visible" Style="{StaticResource SmallSidebarButton}" Margin="0,0,0,4"/>
                    <Button x:Name="DeselectBtn" Content="Clear Selection" Style="{StaticResource SmallSidebarButton}"/>
                    
                    <!-- Date Filter Section -->
                    <TextBlock Text="DATE FILTER" Foreground="#444" FontSize="9" FontWeight="SemiBold" Margin="0,20,0,6"/>
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="50"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="After:" Foreground="#555" FontSize="10" VerticalAlignment="Center"/>
                        <DatePicker x:Name="DateAfterPicker" Grid.Column="1" Height="26" FontSize="10" 
                                    Background="#1a1a1a" Foreground="#888" BorderBrush="#333"/>
                        <TextBlock Text="Before:" Foreground="#555" FontSize="10" VerticalAlignment="Center" Grid.Row="1" Margin="0,4,0,0"/>
                        <DatePicker x:Name="DateBeforePicker" Grid.Row="1" Grid.Column="1" Height="26" FontSize="10" 
                                    Background="#1a1a1a" Foreground="#888" BorderBrush="#333" Margin="0,4,0,0"/>
                        <Button x:Name="ClearDatesBtn" Grid.Row="2" Grid.ColumnSpan="2" Content="Clear Dates" 
                                Style="{StaticResource SmallSidebarButton}" Margin="0,6,0,0" Height="24"/>
                    </Grid>
                    
                    <!-- Stats Section -->
                    <TextBlock Text="STATS" Foreground="#444" FontSize="9" FontWeight="SemiBold" Margin="0,20,0,6"/>
                    <Border Background="#181818" BorderBrush="#252525" BorderThickness="1" Padding="8">
                        <StackPanel x:Name="StatsPanel">
                            <TextBlock x:Name="StatsSummary" Text="Load chats to see stats" Foreground="#555" FontSize="10" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>
                    
                    <!-- Recently Deleted Section -->
                    <TextBlock x:Name="RecentlyDeletedLabel" Text="RECENTLY DELETED (0)" Foreground="#444" FontSize="9" FontWeight="SemiBold" Margin="0,20,0,6" Visibility="Collapsed"/>
                    <Button x:Name="UndoDeleteBtn" Content="↩ Restore to List" Style="{StaticResource SmallSidebarButton}" 
                            Visibility="Collapsed" Margin="0,0,0,4" ToolTip="Local only - does not restore on server"/>
                    <Button x:Name="ClearDeletedBtn" Content="Clear Undo History" Style="{StaticResource SmallSidebarButton}" 
                            Visibility="Collapsed" Foreground="#666"/>
                    
                    <!-- Bottom spacer for scroll -->
                    <Border Height="20"/>
                </StackPanel>
                </ScrollViewer>
                
                <!-- Chat List -->
                <Grid Grid.Column="2">
                    <DataGrid x:Name="Grid" AutoGenerateColumns="False" Background="#161616"
                              RowBackground="#181818" AlternatingRowBackground="#1c1c1c"
                              BorderBrush="#222" BorderThickness="1" GridLinesVisibility="None"
                              HeadersVisibility="Column" CanUserAddRows="False" RowHeight="38" FontSize="11"
                              SelectionMode="Single" SelectionUnit="FullRow" CanUserSortColumns="True"
                              ScrollViewer.VerticalScrollBarVisibility="Auto"
                              ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                              VirtualizingPanel.IsVirtualizing="True"
                              VirtualizingPanel.VirtualizationMode="Recycling"
                              EnableRowVirtualization="True"
                              EnableColumnVirtualization="False">
                        <DataGrid.ContextMenu>
                            <ContextMenu Background="#1a1a1a" BorderBrush="#333" Foreground="#aaa" Padding="2">
                                <MenuItem x:Name="OpenChatMenu" Header="Open in Browser" Background="Transparent" Padding="10,6"/>
                                <MenuItem x:Name="CopyUrlMenu" Header="Copy URL" Background="Transparent" Padding="10,6"/>
                                <Separator Background="#333" Margin="4,2"/>
                                <MenuItem x:Name="CopyIdMenu" Header="Copy ID" Foreground="#666" Background="Transparent" Padding="10,6"/>
                            </ContextMenu>
                        </DataGrid.ContextMenu>
                        <DataGrid.Resources>
                            <Style TargetType="ScrollBar" BasedOn="{StaticResource MinimalScrollBar}"/>
                        </DataGrid.Resources>
                        <DataGrid.ColumnHeaderStyle>
                            <Style TargetType="DataGridColumnHeader" BasedOn="{StaticResource SortableHeader}"/>
                        </DataGrid.ColumnHeaderStyle>
                        <DataGrid.CellStyle>
                            <Style TargetType="DataGridCell">
                                <Setter Property="Foreground" Value="#aaa"/>
                                <Setter Property="BorderThickness" Value="0"/>
                                <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                                <Style.Triggers>
                                    <Trigger Property="IsSelected" Value="True">
                                        <Setter Property="Background" Value="#222"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </DataGrid.CellStyle>
                        <DataGrid.RowStyle>
                            <Style TargetType="DataGridRow">
                                <Setter Property="BorderThickness" Value="0"/>
                                <Setter Property="Cursor" Value="Hand"/>
                                <Style.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter Property="Background" Value="#1f1f1f"/>
                                    </Trigger>
                                    <Trigger Property="IsSelected" Value="True">
                                        <Setter Property="Background" Value="#252525"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </DataGrid.RowStyle>
                        <DataGrid.Columns>
                            <DataGridTemplateColumn Width="36">
                                <DataGridTemplateColumn.HeaderTemplate>
                                    <DataTemplate>
                                        <CheckBox x:Name="SelectAllChk" Style="{StaticResource GridCheckBox}" 
                                                  HorizontalAlignment="Center" VerticalAlignment="Center"
                                                  ToolTip="Select/Deselect All"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.HeaderTemplate>
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" 
                                                  Style="{StaticResource GridCheckBox}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="TITLE" Width="*" Binding="{Binding Name}" IsReadOnly="True" 
                                                CanUserSort="True" SortMemberPath="Name">
                                <DataGridTextColumn.ElementStyle>
                                    <Style TargetType="TextBlock">
                                        <Setter Property="Padding" Value="6,0"/>
                                        <Setter Property="VerticalAlignment" Value="Center"/>
                                        <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                                    </Style>
                                </DataGridTextColumn.ElementStyle>
                            </DataGridTextColumn>
                            <DataGridTemplateColumn x:Name="MatchCol" Header="MATCH" Width="65" IsReadOnly="True" Visibility="Collapsed">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <TextBlock Text="{Binding MatchType}" Foreground="#777" Padding="6,0" 
                                                   VerticalAlignment="Center" FontSize="9" FontStyle="Italic"
                                                   ToolTipService.ShowDuration="30000"
                                                   ToolTipService.InitialShowDelay="200">
                                            <TextBlock.Style>
                                                <Style TargetType="TextBlock">
                                                    <Style.Triggers>
                                                        <DataTrigger Binding="{Binding MatchPreview}" Value="">
                                                            <Setter Property="ToolTip" Value="{x:Null}"/>
                                                        </DataTrigger>
                                                    </Style.Triggers>
                                                    <Setter Property="ToolTip">
                                                        <Setter.Value>
                                                            <ToolTip MaxWidth="450" Padding="10,8">
                                                                <StackPanel>
                                                                    <TextBlock Text="Match Preview" FontWeight="SemiBold" Foreground="#888" FontSize="10" Margin="0,0,0,6"/>
                                                                    <TextBlock Text="{Binding MatchPreview}" TextWrapping="Wrap" MaxWidth="420" Foreground="#ccc"/>
                                                                </StackPanel>
                                                            </ToolTip>
                                                        </Setter.Value>
                                                    </Setter>
                                                </Style>
                                            </TextBlock.Style>
                                        </TextBlock>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>
                            <DataGridTextColumn Header="UPDATED" Width="100" IsReadOnly="True" 
                                                CanUserSort="True" SortMemberPath="Updated"
                                                Binding="{Binding Updated, StringFormat='MMM d, yyyy'}">
                                <DataGridTextColumn.ElementStyle>
                                    <Style TargetType="TextBlock">
                                        <Setter Property="Foreground" Value="#4a4a4a"/>
                                        <Setter Property="Padding" Value="6,0"/>
                                        <Setter Property="VerticalAlignment" Value="Center"/>
                                        <Setter Property="FontSize" Value="10"/>
                                    </Style>
                                </DataGridTextColumn.ElementStyle>
                            </DataGridTextColumn>
                        </DataGrid.Columns>
                    </DataGrid>
                    
                    <!-- Empty State -->
                    <Border x:Name="EmptyPanel" Background="#161616">
                        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                            <TextBlock Text="No conversations" Foreground="#3a3a3a" FontSize="14"/>
                            <TextBlock Text="Login and load chats to begin" Foreground="#2a2a2a" FontSize="11" Margin="0,4,0,0"/>
                        </StackPanel>
                    </Border>
                </Grid>
            </Grid>
            
            <!-- Footer -->
            <Border Grid.Row="2" Background="#161616" CornerRadius="0,0,8,8">
                <Grid Margin="16,0">
                    <TextBlock x:Name="FooterTxt" Text="Ready" VerticalAlignment="Center" Foreground="#3a3a3a" FontSize="10"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="ExportBtn" Content="Export" Style="{StaticResource FooterButton}" Margin="0,0,6,0"/>
                        <Button x:Name="DeleteBtn" Content="Delete Selected" Style="{StaticResource DeleteButton}"/>
                    </StackPanel>
                </Grid>
            </Border>
            
            <!-- Resize Grip -->
            <ResizeGrip x:Name="ResizeGrip" Grid.Row="2" HorizontalAlignment="Right" VerticalAlignment="Bottom" 
                        Cursor="SizeNWSE" Margin="0,0,4,4" Opacity="0.3"/>
        </Grid>
    </Border>
</Window>
'@

#endregion

#region Main Application

function Start-App
{
    Write-Host "`nStarting application..." -ForegroundColor Cyan
    
    # Initialize WebView2 SDK
    if (-not (Initialize-WebView2Sdk))
    {
        Write-Host "Failed to initialize WebView2 - exiting" -ForegroundColor Red
        return
    }
    
    # Parse main window XAML
    $window = [System.Windows.Markup.XamlReader]::Parse($script:main_xaml)
    
    # Build UI element lookup table
    $script:ui = @{}
    
    $element_names = @(
        'TitleBar', 'StatusDot', 'StatusTxt', 'MinBtn', 'MaxBtn', 'CloseBtn', 'HamburgerBtn',
        'SidebarScroller', 'SidebarPanel', 'LoginBtn', 'LoadBtn', 'SearchBox', 'SearchClearBtn', 'SearchContentChk', 
        'IndexedTxt', 'IndexBtn', 'TotalTxt', 'ShowingTxt', 'SelectedTxt', 'TotalRow', 
        'SelectedRow', 'SelectAllBtn', 'DeselectBtn', 
        'DateAfterPicker', 'DateBeforePicker', 'ClearDatesBtn',
        'StatsPanel', 'StatsSummary', 'RecentlyDeletedLabel', 'UndoDeleteBtn', 'ClearDeletedBtn',
        'Grid', 'EmptyPanel', 'FooterTxt', 'ExportBtn', 'DeleteBtn', 'ResizeGrip'
    )
    
    foreach ($name in $element_names)
    {
        $script:ui[$name] = $window.FindName($name)
    }
    
    $script:main_window = $window
    
    # Initialize observable collection
    $script:app_state.all_chats = [ObservableCollection[ChatItem]]::new()
    $script:ui['Grid'].ItemsSource = $script:app_state.all_chats
    
    #region Window Chrome and Resize
    
    # Title bar drag
    $script:ui['TitleBar'].Add_MouseLeftButtonDown({
        param($sender, $event_args)
        
        if ($event_args.ClickCount -eq 2)
        {
            # Double-click to maximize/restore
            $script:main_window.WindowState = if ($script:main_window.WindowState -eq 'Normal') { 'Maximized' } else { 'Normal' }
        }
        else
        {
            $script:main_window.DragMove()
        }
    })
    
    # Window controls
    $script:ui['MinBtn'].Add_Click({ $script:main_window.WindowState = 'Minimized' })
    
    $script:ui['MaxBtn'].Add_Click({
        $script:main_window.WindowState = if ($script:main_window.WindowState -eq 'Normal') { 'Maximized' } else { 'Normal' }
    })
    
    # Update maximize button icon on state change
    $window.Add_StateChanged({
        if ($script:main_window.WindowState -eq 'Maximized')
        {
            $script:ui['MaxBtn'].Content = [char]0xE923  # Restore
            $script:ui['ResizeGrip'].Visibility = 'Collapsed'
        }
        else
        {
            $script:ui['MaxBtn'].Content = [char]0xE922  # Maximize
            $script:ui['ResizeGrip'].Visibility = 'Visible'
        }
    })
    
    # WindowChrome handles resize - just set mode
    $window.ResizeMode = 'CanResize'
    
    #endregion
    
    #region Sidebar Toggle
    
    # Helper to update hamburger icon appearance
    $script:update_hamburger_icon = {
        param([bool]$collapsed)
        
        $btn = $script:ui['HamburgerBtn']
        if (-not $btn) { return }
        
        # Find the template elements
        $template = $btn.Template
        if (-not $template) { return }
        
        $hamburger_lines = $template.FindName('HamburgerLines', $btn)
        $arrow_icon = $template.FindName('ArrowIcon', $btn)
        
        if ($hamburger_lines -and $arrow_icon)
        {
            if ($collapsed)
            {
                # Show arrow, hide hamburger
                $hamburger_lines.Opacity = 0
                $arrow_icon.Opacity = 1
            }
            else
            {
                # Show hamburger, hide arrow
                $hamburger_lines.Opacity = 1
                $arrow_icon.Opacity = 0
            }
        }
    }
    
    $script:toggle_sidebar = {
        $sidebar_column = $script:main_window.FindName('SidebarColumn')
        
        if ($script:ui_cache.sidebar_collapsed)
        {
            # Expand
            $sidebar_column.Width = [System.Windows.GridLength]::new(180)
            $script:ui['SidebarScroller'].Visibility = 'Visible'
            $script:ui_cache.sidebar_collapsed = $false
            & $script:update_hamburger_icon $false
        }
        else
        {
            # Collapse
            $sidebar_column.Width = [System.Windows.GridLength]::new(0)
            $script:ui['SidebarScroller'].Visibility = 'Collapsed'
            $script:ui_cache.sidebar_collapsed = $true
            & $script:update_hamburger_icon $true
        }
    }
    
    $script:ui['HamburgerBtn'].Add_Click({
        & $script:toggle_sidebar
    })
    
    # Restore sidebar state after window loads
    $window.Add_ContentRendered({
        if ($script:ui_cache.sidebar_collapsed)
        {
            $sidebar_column = $script:main_window.FindName('SidebarColumn')
            $sidebar_column.Width = [System.Windows.GridLength]::new(0)
            $script:ui['SidebarScroller'].Visibility = 'Collapsed'
            & $script:update_hamburger_icon $true
        }
    })
    
    #endregion
    
    #region Search Clear Button
    
    $script:ui['SearchBox'].Add_TextChanged({
        # Show/hide clear button based on text
        if ($script:ui['SearchBox'].Text.Length -gt 0)
        {
            $script:ui['SearchClearBtn'].Visibility = 'Visible'
        }
        else
        {
            $script:ui['SearchClearBtn'].Visibility = 'Collapsed'
        }
        
        # Trigger debounced search
        $script:timers.search_debounce.Stop()
        $script:timers.search_debounce.Start()
    })
    
    $script:ui['SearchClearBtn'].Add_Click({
        $script:ui['SearchBox'].Text = ""
        $script:ui['SearchBox'].Focus()
    })
    
    #endregion
    
    #region Date Filters
    
    $script:apply_date_filter = {
        # This is called when date pickers change
        $after_date  = $script:ui['DateAfterPicker'].SelectedDate
        $before_date = $script:ui['DateBeforePicker'].SelectedDate
        
        if (-not $after_date -and -not $before_date)
        {
            # No date filter, use text filter only
            & $script:apply_filter_core
            return
        }
        
        # Apply combined filter
        if (-not $script:ui_cache.collection_view)
        {
            $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
        }
        
        $view = $script:ui_cache.collection_view
        
        $script:ui_cache.date_after  = $after_date
        $script:ui_cache.date_before = $before_date
        
        # Get search mode for text filter
        $search_text = $script:ui['SearchBox'].Text.Trim()
        $search_mode = Get-SearchMode -SearchText $search_text
        $script:ui_cache.current_search_mode = $search_mode
        
        $search_content = $script:ui['SearchContentChk'].IsChecked -eq $true
        
        $view.Filter = [Predicate[object]]{
            param($item)
            
            # Check date range first
            $date_after  = $script:ui_cache.date_after
            $date_before = $script:ui_cache.date_before
            
            if ($date_after -and $item.Updated -lt $date_after)
            {
                return $false
            }
            
            if ($date_before -and $item.Updated -gt $date_before)
            {
                return $false
            }
            
            # Then check text filter
            $mode = $script:ui_cache.current_search_mode
            
            if ($mode.Mode -eq 'None' -or $mode.Mode -eq 'All')
            {
                # Check exclusions only
                if ($mode.Exclusions -and $mode.Exclusions.Count -gt 0)
                {
                    foreach ($exclusion in $mode.Exclusions)
                    {
                        if ($item.NameLower.Contains($exclusion)) { return $false }
                    }
                }
                return $true
            }
            
            $search_content_enabled = $script:ui['SearchContentChk'].IsChecked -eq $true
            
            $title_match = Test-SearchMatch -Text $item.Name -TextLower $item.NameLower -SearchMode $mode
            $content_match = $search_content_enabled -and $item.ContentIndexed -and 
                            (Test-SearchMatch -Text $item.Content -TextLower $item.ContentLower -SearchMode $mode)
            
            return ($title_match -or $content_match)
        }
        
        # Count visible
        $count = 0
        $enumerator = $view.GetEnumerator()
        while ($enumerator.MoveNext()) { $count++ }
        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
        
        $script:ui['ShowingTxt'].Text = $count
        $script:ui['FooterTxt'].Text  = "Showing $count (date filtered)"
    }
    
    if ($script:ui['DateAfterPicker'])
    {
        $script:ui['DateAfterPicker'].Add_SelectedDateChanged({
            & $script:apply_date_filter
        })
    }
    
    if ($script:ui['DateBeforePicker'])
    {
        $script:ui['DateBeforePicker'].Add_SelectedDateChanged({
            & $script:apply_date_filter
        })
    }
    
    if ($script:ui['ClearDatesBtn'])
    {
        $script:ui['ClearDatesBtn'].Add_Click({
            $script:ui['DateAfterPicker'].SelectedDate  = $null
            $script:ui['DateBeforePicker'].SelectedDate = $null
            $script:ui_cache.date_after  = $null
            $script:ui_cache.date_before = $null
            & $script:apply_filter_core
        })
    }
    
    #endregion
    
    #region Undo Delete Functionality
    
    if ($script:ui['UndoDeleteBtn'])
    {
        $script:ui['UndoDeleteBtn'].Add_Click({
            if ($script:app_state.deleted_buffer.Count -eq 0)
            {
                $script:ui['FooterTxt'].Text = "Nothing to restore"
                return
            }
            
            # Restore items
            foreach ($item in $script:app_state.deleted_buffer)
            {
                $script:app_state.all_chats.Add($item)
            }
            
            $restored_count = $script:app_state.deleted_buffer.Count
            $script:app_state.deleted_buffer = @()
            
            Update-DeletedBufferUI
            Update-StatsDisplay
            
            $script:ui['FooterTxt'].Text = "Restored $restored_count to local list (server deletion is permanent)"
        })
    }
    
    if ($script:ui['ClearDeletedBtn'])
    {
        $script:ui['ClearDeletedBtn'].Add_Click({
            $script:app_state.deleted_buffer = @()
            Update-DeletedBufferUI
            $script:ui['FooterTxt'].Text = "Undo history cleared"
        })
    }
    
    #endregion
    
    #region Window State Persistence
    
    # Restore window state on load
    Restore-WindowState -Window $window
    
    # Save window state on close and confirm if selections
    $window.Add_Closing({
        param($sender, $event_args)
        
        # Check for selections
        $selected_count = 0
        if ($script:app_state.all_chats)
        {
            foreach ($chat in $script:app_state.all_chats)
            {
                if ($chat.Selected) { $selected_count++ }
            }
        }
        
        if ($selected_count -gt 0)
        {
            $result = [System.Windows.MessageBox]::Show(
                "You have $selected_count conversation(s) selected.`n`nClose anyway?",
                "Confirm Close", 'YesNo', 'Question')
            
            if ($result -ne 'Yes')
            {
                $event_args.Cancel = $true
                return
            }
        }
        
        Save-WindowState -Window $script:main_window
    })
    
    #endregion
    
    #region Keyboard Shortcuts
    
    $window.Add_PreviewKeyDown({
        param($sender, $event_args)
        
        # Skip if search box has focus (except Escape)
        $search_focused = $script:ui['SearchBox'].IsFocused
        
        # Ctrl+F - Focus search
        if ($event_args.Key -eq 'F' -and $event_args.KeyboardDevice.Modifiers -eq 'Control')
        {
            $script:ui['SearchBox'].Focus()
            $script:ui['SearchBox'].SelectAll()
            $event_args.Handled = $true
        }
        # Escape - Clear search if focused, or deselect all
        elseif ($event_args.Key -eq 'Escape')
        {
            if ($search_focused)
            {
                $script:ui['SearchBox'].Text = ""
                $script:ui['Grid'].Focus()
            }
            else
            {
                # Deselect all
                foreach ($chat in $script:app_state.all_chats)
                {
                    $chat.Selected = $false
                }
            }
            $event_args.Handled = $true
        }
        # Delete - Delete selected chats
        elseif ($event_args.Key -eq 'Delete' -and -not $search_focused)
        {
            if ($script:ui['DeleteBtn'].IsEnabled)
            {
                $script:ui['DeleteBtn'].RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
            $event_args.Handled = $true
        }
        # Ctrl+A - Select all visible
        elseif ($event_args.Key -eq 'A' -and $event_args.KeyboardDevice.Modifiers -eq 'Control' -and -not $search_focused)
        {
            $script:ui['SelectAllBtn'].RaiseEvent(
                [System.Windows.RoutedEventArgs]::new(
                    [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $event_args.Handled = $true
        }
        # Spacebar - Toggle selection of current row
        elseif ($event_args.Key -eq 'Space' -and -not $search_focused)
        {
            $selected_item = $script:ui['Grid'].SelectedItem
            if ($selected_item)
            {
                $selected_item.Selected = -not $selected_item.Selected
            }
            $event_args.Handled = $true
        }
        # Arrow keys - Navigate and optionally select
        elseif (($event_args.Key -eq 'Up' -or $event_args.Key -eq 'Down') -and -not $search_focused)
        {
            $grid = $script:ui['Grid']
            $current_index = $grid.SelectedIndex
            $is_shift = $event_args.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Shift
            
            $new_index = if ($event_args.Key -eq 'Up') 
            { 
                [Math]::Max(0, $current_index - 1) 
            } 
            else 
            { 
                [Math]::Min($grid.Items.Count - 1, $current_index + 1) 
            }
            
            if ($new_index -ne $current_index)
            {
                # If shift is held, select the item we're leaving
                if ($is_shift -and $current_index -ge 0)
                {
                    $current_item = $grid.Items[$current_index]
                    if ($current_item) { $current_item.Selected = $true }
                }
                
                $grid.SelectedIndex = $new_index
                $grid.ScrollIntoView($grid.SelectedItem)
                
                # If shift is held, also select the new item
                if ($is_shift)
                {
                    $new_item = $grid.Items[$new_index]
                    if ($new_item) { $new_item.Selected = $true }
                }
            }
            
            $event_args.Handled = $true
        }
        # Home - Go to first item
        elseif ($event_args.Key -eq 'Home' -and -not $search_focused)
        {
            $script:ui['Grid'].SelectedIndex = 0
            $script:ui['Grid'].ScrollIntoView($script:ui['Grid'].SelectedItem)
            $event_args.Handled = $true
        }
        # End - Go to last item
        elseif ($event_args.Key -eq 'End' -and -not $search_focused)
        {
            $script:ui['Grid'].SelectedIndex = $script:ui['Grid'].Items.Count - 1
            $script:ui['Grid'].ScrollIntoView($script:ui['Grid'].SelectedItem)
            $event_args.Handled = $true
        }
        # Ctrl+Z - Undo delete
        elseif ($event_args.Key -eq 'Z' -and $event_args.KeyboardDevice.Modifiers -eq 'Control')
        {
            if ($script:ui['UndoDeleteBtn'].Visibility -eq 'Visible')
            {
                $script:ui['UndoDeleteBtn'].RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new(
                        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
            $event_args.Handled = $true
        }
        # Ctrl+B - Toggle sidebar
        elseif ($event_args.Key -eq 'B' -and $event_args.KeyboardDevice.Modifiers -eq 'Control')
        {
            & $script:toggle_sidebar
            $event_args.Handled = $true
        }
    })
    
    #endregion
    
    #region Close Button and Cleanup
    
    $script:timers = @{
        selection_timer      = $null
        search_debounce      = $null
        session_check        = $null
    }
    
    $script:ui['CloseBtn'].Add_Click({
        # Stop all timers
        foreach ($key in $script:timers.Keys)
        {
            if ($script:timers[$key])
            {
                $script:timers[$key].Stop()
            }
        }
        
        $script:main_window.Close()
    })
    
    #endregion
    
    #region Collection Change Handler
    
    $script:app_state.all_chats.Add_CollectionChanged({
        # Note: collection_view stays valid when underlying collection changes
        # Only null out match_column as columns might change
        $script:ui_cache.match_column = $null
        
        # Reset last clicked index as indices may have shifted
        $script:_last_clicked_index = -1
        
        $count = $script:app_state.all_chats.Count
        $script:ui['TotalTxt'].Text       = $count
        $script:ui['ShowingTxt'].Text     = $count
        $script:ui['EmptyPanel'].Visibility = if ($count -eq 0) { 'Visible' } else { 'Collapsed' }
    })
    
    #endregion
    
    #region Selection Counting (Event-Driven with Timer Fallback)
    
    # Use timer but only update when needed
    $selection_timer = [System.Windows.Threading.DispatcherTimer]::new()
    $selection_timer.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.SELECTION_POLL_MS)
    $script:timers.selection_timer = $selection_timer
    
    $script:_last_selection_count = 0
    
    $selection_timer.Add_Tick({
        # Efficient counting with early exit
        $count = 0
        $chats = $script:app_state.all_chats
        $total = $chats.Count
        
        for ($i = 0; $i -lt $total; $i++)
        {
            if ($chats[$i].Selected) { $count++ }
        }
        
        # Only update UI if changed
        if ($count -ne $script:_last_selection_count)
        {
            $script:ui['SelectedTxt'].Text = $count
            $script:_last_selection_count  = $count
            
            # Update footer with selection info
            if ($count -gt 0)
            {
                $visible = $script:ui['ShowingTxt'].Text
                $script:ui['FooterTxt'].Text = "Selected: $count of $visible visible"
            }
        }
    })
    
    $selection_timer.Start()
    
    #endregion
    
    #region Context Menu
    
    $context_menu = $script:ui['Grid'].ContextMenu
    
    # Open in browser
    $context_menu.Items[0].Add_Click({
        $item = $script:ui['Grid'].SelectedItem
        if ($item)
        {
            $url = "https://claude.ai/chat/$($item.Id)"
            Write-Host "Opening: $url" -ForegroundColor Cyan
            Start-Process $url
        }
    })
    
    # Copy URL
    $context_menu.Items[1].Add_Click({
        $item = $script:ui['Grid'].SelectedItem
        if ($item)
        {
            $url = "https://claude.ai/chat/$($item.Id)"
            [System.Windows.Clipboard]::SetText($url)
            $script:ui['FooterTxt'].Text = "URL copied to clipboard"
        }
    })
    
    # Copy ID
    $context_menu.Items[3].Add_Click({
        $item = $script:ui['Grid'].SelectedItem
        if ($item)
        {
            [System.Windows.Clipboard]::SetText($item.Id)
            $script:ui['FooterTxt'].Text = "ID copied to clipboard"
        }
    })
    
    #endregion
    
    #region Double-Click to Open
    
    $script:ui['Grid'].Add_MouseDoubleClick({
        param($sender, $event_args)
        
        $item = $script:ui['Grid'].SelectedItem
        if ($item)
        {
            $url = "https://claude.ai/chat/$($item.Id)"
            Write-Host "Opening: $url" -ForegroundColor Cyan
            Start-Process $url
        }
    })
    
    #endregion
    
    #region Row Tooltips
    
    $script:ui['Grid'].Add_LoadingRow({
        param($sender, $event_args)
        
        $item = $event_args.Row.DataContext
        if ($item -and $item.Id)
        {
            $event_args.Row.ToolTip = "ID: $($item.Id)`nUpdated: $($item.Updated.ToString('f'))"
        }
    })
    
    #endregion
    
    #region Shift-Click Range Selection
    
    $script:_last_clicked_index = -1
    
    # Helper to get item index in visible collection
    $script:get_visible_index = {
        param($item)
        
        if (-not $script:ui_cache.collection_view)
        {
            $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
        }
        
        $index = 0
        $enumerator = $script:ui_cache.collection_view.GetEnumerator()
        while ($enumerator.MoveNext())
        {
            if ($enumerator.Current -eq $item) 
            { 
                if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
                return $index 
            }
            $index++
        }
        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
        return -1
    }
    
    # Helper to get item at visible index
    $script:get_item_at_index = {
        param($target_index)
        
        if (-not $script:ui_cache.collection_view)
        {
            $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
        }
        
        $index = 0
        $enumerator = $script:ui_cache.collection_view.GetEnumerator()
        while ($enumerator.MoveNext())
        {
            if ($index -eq $target_index) 
            { 
                $result = $enumerator.Current
                if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
                return $result
            }
            $index++
        }
        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
        return $null
    }
    
    $script:ui['Grid'].Add_PreviewMouseLeftButtonUp({
        param($sender, $event_args)
        
        # Get the clicked element
        $dep_obj = $event_args.OriginalSource
        if (-not $dep_obj) { return }
        
        # Walk up visual tree to find DataGridRow
        $row = $null
        $current = $dep_obj
        while ($current -ne $null)
        {
            if ($current -is [System.Windows.Controls.DataGridRow])
            {
                $row = $current
                break
            }
            
            if ($current -is [System.Windows.DependencyObject])
            {
                $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
            }
            else
            {
                break
            }
        }
        
        if (-not $row) { return }
        
        $clicked_item = $row.DataContext
        if (-not $clicked_item) { return }
        
        $clicked_index = & $script:get_visible_index $clicked_item
        
        # Check if clicking on checkbox - if so, just track index, don't modify selection
        $is_checkbox = $false
        $check_current = $dep_obj
        while ($check_current -ne $null -and $check_current -ne $row)
        {
            if ($check_current -is [System.Windows.Controls.CheckBox])
            {
                $is_checkbox = $true
                break
            }
            if ($check_current -is [System.Windows.DependencyObject])
            {
                $check_current = [System.Windows.Media.VisualTreeHelper]::GetParent($check_current)
            }
            else { break }
        }
        
        # Handle shift-click for range selection
        $is_shift = [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::LeftShift) -or 
                    [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::RightShift)
        
        if ($is_shift -and $script:_last_clicked_index -ge 0 -and -not $is_checkbox)
        {
            # Calculate range
            $start = [Math]::Min($script:_last_clicked_index, $clicked_index)
            $end   = [Math]::Max($script:_last_clicked_index, $clicked_index)
            
            # Select all items in range
            for ($i = $start; $i -le $end; $i++)
            {
                $item = & $script:get_item_at_index $i
                if ($item) { $item.Selected = $true }
            }
            
            $script:ui['FooterTxt'].Text = "Selected range: $($end - $start + 1) items"
        }
        
        # Update last clicked index
        $script:_last_clicked_index = $clicked_index
    })
    
    #endregion
    
    #region Connection State Helper
    
    $script:set_connected = {
        param([bool]$connected)
        
        $green = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(46, 204, 113))
        $gray  = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(85, 85, 85))
        $text_gray = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(102, 102, 102))
        
        if ($connected)
        {
            $script:ui['StatusDot'].Fill       = $green
            $script:ui['StatusTxt'].Text       = "Connected"
            $script:ui['StatusTxt'].Foreground = $text_gray
            $script:ui['LoadBtn'].IsEnabled    = $true
            $script:ui['DeleteBtn'].IsEnabled  = $true
            $script:ui['LoginBtn'].Content     = "Logout"
            
            if ($script:app_state.has_loaded_once)
            {
                $script:ui['LoadBtn'].Content = "Refresh Chats"
            }
        }
        else
        {
            $script:ui['StatusDot'].Fill       = $gray
            $script:ui['StatusTxt'].Text       = "Disconnected"
            $script:ui['StatusTxt'].Foreground = $gray
            $script:ui['LoadBtn'].IsEnabled    = $false
            $script:ui['LoadBtn'].Content      = "Load Chats"
            $script:ui['DeleteBtn'].IsEnabled  = $false
            $script:ui['LoginBtn'].Content     = "Login"
            $script:app_state.org_id           = $null
            $script:app_state.cookie           = $null
        }
    }
    
    #endregion
    
    #region Search/Filter Logic
    
    # Debounce timer
    $search_debounce = [System.Windows.Threading.DispatcherTimer]::new()
    $search_debounce.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.SEARCH_DEBOUNCE_MS)
    $script:timers.search_debounce = $search_debounce
    
    $script:apply_filter_core = {
        $search_text    = $script:ui['SearchBox'].Text.Trim()
        $search_content = $script:ui['SearchContentChk'].IsChecked -eq $true
        
        # Parse search mode
        $search_mode = Get-SearchMode -SearchText $search_text
        $script:ui_cache.current_search_mode = $search_mode
        
        # Get or create collection view
        if (-not $script:ui_cache.collection_view)
        {
            $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
        }
        
        $view = $script:ui_cache.collection_view
        
        # Get match column
        if (-not $script:ui_cache.match_column)
        {
            $script:ui_cache.match_column = $script:ui['Grid'].Columns | Where-Object { $_.Header -eq 'MATCH' }
        }
        
        $match_col = $script:ui_cache.match_column
        
        # Reset selected-only filter
        if ($script:ui_state.showing_selected_only)
        {
            $script:ui_state.showing_selected_only = $false
            $script:ui['SelectedRow'].Background = [System.Windows.Media.Brushes]::Transparent
        }
        
        # Clear previous match data
        $chats = $script:app_state.all_chats
        for ($i = 0; $i -lt $chats.Count; $i++)
        {
            $chats[$i].MatchType    = ""
            $chats[$i].MatchPreview = ""
        }
        
        if ($search_mode.Mode -ne 'None')
        {
            # Build footer text based on mode
            $mode_text = switch ($search_mode.Mode) {
                'Contains' { "" }
                'Or'       { " (OR: $($search_mode.Terms.Count) terms)" }
                'Regex'    { " (regex)" }
                'Id'       { " (ID search: $($search_mode.Ids.Count) IDs)" }
                default    { "" }
            }
            
            # ID search mode - special handling
            if ($search_mode.Mode -eq 'Id')
            {
                $view.Filter = [Predicate[object]]{
                    param($item)
                    
                    $mode = $script:ui_cache.current_search_mode
                    
                    foreach ($search_id in $mode.Ids)
                    {
                        # Exact match or contains
                        if ($item.Id -eq $search_id -or $item.Id.Contains($search_id))
                        {
                            $item.MatchType = "id"
                            $item.MatchPreview = "ID: $($item.Id)"
                            return $true
                        }
                    }
                    return $false
                }
                
                if ($match_col) { $match_col.Visibility = 'Visible' }
            }
            elseif ($search_content)
            {
                # Search title + content with advanced modes
                $view.Filter = [Predicate[object]]{
                    param($item)
                    
                    $mode = $script:ui_cache.current_search_mode
                    
                    $title_match   = Test-SearchMatch -Text $item.Name -TextLower $item.NameLower -SearchMode $mode
                    $content_match = $item.ContentIndexed -and (Test-SearchMatch -Text $item.Content -TextLower $item.ContentLower -SearchMode $mode)
                    
                    if ($title_match -or $content_match)
                    {
                        # Build preview
                        $previews = @()
                        
                        if ($title_match)
                        {
                            $snippet = Get-SearchMatchSnippet -Text $item.Name -SearchMode $mode -ContextChars 30
                            if ($snippet) { $previews += "TITLE: $snippet" }
                        }
                        
                        if ($content_match)
                        {
                            $snippet = Get-SearchMatchSnippet -Text $item.Content -SearchMode $mode -ContextChars 60
                            if ($snippet) { $previews += "CONTENT: $snippet" }
                        }
                        
                        if ($title_match -and $content_match)
                        {
                            $item.MatchType = "both"
                        }
                        elseif ($title_match)
                        {
                            $item.MatchType = "title"
                        }
                        else
                        {
                            $item.MatchType = "content"
                        }
                        
                        $item.MatchPreview = $previews -join "`n`n"
                        return $true
                    }
                    
                    return $false
                }
                
                if ($match_col) { $match_col.Visibility = 'Visible' }
            }
            else
            {
                # Title-only search with advanced modes
                $view.Filter = [Predicate[object]]{
                    param($item)
                    
                    $mode = $script:ui_cache.current_search_mode
                    return Test-SearchMatch -Text $item.Name -TextLower $item.NameLower -SearchMode $mode
                }
                
                if ($match_col) { $match_col.Visibility = 'Collapsed' }
            }
            
            # Count visible items
            $count = 0
            $enumerator = $view.GetEnumerator()
            while ($enumerator.MoveNext()) { $count++ }
            if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
            
            $script:ui['ShowingTxt'].Text = $count
            
            $suffix = if ($search_content -and $search_mode.Mode -ne 'Id') { " (title + content)" } else { "" }
            $script:ui['FooterTxt'].Text = "Found $count matches$mode_text$suffix"
        }
        else
        {
            $view.Filter = $null
            if ($match_col) { $match_col.Visibility = 'Collapsed' }
            
            $script:ui['ShowingTxt'].Text = $chats.Count
            
            if ($chats.Count -gt 0)
            {
                $script:ui['FooterTxt'].Text = "$($chats.Count) conversations"
            }
        }
    }
    
    $search_debounce.Add_Tick({
        $script:timers.search_debounce.Stop()
        & $script:apply_filter_core
    })
    
    $script:ui['SearchContentChk'].Add_Click({
        & $script:apply_filter_core
    })
    
    #endregion
    
    #region Statistics Row Interactions
    
    $hover_brush       = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(37, 37, 37))
    $selected_brush    = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(45, 35, 25))
    $transparent_brush = [System.Windows.Media.Brushes]::Transparent
    
    # Hover effects
    $script:ui['TotalRow'].Add_MouseEnter({ $script:ui['TotalRow'].Background = $hover_brush })
    $script:ui['TotalRow'].Add_MouseLeave({ $script:ui['TotalRow'].Background = $transparent_brush })
    $script:ui['SelectedRow'].Add_MouseEnter({ $script:ui['SelectedRow'].Background = $hover_brush })
    $script:ui['SelectedRow'].Add_MouseLeave({ 
        if (-not $script:ui_state.showing_selected_only)
        {
            $script:ui['SelectedRow'].Background = $transparent_brush 
        }
    })
    
    # Click Total = show all
    $script:ui['TotalRow'].Add_MouseLeftButtonUp({
        $script:ui_state.showing_selected_only = $false
        $script:ui['SearchBox'].Text = ""
        
        if ($script:ui_cache.collection_view)
        {
            $script:ui_cache.collection_view.Filter = $null
        }
        
        $count = $script:app_state.all_chats.Count
        $script:ui['ShowingTxt'].Text         = $count
        $script:ui['FooterTxt'].Text          = "Showing all $count conversations"
        $script:ui['SelectedRow'].Background  = $transparent_brush
    })
    
    # Click Selected = filter to selected
    $script:ui['SelectedRow'].Add_MouseLeftButtonUp({
        $selected_count = [int]$script:ui['SelectedTxt'].Text
        
        if ($selected_count -eq 0)
        {
            $script:ui['FooterTxt'].Text = "No items selected"
            return
        }
        
        $script:ui_state.showing_selected_only = -not $script:ui_state.showing_selected_only
        
        if (-not $script:ui_cache.collection_view)
        {
            $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
        }
        
        $view = $script:ui_cache.collection_view
        
        if ($script:ui_state.showing_selected_only)
        {
            $script:ui['SearchBox'].Text = ""
            $view.Filter = [Predicate[object]]{ param($item) $item.Selected }
            $script:ui['ShowingTxt'].Text        = $selected_count
            $script:ui['FooterTxt'].Text         = "Showing $selected_count selected"
            $script:ui['SelectedRow'].Background = $selected_brush
        }
        else
        {
            $view.Filter = $null
            $count = $script:app_state.all_chats.Count
            $script:ui['ShowingTxt'].Text        = $count
            $script:ui['FooterTxt'].Text         = "$count conversations"
            $script:ui['SelectedRow'].Background = $transparent_brush
        }
    })
    
    #endregion
    
    #region Header Checkbox for Select All
    
    $script:find_header_checkbox = {
        param($parent)
        
        $child_count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent)
        
        for ($i = 0; $i -lt $child_count; $i++)
        {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $i)
            
            if ($child -is [System.Windows.Controls.CheckBox])
            {
                return $child
            }
            
            $result = & $script:find_header_checkbox $child
            if ($result) { return $result }
        }
        
        return $null
    }
    
    $script:ui['Grid'].Add_Loaded({
        # Delay to let headers render - only run once
        if ($script:_header_checkbox_connected) { return }
        
        $script:_header_init_timer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:_header_init_timer.Interval = [TimeSpan]::FromMilliseconds(200)
        
        $script:_header_init_timer.Add_Tick({
            param($sender, $event_args)
            
            $sender.Stop()
            
            # Skip if already connected
            if ($script:_header_checkbox_connected) { return }
            
            $checkbox = & $script:find_header_checkbox $script:ui['Grid']
            
            if ($checkbox)
            {
                $script:ui_cache.header_checkbox = $checkbox
                $script:_header_checkbox_connected = $true
                
                $checkbox.Add_Click({
                    $is_checked = $script:ui_cache.header_checkbox.IsChecked
                    
                    # Ensure we have a collection view
                    if (-not $script:ui_cache.collection_view)
                    {
                        $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
                    }
                    
                    # Select/deselect visible items
                    if ($script:ui_cache.collection_view)
                    {
                        $enumerator = $script:ui_cache.collection_view.GetEnumerator()
                        while ($enumerator.MoveNext())
                        {
                            $enumerator.Current.Selected = $is_checked
                        }
                        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
                    }
                })
                
                Write-Host "Header checkbox connected" -ForegroundColor DarkGray
            }
        })
        
        $script:_header_init_timer.Start()
    })
    
    #endregion
    
    #region Select All / Deselect Buttons
    
    $script:ui['SelectAllBtn'].Add_Click({
        if (-not $script:ui_cache.collection_view)
        {
            $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
        }
        
        $enumerator = $script:ui_cache.collection_view.GetEnumerator()
        while ($enumerator.MoveNext())
        {
            $enumerator.Current.Selected = $true
        }
        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
        
        if ($script:ui_cache.header_checkbox)
        {
            $script:ui_cache.header_checkbox.IsChecked = $true
        }
    })
    
    $script:ui['DeselectBtn'].Add_Click({
        $chats = $script:app_state.all_chats
        for ($i = 0; $i -lt $chats.Count; $i++)
        {
            $chats[$i].Selected = $false
        }
        
        if ($script:ui_cache.header_checkbox)
        {
            $script:ui_cache.header_checkbox.IsChecked = $false
        }
    })
    
    #endregion
    
    #region Login/Logout Button
    
    $script:ui['LoginBtn'].Add_Click({
        if ($script:ui['LoginBtn'].Content -eq "Logout")
        {
            # Confirm logout
            $confirm = [System.Windows.MessageBox]::Show(
                "Log out and clear saved session?",
                "Confirm Logout", 'YesNo', 'Question')
            
            if ($confirm -ne 'Yes') { return }
            
            Clear-Credentials
            & $script:set_connected $false
            $script:app_state.all_chats.Clear()
            $script:app_state.has_loaded_once = $false
            $script:ui['FooterTxt'].Text = "Logged out"
            Write-Host "Logged out" -ForegroundColor Yellow
        }
        else
        {
            # Login
            Update-ButtonState -Button $script:ui['LoginBtn'] -Text "Logging in..." -Enabled $false
            
            $result = Show-LoginDialog -Owner $script:main_window
            
            if ($result)
            {
                $script:app_state.org_id  = $result.org_id
                $script:app_state.cookie  = $result.cookie
                Save-Credentials -OrgId $result.org_id -Cookie $result.cookie
                & $script:set_connected $true
                $script:ui['FooterTxt'].Text = "Login successful"
            }
            
            Update-ButtonState -Button $script:ui['LoginBtn'] -Text "Login" -Enabled $true
            
            if ($script:app_state.org_id)
            {
                $script:ui['LoginBtn'].Content = "Logout"
            }
        }
    })
    
    #endregion
    
    #region Load Chats Button
    
    $script:ui['LoadBtn'].Add_Click({
        Write-Host "`n=== Loading chats ===" -ForegroundColor Magenta
        
        Update-ButtonState -Button $script:ui['LoadBtn'] -Text "Loading..." -Enabled $false
        
        $script:app_state.all_chats.Clear()
        $script:ui['EmptyPanel'].Visibility = 'Collapsed'
        
        # Reset index
        $script:ui['IndexedTxt'].Text            = ""
        $script:ui['SearchContentChk'].IsEnabled = $false
        $script:ui['SearchContentChk'].IsChecked = $false
        
        $count = Get-AllChats `
            -Owner $script:main_window `
            -TargetCollection $script:app_state.all_chats `
            -OnProgress {
                param($n)
                $script:ui['FooterTxt'].Text = "$n conversations found..."
            }
        
        $script:ui['FooterTxt'].Text  = "$count conversations loaded"
        $script:ui['TotalTxt'].Text   = $count
        $script:ui['ShowingTxt'].Text = $count
        
        # Ensure collection view is initialized for filtering/selection
        $script:ui_cache.collection_view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:app_state.all_chats)
        
        # Reset shift-click tracking
        $script:_last_clicked_index = -1
        
        if (-not $script:app_state.has_loaded_once)
        {
            $script:app_state.has_loaded_once = $true
        }
        
        Update-ButtonState -Button $script:ui['LoadBtn'] -Text "Refresh Chats" -Enabled $true
        
        # Update stats display
        Update-StatsDisplay
        
        Write-Host "=== Loaded $count chats ===" -ForegroundColor Magenta
    })
    
    #endregion
    
    #region Index Button
    
    $script:ui['IndexBtn'].Add_Click({
        if ($script:app_state.all_chats.Count -eq 0)
        {
            [System.Windows.MessageBox]::Show("No conversations to index. Load chats first.", "Index", 'OK', 'Information')
            return
        }
        
        # Count already indexed
        $indexed_count = 0
        $chats = $script:app_state.all_chats
        for ($i = 0; $i -lt $chats.Count; $i++)
        {
            if ($chats[$i].ContentIndexed) { $indexed_count++ }
        }
        
        if ($indexed_count -eq $chats.Count)
        {
            $confirm = [System.Windows.MessageBox]::Show(
                "All conversations indexed.`n`nClear index to free memory?",
                "Clear Index?", 'YesNo', 'Question')
            
            if ($confirm -eq 'Yes')
            {
                for ($i = 0; $i -lt $chats.Count; $i++)
                {
                    $chats[$i].Content        = ""
                    $chats[$i].ContentIndexed = $false
                }
                
                $script:ui['IndexedTxt'].Text            = ""
                $script:ui['SearchContentChk'].IsEnabled = $false
                $script:ui['SearchContentChk'].IsChecked = $false
                $script:ui['FooterTxt'].Text             = "Index cleared"
                & $script:apply_filter_core
            }
            return
        }
        
        # Get chats to index (selected unindexed, or all unindexed)
        $to_index = @($chats | Where-Object { $_.Selected -and -not $_.ContentIndexed })
        
        if ($to_index.Count -eq 0)
        {
            $to_index = @($chats | Where-Object { -not $_.ContentIndexed })
        }
        
        if ($to_index.Count -eq 0)
        {
            $script:ui['FooterTxt'].Text = "All conversations already indexed"
            return
        }
        
        $confirm = [System.Windows.MessageBox]::Show(
            "Index $($to_index.Count) conversation(s)?`n`nThis enables content search but uses memory.",
            "Index Content", 'YesNo', 'Question')
        
        if ($confirm -ne 'Yes') { return }
        
        Update-ButtonState -Button $script:ui['IndexBtn'] -Text "Indexing..." -Enabled $false
        
        Update-ChatContentIndex -Chats $to_index -Owner $script:main_window
        
        # Update counts
        $indexed_count = 0
        for ($i = 0; $i -lt $chats.Count; $i++)
        {
            if ($chats[$i].ContentIndexed) { $indexed_count++ }
        }
        
        $script:ui['IndexedTxt'].Text            = "$indexed_count indexed"
        $script:ui['SearchContentChk'].IsEnabled = $indexed_count -gt 0
        $script:ui['FooterTxt'].Text             = "Indexed $($to_index.Count) conversations"
        
        Update-ButtonState -Button $script:ui['IndexBtn'] -Text "Index Chats" -Enabled $true
    })
    
    #endregion
    
    #region Export Button
    
    $script:ui['ExportBtn'].Add_Click({
        $selected = @($script:app_state.all_chats | Where-Object { $_.Selected })
        $all_chats = @($script:app_state.all_chats)
        
        if ($all_chats.Count -eq 0)
        {
            [System.Windows.MessageBox]::Show("No conversations to export.", "Export", 'OK', 'Information')
            return
        }
        
        # If there are selections, ask what to export
        $to_export = $null
        $export_label = ""
        
        if ($selected.Count -gt 0 -and $selected.Count -lt $all_chats.Count)
        {
            $choice = [System.Windows.MessageBox]::Show(
                "Export selected ($($selected.Count)) or all ($($all_chats.Count)) conversations?`n`nYes = Selected only`nNo = All conversations",
                "Export Scope", 'YesNoCancel', 'Question')
            
            if ($choice -eq 'Cancel') { return }
            
            if ($choice -eq 'Yes')
            {
                $to_export = $selected
                $export_label = "Selected"
            }
            else
            {
                $to_export = $all_chats
                $export_label = "All"
            }
        }
        else
        {
            $to_export = $all_chats
            $export_label = "All"
        }
        
        $export_type = [System.Windows.MessageBox]::Show(
            "Include full message content?`n`nYes = Complete backup`nNo = Metadata only (faster)",
            "Export Type", 'YesNoCancel', 'Question')
        
        if ($export_type -eq 'Cancel') { return }
        
        $full_export = ($export_type -eq 'Yes')
        
        $dialog = [Microsoft.Win32.SaveFileDialog]::new()
        $dialog.Filter   = "JSON|*.json"
        $dialog.FileName = "claude_export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $dialog.Title    = "Export $export_label ($($to_export.Count))"
        
        if (-not $dialog.ShowDialog()) { return }
        
        if ($full_export)
        {
            Update-ButtonState -Button $script:ui['ExportBtn'] -Text "Exporting..." -Enabled $false
            Export-ChatsWithContent -Chats $to_export -OutputPath $dialog.FileName -Owner $script:main_window
            Update-ButtonState -Button $script:ui['ExportBtn'] -Text "Export" -Enabled $true
        }
        else
        {
            # Metadata-only export
            try
            {
                $export_data = [PSCustomObject]@{
                    export_date         = (Get-Date).ToString('o')
                    export_version      = "3.0"
                    export_type         = "metadata"
                    total_conversations = $to_export.Count
                    conversations       = @($to_export | ForEach-Object {
                        [PSCustomObject]@{
                            id         = $_.Id
                            name       = $_.Name
                            updated_at = $_.Updated.ToString('o')
                        }
                    })
                }
                
                $export_data | ConvertTo-Json -Depth 5 | Set-Content $dialog.FileName -Encoding UTF8
                
                $script:ui['FooterTxt'].Text = "Exported $($to_export.Count) conversations"
                Write-Host "Exported to: $($dialog.FileName)" -ForegroundColor Green
            }
            catch
            {
                [System.Windows.MessageBox]::Show("Export failed: $_", "Error", 'OK', 'Error')
            }
        }
    })
    
    #endregion
    
    #region Delete Button
    
    $script:ui['DeleteBtn'].Add_Click({
        $to_delete = @($script:app_state.all_chats | Where-Object { $_.Selected })
        
        if ($to_delete.Count -eq 0)
        {
            [System.Windows.MessageBox]::Show("No conversations selected.", "Delete", 'OK', 'Information')
            return
        }
        
        # Log selections
        Write-Host "Selected for deletion: $($to_delete.Count)" -ForegroundColor Yellow
        foreach ($chat in $to_delete | Select-Object -First 5)
        {
            Write-Host "  - $($chat.Name)" -ForegroundColor DarkYellow
        }
        if ($to_delete.Count -gt 5)
        {
            Write-Host "  ... and $($to_delete.Count - 5) more" -ForegroundColor DarkYellow
        }
        
        $confirm = [System.Windows.MessageBox]::Show(
            "Permanently delete $($to_delete.Count) conversation(s)?`n`nThis cannot be undone on the server!",
            "Confirm Delete", 'YesNo', 'Warning')
        
        if ($confirm -ne 'Yes') { return }
        
        # Save copies of items for undo (local view only - server deletion is permanent)
        $script:app_state.deleted_buffer = @()
        foreach ($item in $to_delete)
        {
            $copy = [ChatItem]::new()
            $copy.Id             = $item.Id
            $copy.Name           = $item.Name
            $copy.Updated        = $item.Updated
            $copy.Selected       = $false
            $copy.Content        = $item.Content
            $copy.ContentIndexed = $item.ContentIndexed
            $script:app_state.deleted_buffer += $copy
        }
        
        Update-ButtonState -Button $script:ui['DeleteBtn'] -Text "Deleting..." -Enabled $false
        
        $deleted = Remove-SelectedChats -Chats $to_delete -Owner $script:main_window
        
        $script:ui['FooterTxt'].Text = "Deleted $deleted conversation(s) permanently"
        
        Update-ButtonState -Button $script:ui['DeleteBtn'] -Text "Delete Selected" -Enabled $true
        
        Update-DeletedBufferUI
        Update-StatsDisplay
    })
    
    #endregion
    
    #region Session Check Timer
    
    $session_timer = [System.Windows.Threading.DispatcherTimer]::new()
    $session_timer.Interval = [TimeSpan]::FromMinutes($script:CONSTANTS.SESSION_CHECK_MINUTES)
    $script:timers.session_check = $session_timer
    
    $session_timer.Add_Tick({
        # Only check if connected and has loaded
        if ($script:ui['LoginBtn'].Content -ne "Logout") { return }
        if (-not $script:app_state.org_id) { return }
        if (-not $script:app_state.has_loaded_once) { return }
        
        # Background session check
        try
        {
            $uri = "https://claude.ai/api/organizations/$($script:app_state.org_id)/chat_conversations?limit=1"
            $request = [System.Net.HttpWebRequest]::Create($uri)
            $request.Method    = "GET"
            $request.Timeout   = $script:CONSTANTS.API_CHECK_TIMEOUT_MS
            $request.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            $request.Headers.Add("Cookie", $script:app_state.cookie)
            
            $response = $request.GetResponse()
            $response.Close()
        }
        catch [System.Net.WebException]
        {
            $status = 0
            if ($_.Exception.Response)
            {
                $status = [int]$_.Exception.Response.StatusCode
            }
            
            if ($status -eq 401 -or $status -eq 403)
            {
                Write-Host "Session may have expired" -ForegroundColor Yellow
                $script:ui['FooterTxt'].Text = "Session may need refresh"
            }
        }
        catch { }
    })
    
    $session_timer.Start()
    
    #endregion
    
    #region Restore Saved Session
    
    Write-Host "Checking saved credentials..." -ForegroundColor DarkGray
    $saved = Get-SavedCredentials
    
    if ($saved)
    {
        $script:app_state.org_id  = $saved.org_id
        $script:app_state.cookie  = $saved.cookie
        & $script:set_connected $true
        $script:ui['FooterTxt'].Text = "Session restored - click Load Chats"
        Write-Host "Session restored" -ForegroundColor Green
    }
    
    #endregion
    
    # Show window
    [void]$window.ShowDialog()
}

#endregion

#region Entry Point

Start-App

#endregion
