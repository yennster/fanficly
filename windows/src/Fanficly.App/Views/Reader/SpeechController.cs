using System.Globalization;
using Fanficly.App.Platform;
using Fanficly.App.Shell;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Windows.Media;
using Windows.Media.Core;
using Windows.Media.Devices;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// On-device text-to-speech for the reader ("Listen"): Windows' built-in
/// <see cref="SpeechSynthesizer"/> (the stand-in for AVSpeechSynthesizer) renders
/// each paragraph to audio, and a <see cref="MediaPlaybackList"/> plays them back
/// to back, so narration is gapless. Nothing leaves the PC — no model download,
/// no network.
///
/// Paragraphs are index-aligned with the reader's rendered ones (scene breaks and
/// image slots are empty, unspoken entries), so <see cref="CurrentParagraph"/> drives
/// the karaoke highlight. Synthesis runs a few paragraphs ahead of playback. The
/// media transport controls (keyboard media keys, the volume flyout, Bluetooth
/// headsets) get play / pause / next / previous paragraph.
///
/// Settings are the Swift keys: <c>reader.ttsVoiceId</c> ("" = Automatic: a voice for
/// the work's language, else the system's default voice) and <c>reader.ttsRate</c>, stored on AVSpeechUtterance's scale where 0.5
/// is normal speed (1.0×).
/// </summary>
internal sealed class SpeechController : IDisposable
{
    public const string RateKey = "reader.ttsRate";
    public const string VoiceKey = "reader.ttsVoiceId";
    /// <summary>AVSpeechUtteranceDefaultSpeechRate: the stored rate for 1.0×.</summary>
    public const double DefaultRate = 0.5;
    /// <summary>The multipliers the reader offers: Windows speaks from half to
    /// double speed (AVSpeech's maximum is 2× too).</summary>
    public const double MinMultiplier = 0.5, MaxMultiplier = 2.0;
    private const int SynthesizeAhead = 4;

    private readonly DispatcherQueue _dispatcher;
    private MediaPlayer? _player;
    private SpeechSynthesizer? _synth;
    private MediaPlaybackList? _list;
    private readonly List<MediaPlaybackItem> _items = [];
    private readonly List<int> _itemParagraphs = [];
    private List<string> _paragraphs = [];
    private List<int> _spokenIndices = [];
    private List<int> _toSpeak = [];
    private int _fed;
    private int _generation;
    private int _feedingGeneration = -1;
    private readonly SemaphoreSlim _synthesisGate = new(1, 1);
    private bool _starved;
    private bool _disposed;
    private string _workTitle = "";
    private string _author = "";
    /// <summary>The work's language as AO3 names it ("Español"), for the voice.</summary>
    private string _language = "";
    private double _rateMultiplier;
    private bool _throttlingOptedOut;

    /// <summary>A chapter is loaded — the reader shows the narration bar.</summary>
    public bool IsActive { get; private set; }
    /// <summary>Audio is playing (vs. paused).</summary>
    public bool IsPlaying { get; private set; }
    /// <summary>The rendered paragraph being spoken (for the highlight).</summary>
    public int CurrentParagraph { get; private set; }
    /// <summary>How many paragraphs of the chapter are spoken.</summary>
    public int SpokenCount { get; private set; }
    /// <summary>1-based position of the current paragraph among the spoken ones ("¶ x / y").</summary>
    public int SpokenPosition { get; private set; }
    public string ChapterLabel { get; private set; } = "";
    /// <summary>The sleep timer that's set, if any (#182). Cleared once it pauses
    /// narration, and by <see cref="Stop"/>.</summary>
    public SleepTimer? CurrentSleepTimer { get; private set; }
    /// <summary>When a timed sleep timer runs out; null for "End of chapter", and
    /// once it has run out.</summary>
    public DateTimeOffset? SleepDeadline { get; private set; }
    /// <summary>The sleep timer ran out (or the chapter ended under "End of
    /// chapter"): narration pauses at the end of the paragraph being spoken.</summary>
    public bool SleepPausePending { get; private set; }
    /// <summary>The sleep timer paused narration and nothing has played since; the
    /// reader keeps the display free to sleep then too (#182).</summary>
    public bool PausedBySleepTimer { get; private set; }
    private DispatcherQueueTimer? _sleepTimer;

