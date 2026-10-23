import SwiftUI

/// Full screen's way out: a small Liquid Glass rail on the trailing edge,
/// shown in every reading mode whenever the reader's controls are hidden.
/// Back leaves the reader (pops to the screen it was opened from); the other
/// button brings the controls back.
///
/// Before this, the only way out of full screen was an invisible tap on the
/// page's middle third, and on iPhone Duo (one page or two) that tap could go
/// nowhere, so the only escape was force-quitting the app. A ViewModifier so
/// `ReaderView.body`'s long chain stays within the type-checker's budget.
struct ReaderFullScreenRailModifier: ViewModifier {
    @Binding var isUIMinimized: Bool
    let fg: Color
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.overlay(alignment: .trailing) {
            if isUIMinimized {
                rail
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
    }

    private var rail: some View {
        VStack(spacing: 2) {
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.backward")
                    .railHitTarget()
            }
            .accessibilityIdentifier("reader.fullScreen.back")
            .accessibilityHint("Leaves the reader.")
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isUIMinimized = false }
            } label: {
                Label("Show reader controls", systemImage: "arrow.down.right.and.arrow.up.left")
                    .railHitTarget()
            }
            // Escape leaves full screen on the Mac or with a hardware keyboard.
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityIdentifier("reader.fullScreen.exit")
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .foregroundStyle(fg)
        .buttonStyle(.plain)
        .padding(4)
        .glassRailBackground()
    }
}

private extension View {
    /// 44 pt, the minimum touch target.
    func railHitTarget() -> some View {
        frame(width: 44, height: 44).contentShape(Rectangle())
    }

    /// Liquid Glass where the OS has it (iOS 26+), a material capsule before.
    @ViewBuilder
    func glassRailBackground() -> some View {
        // glassEffect is in the iOS 26 SDK (Swift 6.2): the #if keeps older
        // Xcodes compiling, #available the older OSes.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
        #else
        background(.regularMaterial, in: Capsule())
        #endif
    }
}
