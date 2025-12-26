#requires -Version 7.0
<#
.SYNOPSIS
    Chat export operations
.DESCRIPTION
    Layer 2 - Tasks: Operations to export chats with content
#>

function Export-ChatsWithContent
{
    param(
        [Parameter(Mandatory)]
        [array]$Chats,
        
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [System.Windows.Window]$Owner
    )
    
    Write-Host "Exporting $($Chats.Count) conversations with content..." -ForegroundColor Cyan
    
    $chat_ids = @($Chats | ForEach-Object { $_.Id })
    $ids_json = ConvertTo-Json -InputObject $chat_ids -Compress
    $total    = $chat_ids.Count
    
    $operation = New-WebView2Operation `
        -Title "Exporting Conversations" `
        -Owner $Owner `
        -StatusText "Preparing export..." `
        -ShowProgress $true `
        -ProgressIndeterminate $false `
        -ProgressColor "#2ecc71" `
        -TimeoutSeconds ($script:CONSTANTS.EXPORT_TIMEOUT_MINUTES * 60) `
        -ShowCancel $true `
        -OnWebViewReady {
            param($op)
            
            if ($op.progress_bar) { $op.progress_bar.Maximum = $total }
            
            $export_js = @"
window._exportResult = null;
window._exportDone = false;
window._exportProgress = 0;

(async () => {
    try {
        const ids = $ids_json;
        const orgId = document.cookie.match(/lastActiveOrg=([^;]+)/)?.[1];
        let results = [];
        
        for (const id of ids) {
            try {
                const resp = await fetch(
                    'https://claude.ai/api/organizations/' + orgId + '/chat_conversations/' + id + '?tree=True',
                    {credentials: 'include'}
                );
                
                if (resp.ok) {
                    const data = await resp.json();
                    results.push({id: id, success: true, data: data});
                } else {
                    results.push({id: id, success: false, error: 'HTTP ' + resp.status});
                }
            } catch (e) {
                results.push({id: id, success: false, error: e.message});
            }
            
            window._exportProgress++;
            await new Promise(r => setTimeout(r, $($script:CONSTANTS.EXPORT_REQUEST_DELAY_MS)));
        }
        
        window._exportResult = {success: true, chats: results};
    } catch(e) {
        window._exportResult = {success: false, error: e.message};
    }
    window._exportDone = true;
})();
"@
            
            $start_task = $op.webview.CoreWebView2.ExecuteScriptAsync($export_js)
            Invoke-WithDoEvents -Task $start_task | Out-Null
            
            $poll_timer = [System.Windows.Threading.DispatcherTimer]::new()
            $poll_timer.Interval = [TimeSpan]::FromMilliseconds(200)
            $op.timers.Add($poll_timer) | Out-Null
            
            $script:_export_output = $OutputPath
            $script:_export_total  = $total
            $script:_export_start  = [DateTime]::Now
            
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
                    $progress_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._exportProgress || 0")
                    $progress = [int](Invoke-WithDoEvents -Task $progress_task -PollMs $script:CONSTANTS.POLL_WAIT_MS)
                    
                    # Calculate percentage and ETA
                    $pct = if ($script:_export_total -gt 0) { [int](($progress / $script:_export_total) * 100) } else { 0 }
                    $elapsed = ([DateTime]::Now - $script:_export_start).TotalSeconds
                    $eta_text = ""
                    if ($progress -gt 0 -and $elapsed -gt 1)
                    {
                        $rate = $progress / $elapsed
                        $remaining = $script:_export_total - $progress
                        $eta_seconds = if ($rate -gt 0) { [int]($remaining / $rate) } else { 0 }
                        if ($eta_seconds -gt 0) { $eta_text = " (~${eta_seconds}s)" }
                    }
                    
                    $op.status_text.Text = "Exporting $progress / $script:_export_total ($pct%)$eta_text"
                    if ($op.progress_bar) { $op.progress_bar.Value = $progress }
                    
                    $done_task = $op.webview.CoreWebView2.ExecuteScriptAsync("window._exportDone")
                    $done = (Invoke-WithDoEvents -Task $done_task -PollMs $script:CONSTANTS.POLL_WAIT_MS) -eq "true"
                    
                    if ($done)
                    {
                        $sender.Stop()
                        
                        $result_task = $op.webview.CoreWebView2.ExecuteScriptAsync("JSON.stringify(window._exportResult)")
                        $result_json = Invoke-WithDoEvents -Task $result_task -PollMs $script:CONSTANTS.POLL_WAIT_MS
                        
                        $unescaped = ConvertFrom-JsonSafe -Json $result_json
                        $result    = if ($unescaped) { ConvertFrom-JsonSafe -Json $unescaped } else { $null }
                        
                        if ($result -and $result.success)
                        {
                            $export_data = [PSCustomObject]@{
                                export_date         = (Get-Date).ToString('o')
                                export_version      = "3.0"
                                export_type         = "full"
                                total_conversations = $result.chats.Count
                                conversations       = @($result.chats | ForEach-Object {
                                    if ($_.success -and $_.data)
                                    {
                                        [PSCustomObject]@{
                                            id            = $_.id
                                            name          = $_.data.name
                                            created_at    = $_.data.created_at
                                            updated_at    = $_.data.updated_at
                                            model         = $_.data.model
                                            chat_messages = @($_.data.chat_messages | ForEach-Object {
                                                [PSCustomObject]@{
                                                    uuid        = $_.uuid
                                                    sender      = $_.sender
                                                    text        = $_.text
                                                    created_at  = $_.created_at
                                                    attachments = $_.attachments
                                                }
                                            })
                                        }
                                    }
                                    else
                                    {
                                        [PSCustomObject]@{
                                            id    = $_.id
                                            error = $_.error
                                        }
                                    }
                                })
                            }
                            
                            try
                            {
                                $export_data | ConvertTo-Json -Depth 20 | Set-Content $script:_export_output -Encoding UTF8
                                $success_count = ($result.chats | Where-Object { $_.success }).Count
                                Write-Host "Exported $success_count conversations to: $script:_export_output" -ForegroundColor Green
                                $op.status_text.Text = "Exported $success_count conversations"
                            }
                            catch
                            {
                                Write-Host "Failed to write export file: $_" -ForegroundColor Red
                                $op.status_text.Text = "Failed to save file"
                            }
                        }
                        else
                        {
                            $op.status_text.Text = "Export failed"
                        }
                        
                        Complete-WebView2Operation -Operation $op -Success $true
                    }
                }
                catch
                {
                    Write-Host "Export poll error: $_" -ForegroundColor Red
                    $sender.Stop()
                }
            })
            
            $poll_timer.Start()
        }
    
    if (-not $operation) { return }
    
    [void]$operation.window.ShowDialog()
}
