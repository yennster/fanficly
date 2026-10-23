import GameController
import SwiftUI

struct ReaderKeyPressModifier: ViewModifier {
    let mode: ReadingMode
    @FocusState.Binding var isReaderFocused: Bool
    let turnPageByPage: (Bool) -> Void
    let turnPage: (Bool) -> Void
    // Arrow-key turns need a hardware keyboard, so the page is focusable
    // only while one is connected. Without one, a focusable page can bring
    // up the software keyboard when focus returns to it: on iPhone Duo,
    // opening the Aa menu did, and the keyboard closed the menu.
    @State private var hasHardwareKeyboard = Self.isMac || GCKeyboard.coalesced != nil

    #if targetEnvironment(macCatalyst)
    private static let isMac = true
    #else
    private static let isMac = false
    #endif

    func body(content: Content) -> some View {
        content
            .focusable(hasHardwareKeyboard)
            .focused($isReaderFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                if mode == .pageByPage {
                    if press.key == .leftArrow {
                        turnPageByPage(false)
                        return .handled
                    } else if press.key == .rightArrow {
                        turnPageByPage(true)
                        return .handled
                    }
                } else if mode == .paginated {
                    if press.key == .leftArrow {
                        turnPage(false)
                        return .handled
                    } else if press.key == .rightArrow {
                        turnPage(true)
                        return .handled
                    }
                }
                return .ignored
            }
            .onAppear {
                isReaderFocused = hasHardwareKeyboard
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    isReaderFocused = hasHardwareKeyboard
                }
            )
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
                hasHardwareKeyboard = true
                isReaderFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
                hasHardwareKeyboard = Self.isMac
                isReaderFocused = hasHardwareKeyboard
            }
    }
}
