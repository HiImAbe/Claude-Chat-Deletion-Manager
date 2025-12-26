#requires -Version 7.0
<#
.SYNOPSIS
    UI event wiring
.DESCRIPTION
    Layer 4 - Events: Wires all UI events to adapter methods and handlers.
    Separated from entry point to keep it focused on initialization only.
#>

#region Visual Tree Helpers

function Find-VisualChild
{
    param(
        $Parent,
        [string]$TypeName,
        [string]$Name = $null
    )
    
    if (-not $Parent) { return $null }
    
    try { $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent) } catch { return $null }
    
    for ($i = 0; $i -lt $count; $i++)
    {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        
        if ($child.GetType().Name -eq $TypeName)
        {
            if (-not $Name -or $child.Name -eq $Name) { return $child }
        }
        
        $result = Find-VisualChild -Parent $child -TypeName $TypeName -Name $Name
        if ($result) { return $result }
    }
    
    return $null
}

function Find-AllVisualChildren
{
    param($Parent, [string]$TypeName)
    
    $results = [System.Collections.ArrayList]::new()
    if (-not $Parent) { return $results }
    
    try { $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent) } catch { return $results }
    
    for ($i = 0; $i -lt $count; $i++)
    {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($child.GetType().Name -eq $TypeName) { [void]$results.Add($child) }
        
        $child_results = Find-AllVisualChildren -Parent $child -TypeName $TypeName
        foreach ($r in $child_results) { [void]$results.Add($r) }
    }
    
    return $results
}

#endregion

#region Event Wiring

function Initialize-UIEvents
{
    <#
    .SYNOPSIS
        Wires all UI events. Called after window and adapter are created.
    #>
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$Adapter
    )
    
    # Store in script scope for event handlers
    $script:_main_window  = $Window
    $script:_main_adapter = $Adapter
    $script:_main_border  = $Window.Content
    $script:_header_checkbox = $null
    $script:sidebar_collapsed = $false
    $script:sidebar_width = $script:CONFIG.UI.SidebarWidth
    
    # Wire all event groups
    Initialize-WindowChromeEvents
    Initialize-SidebarEvents
    Initialize-ButtonEvents
    Initialize-SearchEvents
    Initialize-DateFilterEvents
    Initialize-StatisticsEvents
    Initialize-SelectionEvents
    Initialize-GridEvents
    Initialize-ContextMenuEvents
    Initialize-KeyboardEvents
    Initialize-WindowStateEvents
}

