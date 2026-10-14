import SwiftUI
import os
import FieldPlanCore

/// Structured logging (spec §53: no silent error swallowing).
enum AppLog {
    static let general = Logger(subsystem: "com.fieldplan.app", category: "general")
    static let scan = Logger(subsystem: "com.fieldplan.app", category: "scan")
    static let store = Logger(subsystem: "com.fieldplan.app", category: "store")
    static let export = Logger(subsystem: "com.fieldplan.app", category: "export")
    static let geometry = Logger(subsystem: "com.fieldplan.app", category: "geometry")
}

/// Jobsite-friendly visual constants: large targets, high contrast.
enum AppTheme {
    static let corner: CGFloat = 14
    static let bigButtonMinHeight: CGFloat = 56
    static let gridButtonMinHeight: CGFloat = 88

    static func statusColor(_ status: ProjectStatus) -> Color {
        switch status {
        case .lead: return .orange
        case .measured: return .blue
        case .proposalPending: return .purple
        case .proposalSent: return .indigo
        case .won: return .green
        case .lost: return .gray
        case .construction: return .teal
        case .completed: return .mint
        }
    }

    static func severityColor(_ severity: QASeverity) -> Color {
        switch severity {
        case .pass: return .green
        case .review: return .orange
        case .fail: return .red
        }
    }

    static func changeColor(_ status: ChangeStatus) -> Color {
        switch status {
        case .existing: return .primary
        case .demolish: return .red
        case .new: return .blue
        }
    }

    static func verificationColor(_ status: VerificationStatus) -> Color {
        switch status {
        case .unverified: return .orange
        case .fieldChecked: return .blue
        case .laserVerified: return .green
        case .manuallyCorrected: return .purple
        }
    }
}

/// Large primary action button used across jobsite screens.
struct BigButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: AppTheme.bigButtonMinHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.corner)
                    .fill(prominent ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Square dashboard action tile.
struct ActionTile: View {
    let title: String
    let systemImage: String
    var badge: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: AppTheme.gridButtonMinHeight)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.corner)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// A row displaying a label + value pair in schedules and summaries.
struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.subheadline)
    }
}
