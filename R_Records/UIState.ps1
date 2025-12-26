#requires -Version 7.0
<#
.SYNOPSIS
    UI state and cache container
.DESCRIPTION
    Layer 3 - Records: Holds UI-specific state and cached references
    Note: Uses [object] for WPF types to avoid parse-time dependency
#>

class UIState
{
    # Cached UI references (typed at runtime, not parse-time)
    [object]$CollectionView
    [object]$MatchColumn
    [object]$HeaderCheckbox
    
    # Current search state
    [string]$CurrentSearch
    [hashtable]$CurrentSearchMode
    
    # Date filter state
    [object]$DateAfter   # nullable datetime
    [object]$DateBefore  # nullable datetime
    
    # Sidebar state
    [int]$SidebarWidth
    [bool]$SidebarCollapsed
    
    # View state
    [bool]$ShowingSelectedOnly
    [string]$SortColumn
    [string]$SortDirection
    
    # Selection tracking
    [int]$LastClickedIndex
    [int]$LastSelectionCount
    
    UIState()
    {
        $this.CollectionView      = $null
        $this.MatchColumn         = $null
        $this.HeaderCheckbox      = $null
        $this.CurrentSearch       = ""
        $this.CurrentSearchMode   = $null
        $this.DateAfter           = $null
        $this.DateBefore          = $null
        $this.SidebarWidth        = 180
        $this.SidebarCollapsed    = $false
        $this.ShowingSelectedOnly = $false
        $this.SortColumn          = "Updated"
        $this.SortDirection       = "Descending"
        $this.LastClickedIndex    = -1
        $this.LastSelectionCount  = 0
    }
    
    [void] ResetForNewData()
    {
        $this.MatchColumn      = $null
        $this.LastClickedIndex = -1
    }
    
    [void] EnsureCollectionView($Source)
    {
        if (-not $this.CollectionView)
        {
            $this.CollectionView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Source)
        }
    }
    
    [int] CountVisible()
    {
        if (-not $this.CollectionView) { return 0 }
        
        $count = 0
        $enumerator = $this.CollectionView.GetEnumerator()
        while ($enumerator.MoveNext()) { $count++ }
        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
        return $count
    }
    
    [object] GetItemAtIndex([int]$TargetIndex)
    {
        if (-not $this.CollectionView) { return $null }
        
        $index = 0
        $enumerator = $this.CollectionView.GetEnumerator()
        while ($enumerator.MoveNext())
        {
            if ($index -eq $TargetIndex) 
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
    
    [int] GetVisibleIndex($Item)
    {
        if (-not $this.CollectionView) { return -1 }
        
        $index = 0
        $enumerator = $this.CollectionView.GetEnumerator()
        while ($enumerator.MoveNext())
        {
            if ($enumerator.Current -eq $Item) 
            { 
                if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
                return $index 
            }
            $index++
        }
        if ($enumerator -is [System.IDisposable]) { $enumerator.Dispose() }
        return -1
    }
}