    /// <summary>Any state above changed (UI thread).</summary>
    public event Action? Changed;
    /// <summary>A chapter finished; the reader advances to the next one or stops (UI thread).</summary>
    public event Action? Finished;

    public SpeechController(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        _rateMultiplier = StoredMultiplier();
        KeyValueStores.Default.Changed += OnSettingChanged;
        MediaDevice.DefaultAudioRenderDeviceChanged += OnAudioDeviceChanged;
    }

    /// <summary>The speaking rate as a multiplier of normal speed; persisted.</summary>
    public double RateMultiplier
    {
        get => _rateMultiplier;
        set
        {
            var clamped = Math.Clamp(value, MinMultiplier, MaxMultiplier);
            var oldRaw = KeyValueStores.Default.GetDouble(RateKey, DefaultRate);
            _rateMultiplier = clamped;
            var newRaw = clamped * DefaultRate;
            if (Math.Abs(newRaw - oldRaw) > 0.001)
            {
                KeyValueStores.Default.SetDouble(RateKey, newRaw);
                ApplyRateChange();
            }
            Changed?.Invoke();
        }
    }

    private static double StoredMultiplier() =>
        Math.Clamp(KeyValueStores.Default.GetDouble(RateKey, DefaultRate) / DefaultRate, MinMultiplier, MaxMultiplier);

    private void OnSettingChanged(string key)
    {
        if (key != RateKey) return;
        _dispatcher.TryEnqueue(() =>
        {
            if (_disposed) return;
            var stored = StoredMultiplier();
            if (Math.Abs(stored - _rateMultiplier) > 0.001)
            {
                _rateMultiplier = stored;
                ApplyRateChange();
                Changed?.Invoke();
            }
        });
    }

    /// <summary>A new speed reaches paragraphs only when they're synthesized, so
    /// playing narration re-queues from the current paragraph. Paused narration
    /// drops its queue instead of playing again; <see cref="Resume"/> rebuilds it
    /// from the current paragraph at the new speed (Swift: <c>applyRateChange</c>).</summary>
    private void ApplyRateChange()
    {
        if (!IsActive) return;
        if (IsPlaying) Enqueue(CurrentParagraph);
        else { _generation++; StopPlayback(); }
    }

    /// <summary>The default output device changed: a Bluetooth or USB headset
    /// off or flat, separate-endpoint headphones unplugged, or a new device taking over. Pause rather
    /// than carry on through whatever plays next, as the Apple app does when its
    /// route's device goes away (Swift: <c>handleAudioRouteChange</c>); Windows
    /// doesn't say whether the old device went away, so any change pauses.</summary>
    private void OnAudioDeviceChanged(object? sender, DefaultAudioRenderDeviceChangedEventArgs args)
    {
        if (args.Role != AudioDeviceRole.Default) return;
        _dispatcher.TryEnqueue(() =>
        {
            if (_disposed || !IsActive) return;
            Pause();
        });
    }

    // MARK: - Control

    /// <summary>Loads a chapter's paragraphs and starts speaking from <paramref name="paragraph"/>.
    /// False when the chapter has nothing to speak (nothing is loaded then).</summary>
    public bool Play(IReadOnlyList<string> paragraphs, string workTitle, string author, string chapterLabel, int paragraph = 0, string language = "")
    {
        var spoken = Enumerable.Range(0, paragraphs.Count).Where(i => paragraphs[i].Trim().Length > 0).ToList();
        if (spoken.Count == 0) return false;
        _paragraphs = paragraphs.ToList();
        _spokenIndices = spoken;
        SpokenCount = spoken.Count;
        _workTitle = workTitle;
        _author = author;
        _language = language;
        ChapterLabel = chapterLabel;
        IsActive = true;
        // Narration keeps going with the window minimized; keep synthesis ahead of it.
        if (!_throttlingOptedOut) { PowerThrottling.SetOptedOut(true); _throttlingOptedOut = true; }
        EnsurePlayer();
        if (SleepPausePending)
        {
            // The sleep timer ran out at the end of the last chapter (or it was
            // "End of chapter"): the next chapter loads paused at its start.
            _generation++;
            StopPlayback();
            _toSpeak = [];
            CurrentParagraph = spoken.FirstOrDefault(i => i >= Math.Max(0, paragraph), spoken[0]);
            SpokenPosition = spoken.IndexOf(CurrentParagraph) + 1;
            PauseForSleepTimer();
            return true;
        }
        Enqueue(Math.Max(0, paragraph));
        return true;
    }

