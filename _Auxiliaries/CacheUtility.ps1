#requires -Version 7.0
<#
.SYNOPSIS
    Cache management utilities
.DESCRIPTION
    Handles metadata cache and content index persistence for performance.
    - Metadata cache: Avoids full re-fetch by tracking what we've seen
    - Index cache: Persists content index to disk between sessions
#>

#region Metadata Cache

function Get-MetadataCache
{
    <#
    .SYNOPSIS
        Loads cached chat metadata from disk
    .OUTPUTS
        Hashtable with chat_id => { id, name, updated_at, cached_at }
    #>
    
    if (-not $script:CONFIG.Cache.MetadataCacheEnabled) { return @{} }
    
    $cache_file = Join-Path $script:CONFIG.Paths.CacheDir "metadata.json"
    
    if (-not (Test-Path $cache_file)) { return @{} }
    
    try
    {
        $cache_data = Get-Content $cache_file -Raw | ConvertFrom-Json -AsHashtable
        
        # Check cache age
        if ($cache_data.cached_at)
        {
            $cache_time = [datetime]::Parse($cache_data.cached_at)
            $max_age    = [TimeSpan]::FromDays($script:CONFIG.Cache.MaxCacheAgeDays)
            
            if (([datetime]::Now - $cache_time) -gt $max_age)
            {
                Write-Host "  Metadata cache expired, will refresh" -ForegroundColor DarkGray
                return @{}
            }
        }
        
        Write-Host "  Loaded metadata cache ($($cache_data.chats.Count) items)" -ForegroundColor DarkGray
        
        # Convert to lookup hashtable
        $lookup = @{}
        foreach ($chat in $cache_data.chats)
        {
            $lookup[$chat.id] = $chat
        }
        
        return $lookup
    }
    catch
    {
        Write-Host "  Warning: Could not load metadata cache" -ForegroundColor Yellow
        return @{}
    }
}

function Save-MetadataCache
{
    <#
    .SYNOPSIS
        Saves chat metadata to cache file
    #>
    param(
        [Parameter(Mandatory)]
        $Chats  # ObservableCollection or array of ChatItem
    )
    
    if (-not $script:CONFIG.Cache.MetadataCacheEnabled) { return }
    
    $cache_file = Join-Path $script:CONFIG.Paths.CacheDir "metadata.json"
    
    try
    {
        $cache_data = @{
            cached_at = (Get-Date).ToString('o')
            version   = "1.0"
            chats     = @($Chats | ForEach-Object {
                @{
                    id         = $_.Id
                    name       = $_.Name
                    updated_at = $_.Updated.ToString('o')
                }
            })
        }
        
        $cache_data | ConvertTo-Json -Depth 4 -Compress | Set-Content $cache_file -Encoding UTF8
        Write-Host "  Saved metadata cache ($($Chats.Count) items)" -ForegroundColor DarkGray
    }
    catch
    {
        Write-Host "  Warning: Could not save metadata cache: $_" -ForegroundColor Yellow
    }
}

function Get-CacheLastSync
{
    <#
    .SYNOPSIS
        Gets the timestamp of the last full sync
    #>
    
    $cache_file = Join-Path $script:CONFIG.Paths.CacheDir "metadata.json"
    
    if (-not (Test-Path $cache_file)) { return $null }
    
    try
    {
        $cache_data = Get-Content $cache_file -Raw | ConvertFrom-Json
        if ($cache_data.cached_at)
        {
            return [datetime]::Parse($cache_data.cached_at)
        }
    }
    catch { }
    
    return $null
}

#endregion

#region Index Cache

