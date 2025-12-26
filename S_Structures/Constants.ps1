#requires -Version 7.0
<#
.SYNOPSIS
    Application constants
.DESCRIPTION
    Layer 1 - Structures: Defines application-wide constants.
    Some values are overridable via config.json, others are hardcoded.
    
    NOTE: This file loads AFTER Initialize-Config, so $script:CONFIG is available.
#>

function Initialize-Constants
{
    <#
    .SYNOPSIS
        Initializes constants, using config values where available
    #>
    
    # Get config values with safe fallbacks
    $api_timeout = 180
    $max_pages   = 100
    $api_delay   = 100
    $search_deb  = 300
    $select_poll = 250
    
    if ($script:CONFIG -and $script:CONFIG.Api)
    {
        if ($script:CONFIG.Api.FetchTimeoutSeconds) { $api_timeout = $script:CONFIG.Api.FetchTimeoutSeconds }
        if ($script:CONFIG.Api.MaxPaginationPages)  { $max_pages   = $script:CONFIG.Api.MaxPaginationPages }
        if ($script:CONFIG.Api.RequestDelayMs)      { $api_delay   = $script:CONFIG.Api.RequestDelayMs }
    }
    
    if ($script:CONFIG -and $script:CONFIG.UI)
    {
        if ($script:CONFIG.UI.SearchDebounceMs) { $search_deb  = $script:CONFIG.UI.SearchDebounceMs }
        if ($script:CONFIG.UI.SelectionPollMs)  { $select_poll = $script:CONFIG.UI.SelectionPollMs }
    }
    
    $script:CONSTANTS = @{
        # Timing (configurable)
        SEARCH_DEBOUNCE_MS       = $search_deb
        SELECTION_POLL_MS        = $select_poll
        API_REQUEST_DELAY_MS     = $api_delay
        
        # Fixed timing
        WEBVIEW_INIT_DELAY_MS    = 1500
        SESSION_CHECK_MINUTES    = 15
        POLL_INTERVAL_MS         = 100
        POLL_WAIT_MS             = 5
        DELETE_REQUEST_DELAY_MS  = 150
        EXPORT_REQUEST_DELAY_MS  = 100
        INDEX_REQUEST_DELAY_MS   = 30
        INDEX_BATCH_SIZE         = 8
        
        # Limits (configurable)
        MAX_PAGINATION_PAGES     = $max_pages
        FETCH_TIMEOUT_SECONDS    = $api_timeout
        
        # Fixed limits
        MAX_CONTENT_LENGTH       = 50000
        EXPORT_TIMEOUT_MINUTES   = 10
        INDEX_TIMEOUT_MINUTES    = 10
        API_CHECK_TIMEOUT_MS     = 10000
        
        # UI
        SNIPPET_CONTEXT_CHARS    = 50
        TITLE_SNIPPET_CHARS      = 30
        CONTENT_SNIPPET_CHARS    = 60
        
        # WebView2
        WEBVIEW2_SDK_VERSION     = "1.0.2592.51"
        WEBVIEW2_NUGET_URL       = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2"
    }
}

# Initialize with current config (or defaults if config not yet loaded)
Initialize-Constants