    public void TogglePlayPause()
    {
        if (!IsActive) return;
        if (IsPlaying) Pause(); else Resume();
    }

    public void Pause()
    {
        if (!IsPlaying || _player is null) return;
        _player.Pause();
        // Pausing yourself takes over from a sleep timer that already ran out.
        if (SleepPausePending) CancelPendingSleepPause();
        IsPlaying = false;
        UpdateTransportControls();
        Changed?.Invoke();
    }

    public void Resume()
    {
        if (!IsActive) return;
        PausedBySleepTimer = false;
        if (_player is not null && _list is not null && _items.Count > 0 && !_starved
            && _player.PlaybackSession.PlaybackState == MediaPlaybackState.Paused)
        {
            _player.Play();
            IsPlaying = true;
            UpdateTransportControls();
            Changed?.Invoke();
        }
        else
        {
            Enqueue(CurrentParagraph); // restart from where we stopped
        }
    }

    /// <summary>The next spoken paragraph, or the end of the chapter from the last.</summary>
    public void SkipForward()
    {
        if (!IsActive) return;
        var next = _spokenIndices.FirstOrDefault(i => i > CurrentParagraph, -1);
        if (next >= 0) Enqueue(next); else FinishChapter();
    }

    public void SkipBackward()
    {
        if (!IsActive) return;
        var previous = _spokenIndices.LastOrDefault(i => i < CurrentParagraph, -1);
        Enqueue(previous >= 0 ? previous : _spokenIndices.FirstOrDefault());
    }

    /// <summary>Tears everything down: the reader closed, or playback ended with no further chapter.</summary>
    public void Stop()
    {
        _generation++;
        StopPlayback();
        _paragraphs = [];
        _spokenIndices = [];
        _toSpeak = [];
        IsPlaying = false;
        IsActive = false;
        CurrentParagraph = 0;
        SpokenCount = 0;
        SpokenPosition = 0;
        ChapterLabel = "";
        ClearSleepTimer();
        PausedBySleepTimer = false;
        if (_throttlingOptedOut) { PowerThrottling.SetOptedOut(false); _throttlingOptedOut = false; }
        if (_player is not null)
        {
            var smtc = _player.SystemMediaTransportControls;
            smtc.PlaybackStatus = MediaPlaybackStatus.Closed;
            smtc.DisplayUpdater.ClearAll();
            smtc.DisplayUpdater.Update();
            smtc.IsEnabled = false;
        }
        Changed?.Invoke();
    }

    public void Dispose()
    {
        if (_disposed) return;
        Stop();
        _disposed = true;
        KeyValueStores.Default.Changed -= OnSettingChanged;
        MediaDevice.DefaultAudioRenderDeviceChanged -= OnAudioDeviceChanged;
        if (_player is not null)
        {
            _player.MediaEnded -= OnMediaEnded;
            _player.MediaFailed -= OnMediaFailed;
            _player.SystemMediaTransportControls.ButtonPressed -= OnTransportButton;
            _player.Dispose();
            _player = null;
        }
        _synth?.Dispose();
        _synth = null;
    }

    // MARK: - Internals

    private void EnsurePlayer()
    {
        if (_player is not null) return;
        _player = new MediaPlayer { AutoPlay = false, AudioCategory = MediaPlayerAudioCategory.Speech };
        _player.CommandManager.IsEnabled = false;
        _player.MediaEnded += OnMediaEnded;
        _player.MediaFailed += OnMediaFailed;
        var smtc = _player.SystemMediaTransportControls;
        smtc.IsPlayEnabled = true;
        smtc.IsPauseEnabled = true;
        smtc.IsNextEnabled = true;
        smtc.IsPreviousEnabled = true;
        smtc.ButtonPressed += OnTransportButton;
    }

    private void StopPlayback()
    {
        _starved = false;
        if (_player is not null)
        {
            try { _player.Pause(); } catch { }
            _player.Source = null;
        }
        if (_list is not null) _list.CurrentItemChanged -= OnCurrentItemChanged;
        _list = null;
        _items.Clear();
        _itemParagraphs.Clear();
    }

