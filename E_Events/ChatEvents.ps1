#requires -Version 7.0
<#
.SYNOPSIS
    Chat manager event handlers
.DESCRIPTION
    Layer 4 - Events: Orchestration logic for UI events
    Knows: Tasks, Records
#>

function Update-StatsDisplay
{
    <#
    .SYNOPSIS
        Updates the statistics panel with chat data
    #>
    param(
        [AppState]$State,
        $StatsSummary
    )
    
    $chats = $State.AllChats
    
    if (-not $chats -or $chats.Count -eq 0)
    {
        $StatsSummary.Text = "Load chats to see stats"
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
    
    $sorted = $by_month.GetEnumerator() | Sort-Object Name -Descending | Select-Object -First 6
    
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
    
    $StatsSummary.Text = $lines -join "`n"
}

function Update-DeletedBufferUI
{
    <#
    .SYNOPSIS
        Updates the recently deleted UI based on buffer state
    #>
    param(
        [AppState]$State,
        [hashtable]$UI
    )
    
    $count = $State.DeletedBuffer.Count
    
    if ($count -gt 0)
    {
        $UI['RecentlyDeletedLabel'].Text       = "RECENTLY DELETED ($count)"
        $UI['RecentlyDeletedLabel'].Visibility = 'Visible'
        $UI['UndoDeleteBtn'].Visibility        = 'Visible'
        $UI['ClearDeletedBtn'].Visibility      = 'Visible'
    }
    else
    {
        $UI['RecentlyDeletedLabel'].Visibility = 'Collapsed'
        $UI['UndoDeleteBtn'].Visibility        = 'Collapsed'
        $UI['ClearDeletedBtn'].Visibility      = 'Collapsed'
    }
}

function Set-ConnectionState
{
    <#
    .SYNOPSIS
        Updates UI to reflect connected/disconnected state
    #>
    param(
        [bool]$Connected,
        [AppState]$State,
        [hashtable]$UI
    )
    
    $green     = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(46, 204, 113))
    $gray      = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(85, 85, 85))
    $text_gray = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(102, 102, 102))
    
    if ($Connected)
    {
        $UI['StatusDot'].Fill       = $green
        $UI['StatusTxt'].Text       = "Connected"
        $UI['StatusTxt'].Foreground = $text_gray
        $UI['LoadBtn'].IsEnabled    = $true
        $UI['DeleteBtn'].IsEnabled  = $true
        $UI['LoginBtn'].Content     = "Logout"
        
        if ($State.HasLoadedOnce)
        {
            $UI['LoadBtn'].Content = "Refresh Chats"
        }
    }
    else
    {
        $UI['StatusDot'].Fill       = $gray
        $UI['StatusTxt'].Text       = "Disconnected"
        $UI['StatusTxt'].Foreground = $gray
        $UI['LoadBtn'].IsEnabled    = $false
        $UI['LoadBtn'].Content      = "Load Chats"
        $UI['DeleteBtn'].IsEnabled  = $false
        $UI['LoginBtn'].Content     = "Login"
        $State.OrgId                = $null
        $State.Cookie               = $null
    }
}