function Initialize-WindowChromeEvents
{
    $script:_main_adapter.UI['MinBtn'].Add_Click({ $script:_main_window.WindowState = 'Minimized' })
    
    $script:_main_adapter.UI['MaxBtn'].Add_Click({
        $script:_main_window.WindowState = if ($script:_main_window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
    })
    
    $script:_main_adapter.UI['CloseBtn'].Add_Click({ $script:_main_window.Close() })
    
    # Fix borderless maximize clipping by constraining to work area
    $script:_main_window.Add_StateChanged({
        if ($script:_main_window.WindowState -eq 'Maximized')
        {
            # Get the work area of the current screen (excludes taskbar)
            $screen = [System.Windows.Forms.Screen]::FromHandle(
                (New-Object System.Windows.Interop.WindowInteropHelper $script:_main_window).Handle
            )
            $work_area = $screen.WorkingArea
            
            # Set max size to work area to prevent clipping
            $script:_main_window.MaxHeight = $work_area.Height
            $script:_main_window.MaxWidth  = $work_area.Width
            
            # Small padding for visual breathing room
            $script:_main_border.Padding = [System.Windows.Thickness]::new(0)
        }
        else
        {
            # Reset constraints for normal mode
            $script:_main_window.MaxHeight = [double]::PositiveInfinity
            $script:_main_window.MaxWidth  = [double]::PositiveInfinity
            $script:_main_border.Padding = [System.Windows.Thickness]::new(0)
        }
        
        # Force layout update
        $script:_main_window.UpdateLayout()
    })
}

function Initialize-SidebarEvents
{
    $script:_main_adapter.UI['HamburgerBtn'].Add_Click({ Toggle-Sidebar })
}

function Toggle-Sidebar
{
    $sidebar_col = $script:_main_window.FindName('SidebarColumn')
    $hamburger = $script:_main_adapter.UI['HamburgerBtn']
    $lines = $hamburger.Template.FindName('HamburgerLines', $hamburger)
    $arrow = $hamburger.Template.FindName('ArrowIcon', $hamburger)
    
    if ($script:sidebar_collapsed) {
        $sidebar_col.Width = [System.Windows.GridLength]::new($script:sidebar_width)
        $script:_main_adapter.UI['SidebarScroller'].Visibility = 'Visible'
        if ($lines) { $lines.Opacity = 1 }
        if ($arrow) { $arrow.Opacity = 0 }
        $script:sidebar_collapsed = $false
    } else {
        $sidebar_col.Width = [System.Windows.GridLength]::new(0)
        $script:_main_adapter.UI['SidebarScroller'].Visibility = 'Collapsed'
        if ($lines) { $lines.Opacity = 0 }
        if ($arrow) { $arrow.Opacity = 1 }
        $script:sidebar_collapsed = $true
    }
}

function Initialize-ButtonEvents
{
    $script:_main_adapter.UI['LoginBtn'].Add_Click({ $script:_main_adapter.Login() })
    
    $script:_main_adapter.UI['LoadBtn'].Add_Click({
        $script:_main_adapter.LoadChats()
        
        # Wire header checkbox after first load
        if (-not $script:_header_checkbox) {
            $script:_main_window.Dispatcher.InvokeAsync(
                [Action]{ Initialize-HeaderCheckbox },
                [System.Windows.Threading.DispatcherPriority]::Background
            )
        }
        
        # Restore index from cache
        if ($script:_index_cache -and $script:_index_cache.Count -gt 0) {
            $restored = Restore-IndexFromCache -Chats $script:_main_adapter.State.AllChats -IndexCache $script:_index_cache
            if ($restored -gt 0) {
                $script:_main_adapter.UI['IndexedTxt'].Text = "$restored indexed (cached)"
                $script:_main_adapter.UI['SearchContentChk'].IsEnabled = $true
                $script:_main_adapter.UI['FooterTxt'].Text += " | $restored indexed from cache"
            }
        }
        
        Save-MetadataCache -Chats $script:_main_adapter.State.AllChats
    })
    
    $script:_main_adapter.UI['IndexBtn'].Add_Click({
        $script:_main_adapter.IndexChats()
        Save-IndexCache -Chats $script:_main_adapter.State.AllChats
    })
    
    $script:_main_adapter.UI['ExportBtn'].Add_Click({ $script:_main_adapter.ExportChats() })
    $script:_main_adapter.UI['DeleteBtn'].Add_Click({ $script:_main_adapter.DeleteSelected() })
    $script:_main_adapter.UI['UndoDeleteBtn'].Add_Click({ $script:_main_adapter.UndoDelete() })
    $script:_main_adapter.UI['ClearDeletedBtn'].Add_Click({ $script:_main_adapter.ClearDeletedBuffer() })
    
    $script:_main_adapter.UI['SelectAllBtn'].Add_Click({
        $script:_main_adapter.UIState.EnsureCollectionView($script:_main_adapter.State.AllChats)
        $script:_main_adapter.State.SelectAllVisible($script:_main_adapter.UIState.CollectionView)
        $script:_main_adapter.UI['SelectedTxt'].Text = $script:_main_adapter.State.GetSelectedCount()
        if ($script:_header_checkbox) { $script:_header_checkbox.IsChecked = $true }
    })
    
    $script:_main_adapter.UI['DeselectBtn'].Add_Click({
        $script:_main_adapter.State.DeselectAll()
        $script:_main_adapter.UI['SelectedTxt'].Text = "0"
        if ($script:_header_checkbox) { $script:_header_checkbox.IsChecked = $false }
    })
}

function Initialize-SearchEvents
{
    $script:search_timer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:search_timer.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.SEARCH_DEBOUNCE_MS)
    $script:search_timer.Add_Tick({
        $script:search_timer.Stop()
        Invoke-FilterUpdate -State $script:_main_adapter.State -UIState $script:_main_adapter.UIState -UI $script:_main_adapter.UI
    })
    
    $script:_main_adapter.UI['SearchBox'].Add_TextChanged({
        $script:search_timer.Stop()
        $has_text = $script:_main_adapter.UI['SearchBox'].Text.Length -gt 0
        $script:_main_adapter.UI['SearchClearBtn'].Visibility = if ($has_text) { 'Visible' } else { 'Collapsed' }
        $script:search_timer.Start()
    })
    
    $script:_main_adapter.UI['SearchClearBtn'].Add_Click({
        $script:_main_adapter.UI['SearchBox'].Text = ""
        $script:_main_adapter.UI['SearchBox'].Focus()
    })
    
    $filter_handler = { Invoke-FilterUpdate -State $script:_main_adapter.State -UIState $script:_main_adapter.UIState -UI $script:_main_adapter.UI }
    $script:_main_adapter.UI['SearchContentChk'].Add_Checked($filter_handler)
    $script:_main_adapter.UI['SearchContentChk'].Add_Unchecked($filter_handler)
}

