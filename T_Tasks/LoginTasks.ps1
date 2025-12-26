#requires -Version 7.0
<#
.SYNOPSIS
    Login operations
.DESCRIPTION
    Layer 2 - Tasks: Operations to handle Claude authentication
#>

function Show-LoginDialog
{
    param([System.Windows.Window]$Owner)
    
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
    
    if ($Owner) { $window.Owner = $Owner }
    
    $title_bar     = $window.FindName('TitleBar')
    $webview_host  = $window.FindName('WebViewHost')
    $status_text   = $window.FindName('StatusTxt')
    $close_button  = $window.FindName('CloseBtn')
    $cancel_button = $window.FindName('CancelBtn')
    
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
    
    # Close/Cancel
    $close_handler = {
        $script:_login.window.DialogResult = $false
        $script:_login.window.Close()
    }
    
    $close_button.Add_Click($close_handler)
    $cancel_button.Add_Click($close_handler)
    
    # Setup WebView2
    $webview = [Microsoft.Web.WebView2.WinForms.WebView2]::new()
    $creation_props = [Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties]::new()
    $creation_props.UserDataFolder = $script:CONFIG.Paths.WebView2Data
    $webview.CreationProperties    = $creation_props
    $webview.Dock                  = [System.Windows.Forms.DockStyle]::Fill
    
    $forms_host       = [System.Windows.Forms.Integration.WindowsFormsHost]::new()
    $forms_host.Child = $webview
    $webview_host.Child = $forms_host
    $script:_login.webview = $webview
    
    # Poll timer
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    $script:_login.timer = $timer
    
    $timer.Add_Tick({
        try
        {
            $login = $script:_login
            
            if (-not $login.webview -or -not $login.webview.CoreWebView2)
            {
                return
            }
            
            $url = $login.webview.Source
            
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
            $script:_login.status.Text = "Browser init failed: $($event_args.InitializationException.Message)"
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
            $script:_login.status.Text = "Initialization error: $_"
        }
    })
    
    # Cleanup
    $window.Add_Closing({
        if ($script:_login.timer) { $script:_login.timer.Stop() }
        if ($script:_login.webview) 
        { 
            try { $script:_login.webview.Dispose() } catch { }
        }
        $script:_login.webview = $null
        $script:_login.timer   = $null
    })
    
    if ($window.ShowDialog())
    {
        return $script:_login.result
    }
    
    return $null
}
