namespace Fanficly.App.Shell;

/// <summary>How the stack changed: a new tab root, a push, or a step back.</summary>
public enum NavigationChange { Root, Push, Back }

/// <summary>
/// The detail column's navigation stack (SwiftUI's NavigationPath). The root
/// is the selected sidebar tab; screens push on top of it.
/// </summary>
public sealed class Navigator
{
    private readonly List<Screen> _stack = [];

    /// <summary>Raised after every change, with how the stack moved.</summary>
    public event Action<NavigationChange>? Changed;

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
        Changed?.Invoke(NavigationChange.Root);
    }

    public void Push(Screen screen)
    {
        Current?.RememberFocus();
        Current?.OnDisappearing();
        screen.Navigator = this;
        _stack.Add(screen);
        screen.OnAppearing();
        Changed?.Invoke(NavigationChange.Push);
    }

    /// <summary>Replaces everything above the root with <paramref name="screen"/>
    /// (a notification or widget route opening on top of the current tab).</summary>
    public void ReplacePath(Screen screen)
    {
        if (Current == Root) Current?.RememberFocus();
        Current?.OnDisappearing();
        for (var i = _stack.Count - 1; i >= 1; i--) { _stack[i].OnRemoved(); _stack.RemoveAt(i); }
        screen.Navigator = this;
        _stack.Add(screen);
        screen.OnAppearing();
        Changed?.Invoke(NavigationChange.Push);
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
        Changed?.Invoke(NavigationChange.Back);
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
        Changed?.Invoke(NavigationChange.Back);
    }

    public void PopToRoot()
    {
        if (!CanGoBack) return;
        Current?.OnDisappearing();
        for (var i = _stack.Count - 1; i >= 1; i--) { _stack[i].OnRemoved(); _stack.RemoveAt(i); }
        Current?.OnAppearing();
        Changed?.Invoke(NavigationChange.Back);
    }
}