function Initialize-DateFilterEvents
{
    $filter_handler = { Invoke-FilterUpdate -State $script:_main_adapter.State -UIState $script:_main_adapter.UIState -UI $script:_main_adapter.UI }
    $script:_main_adapter.UI['DateAfterPicker'].Add_SelectedDateChanged($filter_handler)
    $script:_main_adapter.UI['DateBeforePicker'].Add_SelectedDateChanged($filter_handler)
    
    $script:_main_adapter.UI['ClearDatesBtn'].Add_Click({
        $script:_main_adapter.UI['DateAfterPicker'].SelectedDate = $null
        $script:_main_adapter.UI['DateBeforePicker'].SelectedDate = $null
    })
}

function Initialize-StatisticsEvents
{
    $script:_main_adapter.UI['TotalRow'].Add_MouseLeftButtonUp({
        $script:_main_adapter.UI['SearchBox'].Text = ""
        $script:_main_adapter.UI['DateAfterPicker'].SelectedDate = $null
        $script:_main_adapter.UI['DateBeforePicker'].SelectedDate = $null
        $script:_main_adapter.UIState.ShowingSelectedOnly = $false
        $script:_main_adapter.UI['SelectedRow'].Background = [System.Windows.Media.Brushes]::Transparent
        Invoke-FilterUpdate -State $script:_main_adapter.State -UIState $script:_main_adapter.UIState -UI $script:_main_adapter.UI
    })
    
    $script:_main_adapter.UI['SelectedRow'].Add_MouseLeftButtonUp({
        $selected_count = $script:_main_adapter.State.GetSelectedCount()
        if ($selected_count -eq 0) {
            $script:_main_adapter.UI['FooterTxt'].Text = "No selected items to filter"
            return
        }
        
        $script:_main_adapter.UIState.EnsureCollectionView($script:_main_adapter.State.AllChats)
        $view = $script:_main_adapter.UIState.CollectionView
        
        if ($script:_main_adapter.UIState.ShowingSelectedOnly) {
            $view.Filter = $null
            $script:_main_adapter.UIState.ShowingSelectedOnly = $false
            $script:_main_adapter.UI['SelectedRow'].Background = [System.Windows.Media.Brushes]::Transparent
            $script:_main_adapter.UI['ShowingTxt'].Text = $script:_main_adapter.State.AllChats.Count
            $script:_main_adapter.UI['FooterTxt'].Text = "Showing all conversations"
        } else {
            $view.Filter = [Predicate[object]]{ param($item) $item.Selected }
            $script:_main_adapter.UIState.ShowingSelectedOnly = $true
            $script:_main_adapter.UI['SelectedRow'].Background = [System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.Color]::FromRgb(40, 35, 25))
            $script:_main_adapter.UI['ShowingTxt'].Text = $selected_count
            $script:_main_adapter.UI['FooterTxt'].Text = "Showing $selected_count selected"
        }
    })
}

