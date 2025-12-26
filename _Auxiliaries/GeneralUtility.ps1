#requires -Version 7.0
<#
.SYNOPSIS
    General utility functions
.DESCRIPTION
    Auxiliaries: Domain-agnostic helper functions
#>

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
