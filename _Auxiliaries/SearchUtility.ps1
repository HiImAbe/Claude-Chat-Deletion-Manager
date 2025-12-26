#requires -Version 7.0
<#
.SYNOPSIS
    Search parsing and matching utilities
.DESCRIPTION
    Auxiliaries: Domain-agnostic search helper functions
#>

function Get-SearchMode
{
    <#
    .SYNOPSIS
        Parses search text to determine search mode and extract pattern
    .OUTPUTS
        Hashtable with Mode, Pattern, Terms (for OR), Ids (for ID search), Exclusions
    #>
    param([string]$SearchText)
    
    $search_text = $SearchText.Trim()
    
    if (-not $search_text)
    {
        return @{ Mode = 'None'; Exclusions = @() }
    }
    
    # Extract exclusions first: not:word or not:word1,word2,word3
    $exclusions = @()
    $remaining_text = $search_text
    
    $not_matches = [regex]::Matches($search_text, 'not:([^\s]+)')
    foreach ($match in $not_matches)
    {
        $exclude_part = $match.Groups[1].Value
        $exclude_terms = @($exclude_part -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
        $exclusions += $exclude_terms
        $remaining_text = $remaining_text.Replace($match.Value, '')
    }
    
    $remaining_text = $remaining_text.Trim()
    
    if (-not $remaining_text)
    {
        return @{
            Mode       = 'All'
            Exclusions = $exclusions
        }
    }
    
    # ID search: id:value or ids:val1,val2,val3
    if ($remaining_text -match '^ids?:(.+)$')
    {
        $id_part = $Matches[1].Trim()
        $ids = @($id_part -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim() })
        return @{
            Mode       = 'Id'
            Ids        = $ids
            Exclusions = $exclusions
        }
    }
    
    # Regex search: /pattern/
    if ($remaining_text -match '^/(.+)/$')
    {
        $pattern = $Matches[1]
        try
        {
            [void][regex]::new($pattern, 'IgnoreCase')
            return @{
                Mode       = 'Regex'
                Pattern    = $pattern
                Exclusions = $exclusions
            }
        }
        catch
        {
            return @{
                Mode       = 'Contains'
                Pattern    = $remaining_text.ToLowerInvariant()
                Exclusions = $exclusions
            }
        }
    }
    
    # OR search: term1|term2|term3
    if ($remaining_text.Contains('|'))
    {
        $terms = @($remaining_text -split '\|' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
        if ($terms.Count -gt 1)
        {
            return @{
                Mode       = 'Or'
                Terms      = $terms
                Exclusions = $exclusions
            }
        }
    }
    
    # Default: substring contains
    return @{
        Mode       = 'Contains'
        Pattern    = $remaining_text.ToLowerInvariant()
        Exclusions = $exclusions
    }
}

function Test-SearchMatch
{
    <#
    .SYNOPSIS
        Tests if text matches the search criteria (including exclusions)
    .OUTPUTS
        Boolean indicating match
    #>
    param(
        [string]$Text,
        [string]$TextLower,
        [hashtable]$SearchMode
    )
    
    # Check exclusions first
    if ($SearchMode.Exclusions -and $SearchMode.Exclusions.Count -gt 0)
    {
        foreach ($exclusion in $SearchMode.Exclusions)
        {
            if ($TextLower.Contains($exclusion))
            {
                return $false
            }
        }
    }
    
    switch ($SearchMode.Mode)
    {
        'None' { return $true }
        'All'  { return $true }
        
        'Contains' {
            return $TextLower.Contains($SearchMode.Pattern)
        }
        
        'Or' {
            foreach ($term in $SearchMode.Terms)
            {
                if ($TextLower.Contains($term)) { return $true }
            }
            return $false
        }
        
        'Regex' {
            try
            {
                return [regex]::IsMatch($Text, $SearchMode.Pattern, 'IgnoreCase')
            }
            catch
            {
                return $false
            }
        }
        
        'Id' {
            return $false
        }
        
        default { return $false }
    }
}

function Get-MatchSnippet
{
    <#
    .SYNOPSIS
        Extracts a snippet around a search match
    #>
    param(
        [string]$Text,
        [string]$SearchTerm,
        [int]$ContextChars = 50
    )
    
    if (-not $Text -or -not $SearchTerm)
    {
        return ""
    }
    
    $index = $Text.IndexOf($SearchTerm, [StringComparison]::OrdinalIgnoreCase)
    
    if ($index -lt 0)
    {
        return ""
    }
    
    $start = [Math]::Max(0, $index - $ContextChars)
    $end   = [Math]::Min($Text.Length, $index + $SearchTerm.Length + $ContextChars)
    
    $snippet = $Text.Substring($start, $end - $start)
    
    $prefix = if ($start -gt 0) { "..." } else { "" }
    $suffix = if ($end -lt $Text.Length) { "..." } else { "" }
    
    return "$prefix$snippet$suffix"
}

function Get-SearchMatchSnippet
{
    <#
    .SYNOPSIS
        Gets a snippet showing the match for complex search modes
    #>
    param(
        [string]$Text,
        [hashtable]$SearchMode,
        [int]$ContextChars = 50
    )
    
    if (-not $Text) { return "" }
    
    switch ($SearchMode.Mode)
    {
        'Contains' {
            return Get-MatchSnippet -Text $Text -SearchTerm $SearchMode.Pattern -ContextChars $ContextChars
        }
        
        'Or' {
            $text_lower = $Text.ToLowerInvariant()
            foreach ($term in $SearchMode.Terms)
            {
                $index = $text_lower.IndexOf($term)
                if ($index -ge 0)
                {
                    return Get-MatchSnippet -Text $Text -SearchTerm $term -ContextChars $ContextChars
                }
            }
            return ""
        }
        
        'Regex' {
            try
            {
                $match = [regex]::Match($Text, $SearchMode.Pattern, 'IgnoreCase')
                if ($match.Success)
                {
                    return Get-MatchSnippet -Text $Text -SearchTerm $match.Value -ContextChars $ContextChars
                }
            }
            catch { }
            return ""
        }
        
        default { return "" }
    }
}
