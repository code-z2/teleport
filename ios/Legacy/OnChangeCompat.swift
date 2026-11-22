// iOS 16 support: `onChange(of:)` with the new two-value closure is iOS 17+; iOS 16 has
// the one-value form (deprecated from 17). This picks the right one for the running iOS.

import SwiftUI

extension View {
    /// Calls `action` with the new value whenever `value` changes.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
