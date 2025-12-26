#requires -Version 7.0
<#
.SYNOPSIS
    Application state container
.DESCRIPTION
    Layer 3 - Records: Holds the current application state
    Note: Uses [object] for WPF types to avoid parse-time dependency
#>

class AppState
{
    [string]$OrgId
    [string]$Cookie
    [object]$AllChats          # ObservableCollection[ChatItem] - typed at runtime
    [bool]$HasLoadedOnce
    [bool]$WebView2Ready
    [bool]$IsBusy
    [array]$DeletedBuffer
    
    AppState()
    {
        $this.OrgId          = $null
        $this.Cookie         = $null
        $this.AllChats       = $null  # Created after assemblies load
        $this.HasLoadedOnce  = $false
        $this.WebView2Ready  = $false
        $this.IsBusy         = $false
        $this.DeletedBuffer  = @()
    }
    
    [void] InitializeCollections()
    {
        # Call this after WPF assemblies are loaded
        $this.AllChats = [System.Collections.ObjectModel.ObservableCollection[ChatItem]]::new()
    }
    
    [void] ClearChats()
    {
        if ($this.AllChats) { $this.AllChats.Clear() }
    }
    
    [int] GetSelectedCount()
    {
        if (-not $this.AllChats) { return 0 }
        $count = 0
        foreach ($chat in $this.AllChats)
        {
            if ($chat.Selected) { $count++ }
        }
        return $count
    }
    
    [array] GetSelectedChats()
    {
        if (-not $this.AllChats) { return @() }
        return @($this.AllChats | Where-Object { $_.Selected })
    }
    
    [int] GetIndexedCount()
    {
        if (-not $this.AllChats) { return 0 }
        $count = 0
        foreach ($chat in $this.AllChats)
        {
            if ($chat.ContentIndexed) { $count++ }
        }
        return $count
    }
    
    [void] SelectAllVisible($View)
    {
        $enumerator = $View.GetEnumerator()
        while ($enumerator.MoveNext())
        {
            $enumerator.Current.Selected = $true
        }
        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
    }
    
    [void] DeselectAll()
    {
        if (-not $this.AllChats) { return }
        foreach ($chat in $this.AllChats)
        {
            $chat.Selected = $false
        }
    }
    
    [void] ClearMatchData()
    {
        if (-not $this.AllChats) { return }
        foreach ($chat in $this.AllChats)
        {
            $chat.MatchType    = ""
            $chat.MatchPreview = ""
        }
    }
    
    [void] ClearIndex()
    {
        if (-not $this.AllChats) { return }
        foreach ($chat in $this.AllChats)
        {
            $chat.Content        = ""
            $chat.ContentIndexed = $false
        }
    }
    
    [void] BufferForUndo([array]$Chats)
    {
        $this.DeletedBuffer = @()
        foreach ($item in $Chats)
        {
            $copy = [ChatItem]::new()
            $copy.Id             = $item.Id
            $copy.Name           = $item.Name
            $copy.Updated        = $item.Updated
            $copy.Selected       = $false
            $copy.Content        = $item.Content
            $copy.ContentIndexed = $item.ContentIndexed
            $this.DeletedBuffer += $copy
        }
    }
    
    [int] RestoreFromBuffer()
    {
        $count = $this.DeletedBuffer.Count
        foreach ($item in $this.DeletedBuffer)
        {
            $this.AllChats.Add($item)
        }
        $this.DeletedBuffer = @()
        return $count
    }
}
