import SwiftUI
import FieldPlanCore

/// Text field for entering lengths in contractor formats ("12' 6 1/2\"",
/// "84\"", "2.5m"). Shows live parse feedback; commits meters at full
/// precision. Minimal typing, large target (spec §42).
struct DimensionField: View {
    let label: String
    /// Meters. Nil while empty/invalid.
    @Binding var meters: Double?
    var formatter: UnitFormatter
    var placeholder: String = "12' 6 1/2\""
    /// Larger type for a field that is the only thing on a screen — the
    /// ground-truth entry in field validation mode.
    var prominent = false
    /// Opens the keyboard on the field as soon as it appears, so recording a
    /// measurement is one tap and one number.
    var autoFocus = false

    @State private var text: String = ""
    @State private var isValid = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !label.isEmpty {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let meters, isValid {
                    Text(formatter.length(meters))
                        .font(.caption)
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
            }
            TextField(placeholder, text: $text)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .focused($focused)
                .font(prominent
                       ? .system(size: 32, weight: .semibold, design: .rounded).monospacedDigit()
                       : .title3.monospacedDigit())
                .padding(prominent ? 14 : 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.tertiarySystemFill))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isValid ? Color.clear : Color.red, lineWidth: 1.5)
                )
                .onChange(of: text) { _, newValue in
                    parse(newValue)
                }
                .onAppear {
                    if let meters {
                        text = formatter.length(meters)
                    }
                    if autoFocus { focused = true }
                }
                .accessibilityLabel(label)
        }
    }

    private func parse(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            meters = nil
            isValid = true
            return
        }
        if let value = DimensionParser.parseLength(trimmed) {
            meters = value
            isValid = true
        } else {
            meters = nil
            isValid = false
        }
    }
}

/// Quick fraction/feet keypad accessory row could be added later; the parser
/// already accepts everything a laser meter or tape reads out.
