using System.Diagnostics;
using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class ThrottleTests
{
    [Fact]
    public async Task FirstCallDoesNotWait()
    {
        var throttle = new Throttle(TimeSpan.FromSeconds(1));
        var sw = Stopwatch.StartNew();
        await throttle.WaitAsync();
        Assert.True(sw.Elapsed < TimeSpan.FromSeconds(0.2), "first call should be immediate");
    }

    [Fact]
    public async Task SecondCallWaitsTheInterval()
    {
        var throttle = new Throttle(TimeSpan.FromSeconds(0.4));
        await throttle.WaitAsync();
        var sw = Stopwatch.StartNew();
        await throttle.WaitAsync();
        Assert.True(sw.Elapsed > TimeSpan.FromSeconds(0.25), "second call should be throttled");
    }

    /// <summary>Concurrent callers must each get a distinct, strictly-spaced slot —
    /// they must NOT all sleep to the same instant and fire together. Setting the
    /// next slot only after sleeping let a burst leak through at once; this guards
    /// against that regression (which overran AO3's rate limit and led to
    /// stalls/timeouts).</summary>
    [Fact]
    public async Task ConcurrentCallsAreSerializedNotBursted()
    {
        var interval = TimeSpan.FromSeconds(0.2);
        var throttle = new Throttle(interval);
        const int count = 5;

        var sw = Stopwatch.StartNew();
        await Task.WhenAll(Enumerable.Range(0, count).Select(_ => Task.Run(() => throttle.WaitAsync())));
        var elapsed = sw.Elapsed;

        // N calls spaced by `interval` take at least (N-1)*interval overall. If
        // they had bursted, this would be ~0.
        var expectedMinimum = (count - 1) * interval;
        Assert.True(elapsed > expectedMinimum * 0.8, "concurrent calls should be spaced, not fired in a burst");
    }
}
