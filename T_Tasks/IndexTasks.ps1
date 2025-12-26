#requires -Version 7.0
<#
.SYNOPSIS
    Chat content indexing operations
.DESCRIPTION
    Layer 2 - Tasks: Operations to index chat content for deep search.
    Uses parallel batching for performance (8 concurrent requests).
#>

function Update-ChatContentIndex
{
    param(
        [Parameter(Mandatory)]
        [array]$Chats,
        
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner,
        
        [Parameter(Mandatory)]
        [System.Collections.ObjectModel.ObservableCollection[ChatItem]]$SourceCollection
    )
    
    $total = $Chats.Count
    Write-Host "Indexing content for $total conversations (batch size: $($script:CONSTANTS.INDEX_BATCH_SIZE))..." -ForegroundColor Cyan
    
    $chat_ids  = @($Chats | ForEach-Object { $_.Id })
    $ids_json  = ConvertTo-Json -InputObject $chat_ids -Compress
    $batch_size = $script:CONSTANTS.INDEX_BATCH_SIZE
    $delay_ms   = $script:CONSTANTS.INDEX_REQUEST_DELAY_MS
    $max_len    = $script:CONSTANTS.MAX_CONTENT_LENGTH
    
    $operation = New-WebView2Operation `
        -Title "Indexing Content" `
        -Owner $Owner `
        -StatusText "Preparing..." `
        -ShowProgress $true `
        -ProgressIndeterminate $false `
        -ProgressColor "#9b59b6" `
        -TimeoutSeconds ($script:CONSTANTS.INDEX_TIMEOUT_MINUTES * 60) `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            if ($op.progress_bar) { $op.progress_bar.Maximum = $total }
            
            # JavaScript with parallel batching
            $index_js = @"
window._indexDone = false;
window._indexProgress = 0;
window._indexResults = [];
window._indexTotal = $total;
window._indexStartTime = Date.now();

(async () => {
    const ids = $ids_json;
    const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
    const maxLen = $max_len;
    const batchSize = $batch_size;
    const delayMs = $delay_ms;
    
    // Function to fetch a single chat
    async function fetchChat(id) {
        try {
            const resp = await fetch(
                'https://claude.ai/api/organizations/' + orgId + '/chat_conversations/' + id + '?tree=True',
                { credentials: 'include' }
            );
            
            if (resp.ok) {
                const data = await resp.json();
                let content = '';
                if (data.chat_messages) {
                    content = data.chat_messages.map(m => m.text || '').join(' ');
                }
                return { id: id, content: content.substring(0, maxLen), success: true };
            }
            return { id: id, content: '', success: false };
        } catch (e) {
            return { id: id, content: '', success: false };
        }
    }
    
    // Process in batches
    for (let i = 0; i < ids.length; i += batchSize) {
        const batch = ids.slice(i, i + batchSize);
        
        // Fetch batch in parallel
        const batchPromises = batch.map(id => fetchChat(id));
        const batchResults = await Promise.all(batchPromises);
        
        // Add results
        for (const result of batchResults) {
            window._indexResults.push({ id: result.id, content: result.content });
            window._indexProgress++;
        }
        
        // Small delay between batches to avoid rate limiting
        if (i + batchSize < ids.length) {
            await new Promise(r => setTimeout(r, delayMs));
        }
    }
    
    window._indexDone = true;
})();
"@
            
            $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($index_js)
            Invoke-WithDoEvents -Task $start_task | Out-Null
            
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds(150)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_index_total  = $total
            $script:_index_source = $SourceCollection
            $script:_index_start  = [DateTime]::Now
            
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
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._indexProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    # Calculate ETA
                    $elapsed = ([DateTime]::Now - $script:_index_start).TotalSeconds
                    $eta_text = ""
                    if ($progress -gt 0 -and $elapsed -gt 1)
                    {
                        $rate = $progress / $elapsed
                        $remaining = $script:_index_total - $progress
                        $eta_seconds = if ($rate -gt 0) { [int]($remaining / $rate) } else { 0 }
                        if ($eta_seconds -gt 0) { $eta_text = " (~${eta_seconds}s remaining)" }
                    }
                    
                    $pct = if ($script:_index_total -gt 0) { [int](($progress / $script:_index_total) * 100) } else { 0 }
                    $op.status_text.Text = "Indexing $progress / $script:_index_total ($pct%)$eta_text"
                    if ($op.progress_bar) { $op.progress_bar.Value = $progress }
                    
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._indexDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                        
                        $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._indexResults)")
                        $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        
                        $unescaped = ConvertFrom-JsonSafe -Json $result_json
                        $results   = if ($unescaped) { ConvertFrom-JsonSafe -Json $unescaped } else { @() }
                        
                        if ($results)
                        {
                            $indexed_count = 0
                            foreach ($result_item in $results)
                            {
                                $chat = $script:_index_source | Where-Object { $_.Id -eq $result_item.id } | Select-Object -First 1
                                
                                if ($chat -and $result_item.content)
                                {
                                    $chat.Content        = $result_item.content
                                    $chat.ContentIndexed = $true
                                    $indexed_count++
                                }
                            }
                            
                            $elapsed_total = [int]([DateTime]::Now - $script:_index_start).TotalSeconds
                            Write-Host "Indexed $indexed_count conversations in ${elapsed_total}s" -ForegroundColor Green
                            $op.status_text.Text = "Indexed $indexed_count conversations"
                        }
                        
                        Complete-WebView2Operation -Operation $op -Success $true
                    }
                }
                catch
                {
                    Write-Host "Index poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation) { return }
    
    [void]$operation.window.ShowDialog()
}
