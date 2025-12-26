#requires -Version 7.0
<#
.SYNOPSIS
    Chat manager adapter (ViewModel-like)
.DESCRIPTION
    Layer 5 - Adapters: Interface between UI and application logic
    Knows: Events, Records
#>

class ChatAdapter
{
    [AppState]$State
    [UIState]$UIState
    [hashtable]$UI
    [object]$Window  # System.Windows.Window - typed at runtime
    [hashtable]$Timers
    
    ChatAdapter()
    {
        $this.State   = [AppState]::new()
        $this.UIState = [UIState]::new()
        $this.UI      = @{}
        $this.Timers  = @{}
        
        # Initialize collections now that assemblies are loaded
        $this.State.InitializeCollections()
    }
    
    [void] InitializeUI($Window)
    {
        $this.Window = $Window
        
        $element_names = @(
            'TitleBar', 'StatusDot', 'StatusTxt', 'MinBtn', 'MaxBtn', 'CloseBtn', 'HamburgerBtn',
            'SidebarScroller', 'SidebarPanel', 'LoginBtn', 'LoadBtn', 'SearchBox', 'SearchClearBtn', 
            'SearchContentChk', 'IndexedTxt', 'IndexBtn', 'TotalTxt', 'ShowingTxt', 'SelectedTxt', 
            'TotalRow', 'SelectedRow', 'SelectAllBtn', 'DeselectBtn', 
            'DateAfterPicker', 'DateBeforePicker', 'ClearDatesBtn',
            'StatsPanel', 'StatsSummary', 'RecentlyDeletedLabel', 'UndoDeleteBtn', 'ClearDeletedBtn',
            'Grid', 'EmptyPanel', 'FooterTxt', 'ExportBtn', 'DeleteBtn', 'ResizeGrip'
        )
        
        foreach ($name in $element_names)
        {
            $this.UI[$name] = $Window.FindName($name)
        }
        
        $this.UI['Grid'].ItemsSource = $this.State.AllChats
    }
    
    [void] UpdateCounts()
    {
        $total = $this.State.AllChats.Count
        
        # Ensure view exists before counting visible
        $this.UIState.EnsureCollectionView($this.State.AllChats)
        $showing = $this.UIState.CountVisible()
        
        # If no filter, showing equals total
        if ($showing -eq 0 -and $total -gt 0 -and -not $this.UIState.CollectionView.Filter) {
            $showing = $total
        }
        
        $this.UI['TotalTxt'].Text    = $total
        $this.UI['ShowingTxt'].Text  = $showing
        $this.UI['SelectedTxt'].Text = $this.State.GetSelectedCount()
    }
    
    [void] Login()
    {
        if ($this.UI['LoginBtn'].Content -eq "Logout")
        {
            $confirm = [System.Windows.MessageBox]::Show(
                "Log out and clear saved session?",
                "Confirm Logout", 'YesNo', 'Question')
            
            if ($confirm -ne 'Yes') { return }
            
            Clear-Credentials
            
            # Clear sensitive data from memory
            $this.State.OrgId  = $null
            $this.State.Cookie = $null
            [System.GC]::Collect()
            
            Set-ConnectionState -Connected $false -State $this.State -UI $this.UI
            $this.State.ClearChats()
            $this.State.HasLoadedOnce = $false
            $this.UI['FooterTxt'].Text = "Logged out"
            $this.UpdateCounts()
        }
        else
        {
            Update-ButtonState -Button $this.UI['LoginBtn'] -Text "Logging in..." -Enabled $false
            
            $result = Show-LoginDialog -Owner $this.Window
            
            if ($result)
            {
                $this.State.OrgId  = $result.org_id
                $this.State.Cookie = $result.cookie
                Save-Credentials -OrgId $result.org_id -Cookie $result.cookie
                Set-ConnectionState -Connected $true -State $this.State -UI $this.UI
                $this.UI['FooterTxt'].Text = "Login successful"
            }
            
            Update-ButtonState -Button $this.UI['LoginBtn'] -Text "Login" -Enabled $true
            
            if ($this.State.OrgId)
            {
                $this.UI['LoginBtn'].Content = "Logout"
            }
        }
    }
    
