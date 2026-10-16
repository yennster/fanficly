namespace Fanficly.App.Shell;

/// <summary>
/// The detail column's navigation stack (SwiftUI's NavigationPath). The root
/// is the selected sidebar tab; screens push on top of it.
/// </summary>
public sealed class Navigator
{
    private readonly List<Screen> _stack = [];

    /// <summary>Raised after every change, with whether it moved forward (a push).</summary>
    public event Action<bool>? Changed;

    public Screen? Current => _stack.Count > 0 ? _stack[^1] : null;
    public Screen? Root => _stack.Count > 0 ? _stack[0] : null;
    public int Depth => _stack.Count;
    public bool CanGoBack => _stack.Count > 1;
    public IReadOnlyList<Screen> Stack => _stack;

    /// <summary>Shows a tab: the root becomes <paramref name="root"/> and anything
    /// pushed is dropped (selecting a sidebar item clears the detail path).</summary>
    public void SetRoot(Screen root)
    {
        Current?.OnDisappearing();
        for (var i = _stack.Count - 1; i >= 1; i--) _stack[i].OnRemoved();
        _stack.Clear();
        root.Navigator = this;
        _stack.Add(root);
        root.OnAppearing();
        Changed?.Invoke(false);
    }

    public void Push(Screen screen)
    {
        Current?.OnDisappearing();
        screen.Navigator = this;
        _stack.Add(screen);
        screen.OnAppearing();
        Changed?.Invoke(true);
    }

    /// <summary>Replaces everything above the root with <paramref name="screen"/>
    /// (a notification or widget route opening on top of the current tab).</summary>
    public void ReplacePath(Screen screen)
    {
        Current?.OnDisappearing();
        for (var i = _stack.Count - 1; i >= 1; i--) { _stack[i].OnRemoved(); _stack.RemoveAt(i); }
        screen.Navigator = this;
        _stack.Add(screen);
        screen.OnAppearing();
        Changed?.Invoke(true);
    }

    public bool GoBack()
    {
        if (!CanGoBack) return false;
        if (Current!.HandleBack()) return true;
        var top = _stack[^1];
        top.OnDisappearing();
        _stack.RemoveAt(_stack.Count - 1);
        top.OnRemoved();
        Current?.OnAppearing();
        Changed?.Invoke(false);
        return true;
    }

    /// <summary>Pops <paramref name="screen"/> (and anything above it), if it's on the stack.</summary>
    public void Remove(Screen screen)
    {
        var index = _stack.IndexOf(screen);
        if (index <= 0) return;
        Current?.OnDisappearing();
        for (var i = _stack.Count - 1; i >= index; i--) { _stack[i].OnRemoved(); _stack.RemoveAt(i); }
        Current?.OnAppearing();
        Changed?.Invoke(false);
    }

    public void PopToRoot()
    {
        if (!CanGoBack) return;
        Current?.OnDisappearing();
        for (var i = _stack.Count - 1; i >= 1; i--) { _stack[i].OnRemoved(); _stack.RemoveAt(i); }
        Current?.OnAppearing();
        Changed?.Invoke(false);
    }
}
