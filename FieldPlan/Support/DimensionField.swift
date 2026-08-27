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

    @State private var text: String = ""
    @State private var isValid = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                .font(.title3.monospacedDigit())
                .padding(10)
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
