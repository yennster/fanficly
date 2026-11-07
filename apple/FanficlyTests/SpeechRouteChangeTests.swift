import AVFoundation
import XCTest
@testable import Fanficly

/// Listen pauses when the headphones it was playing through go away (#162),
/// and only then; a speed change never starts paused narration.
final class SpeechRouteChangeTests: XCTestCase {
    func test_losingTheOutputDevicePauses() {
        XCTAssertTrue(SpeechController.pausesNarration(for: .oldDeviceUnavailable))
    }

    func test_otherRouteChangesKeepPlaying() {
        let others: [AVAudioSession.RouteChangeReason] = [
            .unknown, .newDeviceAvailable, .categoryChange, .override,
            .wakeFromSleep, .noSuitableRouteForCategory, .routeConfigurationChange,
        ]
        for reason in others {
            XCTAssertFalse(SpeechController.pausesNarration(for: reason), "\(reason.rawValue)")
        }
    }

    func test_speedChangeWhilePausedDropsTheQueueWithoutSpeaking() {
        XCTAssertEqual(SpeechController.rateChange(isActive: true, isPlaying: false), .dropQueue)
    }

    func test_speedChangeWhilePlayingRequeues() {
        XCTAssertEqual(SpeechController.rateChange(isActive: true, isPlaying: true), .requeue)
    }

    func test_speedChangeWithNothingLoadedDoesNothing() {
        XCTAssertEqual(SpeechController.rateChange(isActive: false, isPlaying: false), .ignore)
    }
}

/// Listen reads a work with a voice for its language when no voice is picked
/// (#184). The Windows app's `SpeechLanguageTests` checks the same cases.
final class SpeechLanguageTests: XCTestCase {
    private typealias Voice = SpeechLanguage.Voice

    func test_ao3LanguageNamesMapToTags() {
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "English"), "en")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "Español"), "es")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: " Français "), "fr")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "Русский"), "ru")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "日本語"), "ja")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "Português brasileiro"), "pt-BR")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "Português europeu"), "pt-PT")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "Norsk"), "nb")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "中文-普通话 國語"), "zh-CN")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "中文-广东话 粵語"), "zh-HK")
    }

    func test_englishNamesAndCodesMapToTags() {
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "Spanish"), "es")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "en"), "en")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "pt_BR"), "pt-br")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "ptBR"), "pt-BR")
        XCTAssertEqual(SpeechLanguage.tag(forWorkLanguage: "zh"), "zh-CN")
    }

    func test_emptyOrUnknownLanguageHasNoTag() {
        XCTAssertNil(SpeechLanguage.tag(forWorkLanguage: ""))
        XCTAssertNil(SpeechLanguage.tag(forWorkLanguage: "   "))
        XCTAssertNil(SpeechLanguage.tag(forWorkLanguage: "Klingon (tlhIngan Hol)"))
    }

    private let voices = [
        Voice(id: "en-us", language: "en-US", quality: 1),
        Voice(id: "es-es", language: "es-ES", quality: 1),
        Voice(id: "es-mx-enhanced", language: "es-MX", quality: 2),
        Voice(id: "pt-pt", language: "pt-PT", quality: 2),
        Voice(id: "pt-br", language: "pt-BR", quality: 1),
        Voice(id: "zh-hk", language: "zh-HK", quality: 3),
        Voice(id: "zh-tw", language: "zh-TW", quality: 1),
        Voice(id: "nb-no", language: "nb-NO", quality: 1),
    ]

    func test_aWorkInTheSystemLanguageKeepsTheSystemVoice() {
        XCTAssertNil(SpeechLanguage.voiceID(forTag: "en", voices: voices, defaultLanguage: "en-US"))
        XCTAssertNil(SpeechLanguage.voiceID(forTag: "es", voices: voices, defaultLanguage: "es-MX"))
    }

    func test_anotherLanguageGetsItsBestVoice() {
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "es", voices: voices, defaultLanguage: "en-US"), "es-mx-enhanced")
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "en", voices: voices, defaultLanguage: "fr-FR"), "en-us")
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "nb", voices: voices, defaultLanguage: "en-US"), "nb-no")
    }

    func test_theSystemsPickBreaksATie() {
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "es", voices: [
            Voice(id: "a", language: "es-ES", quality: 1),
            Voice(id: "b", language: "es-MX", quality: 1),
        ], defaultLanguage: "en-US", preferredID: "b"), "b")
    }

    func test_theExactDialectWinsOverABetterVoice() {
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "pt-BR", voices: voices, defaultLanguage: "en-US"), "pt-br")
    }

    func test_mandarinAvoidsCantonese() {
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "zh-CN", voices: voices, defaultLanguage: "en-US"), "zh-tw")
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "zh-HK", voices: voices, defaultLanguage: "en-US"), "zh-hk")
        let cantoneseOnly = [Voice(id: "zh-hk", language: "zh-HK", quality: 1)]
        XCTAssertEqual(SpeechLanguage.voiceID(forTag: "zh-CN", voices: cantoneseOnly, defaultLanguage: "en-US"), "zh-hk")
    }

    func test_noVoiceForTheLanguageKeepsTheSystemVoice() {
        XCTAssertNil(SpeechLanguage.voiceID(forTag: "ja", voices: voices, defaultLanguage: "en-US"))
        XCTAssertNil(SpeechLanguage.voiceID(forTag: nil, voices: voices, defaultLanguage: "en-US"))
    }

    func test_settingsListsTheSystemLanguageFirstThenByName() {
        let groups = [("fr-FR", "French (France)"), ("en-GB", "English (United Kingdom)"),
                      ("de-DE", "German (Germany)"), ("en-US", "English (United States)")]
        let sorted = groups.sorted {
            SpeechLanguage.listsBefore(($0.0, $0.1), ($1.0, $1.1), systemLanguage: "de-DE")
        }
        XCTAssertEqual(sorted.map(\.0), ["de-DE", "en-GB", "en-US", "fr-FR"])
    }
}
