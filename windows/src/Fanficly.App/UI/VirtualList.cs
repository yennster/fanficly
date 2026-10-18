using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.UI;

/// <summary>
/// A virtualized, vertically scrolling list (SwiftUI's List / LazyVStack):
/// only rows near the viewport are built. Optional header and footer scroll
/// with it, and <see cref="LoadMore"/> fires as the end comes into view
/// (infinite scroll for AO3 result pages).
/// </summary>
/// <remarks>Rows are addressed by index (the repeater sees boxed ints), so any
/// C# type can be listed without WinRT marshalling.</remarks>
public sealed class VirtualList<T>
{
    private readonly ObservableCollection<object> _indices = [];
    private readonly ItemsRepeater _repeater;
    private readonly StackPanel _stack;
    private bool _loadingMore;

    public List<T> Items { get; } = [];

    /// <summary>The scrolling element to put on screen.</summary>
    public ScrollViewer Element { get; }

    /// <summary>Called when the user nears the end; return when the next page is appended.</summary>
    public Func<Task>? LoadMore { get; set; }

    /// <summary>False once there's nothing more to load.</summary>
    public bool HasMore { get; set; } = true;

    public VirtualList(Func<T, int, UIElement> buildRow, double spacing = 0, Thickness? padding = null, double maxWidth = double.PositiveInfinity)
    {
        _repeater = new ItemsRepeater
        {
            ItemsSource = _indices,
            Layout = new StackLayout { Orientation = Orientation.Vertical, Spacing = spacing },
            ItemTemplate = new DelegateElementFactory(data => data is int i && i < Items.Count ? buildRow(Items[i], i) : new Grid()),
        };
        _stack = new StackPanel { Margin = padding ?? new Thickness(16, 4, 16, 24), MaxWidth = maxWidth };
        _stack.Children.Add(_repeater);
        Element = new ScrollViewer
        {
            Content = _stack,
            HorizontalScrollMode = ScrollMode.Disabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        Element.ViewChanged += (_, _) => _ = CheckLoadMoreAsync();
        Element.SizeChanged += (_, _) => _ = CheckLoadMoreAsync();
    }

    /// <summary>Content above the rows (scrolls with them).</summary>
    public UIElement? Header
    {
        set
        {
            if (_stack.Children.Count > 0 && _stack.Children[0] != _repeater) _stack.Children.RemoveAt(0);
            if (value is not null) _stack.Children.Insert(0, value);
        }
    }

    /// <summary>Content below the rows (a loading spinner, an end note).</summary>
    public UIElement? Footer
    {
        set
        {
            var index = _stack.Children.IndexOf(_repeater);
            while (_stack.Children.Count > index + 1) _stack.Children.RemoveAt(index + 1);
            if (value is not null) _stack.Children.Add(value);
        }
    }

    public void Reset(IEnumerable<T> items)
    {
        Items.Clear();
        _indices.Clear();
        Append(items);
        Element.ChangeView(null, 0, null, disableAnimation: true);
    }

    public void Append(IEnumerable<T> items)
    {
        foreach (var item in items)
        {
            Items.Add(item);
            _indices.Add(Items.Count - 1);
        }
    }

    public void RemoveAt(int index)
    {
        Items.RemoveAt(index);
        // Indices shift; rebuild the index list.
        _indices.Clear();
        for (var i = 0; i < Items.Count; i++) _indices.Add(i);
    }

    /// <summary>Rebuilds every realized row (e.g. after a sort or a state change).</summary>
    public void Refresh()
    {
        var copy = Items.ToList();
        Items.Clear();
        _indices.Clear();
        Append(copy);
    }

    private async Task CheckLoadMoreAsync()
    {
        if (_loadingMore || !HasMore || LoadMore is null || Items.Count == 0) return;
        if (Element.ScrollableHeight - Element.VerticalOffset > 800) return;
        _loadingMore = true;
        try { await LoadMore(); }
        finally { _loadingMore = false; }
    }
}

/// <summary>An ItemsRepeater template built in code.</summary>
public sealed partial class DelegateElementFactory(Func<object?, UIElement> build) : IElementFactory
{
    public UIElement GetElement(ElementFactoryGetArgs args) => build(args.Data);

    public void RecycleElement(ElementFactoryRecycleArgs args) { }
}
