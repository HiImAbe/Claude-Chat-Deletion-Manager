#requires -Version 7.0
<#
.SYNOPSIS
    ChatItem class with INotifyPropertyChanged
.DESCRIPTION
    Layer 1 - Structures: Defines the ChatItem data shape for WPF binding
#>

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;

public class ChatItem : INotifyPropertyChanged
{
    private string _id;
    private string _name;
    private string _nameLower;
    private DateTime _updated;
    private bool _selected;
    private string _content;
    private string _contentLower;
    private bool _contentIndexed;
    private string _matchType;
    private string _matchPreview;

    public event PropertyChangedEventHandler PropertyChanged;

    protected virtual void OnPropertyChanged(string propertyName)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    public string Id
    {
        get { return _id ?? ""; }
        set { _id = value; OnPropertyChanged("Id"); }
    }

    public string Name
    {
        get { return _name ?? ""; }
        set 
        { 
            _name = value; 
            _nameLower = value?.ToLowerInvariant() ?? "";
            OnPropertyChanged("Name"); 
            OnPropertyChanged("NameLower");
        }
    }

    public string NameLower
    {
        get { return _nameLower ?? ""; }
    }

    public DateTime Updated
    {
        get { return _updated; }
        set { _updated = value; OnPropertyChanged("Updated"); }
    }

    public bool Selected
    {
        get { return _selected; }
        set 
        { 
            if (_selected != value)
            {
                _selected = value; 
                OnPropertyChanged("Selected"); 
            }
        }
    }

    public string Content
    {
        get { return _content ?? ""; }
        set 
        { 
            _content = value; 
            _contentLower = value?.ToLowerInvariant() ?? "";
            OnPropertyChanged("Content"); 
            OnPropertyChanged("ContentLower");
        }
    }

    public string ContentLower
    {
        get { return _contentLower ?? ""; }
    }

    public bool ContentIndexed
    {
        get { return _contentIndexed; }
        set { _contentIndexed = value; OnPropertyChanged("ContentIndexed"); }
    }

    public string MatchType
    {
        get { return _matchType ?? ""; }
        set { _matchType = value; OnPropertyChanged("MatchType"); }
    }

    public string MatchPreview
    {
        get { return _matchPreview ?? ""; }
        set { _matchPreview = value; OnPropertyChanged("MatchPreview"); }
    }
}
'@ -ReferencedAssemblies 'System.ComponentModel.Primitives', 'System.ObjectModel'
