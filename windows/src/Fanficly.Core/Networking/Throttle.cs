namespace Fanficly.Core;

/// <summary>Spaces requests at least <see cref="MinimumInterval"/> apart (the AO3
/// client uses 1 request/second). Swift's <c>ThrottleActor</c>.</summary>
public sealed class Throttle(TimeSpan minimumInterval, TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private readonly Lock _gate = new();
    private DateTimeOffset _nextEarliest = DateTimeOffset.MinValue;

    public TimeSpan MinimumInterval { get; } = minimumInterval;

    /// <summary>Waits for this caller's slot. The slot is reserved atomically
    /// *before* waiting: concurrent callers each grab a distinct, strictly-spaced
    /// instant instead of all reading the same value, sleeping to the same time,
    /// and firing together. Setting the next slot only after the sleep let a burst
    /// of concurrent requests leak through at once — overrunning AO3's rate limit,
    /// which makes AO3 stall/tarpit the client until requests time out.</summary>
    public Task WaitAsync(CancellationToken ct = default)
    {
        TimeSpan delay;
        lock (_gate)
        {
            var now = _time.GetUtcNow();
            var scheduled = now > _nextEarliest ? now : _nextEarliest;
            _nextEarliest = scheduled + MinimumInterval;
            delay = scheduled - now;
        }
        return delay > TimeSpan.Zero ? Task.Delay(delay, _time, ct) : Task.CompletedTask;
    }
}
