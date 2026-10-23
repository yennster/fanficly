import SwiftUI

struct ReaderKeyPressModifier: ViewModifier {
    let mode: ReadingMode
    @FocusState.Binding var isReaderFocused: Bool
    let turnPageByPage: (Bool) -> Void
    let turnPage: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
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
                isReaderFocused = true
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    isReaderFocused = true
                }
            )
    }
}
