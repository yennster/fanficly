import AVFoundation
import SwiftUI
import SwiftData

struct ReaderSettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(ReaderProfile.deviceKey("reader.theme")) private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.fontFamily")) private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.widthPercent")) private var widthPercent: Double = 70.0
    @AppStorage(ReaderProfile.deviceKey("reader.mode")) private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.fontSizePt")) private var fontSizePt: Double = ReaderMetrics.defaultFontSize
    @AppStorage(ReaderProfile.deviceKey("reader.lineSpacingPt")) private var lineSpacingPt: Double = ReaderMetrics.defaultLineSpacing
    @AppStorage(ReaderProfile.deviceKey("reader.paragraphSpacingPt")) private var paragraphSpacingPt: Double = ReaderMetrics.defaultParagraphSpacing
    @AppStorage(ReaderProfile.deviceKey("reader.pageTurnHaptics")) private var pageTurnHaptics: Bool = false
    @AppStorage(ReaderProfile.deviceKey("reader.pageTurnAnimations")) private var pageTurnAnimations: Bool = true
    @AppStorage(ReaderProfile.deviceKey("reader.kerningPt")) private var kerningPt: Double = ReaderMetrics.defaultKerning
    @AppStorage(ReaderProfile.deviceKey("reader.boldText")) private var boldText: Bool = false
    @AppStorage("reader.keepScreenAwake") private var keepScreenAwake: Bool = true
    // Global (not per-device / not part of reader profiles): a content &
    // privacy choice, not typography. Matches ReaderView's key.
    @AppStorage("reader.showImages") private var showImages: Bool = false
    @AppStorage(SpeechController.rateKey) private var ttsRate: Double = Double(SpeechController.defaultRate)
    @AppStorage(SpeechController.voiceKey) private var ttsVoiceId: String = ""
    @Environment(\.colorScheme) private var systemColorScheme

    // Profile Management
    @AppStorage("app.zoomScale") private var zoomScale: Double = 1.0
    @AppStorage(ReaderProfile.deviceActiveProfileKey) private var activeProfileName: String = "Default"
    @AppStorage("reader.profiles") private var profilesJSON: String = ""
    @State private var showingNewProfileAlert = false
    @State private var newProfileName = ""
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""

    init() {
        ReaderProfile.migrateLegacySettingsIfNeeded()
    }

    private var profiles: [ReaderProfile] {
        ReaderProfile.loadProfiles(from: profilesJSON)
    }

    private func saveCurrentToActiveProfile() {
        var list = profiles
        if let idx = list.firstIndex(where: { $0.name == activeProfileName }) {
            list[idx].themeRaw = themeRaw
            list[idx].fontFamilyRaw = fontFamilyRaw
            list[idx].widthPercent = widthPercent
            list[idx].modeRaw = modeRaw
            list[idx].fontSizePt = fontSizePt
            list[idx].lineSpacingPt = lineSpacingPt
            list[idx].paragraphSpacingPt = paragraphSpacingPt
            list[idx].pageTurnHaptics = pageTurnHaptics
            list[idx].pageTurnAnimations = pageTurnAnimations
            list[idx].kerningPt = kerningPt
            list[idx].boldText = boldText
        } else {
            let newProfile = ReaderProfile(
                name: activeProfileName,
                themeRaw: themeRaw,
                fontFamilyRaw: fontFamilyRaw,
                widthRaw: nil,
                widthPercent: widthPercent,
                modeRaw: modeRaw,
                fontSizePt: fontSizePt,
                lineSpacingPt: lineSpacingPt,
                paragraphSpacingPt: paragraphSpacingPt,
                pageTurnHaptics: pageTurnHaptics,
                pageTurnAnimations: pageTurnAnimations,
                kerningPt: kerningPt,
                boldText: boldText
            )
            list.append(newProfile)
        }
        saveProfiles(list)
        queueBackup()
    }

    private func selectProfile(_ profile: ReaderProfile) {
        activeProfileName = profile.name
        themeRaw = profile.themeRaw
        fontFamilyRaw = profile.fontFamilyRaw
        widthPercent = profile.widthPercent ?? 70.0
        modeRaw = profile.modeRaw
        fontSizePt = profile.fontSizePt
        lineSpacingPt = profile.lineSpacingPt
        paragraphSpacingPt = profile.paragraphSpacingPt
        pageTurnHaptics = profile.pageTurnHaptics
        pageTurnAnimations = profile.pageTurnAnimations
        kerningPt = profile.kerningPt ?? ReaderMetrics.defaultKerning
        boldText = profile.boldText ?? false
        queueBackup()
    }

    private func deleteProfile(_ name: String) {
        var list = profiles
        list.removeAll { $0.name == name }
        if activeProfileName == name {
            activeProfileName = "Default"
            if let defaultProf = list.first(where: { $0.name == "Default" }) {
                selectProfile(defaultProf)
            } else {
                selectProfile(ReaderProfile.defaultProfiles[0])
            }
        }
        saveProfiles(list)
        queueBackup()
    }

    private func saveNewProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            errorMessage = "A profile named \"\(trimmed)\" already exists."
            showingErrorAlert = true
            return
        }
        activeProfileName = trimmed
        saveCurrentToActiveProfile()
    }

    /// On-device voices for the current language (fall back to all installed
    /// voices if the language has none), sorted by name.
    private var voices: [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let matching = all.filter { $0.language.hasPrefix(lang) }
        return (matching.isEmpty ? all : matching).sorted { $0.name < $1.name }
    }

    var body: some View {
        let theme = ReaderTheme(rawValue: themeRaw) ?? .system
        let family = ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork
        let scheme = theme.preferredColorScheme ?? systemColorScheme

        Form {
            if contrast == .increased {
                Section {
                    Label {
                        Text("High Contrast is active in system settings. We recommend using 'Match System' or 'Dracula Navy' theme to ensure readable text contrast.")
                    } icon: {
                        Image(systemName: "circle.lefthalf.striped.horizontal")
                            .foregroundColor(.orange)
                    }
                }
            }

            Section("Reader Profile") {
                Picker("Active Profile", selection: $activeProfileName) {
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.name)
                    }
                }
                .onChange(of: activeProfileName) { _, newName in
                    if let profile = profiles.first(where: { $0.name == newName }) {
                        selectProfile(profile)
                    }
                }
                .help("Select a reader settings profile to apply or edit.")
                
                Button("Save Current Settings as New Profile...") {
                    newProfileName = ""
                    showingNewProfileAlert = true
                }
                .help("Save these settings as a reusable configuration profile.")
                
                if activeProfileName != "Default" {
                    Button("Save Current Settings to \"\(activeProfileName)\"") {
                        saveCurrentToActiveProfile()
                    }
                    .help("Overwrite the selected profile with your current settings.")

                    Button("Delete Profile \"\(activeProfileName)\"", role: .destructive) {
                        deleteProfile(activeProfileName)
                    }
                    .help("Delete the selected profile.")
                }
            }

            Section("Preview") {
                VStack(alignment: .leading, spacing: paragraphSpacingPt / zoomScale) {
                    Text("A Coffee Shop Tale")
                        .font(family.font(size: CGFloat(fontSizePt + 6) / CGFloat(zoomScale), weight: .bold))
                        .tracking(kerningPt / zoomScale)
                    Text("Bella poured the latte. It was hot.")
                        .font(family.font(size: CGFloat(fontSizePt) / CGFloat(zoomScale)))
                        .lineSpacing(lineSpacingPt / zoomScale)
                        .tracking(kerningPt / zoomScale)
                        .bold(boldText)
                    Text("Edward looked up from the corner table and met her eyes. The cafe felt suddenly quieter.")
                        .font(family.font(size: CGFloat(fontSizePt) / CGFloat(zoomScale)))
                        .lineSpacing(lineSpacingPt / zoomScale)
                        .tracking(kerningPt / zoomScale)
                        .bold(boldText)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.background(for: scheme))
                .foregroundStyle(theme.foreground(for: scheme))
                .cornerRadius(8)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .help("Visual preview of current font size, spacing, font, and theme.")
            }

            Section {
                metricSlider("Text size", value: $fontSizePt, range: ReaderMetrics.fontSizeRange,
                             step: 1, unit: "pt", icon: "textformat.size")
                metricSlider("Line spacing", value: $lineSpacingPt, range: ReaderMetrics.lineSpacingRange,
                             step: 1, unit: "pt", icon: "arrow.up.and.down.text.horizontal")
                metricSlider("Paragraph spacing", value: $paragraphSpacingPt, range: ReaderMetrics.paragraphSpacingRange,
                             step: 2, unit: "pt", icon: "text.justify.left")
                metricSlider("Character spacing", value: $kerningPt, range: ReaderMetrics.kerningRange,
                             step: 0.1, unit: "pt", icon: "character.textbox")
            } header: {
                Text("Text size & spacing")
            } footer: {
                Text("Drag the sliders, or tap − / + to fine-tune.")
            }

            Section {
                Picker("Reading mode", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) { m in
                        Label(m.displayName, systemImage: m.symbol).tag(m.rawValue)
                    }
                }
                .pickerStyle(.inline).labelsHidden()
                .help("Choose how stories are paginated and scrolled.")

                Toggle(isOn: $pageTurnHaptics) {
                    Label("Page-turn haptics", systemImage: "hand.tap")
                }
                .help("Enable small vibrations on page flips.")

                Toggle(isOn: $pageTurnAnimations) {
                    Label("Page-turn animation", systemImage: "square.2.layers.3d")
                }
                .help("Enable visual curl or slide animation on page flips.")

                Toggle(isOn: $keepScreenAwake) {
                    Label("Keep screen awake while reading", systemImage: "sun.max")
                }
                .help("Stop the display from dimming or locking while a story is open, like a video player.")
            } header: {
                Text("Reading mode")
            } footer: {
                Text("Continuous scrolls the whole work in one column. Swipe by chapter shows one chapter per page — scroll vertically inside it. Page-by-page formats the work into horizontal pages you swipe or tap to turn. Page-turn options configure haptic feedback and animations. “Keep screen awake” holds the display on while you read and releases it as soon as you leave the reader.")
            }

            Section {
                Toggle(isOn: $showImages) {
                    Label("Show images in stories", systemImage: "photo")
                }
                .help("Render images that authors embed in chapters.")
            } header: {
                Text("Story images")
            } footer: {
                Text("Off by default: chapters render as text only. When on, images embedded in a story are fetched from the author's original image host as you read — like opening that site in a browser, it can see your IP address. Images aren't saved with downloaded works, so offline reading stays text-only, though iOS may keep a temporary cache of recently viewed images on this device.")
            }

            Section {
                Picker(selection: $ttsVoiceId) {
                    Text("System default").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                    }
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .help("Select a voice for reading aloud.")

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Speaking rate", systemImage: "speedometer").font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f×", ttsRate / Double(SpeechController.defaultRate)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $ttsRate,
                           in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate))
                    .accessibilityLabel("Speaking rate")
                    .accessibilityValue(String(format: "%.1f times standard speed", ttsRate / Double(SpeechController.defaultRate)))
                    .accessibilityHint("Adjusts the voice reading speed.")
                }
                .padding(.vertical, 2)
                .help("Drag to adjust the speech speed.")
            } footer: {
                Text("Tap the headphones in the reader to have a chapter read aloud. To use highly realistic neural voices (including Siri voices or your own cloned Personal Voice), download them in iOS Settings → Accessibility → Spoken Content → Voices (or set up Personal Voice under Settings → Accessibility → Personal Voice). System voices run entirely on-device and are completely free.")
            }

            Section("Theme") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ReaderTheme.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline).labelsHidden()
                .help("Choose the color scheme for the reader.")
            }

            Section("Font") {
                Picker("Font", selection: $fontFamilyRaw) {
                    ForEach(ReaderFontFamily.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .pickerStyle(.inline).labelsHidden()
                .help("Choose the typography for the reader.")
                
                Toggle(isOn: $boldText) {
                    Label("Bold text", systemImage: "bold")
                }
                .help("Make all reader text bold for easier reading.")
            }

            Section {
                metricSlider("Margins", value: $widthPercent, range: 30.0...100.0,
                             step: 5.0, unit: "%", icon: "arrow.left.and.right.square")
            } header: {
                Text("Margins")
            } footer: {
                Text("Adjust the width of the text column as a percentage of the window.")
            }
        }
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: themeRaw) { _, _ in queueBackup() }
        .onChange(of: fontFamilyRaw) { _, _ in queueBackup() }
        .onChange(of: widthPercent) { _, _ in queueBackup() }
        .onChange(of: modeRaw) { _, _ in queueBackup() }
        .onChange(of: fontSizePt) { _, _ in queueBackup() }
        .onChange(of: lineSpacingPt) { _, _ in queueBackup() }
        .onChange(of: paragraphSpacingPt) { _, _ in queueBackup() }
        .onChange(of: pageTurnHaptics) { _, _ in queueBackup() }
        .onChange(of: pageTurnAnimations) { _, _ in queueBackup() }
        .onChange(of: kerningPt) { _, _ in queueBackup() }
        .onChange(of: boldText) { _, _ in queueBackup() }
        .onChange(of: ttsRate) { _, _ in queueBackup() }
        .onChange(of: ttsVoiceId) { _, _ in queueBackup() }
        .alert("New Profile", isPresented: $showingNewProfileAlert) {
            TextField("Profile Name", text: $newProfileName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                saveNewProfile(name: newProfileName)
            }
        } message: {
            Text("Enter a name for this reader settings configuration profile.")
        }
        .alert(errorMessage, isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    private func queueBackup() {
        iCloudSyncManager.shared.queueBackup(context: context)
    }

    private func saveProfiles(_ list: [ReaderProfile]) {
        // Diffing against the stored JSON stamps edits and tombstones removed
        // names, so deletions survive the cloud merge in publishLocalProfiles.
        let json = ReaderProfile.saveProfiles(list, previousJSON: profilesJSON)
        profilesJSON = json
        ReaderProfileSyncStore.publishLocalProfiles(json)
    }

    @ViewBuilder
    private func metricSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                              step: Double, unit: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline)
                Spacer()
                let formattedValue = step < 1.0 ? String(format: "%.1f", value.wrappedValue) : "\(Int(value.wrappedValue.rounded()))"
                Text("\(formattedValue) \(unit)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Decrease \(title)")
                .accessibilityHint("Decreases \(title.lowercased()) by \(Int(step)) \(unit)")

                Slider(value: value, in: range, step: step)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(step < 1.0 ? String(format: "%.1f", value.wrappedValue) : "\(Int(value.wrappedValue.rounded()))") \(unit)")
                    .accessibilityHint("Adjusts the \(title.lowercased()) of the reader text.")

                Button {
                    value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Increase \(title)")
                .accessibilityHint("Increases \(title.lowercased()) by \(Int(step)) \(unit)")
            }
        }
        .padding(.vertical, 2)
        .help("Adjust the \(title.lowercased())")
    }
}

#Preview {
    NavigationStack { ReaderSettingsView() }
}