function Invoke-FilterUpdate
{
    <#
    .SYNOPSIS
        Applies search/date filter to the chat list
    #>
    param(
        [AppState]$State,
        [UIState]$UIState,
        [hashtable]$UI
    )
    
    $search_text    = $UI['SearchBox'].Text.Trim()
    $search_content = $UI['SearchContentChk'].IsChecked -eq $true
    
    $search_mode = Get-SearchMode -SearchText $search_text
    $UIState.CurrentSearchMode = $search_mode
    
    $UIState.EnsureCollectionView($State.AllChats)
    $view = $UIState.CollectionView
    
    # Get match column
    if (-not $UIState.MatchColumn)
    {
        $UIState.MatchColumn = $UI['Grid'].Columns | Where-Object { $_.Header -eq 'MATCH' }
    }
    
    $match_col = $UIState.MatchColumn
    
    # Reset selected-only filter
    if ($UIState.ShowingSelectedOnly)
    {
        $UIState.ShowingSelectedOnly = $false
        $UI['SelectedRow'].Background = [System.Windows.Media.Brushes]::Transparent
    }
    
    # Clear previous match data
    $State.ClearMatchData()
    
    # Get date filters
    $date_after  = $UI['DateAfterPicker'].SelectedDate
    $date_before = $UI['DateBeforePicker'].SelectedDate
    
    $UIState.DateAfter  = $date_after
    $UIState.DateBefore = $date_before
    
    # Store filter context in script scope for predicate access
    $script:_filter_mode         = $search_mode
    $script:_filter_date_after   = $date_after
    $script:_filter_date_before  = $date_before
    $script:_filter_search_content = $search_content
    
    if ($search_mode.Mode -ne 'None' -or $date_after -or $date_before)
    {
        if ($search_mode.Mode -eq 'Id')
        {
            $view.Filter = [Predicate[object]]{
                param($item)
                
                # Date filter
                if ($script:_filter_date_after -and $item.Updated -lt $script:_filter_date_after) { return $false }
                if ($script:_filter_date_before -and $item.Updated -gt $script:_filter_date_before) { return $false }
                
                foreach ($search_id in $script:_filter_mode.Ids)
                {
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
        elseif ($search_content -and $search_mode.Mode -ne 'None')
        {
            $view.Filter = [Predicate[object]]{
                param($item)
                
                if ($script:_filter_date_after -and $item.Updated -lt $script:_filter_date_after) { return $false }
                if ($script:_filter_date_before -and $item.Updated -gt $script:_filter_date_before) { return $false }
                
                $title_match   = Test-SearchMatch -Text $item.Name -TextLower $item.NameLower -SearchMode $script:_filter_mode
                $content_match = $item.ContentIndexed -and (Test-SearchMatch -Text $item.Content -TextLower $item.ContentLower -SearchMode $script:_filter_mode)
                
                if ($title_match -or $content_match)
                {
                    $previews = @()
                    
                    if ($title_match)
                    {
                        $snippet = Get-SearchMatchSnippet -Text $item.Name -SearchMode $script:_filter_mode -ContextChars 30
                        if ($snippet) { $previews += "TITLE: $snippet" }
                    }
                    
                    if ($content_match)
                    {
                        $snippet = Get-SearchMatchSnippet -Text $item.Content -SearchMode $script:_filter_mode -ContextChars 60
                        if ($snippet) { $previews += "CONTENT: $snippet" }
                    }
                    
                    if ($title_match -and $content_match) { $item.MatchType = "both" }
                    elseif ($title_match) { $item.MatchType = "title" }
                    else { $item.MatchType = "content" }
                    
                    $item.MatchPreview = $previews -join "`n`n"
                    return $true
                }
                
                return $false
            }
            
            if ($match_col) { $match_col.Visibility = 'Visible' }
        }
        elseif ($search_mode.Mode -ne 'None')
        {
            $view.Filter = [Predicate[object]]{
                param($item)
                
                if ($script:_filter_date_after -and $item.Updated -lt $script:_filter_date_after) { return $false }
                if ($script:_filter_date_before -and $item.Updated -gt $script:_filter_date_before) { return $false }
                
                return Test-SearchMatch -Text $item.Name -TextLower $item.NameLower -SearchMode $script:_filter_mode
            }
            
            if ($match_col) { $match_col.Visibility = 'Collapsed' }
        }
        else
        {
            # Date filter only
            $view.Filter = [Predicate[object]]{
                param($item)
                
                if ($script:_filter_date_after -and $item.Updated -lt $script:_filter_date_after) { return $false }
                if ($script:_filter_date_before -and $item.Updated -gt $script:_filter_date_before) { return $false }
                return $true
            }
            
            if ($match_col) { $match_col.Visibility = 'Collapsed' }
        }
        
        $count = $UIState.CountVisible()
        $UI['ShowingTxt'].Text = $count
        
        $suffix = if ($date_after -or $date_before) { " (date filtered)" } else { "" }
        $UI['FooterTxt'].Text = "Found $count matches$suffix"
        
        # Update empty state
        Update-EmptyState -UI $UI -Total $State.AllChats.Count -Showing $count -IsFiltered
    }
    else
    {
        $view.Filter = $null
        if ($match_col) { $match_col.Visibility = 'Collapsed' }
        
        $UI['ShowingTxt'].Text = $State.AllChats.Count
        
        if ($State.AllChats.Count -gt 0)
        {
            $UI['FooterTxt'].Text = "$($State.AllChats.Count) conversations"
        }
        
        # Update empty state
        Update-EmptyState -UI $UI -Total $State.AllChats.Count -Showing $State.AllChats.Count
    }
}

function Update-EmptyState
{
    <#
    .SYNOPSIS
        Updates empty panel visibility and message based on filter state
    #>
    param(
        [hashtable]$UI,
        [int]$Total,
        [int]$Showing,
        [switch]$IsFiltered
    )
    
    $panel = $UI['EmptyPanel']
    if (-not $panel) { return }
    
    if ($Total -eq 0)
    {
        $panel.Visibility = 'Visible'
    }
    elseif ($Showing -eq 0 -and $IsFiltered)
    {
        $panel.Visibility = 'Visible'
        $stack = $panel.Child
        if ($stack -and $stack.Children.Count -ge 2)
        {
            $stack.Children[0].Text = "No matches found"
            $stack.Children[1].Text = "Try a different search or clear filters"
        }
    }
    else
    {
        $panel.Visibility = 'Collapsed'
        # Reset to default text
        $stack = $panel.Child
        if ($stack -and $stack.Children.Count -ge 2)
        {
            $stack.Children[0].Text = "No conversations"
            $stack.Children[1].Text = "Login and load chats to begin"
        }
    }
}