    [void] LoadChats()
    {
        Update-ButtonState -Button $this.UI['LoadBtn'] -Text "Loading..." -Enabled $false
        
        $this.State.ClearChats()
        $this.UI['EmptyPanel'].Visibility = 'Collapsed'
        
        $this.UI['IndexedTxt'].Text            = ""
        $this.UI['SearchContentChk'].IsEnabled = $false
        $this.UI['SearchContentChk'].IsChecked = $false
        
        # Store reference for scriptblock
        $script:_adapter_ui = $this.UI
        
        $count = Get-AllChats `
            -Owner $this.Window `
            -TargetCollection $this.State.AllChats `
            -OnProgress {
                param($n)
                $script:_adapter_ui['FooterTxt'].Text = "$n conversations found..."
            }
        
        $script:_adapter_ui = $null
        
        $this.UI['FooterTxt'].Text = "$count conversations loaded"
        
        $this.UIState.EnsureCollectionView($this.State.AllChats)
        $this.UIState.ResetForNewData()
        $this.UpdateCounts()
        
        if (-not $this.State.HasLoadedOnce)
        {
            $this.State.HasLoadedOnce = $true
        }
        
        Update-ButtonState -Button $this.UI['LoadBtn'] -Text "Refresh Chats" -Enabled $true
        
        Update-StatsDisplay -State $this.State -StatsSummary $this.UI['StatsSummary']
    }
    
    [void] IndexChats()
    {
        if ($this.State.AllChats.Count -eq 0)
        {
            [System.Windows.MessageBox]::Show("No conversations to index. Load chats first.", "Index", 'OK', 'Information')
            return
        }
        
        $indexed_count = $this.State.GetIndexedCount()
        
        if ($indexed_count -eq $this.State.AllChats.Count)
        {
            $confirm = [System.Windows.MessageBox]::Show(
                "All conversations indexed.`n`nClear index to free memory?",
                "Clear Index?", 'YesNo', 'Question')
            
            if ($confirm -eq 'Yes')
            {
                $this.State.ClearIndex()
                $this.UI['IndexedTxt'].Text            = ""
                $this.UI['SearchContentChk'].IsEnabled = $false
                $this.UI['SearchContentChk'].IsChecked = $false
                $this.UI['FooterTxt'].Text             = "Index cleared"
                Invoke-FilterUpdate -State $this.State -UIState $this.UIState -UI $this.UI
            }
            return
        }
        
        $to_index = @($this.State.AllChats | Where-Object { $_.Selected -and -not $_.ContentIndexed })
        
        if ($to_index.Count -eq 0)
        {
            $to_index = @($this.State.AllChats | Where-Object { -not $_.ContentIndexed })
        }
        
        if ($to_index.Count -eq 0)
        {
            $this.UI['FooterTxt'].Text = "All conversations already indexed"
            return
        }
        
        $confirm = [System.Windows.MessageBox]::Show(
            "Index $($to_index.Count) conversation(s)?`n`nThis enables content search but uses memory.",
            "Index Content", 'YesNo', 'Question')
        
        if ($confirm -ne 'Yes') { return }
        
        Update-ButtonState -Button $this.UI['IndexBtn'] -Text "Indexing..." -Enabled $false
        
        Update-ChatContentIndex -Chats $to_index -Owner $this.Window -SourceCollection $this.State.AllChats
        
        $indexed_count = $this.State.GetIndexedCount()
        
        $this.UI['IndexedTxt'].Text            = "$indexed_count indexed"
        $this.UI['SearchContentChk'].IsEnabled = $indexed_count -gt 0
        $this.UI['FooterTxt'].Text             = "Indexed $($to_index.Count) conversations"
        
        Update-ButtonState -Button $this.UI['IndexBtn'] -Text "Index Chats" -Enabled $true
    }
    
    [void] ExportChats()
    {
        $selected  = $this.State.GetSelectedChats()
        $all_chats = @($this.State.AllChats)
        
        if ($all_chats.Count -eq 0)
        {
            [System.Windows.MessageBox]::Show("No conversations to export.", "Export", 'OK', 'Information')
            return
        }
        
        $to_export    = $null
        $export_label = ""
        
        if ($selected.Count -gt 0 -and $selected.Count -lt $all_chats.Count)
        {
            $choice = [System.Windows.MessageBox]::Show(
                "Export selected ($($selected.Count)) or all ($($all_chats.Count)) conversations?`n`nYes = Selected only`nNo = All conversations",
                "Export Scope", 'YesNoCancel', 'Question')
            
            if ($choice -eq 'Cancel') { return }
            
