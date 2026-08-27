import SwiftUI
import SwiftData
import FieldPlanCore

/// Quick field notes (spec §21). Fast entry with common contractor phrases;
/// dictation comes free with the keyboard microphone.
struct NotesScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord
    var roomFilter: UUID? = nil
    var roomName: String? = nil

    @State private var draft = ""
    @FocusState private var focused: Bool

    static let quickPhrases = [
        "Replace flooring", "Skim coat walls", "Remove soffit",
        "New recessed lighting", "Convert tub to shower", "Relocate refrigerator",
        "Remove closet", "Patch ceiling", "New subpanel", "Level floor",
    ]

    private var notes: [NoteRecord] {
        project.noteRecords
            .filter { roomFilter == nil || $0.roomID == roomFilter }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if notes.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "note.text",
                                           description: Text("Type below or use the mic key to dictate."))
                }
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.text)
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            context.delete(note)
                            try? context.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            VStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.quickPhrases, id: \.self) { phrase in
                            Button(phrase) {
                                add(text: phrase)
                            }
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                        }
                    }
                    .padding(.horizontal)
                }
                HStack {
                    TextField("Add note (mic key dictates)…", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                    Button {
                        add(text: draft)
                        draft = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add note")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .background(.bar)
        }
        .navigationTitle(roomName.map { "\($0) Notes" } ?? "Notes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = NoteRecord(text: trimmed, roomID: roomFilter)
        note.project = project
        context.insert(note)
        project.updatedAt = Date()
        do {
            try context.save()
        } catch {
            AppLog.store.error("Note save failed: \(error.localizedDescription)")
        }
    }
}
