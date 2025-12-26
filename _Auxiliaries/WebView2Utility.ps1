#requires -Version 7.0
<#
.SYNOPSIS
    WebView2 SDK and runtime utilities
.DESCRIPTION
    Auxiliaries: Domain-agnostic WebView2 bootstrap functions
#>

function Test-WebView2Runtime
{
    <#
    .SYNOPSIS
        Checks if WebView2 Runtime is installed
    .OUTPUTS
        Boolean indicating if runtime is available
    #>
    
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
                Write-Host "  WebView2 Runtime: $($version.pv)" -ForegroundColor DarkGray
                return $true
            }
        }
    }
    
    $edge_path = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (Test-Path $edge_path)
    {
        Write-Host "  Microsoft Edge found (WebView2 host)" -ForegroundColor DarkGray
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

function Copy-NativeLoader
{
    <#
    .SYNOPSIS
        Copies the native WebView2Loader.dll to the managed DLL folder
    #>
    param(
        [string]$ExtractPath,
        [string]$LibPath
    )
    
    # Determine architecture
    $arch = if ([Environment]::Is64BitProcess) { "win-x64" } else { "win-x86" }
    
    $native_dll = Join-Path $ExtractPath "runtimes\$arch\native\WebView2Loader.dll"
    $dest_dll   = Join-Path $LibPath "WebView2Loader.dll"
    
    if ((Test-Path $native_dll) -and -not (Test-Path $dest_dll))
    {
        Write-Host "  Copying native loader ($arch)..." -ForegroundColor DarkGray
        Copy-Item $native_dll $dest_dll -Force
        return $true
    }
    elseif (Test-Path $dest_dll)
    {
        return $true
    }
    
    Write-Host "  Warning: Native loader not found at $native_dll" -ForegroundColor Yellow
    return $false
}

function Initialize-WebView2Sdk
{
    <#
    .SYNOPSIS
        Downloads and loads WebView2 SDK if needed
    .OUTPUTS
        Boolean indicating success
    #>
    
    if (-not (Test-WebView2Runtime))
    {
        Show-WebView2RuntimeError
        return $false
    }
    
    $webview2_path = $script:CONFIG.Paths.WebView2Data
    $extract_path  = Join-Path $webview2_path "extracted"
    $dll_info      = Find-WebView2Dlls -BasePath $extract_path
    
    if (-not $dll_info)
    {
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
        
        Write-Host "  Downloading WebView2 SDK..." -ForegroundColor Cyan
        
        try
        {
            New-Item -ItemType Directory -Path $webview2_path -Force | Out-Null
            
            $nuget_url    = "$($script:CONSTANTS.WEBVIEW2_NUGET_URL)/$($script:CONSTANTS.WEBVIEW2_SDK_VERSION)"
            $package_path = Join-Path $webview2_path "package.zip"
            
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            
            $progress_preference_backup = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            
            Invoke-WebRequest -Uri $nuget_url -OutFile $package_path -UseBasicParsing
            
            $ProgressPreference = $progress_preference_backup
            
            Write-Host "  Extracting SDK..." -ForegroundColor Cyan
            Expand-Archive -Path $package_path -DestinationPath $extract_path -Force
            Remove-Item $package_path -Force
            
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
            Write-Host "  Download failed: $_" -ForegroundColor Red
            [System.Windows.MessageBox]::Show(
                "Failed to download WebView2 SDK:`n`n$($_.Exception.Message)",
                "Download Error", 'OK', 'Error')
            return $false
        }
    }
    
    if (-not $dll_info)
    {
        Write-Host "  WebView2 DLLs not found after extraction" -ForegroundColor Red
        return $false
    }
    
    # Copy native loader DLL to lib folder
    if (-not (Copy-NativeLoader -ExtractPath $extract_path -LibPath $dll_info.lib_path))
    {
        Write-Host "  Warning: Native loader copy failed, WebView2 may not work" -ForegroundColor Yellow
    }
    
    try
    {
        Add-Type -Path $dll_info.core_dll
        Add-Type -Path $dll_info.winforms_dll
        Write-Host "  WebView2 SDK loaded" -ForegroundColor DarkGray
        return $true
    }
    catch
    {
        Write-Host "  Failed to load WebView2 assemblies: $_" -ForegroundColor Red
        [System.Windows.MessageBox]::Show(
            "Failed to load WebView2 SDK:`n`n$($_.Exception.Message)",
            "Load Error", 'OK', 'Error')
        return $false
    }
}
