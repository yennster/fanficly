using Fanficly.Core;
using Microsoft.UI.Dispatching;

namespace Fanficly.App.Views.Browse;

/// <summary>
/// SwiftData's <c>@Query</c> refresh for these screens: runs <c>onChange</c> on
/// the UI thread whenever a library save touches one of <c>kinds</c>. The
/// store raises <see cref="LibraryStore.Changed"/> on the saving thread, so the
/// callback is marshalled through the creating thread's dispatcher queue.
/// </summary>
internal sealed class LibraryChanges : IDisposable
{
    private readonly LibraryStore _store;
    private readonly LibraryEntityKinds _kinds;
    private readonly Action _onChange;
    private readonly DispatcherQueue _queue;
    private readonly Lock _gate = new();
    private bool _queued;

    public LibraryChanges(LibraryStore store, LibraryEntityKinds kinds, Action onChange)
    {
        _store = store;
        _kinds = kinds;
        _onChange = onChange;
        _queue = DispatcherQueue.GetForCurrentThread();
        _store.Changed += OnChanged;
    }

    private void OnChanged(LibraryEntityKinds changed)
    {
        if ((changed & _kinds) == 0) return;
        if (_queue.HasThreadAccess) { _onChange(); return; }
        lock (_gate)
        {
            if (_queued) return; // coalesce a burst of saves into one refresh
            _queued = true;
        }
        _queue.TryEnqueue(() =>
        {
            lock (_gate) _queued = false;
            _onChange();
        });
    }

    public void Dispose() => _store.Changed -= OnChanged;
}
