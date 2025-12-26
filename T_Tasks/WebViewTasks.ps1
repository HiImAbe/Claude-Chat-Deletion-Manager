#requires -Version 7.0
<#
.SYNOPSIS
    WebView2 dialog factory for async operations
.DESCRIPTION
    Layer 2 - Tasks: Provides reusable WebView2 dialog creation
#>

function New-WebView2Operation
{
    <#
    .SYNOPSIS
        Creates a WebView2-based dialog for async operations
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
    
    # Build XAML
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
    
    if ($Owner) { $window.Owner = $Owner }
    
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
    
    $script:_current_operation = $operation
    
    # Setup WebView2
    $webview = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
    $creation_props = [Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties]::new()
    $creation_props.UserDataFolder = $script:CONFIG.Paths.WebView2Data
    $webview.CreationProperties    = $creation_props
    $webview.Width                 = 1
    $webview.Height                = 1
    
    $forms_host       = [System.Windows.Forms.Integration.WindowsFormsHost]::new()
    $forms_host.Child = $webview
    $operation.webview_host.Child = $forms_host
    $operation.webview = $webview
    
    # Cancel handler
    if ($operation.cancel_button)
    {
        $operation.cancel_button.Add_Click({
            $op = $script:_current_operation
            $op.is_cancelled = $true
            $op.status_text.Text = "Cancelling..."
            
            if ($op.on_cancelled) { & $op.on_cancelled }
            
            foreach ($timer in $op.timers) { $timer.Stop() }
            
            $op.window.DialogResult = $false
            $op.window.Close()
        })
    }
    
    # WebView2 init complete
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
    
    # Navigation complete
    $webview.Add_NavigationCompleted({
        param($sender, $event_args)
        
        $op = $script:_current_operation
        
        if ($op.is_cancelled -or $op.is_complete) { return }
        
        if (-not $event_args.IsSuccess)
        {
            $op.status_text.Text = "Navigation failed"
            return
        }
        
        $url = $op.webview.Source
        
        if ($url.Host -eq 'claude.ai' -and $url.AbsolutePath -match 'recents|chat')
        {
            $delay_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $delay_timer.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.WEBVIEW_INIT_DELAY_MS)
            $op.timers.Add($delay_timer) | Out-Null
            
            $delay_timer.Add_Tick({
                param($sender, $event_args)
                
                $sender.Stop()
                $op = $script:_current_operation
                
                if ($op -and -not $op.is_cancelled)
                {
                    & $op.on_ready $op
                }
            })
            
            $delay_timer.Start()
        }
        else
        {
            $op.status_text.Text = "Unexpected page - may need to login"
        }
    })
    
    # Timeout
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
            Start-Sleep -Milliseconds 500
            $op.window.DialogResult = $false
            $op.window.Close()
        }
    })
    
    # Window loaded
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
            
            $op.timers[-1].Start()
        }
        catch
        {
            $op.status_text.Text = "Browser init error"
        }
    })
    
    # Cleanup
    $window.Add_Closing({
        $op = $script:_current_operation
        
        foreach ($timer in $op.timers)
        {
            if ($timer) { $timer.Stop() }
        }
        
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
    param(
        [Parameter(Mandatory)]
        $Operation,
        
        [bool]$Success = $true,
        $Result = $null
    )
    
    $Operation.is_complete = $true
    $Operation.result      = $Result
    
    foreach ($timer in $Operation.timers)
    {
        if ($timer) { $timer.Stop() }
    }
    
    Start-Sleep -Milliseconds 300
    $Operation.window.DialogResult = $Success
    $Operation.window.Close()
}
