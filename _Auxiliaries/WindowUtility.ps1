#requires -Version 7.0
<#
.SYNOPSIS
    Window state persistence utilities
.DESCRIPTION
    Auxiliaries: Domain-agnostic window state save/restore functions
#>

function Save-WindowState
{
    <#
    .SYNOPSIS
        Saves window position, size, and sidebar state to config file
    #>
    param(
        [System.Windows.Window]$Window,
        [bool]$SidebarCollapsed
    )
    
    $state_file = $script:CONFIG.Paths.WindowStateFile
    
    try
    {
        $state = @{
            Left             = $Window.Left
            Top              = $Window.Top
            Width            = $Window.Width
            Height           = $Window.Height
            Maximized        = ($Window.WindowState -eq 'Maximized')
            SidebarCollapsed = $SidebarCollapsed
        }
        
        $state | ConvertTo-Json | Set-Content -Path $state_file -Encoding UTF8
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
    .OUTPUTS
        Hashtable with restored state or $null
    #>
    param([System.Windows.Window]$Window)
    
    $state_file = $script:CONFIG.Paths.WindowStateFile
    
    if (-not (Test-Path $state_file))
    {
        return $null
    }
    
    try
    {
        $state = Get-Content -Path $state_file -Raw | ConvertFrom-Json
        
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
        
        return @{
            SidebarCollapsed = $state.SidebarCollapsed -eq $true
        }
    }
    catch
    {
        Write-Host "Failed to restore window state: $_" -ForegroundColor Yellow
        return $null
    }
}