function Initialize-SelectionEvents
{
    $script:selection_timer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:selection_timer.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.SELECTION_POLL_MS)
    $script:selection_timer.Add_Tick({
        $count = $script:_main_adapter.State.GetSelectedCount()
        if ($count -ne $script:_main_adapter.UIState.LastSelectionCount) {
            $script:_main_adapter.UIState.LastSelectionCount = $count
            $script:_main_adapter.UI['SelectedTxt'].Text = $count
            
            # Update dynamic tooltips
            if ($count -gt 0) {
                $script:_main_adapter.UI['DeleteBtn'].ToolTip = "Delete $count selected conversation(s)"
                $script:_main_adapter.UI['ExportBtn'].ToolTip = "Export $count selected (or all if none selected)"
            } else {
                $script:_main_adapter.UI['DeleteBtn'].ToolTip = "Select conversations to delete"
                $script:_main_adapter.UI['ExportBtn'].ToolTip = "Export all conversations"
            }
        }
    })
    $script:selection_timer.Start()
}

function Initialize-GridEvents
{
    # Double-click to open in browser
    $script:_main_adapter.UI['Grid'].Add_MouseDoubleClick({
        param($sender, $e)
        
        $item = $script:_main_adapter.UI['Grid'].SelectedItem
        if ($item -and $item -is [ChatItem])
        {
            Start-Process "https://claude.ai/chat/$($item.Id)"
        }
    })
    
    # Single click for selection
    $script:_main_adapter.UI['Grid'].Add_PreviewMouseLeftButtonDown({
        param($sender, $e)
        
        # Find the row
        $dep_obj = $e.OriginalSource
        while ($dep_obj -and $dep_obj -isnot [System.Windows.Controls.DataGridRow]) {
            $dep_obj = [System.Windows.Media.VisualTreeHelper]::GetParent($dep_obj)
        }
        if (-not $dep_obj) { return }
        
        $row = $dep_obj
        $item = $row.Item
        if ($item -isnot [ChatItem]) { return }
        
        # Ignore clicks on checkbox column
        $pos = $e.GetPosition($row)
        if ($pos.X -lt 36) { return }
        
        $script:_main_adapter.UIState.EnsureCollectionView($script:_main_adapter.State.AllChats)
        $current_index = $script:_main_adapter.UIState.GetVisibleIndex($item)
        
        $is_shift = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift
        $is_ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
        
        if ($is_shift -and $script:_main_adapter.UIState.LastClickedIndex -ge 0) {
            $start_idx = [Math]::Min($script:_main_adapter.UIState.LastClickedIndex, $current_index)
            $end_idx = [Math]::Max($script:_main_adapter.UIState.LastClickedIndex, $current_index)
            for ($i = $start_idx; $i -le $end_idx; $i++) {
                $range_item = $script:_main_adapter.UIState.GetItemAtIndex($i)
                if ($range_item) { $range_item.Selected = $true }
            }
        } elseif ($is_ctrl) {
            $item.Selected = -not $item.Selected
            $script:_main_adapter.UIState.LastClickedIndex = $current_index
        } else {
            $item.Selected = -not $item.Selected
            $script:_main_adapter.UIState.LastClickedIndex = $current_index
        }
        
        $script:_main_adapter.UI['SelectedTxt'].Text = $script:_main_adapter.State.GetSelectedCount()
    })
}

function Initialize-ContextMenuEvents
{
    $menu = $script:_main_adapter.UI['Grid'].ContextMenu
    
    $menu.Items[0].Add_Click({  # Open
        $item = $script:_main_adapter.UI['Grid'].SelectedItem
        if ($item) { Start-Process "https://claude.ai/chat/$($item.Id)" }
    })
    
    $menu.Items[1].Add_Click({  # Copy URL
        $item = $script:_main_adapter.UI['Grid'].SelectedItem
        if ($item) { [System.Windows.Clipboard]::SetText("https://claude.ai/chat/$($item.Id)") }
    })
    
    $menu.Items[3].Add_Click({  # Copy ID
        $item = $script:_main_adapter.UI['Grid'].SelectedItem
        if ($item) { [System.Windows.Clipboard]::SetText($item.Id) }
    })
}

