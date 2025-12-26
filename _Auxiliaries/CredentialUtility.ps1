#requires -Version 7.0
<#
.SYNOPSIS
    Credential storage utilities with machine-specific encryption
.DESCRIPTION
    Auxiliaries: Secure credential persistence using AES encryption
    with a key derived from machine-specific identifiers.
    
    Credentials can only be decrypted on the same machine by the same user.
#>

function Get-MachineKey
{
    <#
    .SYNOPSIS
        Generates a machine-specific encryption key
    .DESCRIPTION
        Combines machine GUID, user SID, and app-specific salt to create
        a unique key that only works on this machine for this user.
    #>
    
    # Get machine GUID from registry
    $machine_guid = $null
    try
    {
        $machine_guid = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
    }
    catch
    {
        # Fallback to computer name + OS install date
        $machine_guid = "$env:COMPUTERNAME-$((Get-CimInstance Win32_OperatingSystem).InstallDate)"
    }
    
    # Get current user SID
    $user_sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    
    # App-specific salt (makes keys unique to this application)
    $app_salt = "ClaudeChatManager-v3.0-SecureStorage"
    
    # Combine and hash to create key material
    $combined = "$machine_guid|$user_sid|$app_salt"
    $sha256   = [System.Security.Cryptography.SHA256]::Create()
    $key_bytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($combined))
    
    return $key_bytes
}

function Protect-String
{
    <#
    .SYNOPSIS
        Encrypts a string using AES with machine-specific key
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PlainText
    )
    
    try
    {
        $key = Get-MachineKey
        
        # Create AES encryptor
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.GenerateIV()
        
        $encryptor  = $aes.CreateEncryptor()
        $plain_bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
        $encrypted  = $encryptor.TransformFinalBlock($plain_bytes, 0, $plain_bytes.Length)
        
        # Combine IV + encrypted data and convert to base64
        $combined = [byte[]]::new($aes.IV.Length + $encrypted.Length)
        [Array]::Copy($aes.IV, 0, $combined, 0, $aes.IV.Length)
        [Array]::Copy($encrypted, 0, $combined, $aes.IV.Length, $encrypted.Length)
        
        $aes.Dispose()
        
        return [Convert]::ToBase64String($combined)
    }
    catch
    {
        Write-Host "Encryption failed: $_" -ForegroundColor Red
        return $null
    }
}

function Unprotect-String
{
    <#
    .SYNOPSIS
        Decrypts a string that was encrypted with Protect-String
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EncryptedText
    )
    
    try
    {
        $key = Get-MachineKey
        
        # Decode from base64
        $combined = [Convert]::FromBase64String($EncryptedText)
        
        # Extract IV (first 16 bytes) and encrypted data
        $iv = $combined[0..15]
        $encrypted = $combined[16..($combined.Length - 1)]
        
        # Create AES decryptor
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV  = $iv
        
        $decryptor = $aes.CreateDecryptor()
        $decrypted = $decryptor.TransformFinalBlock($encrypted, 0, $encrypted.Length)
        
        $aes.Dispose()
        
        return [System.Text.Encoding]::UTF8.GetString($decrypted)
    }
    catch
    {
        Write-Host "Decryption failed (credentials may be from different machine): $_" -ForegroundColor Yellow
        return $null
    }
}

function Save-Credentials
{
    <#
    .SYNOPSIS
        Saves encrypted credentials to file
    #>
    param(
        [Parameter(Mandatory)]
        [string]$OrgId,
        
        [Parameter(Mandatory)]
        [string]$Cookie
    )
    
    try
    {
        $cred_file = $script:CONFIG.Paths.CredentialsFile
        
        # Encrypt the sensitive cookie data
        $encrypted_cookie = Protect-String -PlainText $Cookie
        
        if (-not $encrypted_cookie)
        {
            Write-Host "Failed to encrypt credentials" -ForegroundColor Red
            return $false
        }
        
        $cred_data = @{
            Version   = 2  # Version 2 = AES encryption
            OrgId     = $OrgId
            Cookie    = $encrypted_cookie
            SavedAt   = (Get-Date).ToString('o')
            Machine   = $env:COMPUTERNAME
        }
        
        $cred_data | ConvertTo-Json | Set-Content $cred_file -Force
        
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
    <#
    .SYNOPSIS
        Retrieves and decrypts saved credentials
    #>
    
    $cred_file = $script:CONFIG.Paths.CredentialsFile
    
    if (-not (Test-Path $cred_file))
    {
        return $null
    }
    
    try
    {
        $data = Get-Content $cred_file -Raw -ErrorAction Stop | ConvertFrom-Json
        
        if (-not $data.OrgId -or -not $data.Cookie)
        {
            Write-Host "Invalid credentials file format" -ForegroundColor Yellow
            return $null
        }
        
        # Check version and decrypt accordingly
        $cookie = $null
        
        if ($data.Version -eq 2)
        {
            # Version 2: AES encryption
            $cookie = Unprotect-String -EncryptedText $data.Cookie
        }
        else
        {
            # Version 1 or unversioned: Legacy DPAPI (try to read and migrate)
            try
            {
                $secure_string = $data.Cookie | ConvertTo-SecureString -ErrorAction Stop
                $cookie = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure_string))
                
                # Migrate to new format
                Write-Host "  Migrating credentials to new encryption..." -ForegroundColor DarkGray
                Save-Credentials -OrgId $data.OrgId -Cookie $cookie
            }
            catch
            {
                Write-Host "Could not read legacy credentials: $_" -ForegroundColor Yellow
                return $null
            }
        }
        
        if (-not $cookie)
        {
            Write-Host "Could not decrypt credentials" -ForegroundColor Yellow
            return $null
        }
        
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
    <#
    .SYNOPSIS
        Removes saved credentials and browser cookies
    #>
    
    $cred_file = $script:CONFIG.Paths.CredentialsFile
    
    if (Test-Path $cred_file)
    {
        Remove-Item $cred_file -Force -ErrorAction SilentlyContinue
    }
    
    # Also clear WebView2 browser data (cookies)
    $webview_data = $script:CONFIG.Paths.WebView2Data
    $cookies_path = Join-Path $webview_data "EBWebView"
    
    if (Test-Path $cookies_path)
    {
        Remove-Item $cookies_path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-CredentialsValid
{
    <#
    .SYNOPSIS
        Quick check if credentials file exists and is readable
    #>
    
    $cred_file = $script:CONFIG.Paths.CredentialsFile
    
    if (-not (Test-Path $cred_file))
    {
        return $false
    }
    
    try
    {
        $data = Get-Content $cred_file -Raw | ConvertFrom-Json
        return ($null -ne $data.OrgId -and $null -ne $data.Cookie)
    }
    catch
    {
        return $false
    }
}
