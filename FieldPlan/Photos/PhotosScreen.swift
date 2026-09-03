import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import FieldPlanCore

/// Photo documentation (spec §20): capture, import, room galleries,
/// captions, annotation, cover photo.
struct PhotosScreen: View {
    @Environment(\.modelContext) private var context
    let project: ProjectRecord
    var roomFilter: UUID? = nil
    var roomName: String? = nil

    @State private var showCamera = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedPhoto: PhotoRecord? = nil
    @State private var errorMessage: String? = nil

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    private var photos: [PhotoRecord] {
        project.photos
            .filter { roomFilter == nil || $0.roomID == roomFilter }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        ScrollView {
            if photos.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Take jobsite photos or import from your library."))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(photos) { photo in
                    Button {
                        selectedPhoto = photo
                    } label: {
                        PhotoThumb(photo: photo, projectID: project.id)
                    }
                }
            }
            .padding(8)
        }
        .navigationTitle(roomName.map { "\($0) Photos" } ?? "Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        showCamera = true
                    } label: {
                        Image(systemName: "camera.fill")
                    }
                    .accessibilityLabel("Take photo")
                }
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                }
                .accessibilityLabel("Import photos")
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                store(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        store(image)
                    }
                }
                pickerItems = []
            }
        }
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(project: project, photo: photo)
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func store(_ image: UIImage) {
        do {
            _ = try ProjectStore.shared.savePhoto(
                image, project: project, context: context, roomID: roomFilter)
        } catch {
            errorMessage = "Photo save failed: \(error.localizedDescription)"
            AppLog.store.error("Photo save failed: \(error.localizedDescription)")
        }
    }
}

private struct PhotoThumb: View {
    let photo: PhotoRecord
    let projectID: UUID

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = ProjectStore.shared.loadImage(photo, projectID: projectID, thumbnail: true) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            if !photo.caption.isEmpty {
                Text(photo.caption)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.45))
                    .foregroundStyle(.white)
            }
        }
        .frame(minHeight: 110)
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Full photo view: caption, room assignment, annotate, cover, share, delete.
struct PhotoDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    @Bindable var photo: PhotoRecord

    @State private var showAnnotator = false
    @State private var rooms: [(UUID, String)] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let image = ProjectStore.shared.loadImage(photo, projectID: project.id) {
                        AnnotatedPhotoView(image: image, annotationData: photo.annotationData)
                            .frame(maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal)
                    }

                    Form {
                        Section("Caption") {
                            TextField("Caption", text: $photo.caption, axis: .vertical)
                                .lineLimit(1...3)
                                .onChange(of: photo.caption) {
                                    try? context.save()
                                }
                        }
                        Section("Attached To") {
                            Picker("Room", selection: Binding(
                                get: { photo.roomID },
                                set: { photo.roomID = $0; try? context.save() })) {
                                Text("None").tag(UUID?.none)
                                ForEach(rooms, id: \.0) { room in
                                    Text(room.1).tag(UUID?.some(room.0))
                                }
                            }
                        }
                        Section {
                            Button {
                                showAnnotator = true
                            } label: {
                                Label("Annotate (arrows, circles, text)", systemImage: "pencil.tip.crop.circle")
                            }
                            Button {
                                project.coverPhotoID = photo.id
                                try? context.save()
                            } label: {
                                Label(project.coverPhotoID == photo.id ? "Cover Photo ✓" : "Use as Cover Photo",
                                      systemImage: "star")
                            }
                            if let url = shareURL {
                                ShareLink(item: url) {
                                    Label("Share Photo", systemImage: "square.and.arrow.up")
                                }
                            }
                            Button(role: .destructive) {
                                ProjectStore.shared.deletePhotoFiles(photo, projectID: project.id)
                                context.delete(photo)
                                try? context.save()
                                dismiss()
                            } label: {
                                Label("Delete Photo", systemImage: "trash")
                            }
                        }
                    }
                    .frame(minHeight: 420)
                }
            }
            .navigationTitle(photo.createdAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showAnnotator) {
                if let image = ProjectStore.shared.loadImage(photo, projectID: project.id) {
                    PhotoAnnotationEditor(image: image, existing: photo.annotationData) { data in
                        photo.annotationData = data
                        try? context.save()
                    }
                }
            }
            .onAppear(perform: loadRooms)
        }
    }

    private var shareURL: URL? {
        let url = ProjectStore.shared.photoURL(photo, projectID: project.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func loadRooms() {
        guard let snapshot = try? ProjectStore.shared.activeSnapshot(for: project, context: context) else { return }
        rooms = snapshot.levels.flatMap { level in
            level.rooms.map { ($0.id, "\(level.name) — \($0.name)") }
        }
    }
}

// MARK: - Camera

/// Simple, reliable camera capture via UIImagePickerController.
struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