function Get-IndexCache
{
    <#
    .SYNOPSIS
        Loads cached content index from disk
    .OUTPUTS
        Hashtable with chat_id => { content }
    #>
    
    if (-not $script:CONFIG.Cache.IndexCacheEnabled) { return @{} }
    
    $cache_file = Join-Path $script:CONFIG.Paths.CacheDir "index.json"
    
    if (-not (Test-Path $cache_file)) { return @{} }
    
    try
    {
        $cache_data = Get-Content $cache_file -Raw | ConvertFrom-Json -AsHashtable
        
        Write-Host "  Loaded index cache ($($cache_data.entries.Count) items)" -ForegroundColor DarkGray
        
        # Convert to lookup hashtable
        $lookup = @{}
        foreach ($entry in $cache_data.entries)
        {
            $lookup[$entry.id] = @{ content = $entry.content }
        }
        
        return $lookup
    }
    catch
    {
        Write-Host "  Warning: Could not load index cache" -ForegroundColor Yellow
        return @{}
    }
}

function Save-IndexCache
{
    <#
    .SYNOPSIS
        Saves content index to cache file
    #>
    param(
        [Parameter(Mandatory)]
        $Chats  # ObservableCollection or array of ChatItem with Content
    )
    
    if (-not $script:CONFIG.Cache.IndexCacheEnabled) { return }
    
    $cache_file = Join-Path $script:CONFIG.Paths.CacheDir "index.json"
    
    try
    {
        # Only cache indexed chats, up to max limit
        $indexed = @($Chats | Where-Object { $_.ContentIndexed } | Select-Object -First $script:CONFIG.Cache.MaxIndexedChats)
        
        if ($indexed.Count -eq 0) { return }
        
        $cache_data = @{
            cached_at = (Get-Date).ToString('o')
            version   = "1.0"
            entries   = @($indexed | ForEach-Object {
                @{
                    id      = $_.Id
                    content = $_.Content
                }
            })
        }
        
        $cache_data | ConvertTo-Json -Depth 4 -Compress | Set-Content $cache_file -Encoding UTF8
        Write-Host "  Saved index cache ($($indexed.Count) items)" -ForegroundColor DarkGray
    }
    catch
    {
        Write-Host "  Warning: Could not save index cache: $_" -ForegroundColor Yellow
    }
}

function Restore-IndexFromCache
{
    <#
    .SYNOPSIS
        Restores content index to ChatItem objects from cache
    #>
    param(
        [Parameter(Mandatory)]
        $Chats,  # ObservableCollection of ChatItem
        
        [hashtable]$IndexCache
    )
    
    if (-not $IndexCache -or $IndexCache.Count -eq 0) { return 0 }
    
    $restored = 0
    
    foreach ($chat in $Chats)
    {
        if ($IndexCache.ContainsKey($chat.Id))
        {
            $cached = $IndexCache[$chat.Id]
            $chat.Content        = $cached.content  # ContentLower computed automatically
            $chat.ContentIndexed = $true
            $restored++
        }
    }
    
    return $restored
}

#endregion

#region Cache Maintenance

function Clear-AllCache
{
    <#
    .SYNOPSIS
        Clears all cache files
    #>
    
    $cache_dir = $script:CONFIG.Paths.CacheDir
    
    if (Test-Path $cache_dir)
    {
        Remove-Item "$cache_dir\*.json" -Force -ErrorAction SilentlyContinue
        Write-Host "Cache cleared" -ForegroundColor Green
    }
}

function Get-CacheStats
{
    <#
    .SYNOPSIS
        Returns cache statistics
    #>
    
    $cache_dir = $script:CONFIG.Paths.CacheDir
    
    $stats = @{
        MetadataExists = $false
        MetadataSize   = 0
        MetadataAge    = $null
        IndexExists    = $false
        IndexSize      = 0
        IndexAge       = $null
    }
    
    $metadata_file = Join-Path $cache_dir "metadata.json"
    $index_file    = Join-Path $cache_dir "index.json"
    
    if (Test-Path $metadata_file)
    {
        $info = Get-Item $metadata_file
        $stats.MetadataExists = $true
        $stats.MetadataSize   = $info.Length
        $stats.MetadataAge    = [datetime]::Now - $info.LastWriteTime
    }
    
    if (Test-Path $index_file)
    {
        $info = Get-Item $index_file
        $stats.IndexExists = $true
        $stats.IndexSize   = $info.Length
        $stats.IndexAge    = [datetime]::Now - $info.LastWriteTime
    }
    
    return $stats
}

#endregion