    /// <summary>Speaks every spoken paragraph at or after <paramref name="renderedIndex"/>.</summary>
    private void Enqueue(int renderedIndex)
    {
        var generation = ++_generation;
        StopPlayback();
        _toSpeak = _spokenIndices.Where(i => i >= renderedIndex).ToList();
        if (_toSpeak.Count == 0) { FinishChapter(); return; }
        CurrentParagraph = _toSpeak[0];
        SpokenPosition = _spokenIndices.IndexOf(CurrentParagraph) + 1;
        _fed = 0;
        EnsurePlayer();
        _list = new MediaPlaybackList { AutoRepeatEnabled = false, MaxPlayedItemsToKeepOpen = 1 };
        _list.CurrentItemChanged += OnCurrentItemChanged;
        _player!.Source = _list;
        PausedBySleepTimer = false;
        IsPlaying = true;
        UpdateTransportControls();
        Changed?.Invoke();
        _ = FeedAsync(generation);
    }

    /// <summary>Synthesizes paragraphs into the playback list, a few ahead of the
    /// one being spoken.</summary>
    private async Task FeedAsync(int generation)
    {
        if (_feedingGeneration == generation) return;
        _feedingGeneration = generation;
        try
        {
            while (generation == _generation && _list is { } list && _fed < _toSpeak.Count && !HoldsFeeding)
            {
                var playingAt = Math.Max(0, _itemParagraphs.IndexOf(CurrentParagraph));
                if (_items.Count - playingAt > SynthesizeAhead) break;
                var index = _toSpeak[_fed];
                var stream = await SynthesizeAsync(_paragraphs[index]);
                if (generation != _generation || !ReferenceEquals(list, _list) || HoldsFeeding)
                {
                    stream.Dispose();
                    return;
                }
                var item = new MediaPlaybackItem(MediaSource.CreateFromStream(stream, stream.ContentType));
                _items.Add(item);
                _itemParagraphs.Add(index);
                list.Items.Add(item);
                _fed++;
                if (_items.Count == 1 && IsPlaying) _player?.Play();
                else if (_starved && IsPlaying)
                {
                    _starved = false;
                    list.MoveTo((uint)(_items.Count - 1));
                    _player?.Play();
                }
            }
        }
        catch (Exception e)
        {
            AppHost.Log($"Listen failed: {e.Message}");
            if (generation == _generation)
            {
                Stop();
                MainWindow.Current?.ShowMessage("Listen isn't available",
                    "Windows couldn't speak this text. Check that a speech voice is installed in Settings → Time & language → Speech.",
                    Microsoft.UI.Xaml.Controls.InfoBarSeverity.Warning);
            }
        }
        finally
        {
            if (_feedingGeneration == generation) _feedingGeneration = -1;
        }
        // The current paragraph moved on while that synthesis ran.
        if (generation == _generation && _fed < _toSpeak.Count && !HoldsFeeding
            && _items.Count - Math.Max(0, _itemParagraphs.IndexOf(CurrentParagraph)) <= SynthesizeAhead)
            _ = FeedAsync(generation);
    }