function Initialize-KeyboardEvents
{
    $script:_main_window.Add_PreviewKeyDown({
        param($sender, $e)
        
        $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
        $grid = $script:_main_adapter.UI['Grid']
        $search_focused = $script:_main_adapter.UI['SearchBox'].IsFocused
        
        # Enter to open selected chat in browser
        if ($e.Key -eq 'Return' -and -not $search_focused) {
            $item = $grid.SelectedItem
            if ($item -and $item -is [ChatItem]) {
                Start-Process "https://claude.ai/chat/$($item.Id)"
                $e.Handled = $true
            }
        }
        
        # Space bar to toggle selection
        if ($e.Key -eq 'Space' -and -not $search_focused) {
            $item = $grid.SelectedItem
            if ($item -and $item -is [ChatItem]) {
                $item.Selected = -not $item.Selected
                $script:_main_adapter.UI['SelectedTxt'].Text = $script:_main_adapter.State.GetSelectedCount()
                $e.Handled = $true
            }
        }
        
        # Up/Down arrows for navigation (let DataGrid handle, but update after)
        if (($e.Key -eq 'Up' -or $e.Key -eq 'Down') -and -not $search_focused) {
            # Focus the grid if not already focused
            if (-not $grid.IsFocused -and -not $grid.IsKeyboardFocusWithin) {
                $grid.Focus()
            }
        }
        
        if ($ctrl) {
            switch ($e.Key) {
                'F' {
                    $script:_main_adapter.UI['SearchBox'].Focus()
                    $script:_main_adapter.UI['SearchBox'].SelectAll()
                    $e.Handled = $true
                }
                'B' {
                    Toggle-Sidebar
                    $e.Handled = $true
                }
                'A' {
                    if (-not $search_focused) {
                        $script:_main_adapter.UIState.EnsureCollectionView($script:_main_adapter.State.AllChats)
                        $script:_main_adapter.State.SelectAllVisible($script:_main_adapter.UIState.CollectionView)
                        $script:_main_adapter.UI['SelectedTxt'].Text = $script:_main_adapter.State.GetSelectedCount()
                        if ($script:_header_checkbox) { $script:_header_checkbox.IsChecked = $true }
                        $e.Handled = $true
                    }
                }
                'O' {
                    # Ctrl+O to open selected in browser
                    if (-not $search_focused) {
                        $item = $grid.SelectedItem
                        if ($item -and $item -is [ChatItem]) {
                            Start-Process "https://claude.ai/chat/$($item.Id)"
                            $e.Handled = $true
                        }
                    }
                }
            }
        }
        
        if ($e.Key -eq 'Escape') {
            if ($search_focused -and $script:_main_adapter.UI['SearchBox'].Text) {
                $script:_main_adapter.UI['SearchBox'].Text = ""
                $e.Handled = $true
            }
        }
    })
}

function Initialize-WindowStateEvents
{
    $script:_main_window.Add_Closing({
        $script:selection_timer.Stop()
        $script:search_timer.Stop()
        
        if ($script:_main_adapter.State.AllChats.Count -gt 0) {
            Save-MetadataCache -Chats $script:_main_adapter.State.AllChats
            Save-IndexCache -Chats $script:_main_adapter.State.AllChats
        }
        
        Save-WindowState -Window $script:_main_window -SidebarCollapsed $script:sidebar_collapsed
    })
    
    $script:_main_window.Add_Loaded({
        $saved_state = Restore-WindowState -Window $script:_main_window
        if ($saved_state -and $saved_state.SidebarCollapsed) {
            Toggle-Sidebar
        }
        $script:_main_adapter.RestoreSavedSession()
    })
}

function Initialize-HeaderCheckbox
{
    $all_checkboxes = Find-AllVisualChildren -Parent $script:_main_adapter.UI['Grid'] -TypeName 'CheckBox'
    
    foreach ($chk in $all_checkboxes)
    {
        if ($chk.Name -eq 'SelectAllChk')
        {
            $script:_header_checkbox = $chk
            
            $chk.Add_Click({
                if ($script:_header_checkbox.IsChecked) {
                    $script:_main_adapter.UIState.EnsureCollectionView($script:_main_adapter.State.AllChats)
                    $script:_main_adapter.State.SelectAllVisible($script:_main_adapter.UIState.CollectionView)
                } else {
                    $script:_main_adapter.State.DeselectAll()
                }
                $script:_main_adapter.UI['SelectedTxt'].Text = $script:_main_adapter.State.GetSelectedCount()
            })
            
            break
        }
    }
}

#endregion