            if ($choice -eq 'Yes')
            {
                $to_export    = $selected
                $export_label = "Selected"
            }
            else
            {
                $to_export    = $all_chats
                $export_label = "All"
            }
        }
        else
        {
            $to_export    = $all_chats
            $export_label = "All"
        }
        
        $export_type = [System.Windows.MessageBox]::Show(
            "Include full message content?`n`nYes = Complete backup`nNo = Metadata only (faster)",
            "Export Type", 'YesNoCancel', 'Question')
        
        if ($export_type -eq 'Cancel') { return }
        
        $full_export = ($export_type -eq 'Yes')
        
        $dialog = [Microsoft.Win32.SaveFileDialog]::new()
        $dialog.Filter   = "JSON|*.json"
        $dialog.FileName = "claude_export_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $dialog.Title    = "Export $export_label ($($to_export.Count))"
        
        if (-not $dialog.ShowDialog()) { return }
        
        if ($full_export)
        {
            Update-ButtonState -Button $this.UI['ExportBtn'] -Text "Exporting..." -Enabled $false
            Export-ChatsWithContent -Chats $to_export -OutputPath $dialog.FileName -Owner $this.Window
            Update-ButtonState -Button $this.UI['ExportBtn'] -Text "Export" -Enabled $true
        }
        else
        {
            try
            {
                $export_data = [PSCustomObject]@{
                    export_date         = (Get-Date).ToString('o')
                    export_version      = "3.0"
                    export_type         = "metadata"
                    total_conversations = $to_export.Count
                    conversations       = @($to_export | ForEach-Object {
                        [PSCustomObject]@{
                            id         = $_.Id
                            name       = $_.Name
                            updated_at = $_.Updated.ToString('o')
                        }
                    })
                }
                
                $export_data | ConvertTo-Json -Depth 5 | Set-Content $dialog.FileName -Encoding UTF8
                
                $this.UI['FooterTxt'].Text = "Exported $($to_export.Count) conversations"
            }
            catch
            {
                [System.Windows.MessageBox]::Show("Export failed: $_", "Error", 'OK', 'Error')
            }
        }
    }
    
    [void] DeleteSelected()
    {
        $to_delete = $this.State.GetSelectedChats()
        
        if ($to_delete.Count -eq 0)
        {
            [System.Windows.MessageBox]::Show("No conversations selected.", "Delete", 'OK', 'Information')
            return
        }
        
        $confirm = [System.Windows.MessageBox]::Show(
            "Permanently delete $($to_delete.Count) conversation(s)?`n`nThis cannot be undone on the server!",
            "Confirm Delete", 'YesNo', 'Warning')
        
        if ($confirm -ne 'Yes') { return }
        
        $this.State.BufferForUndo($to_delete)
        
        Update-ButtonState -Button $this.UI['DeleteBtn'] -Text "Deleting..." -Enabled $false
        
        $deleted = Remove-SelectedChats -Chats $to_delete -Owner $this.Window -SourceCollection $this.State.AllChats
        
        $this.UI['FooterTxt'].Text = "Deleted $deleted conversation(s) permanently"
        
        Update-ButtonState -Button $this.UI['DeleteBtn'] -Text "Delete Selected" -Enabled $true
        
        # Refresh view and update all counts after deletion
        $this.UIState.EnsureCollectionView($this.State.AllChats)
        if ($this.UIState.CollectionView) {
            $this.UIState.CollectionView.Refresh()
        }
        $this.UpdateCounts()
        
        Update-DeletedBufferUI -State $this.State -UI $this.UI
        Update-StatsDisplay -State $this.State -StatsSummary $this.UI['StatsSummary']
    }
    
    [void] UndoDelete()
    {
        if ($this.State.DeletedBuffer.Count -eq 0)
        {
            $this.UI['FooterTxt'].Text = "Nothing to restore"
            return
        }
        
        $restored_count = $this.State.RestoreFromBuffer()
        
        # Refresh view and update all counts after restore
        $this.UIState.EnsureCollectionView($this.State.AllChats)
        if ($this.UIState.CollectionView) {
            $this.UIState.CollectionView.Refresh()
        }
        $this.UpdateCounts()
        
        Update-DeletedBufferUI -State $this.State -UI $this.UI
        Update-StatsDisplay -State $this.State -StatsSummary $this.UI['StatsSummary']
        
        $this.UI['FooterTxt'].Text = "Restored $restored_count to local list (server deletion is permanent)"
    }
    
    [void] ClearDeletedBuffer()
    {
        $this.State.DeletedBuffer = @()
        Update-DeletedBufferUI -State $this.State -UI $this.UI
        $this.UI['FooterTxt'].Text = "Undo history cleared"
    }
    
    [void] RestoreSavedSession()
    {
        $saved = Get-SavedCredentials
        
        if ($saved)
        {
            $this.State.OrgId  = $saved.org_id
            $this.State.Cookie = $saved.cookie
            Set-ConnectionState -Connected $true -State $this.State -UI $this.UI
            $this.UI['FooterTxt'].Text = "Session restored - click Load Chats"
        }
    }
}