    private async Task<SpeechSynthesisStream> SynthesizeAsync(string text)
    {
        await _synthesisGate.WaitAsync();
        try
        {
            _synth ??= new SpeechSynthesizer();
            var voiceId = KeyValueStores.Default.GetString(VoiceKey) ?? "";
            var voice = voiceId.Length > 0 ? SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Id == voiceId) : null;
            _synth.Voice = voice ?? AutomaticVoice(_language) ?? SpeechSynthesizer.DefaultVoice;
            _synth.Options.SpeakingRate = Math.Clamp(_rateMultiplier, MinMultiplier, MaxMultiplier);
            // A small breath between paragraphs (Swift: postUtteranceDelay 0.15 s).
            _synth.Options.AppendedSilence = SpeechAppendedSilence.Default;
            return await _synth.SynthesizeTextToStreamAsync(text);
        }
        finally
        {
            _synthesisGate.Release();
        }
    }

    /// <summary>An installed voice for the work's language (#184), or null, which is
    /// the system's default voice: when the work is in that voice's language, its
    /// language is unknown, or no voice speaks it. Used when no voice is picked in
    /// Settings, or the picked one isn't installed here (Swift: <c>automaticVoice</c>).</summary>
    private static VoiceInformation? AutomaticVoice(string language)
    {
        if (SpeechLanguage.Tag(language) is not { } tag) return null;
        var all = SpeechSynthesizer.AllVoices;
        var id = SpeechLanguage.VoiceId(tag, all.Select(v => new SpeechLanguage.Voice(v.Id, v.Language)),
            SpeechSynthesizer.DefaultVoice?.Language ?? CultureInfo.CurrentUICulture.Name);
        return id is null ? null : all.FirstOrDefault(v => v.Id == id);
    }

    private void FinishChapter()
    {
        // "End of chapter": the next chapter the reader loads stays paused.
        if (SleepTimer.PausesAtChapterEnd(CurrentSleepTimer)) SleepPausePending = true;
        _generation++;
        StopPlayback();
        IsPlaying = false;
        UpdateTransportControls();
        Changed?.Invoke();
        Finished?.Invoke(); // the reader decides whether to advance or stop
    }

    // MARK: - Sleep timer (#182)

    /// <summary>Sets the sleep timer, or turns it off with null. A timed one
    /// counts down from now, playing or paused; when it runs out, narration
    /// that's playing pauses at the end of the paragraph being spoken.</summary>
    public void SetSleepTimer(SleepTimer? timer)
    {
        CancelPendingSleepPause();
        CurrentSleepTimer = timer;
        if (timer?.Duration is { } duration)
        {
            SleepDeadline = DateTimeOffset.Now + duration;
            _sleepTimer = _dispatcher.CreateTimer();
            _sleepTimer.IsRepeating = false;
            _sleepTimer.Interval = duration;
            _sleepTimer.Tick += OnSleepTimerTick;
            _sleepTimer.Start();
        }
        Changed?.Invoke();
    }

    private void OnSleepTimerTick(DispatcherQueueTimer sender, object args)
    {
        if (_disposed || !ReferenceEquals(sender, _sleepTimer)) return;
        StopSleepCountdown();
        SleepDeadline = null;
        if (!IsActive || !SleepTimer.PausesWhenRunningOut(IsPlaying))
        {
            CurrentSleepTimer = null;
            Changed?.Invoke();
            return;
        }
        SleepPausePending = true;
        if (_starved)
        {
            // The paragraph already ended and the next is still being synthesized.
            PauseAfterCurrentParagraph();
            return;
        }
        // Drop what's queued after the paragraph being spoken, so the list ends
        // with it (OnMediaEnded then pauses); FeedAsync adds no more. The list's
        // own position, since CurrentParagraph follows it a dispatch later.
        var at = _itemParagraphs.IndexOf(CurrentParagraph);
        if (_list is { } playing && playing.CurrentItemIndex < (uint)_items.Count && (int)playing.CurrentItemIndex > at)
        {
            at = (int)playing.CurrentItemIndex;
            CurrentParagraph = _itemParagraphs[at];
            SpokenPosition = _spokenIndices.IndexOf(CurrentParagraph) + 1;
        }
        if (_list is { } list && at >= 0)
        {
            for (var k = _items.Count - 1; k > at; k--)
            {
                if (k < list.Items.Count) list.Items.RemoveAt(k);
                _items.RemoveAt(k);
                _itemParagraphs.RemoveAt(k);
            }
            _fed = at + 1;
        }
        Changed?.Invoke();
    }

    /// <summary>A sleep pause is pending: feed nothing past the current paragraph.</summary>
    private bool HoldsFeeding => SleepPausePending && _fed > _toSpeak.IndexOf(CurrentParagraph);

    /// <summary>The paragraph being spoken finished with a sleep pause pending:
    /// the chapter's last one finishes the chapter (the next loads paused);
    /// any other leaves narration paused at the next paragraph, nothing queued,
    /// so <see cref="Resume"/> starts it afresh.</summary>
    private void PauseAfterCurrentParagraph()
    {
        var next = _spokenIndices.FirstOrDefault(i => i > CurrentParagraph, -1);
        if (SleepTimer.ParagraphEnd(isLast: next < 0, sleepPausePending: true) == SleepParagraphEnd.FinishChapter)
        {
            FinishChapter();
            return;
        }
        _generation++;
        StopPlayback();
        CurrentParagraph = next;
        SpokenPosition = _spokenIndices.IndexOf(next) + 1;
        PauseForSleepTimer();
    }

    private void PauseForSleepTimer()
    {
        ClearSleepTimer();
        PausedBySleepTimer = true;
        IsPlaying = false;
        UpdateTransportControls();
        Changed?.Invoke();
    }

    /// <summary>Clears the timer; a pause it left pending had stopped feeding past
    /// the current paragraph, so feeding picks up again (no gap at its end).</summary>
    private void CancelPendingSleepPause()
    {
        var wasPending = SleepPausePending;
        ClearSleepTimer();
        if (wasPending && IsActive && _list is not null) _ = FeedAsync(_generation);
    }

    private void ClearSleepTimer()
    {
        StopSleepCountdown();
        CurrentSleepTimer = null;
        SleepDeadline = null;
        SleepPausePending = false;
    }

    private void StopSleepCountdown()
    {
        if (_sleepTimer is null) return;
        _sleepTimer.Stop();
        _sleepTimer.Tick -= OnSleepTimerTick;
        _sleepTimer = null;
    }

    // MARK: - Player events (background threads → UI thread)

    private void OnCurrentItemChanged(MediaPlaybackList sender, CurrentMediaPlaybackItemChangedEventArgs args)
    {
        var item = args.NewItem;
        _dispatcher.TryEnqueue(() =>
        {
            if (_disposed || !ReferenceEquals(sender, _list) || item is null) return;
            var position = _items.IndexOf(item);
            if (position < 0) return;
            CurrentParagraph = _itemParagraphs[position];
            SpokenPosition = _spokenIndices.IndexOf(CurrentParagraph) + 1;
            UpdateTransportControls();
            Changed?.Invoke();
            _ = FeedAsync(_generation);
        });
    }

    private void OnMediaEnded(MediaPlayer sender, object args)
    {
        var list = _list;
        _dispatcher.TryEnqueue(() =>
        {
            if (_disposed || !ReferenceEquals(list, _list) || list is null) return;
            // Only the chapter's last paragraph ending finishes it; running ahead
            // of synthesis waits for the next paragraph instead, unless the
            // sleep timer ran out (feeding stopped after the current paragraph).
            if (SleepPausePending) PauseAfterCurrentParagraph();
            else if (_fed < _toSpeak.Count) { _starved = true; _ = FeedAsync(_generation); }
            else FinishChapter();
        });
    }

    private void OnMediaFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
    {
        var message = args.ErrorMessage;
        _dispatcher.TryEnqueue(() =>
        {
            if (_disposed || !IsActive) return;
            AppHost.Log($"Listen playback failed: {message}");
            Stop();
        });
    }

    private void OnTransportButton(SystemMediaTransportControls sender, SystemMediaTransportControlsButtonPressedEventArgs args)
    {
        var button = args.Button;
        _dispatcher.TryEnqueue(() =>
        {
            if (_disposed) return;
            switch (button)
            {
                case SystemMediaTransportControlsButton.Play: Resume(); break;
                case SystemMediaTransportControlsButton.Pause: Pause(); break;
                case SystemMediaTransportControlsButton.Next: SkipForward(); break;
                case SystemMediaTransportControlsButton.Previous: SkipBackward(); break;
            }
        });
    }

    /// <summary>The system media overlay: chapter, author, work, playing or paused.</summary>
    private void UpdateTransportControls()
    {
        if (_player is null) return;
        var smtc = _player.SystemMediaTransportControls;
        smtc.IsEnabled = IsActive;
        if (!IsActive) return;
        smtc.PlaybackStatus = IsPlaying ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
        var display = smtc.DisplayUpdater;
        display.Type = MediaPlaybackType.Music;
        display.MusicProperties.Title = ChapterLabel.Length == 0 ? _workTitle : ChapterLabel;
        display.MusicProperties.Artist = _author;
        display.MusicProperties.AlbumTitle = _workTitle;
        display.MusicProperties.TrackNumber = (uint)Math.Max(0, SpokenPosition);
        display.MusicProperties.AlbumTrackCount = (uint)Math.Max(0, SpokenCount);
        display.Update();
    }
}
