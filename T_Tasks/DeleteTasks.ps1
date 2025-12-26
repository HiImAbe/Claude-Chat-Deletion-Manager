#requires -Version 7.0
<#
.SYNOPSIS
    Chat deletion operations
.DESCRIPTION
    Layer 2 - Tasks: Operations to delete chats via Claude API
#>

function Remove-SelectedChats
{
    param(
        [Parameter(Mandatory)]
        [array]$Chats,
        
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner,
        
        [Parameter(Mandatory)]
        [System.Collections.ObjectModel.ObservableCollection[ChatItem]]$SourceCollection
    )
    
    Write-Host "Deleting $($Chats.Count) conversations..." -ForegroundColor Yellow
    
    $chat_ids = @($Chats | ForEach-Object { $_.Id })
    $ids_json = ConvertTo-Json -InputObject $chat_ids -Compress
    $total    = $chat_ids.Count
    
    $script:_delete_success_count = 0
    
    $operation = New-WebView2Operation `
        -Title "Deleting Conversations" `
        -Owner $Owner `
        -StatusText "Preparing..." `
        -ShowProgress $true `
        -ProgressIndeterminate $false `
        -ProgressColor "#e74c3c" `
        -TimeoutSeconds 300 `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            if ($op.progress_bar) { $op.progress_bar.Maximum = $total }
            
            $delete_js = @"
window._deleteResult = null;
window._deleteDone = false;
window._deleteProgress = 0;

(async () => {
    const ids = $ids_json;
    const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
    let deleted = 0;
    let failed = 0;
    
    for (const id of ids) {
        try {
            const resp = await fetch(
                'https://claude.ai/api/organizations/' + orgId + '/chat_conversations/' + id,
                {method: 'DELETE', credentials: 'include'}
            );
            
            if (resp.ok || resp.status === 204) {
                deleted++;
            } else {
                failed++;
            }
        } catch (e) {
            failed++;
        }
        
        window._deleteProgress++;
        await new Promise(r => setTimeout(r, $($script:CONSTANTS.DELETE_REQUEST_DELAY_MS)));
    }
    
    window._deleteResult = {deleted: deleted, failed: failed};
    window._deleteDone = true;
})();
"@
            
            $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($delete_js)
            Invoke-WithDoEvents -Task $start_task | Out-Null
            
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds(200)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_delete_total  = $total
            $script:_delete_ids    = $chat_ids
            $script:_delete_source = $SourceCollection
            $script:_delete_start  = [DateTime]::Now
            
            $poll_timer.Add_Tick({
                param($sender, $event_args)
                
                $op = $script:_current_operation
                
                if (-not $op -or $op.is_cancelled -or -not $op.webview -or -not $op.webview.CoreWebView2)
                {
                    $sender.Stop()
                    return
                }
                
                try
                {
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._deleteProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    $pct = if ($script:_delete_total -gt 0) { [int](($progress / $script:_delete_total) * 100) } else { 0 }
                    $elapsed = [int]([DateTime]::Now - $script:_delete_start).TotalSeconds
                    $op.status_text.Text = "Deleting $progress / $script:_delete_total ($pct%) - ${elapsed}s"
                    if ($op.progress_bar) { $op.progress_bar.Value = $progress }
                    
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._deleteDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                        
                        $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._deleteResult)")
                        $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        
                        $unescaped = ConvertFrom-JsonSafe -Json $result_json
                        $result    = if ($unescaped) { ConvertFrom-JsonSafe -Json $unescaped } else { $null }
                        
                        if ($result)
                        {
                            $items_to_remove = @($script:_delete_source | Where-Object { $script:_delete_ids -contains $_.Id })
                            
                            foreach ($item in $items_to_remove)
                            {
                                $script:_delete_source.Remove($item)
                            }
                            
                            $script:_delete_success_count = $result.deleted
                            
                            $color = if ($result.failed -gt 0) { "Yellow" } else { "Green" }
                            Write-Host "Deleted $($result.deleted), failed $($result.failed)" -ForegroundColor $color
                            $op.status_text.Text = "Deleted $($result.deleted) conversations"
                        }
                        
                        Complete-WebView2Operation -Operation $op -Success $true
                    }
                }
                catch
                {
                    Write-Host "Delete poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation) { return 0 }
    
    [void]$operation.window.ShowDialog()
    
    return $script:_delete_success_count
}
