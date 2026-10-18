using System.Globalization;
using Fanficly.App.Shell;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Media.SpeechSynthesis;

namespace Fanficly.App.Views.Settings;

/// <summary>
/// The Listen settings: the voice list and a short spoken sample at the chosen
/// voice and rate. Windows' on-device speech (Windows.Media.SpeechSynthesis)
/// stands in for AVSpeechSynthesizer; nothing leaves the PC.
///
/// Keys and units are the Swift app's so they sync: <c>reader.ttsVoiceId</c>
/// ("" = the system default voice) and <c>reader.ttsRate</c>, stored on
/// AVSpeechUtterance's 0…1 scale where 0.5 is normal speed (shown as 1.0×).
/// </summary>
internal static class SpeechSample
{
    public const string RateKey = "reader.ttsRate";
    public const string VoiceKey = "reader.ttsVoiceId";

    /// <summary>AVSpeechUtteranceDefaultSpeechRate: the stored value for 1.0×.</summary>
    public const double DefaultRate = 0.5;

    /// <summary>The slider's range on the stored scale: 0.5× to 2.0×. Windows
    /// can't speak slower than half speed, so the Apple scale's lower end
    /// (down to 0×) isn't offered; AVSpeech's maximum (1.0) is 2×.</summary>
    public static readonly (double Min, double Max) RateRange = (0.25, 1.0);

    public const string SampleText = "Bella poured the latte. It was hot. Edward looked up from the corner table and met her eyes.";

    private static MediaPlayer? _player;
    private static SpeechSynthesizer? _synth;
    private static Action? _onEnded;

    public static bool IsPlaying => _player is not null;

    /// <summary>On-device voices for the current language (all installed voices
    /// when the language has none), sorted by name. Empty when speech isn't available.</summary>
    public static IReadOnlyList<VoiceInformation> Voices()
    {
        try
        {
            var all = SpeechSynthesizer.AllVoices.ToList();
            var lang = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
            var matching = all.Where(v => v.Language.StartsWith(lang, StringComparison.OrdinalIgnoreCase)).ToList();
            return (matching.Count == 0 ? all : matching)
                .OrderBy(v => v.DisplayName, StringComparer.CurrentCultureIgnoreCase)
                .ToList();
        }
        catch (Exception e)
        {
            AppHost.Log($"Speech voices unavailable: {e.Message}");
            return [];
        }
    }

    /// <summary>The multiplier shown for a stored rate (1.0× at the default).</summary>
    public static double Multiplier(double storedRate) => storedRate / DefaultRate;

    /// <summary>Speaks the sample; <paramref name="onEnded"/> runs on the UI thread when it finishes or stops.</summary>
    public static async Task PlayAsync(string voiceId, double storedRate, Action onEnded)
    {
        Stop();
        _onEnded = onEnded;
        try
        {
            _synth = new SpeechSynthesizer();
            if (!string.IsNullOrEmpty(voiceId)
                && SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Id == voiceId) is { } voice)
                _synth.Voice = voice;
            _synth.Options.SpeakingRate = Math.Clamp(Multiplier(storedRate), 0.5, 6.0);
            var stream = await _synth.SynthesizeTextToStreamAsync(SampleText);
            if (_onEnded != onEnded) return; // stopped while synthesizing
            var player = new MediaPlayer { AutoPlay = false };
            player.MediaEnded += (_, _) => MainWindow.Current?.DispatcherQueue.TryEnqueue(Stop);
            player.MediaFailed += (_, _) => MainWindow.Current?.DispatcherQueue.TryEnqueue(Stop);
            player.Source = MediaSource.CreateFromStream(stream, stream.ContentType);
            _player = player;
            player.Play();
        }
        catch (Exception e)
        {
            AppHost.Log($"Speech sample failed: {e.Message}");
            Stop();
        }
    }

    public static void Stop()
    {
        var player = _player;
        _player = null;
        if (player is not null)
        {
            try { player.Pause(); } catch { }
            player.Dispose();
        }
        _synth?.Dispose();
        _synth = null;
        var ended = _onEnded;
        _onEnded = null;
        ended?.Invoke();
    }
}
