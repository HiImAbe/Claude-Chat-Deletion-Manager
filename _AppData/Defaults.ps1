#requires -Version 7.0
<#
.SYNOPSIS
    Default configuration values
.DESCRIPTION
    Fallback values when config.json doesn't exist or is missing keys.
    These are the "factory defaults" that ship with the application.
#>

$script:CONFIG_DEFAULTS = @{
    # API Settings
    Api = @{
        FetchTimeoutSeconds     = 180
        MaxPaginationPages      = 100
        RequestDelayMs          = 100
    }
    
    # UI Settings
    UI = @{
        SearchDebounceMs        = 300
        SelectionPollMs         = 250
        SidebarWidth            = 180
        RememberWindowState     = $true
        RememberSidebarState    = $true
        Theme                   = "dark"
    }
    
    # Cache Settings
    Cache = @{
        Enabled                 = $true
        MetadataCacheEnabled    = $true
        IndexCacheEnabled       = $true
        MaxCacheAgeDays         = 7
        MaxIndexedChats         = 500
    }
    
    # Export Settings
    Export = @{
        DefaultFormat           = "json"
        IncludeTimestamps       = $true
        PrettyPrint             = $true
    }
}
