#requires -Version 7.0
using namespace System.Collections.ObjectModel

<#
.SYNOPSIS
    Chat fetching operations
.DESCRIPTION
    Layer 2 - Tasks: Operations to fetch chats from Claude API
#>

function Get-AllChats
{
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner,
        
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [ObservableCollection[ChatItem]]$TargetCollection,
        
        [scriptblock]$OnProgress
    )
    
    Write-Host "Fetching all conversations..." -ForegroundColor Cyan
    
    $operation = New-WebView2Operation `
        -Title "Fetching Conversations" `
        -Owner $Owner `
        -StatusText "Connecting to Claude..." `
        -ShowProgress $true `
        -ProgressIndeterminate $true `
        -ProgressColor "#3498db" `
        -TimeoutSeconds $script:CONSTANTS.FETCH_TIMEOUT_SECONDS `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            $op.status_text.Text = "Loading conversations..."
            
            $fetch_js = @"
window._fetchResult = null;
window._fetchDone = false;
window._fetchProgress = 0;
window._fetchStarted = false;
window._fetchError = null;

(async () => {
    window._fetchStarted = true;
    try {
        const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
        window._fetchOrgId = orgId || 'NOT_FOUND';
        
        if (!orgId) {
            window._fetchError = 'No organization ID in cookies';
            window._fetchResult = {success: false, error: 'No organization ID found'};
            window._fetchDone = true;
            return;
        }
        
        let allChats = [];
        let seenIds = new Set();
        let cursor = null;
        let lastCursor = null;
        let page = 0;
        const maxPages = $($script:CONSTANTS.MAX_PAGINATION_PAGES);
        
        while (page < maxPages) {
            page++;
            window._fetchPage = page;
            
            const url = cursor 
                ? 'https://claude.ai/api/organizations/' + orgId + '/chat_conversations?cursor=' + cursor
                : 'https://claude.ai/api/organizations/' + orgId + '/chat_conversations';
            
            const resp = await fetch(url, {credentials: 'include'});
            
            if (!resp.ok) {
                if (resp.status === 401 || resp.status === 403) {
                    window._fetchResult = {success: false, error: 'Session expired - please login again'};
                    window._fetchDone = true;
                    return;
                }
                break;
            }
            
            const data = await resp.json();
            if (!data || !Array.isArray(data) || data.length === 0) break;
            
            let newCount = 0;
            for (const chat of data) {
                if (chat.uuid && !seenIds.has(chat.uuid)) {
                    seenIds.add(chat.uuid);
                    allChats.push({
                        uuid: chat.uuid,
                        name: chat.name || 'Untitled',
                        updated_at: chat.updated_at
                    });
                    newCount++;
                }
            }
            
            window._fetchProgress = allChats.length;
            
            if (newCount === 0) break;
            
            cursor = data[data.length - 1]?.uuid;
            if (!cursor || cursor === lastCursor) break;
            lastCursor = cursor;
            
            if (data.length < 50) break;
            
            await new Promise(r => setTimeout(r, $($script:CONSTANTS.API_REQUEST_DELAY_MS)));
        }
        
        window._fetchResult = {success: true, count: allChats.length, chats: allChats};
    } catch(e) {
        window._fetchError = e.message;
        window._fetchResult = {success: false, error: e.message};
    }
    window._fetchDone = true;
})();

'INJECTED';
"@
            
            try
            {
                $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($fetch_js)
                Invoke-WithDoEvents -Task $start_task | Out-Null
            }
            catch
            {
                $op.status_text.Text = "Script injection failed"
                Complete-WebView2Operation -Operation $op -Success $false
                return
            }
            
            # Poll for progress
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds($script:CONSTANTS.POLL_INTERVAL_MS)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_fetch_last_progress = 0
            $script:_fetch_target = $TargetCollection
            $script:_fetch_on_progress = $OnProgress
            $script:_fetch_start = [DateTime]::Now
            
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
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._fetchProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    if ($progress -gt $script:_fetch_last_progress)
                    {
                        # Show page number for context
                        $page_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._fetchPage || 0")
                        $page = [int](Invoke-WithDoEvents -Task $page_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                        
                        $elapsed = [int]([DateTime]::Now - $script:_fetch_start).TotalSeconds
                        $op.status_text.Text = "Found $progress conversations (page $page, ${elapsed}s)"
                        $script:_fetch_last_progress = $progress
                        
                        if ($script:_fetch_on_progress)
                        {
                            & $script:_fetch_on_progress $progress
                        }
                    }
                    
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._fetchDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                        
                        $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._fetchResult)")
                        $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        
                        $unescaped = ConvertFrom-JsonSafe -Json $result_json
                        
                        if ($unescaped)
                        {
                            $result = ConvertFrom-JsonSafe -Json $unescaped
                            
                            if ($result)
                            {
                                if ($result.error)
                                {
                                    $op.status_text.Text = "Error: $($result.error)"
                                    Start-Sleep -Milliseconds 1500
                                }
                                elseif ($result.success -and $result.chats)
                                {
                                    foreach ($chat_data in $result.chats)
                                    {
                                        $item = [ChatItem]::new()
                                        $item.Id       = $chat_data.uuid
                                        $item.Name     = $chat_data.name
                                        $item.Selected = $false
                                        
                                        try 
                                        {
                                            $item.Updated = [datetime]$chat_data.updated_at
                                        }
                                        catch 
                                        {
                                            $item.Updated = [datetime]::Now
                                        }
                                        
                                        $script:_fetch_target.Add($item)
                                    }
                                    
                                    $op.status_text.Text = "$($result.count) conversations loaded"
                                    Write-Host "Fetched $($result.count) conversations" -ForegroundColor Green
                                }
                            }
                        }
                        
                        Complete-WebView2Operation -Operation $op -Success $true
                    }
                }
                catch
                {
                    Write-Host "Poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation) { return 0 }
    
    [void]$operation.window.ShowDialog()
    
    return $TargetCollection.Count
}
