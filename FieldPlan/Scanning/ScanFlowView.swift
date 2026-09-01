import SwiftUI
import SwiftData
import RoomPlan
import UIKit
import FieldPlanCore

// MARK: - Scan coordinator
//
// Owns the RoomCaptureView and session across a multi-room flow. The
// ARSession is kept alive between rooms (stop(pauseARSession: false)) so all
// rooms in one flow share a coordinate space and merge cleanly (spec §8).
// A ScanRecorder rides on the same ARSession and keeps the sensor stream,
// the live quality advice and the coverage map (spec §4–§6).

@MainActor
final class ScanCoordinator: NSObject, ObservableObject {

    enum Phase: Equatable {
        case ready               // waiting to start the next room
        case scanning
        case processing
        case review              // captured room ready to accept/rescan
        case merging
        case failed(String)
    }

    @Published var phase: Phase = .ready
    @Published var instructionText: String? = nil
    @Published var acceptedRoomNames: [String] = []
    @Published var liveWallCount = 0
    @Published var currentRoomName = ""
    @Published private(set) var recorder: ScanRecorder? = nil

    let captureView = RoomCaptureView(frame: .zero)
    private(set) var pendingRoom: CapturedRoom? = nil
    private(set) var acceptedRooms: [(name: String, room: CapturedRoom)] = []
    private var sessionActive = false
    private var lastLiveRoomForward: TimeInterval = 0

    override init() {
        super.init()
        captureView.delegate = self
        captureView.captureSession.delegate = self
    }

    func startRoom(named name: String, projectID: UUID, levelID: UUID?) {
        currentRoomName = name
        pendingRoom = nil
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
        sessionActive = true

        // One recorder per flow: it observes the shared ARSession, so every
        // room scanned without leaving this screen lands in one session log.
        if recorder == nil, SettingsStore.shared.recordSensorData {
            let recorder = ScanRecorder(
                projectID: projectID, levelID: levelID,
                directory: ProjectStore.shared.sessionsDir(projectID))
            recorder.attach(to: captureView.captureSession.arSession)
            self.recorder = recorder
            // RoomPlan may install its own delegate after `run`; make sure the
            // recorder is still in the chain once frames should be flowing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak recorder] in
                recorder?.ensureAttached()
            }
        }
        recorder?.record(.roomStarted, detail: name)

        phase = .scanning
        if SettingsStore.shared.keepScreenAwakeDuringScan {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        AppLog.scan.info("Scan started for room \(name, privacy: .public)")
    }

    func finishRoom() {
        guard phase == .scanning else { return }
        phase = .processing
        // Keep the AR session alive for coordinate continuity between rooms.
        captureView.captureSession.stop(pauseARSession: false)
    }

    func cancelRoom() {
        captureView.captureSession.stop(pauseARSession: false)
        sessionActive = false
        pendingRoom = nil
        recorder?.record(.roomDiscarded, detail: currentRoomName)
        phase = .ready
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func acceptPendingRoom() {
        guard let room = pendingRoom else { return }
        acceptedRooms.append((currentRoomName, room))
        acceptedRoomNames.append(currentRoomName)
        recorder?.noteAcceptedRoom(room.identifier)
        recorder?.record(.roomFinished, detail: currentRoomName)
        pendingRoom = nil
        phase = .ready
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func discardPendingRoom() {
        pendingRoom = nil
        recorder?.record(.roomDiscarded, detail: currentRoomName)
        phase = .ready
    }

    /// Called after a successful save so the next session starts clean.
    func clearAccepted() {
        acceptedRooms.removeAll()
        acceptedRoomNames.removeAll()
    }

    /// Takes a positioned photo from the next camera frame (spec §17).
    func takePhoto() {
        recorder?.takePhoto()
    }

    /// Handles app interruption (phone call, backgrounding) — spec §46.
    /// Accepted rooms are already safe; only the in-progress room is lost.
    func handleInterruption() {
        guard phase == .scanning else { return }
        captureView.captureSession.stop(pauseARSession: false)
        sessionActive = false
        recorder?.record(.interrupted, detail: "app inactive")
        phase = .failed("Scanning was interrupted. Rooms already accepted are saved — rescan the room that was in progress.")
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Closes the sensor session and hands back its log and coverage map.
    /// The next room starts a fresh session on the same AR frame.
    func finishRecorder() -> (log: ScanSessionLog, grid: CoverageGrid?)? {
        guard let recorder else { return nil }
        let grid = recorder.coverageGrid
        let log = recorder.finish()
        self.recorder = nil
        return (log, grid)
    }

    func endFlow() {
        _ = finishRecorder()
        if sessionActive {
            captureView.captureSession.stop()
        }
        sessionActive = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Merges accepted rooms with StructureBuilder (multi-room alignment) and
    /// returns the merged structure plus per-room results. Falls back to the
    /// individually captured rooms if merging fails (spec §46).
    func mergedStructure() async -> CapturedStructure? {
        guard acceptedRooms.count >= 1 else { return nil }
        phase = .merging
        defer { phase = .ready }
        do {
            let builder = StructureBuilder(options: [.beautifyObjects])
            let structure = try await builder.capturedStructure(from: acceptedRooms.map(\.room))
            return structure
        } catch {
            AppLog.scan.error("Structure merge failed: \(error.localizedDescription)")
            return nil
        }
    }
}

extension ScanCoordinator: RoomCaptureViewDelegate {
    // RoomCaptureViewDelegate inherits NSCoding; the coordinator is never
    // actually archived, so these are inert conformances.
    nonisolated func encode(with coder: NSCoder) {}
    nonisolated convenience init?(coder: NSCoder) { return nil }

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error {
            Task { @MainActor in
                self.phase = .failed("Scan processing failed: \(error.localizedDescription)")
                UIApplication.shared.isIdleTimerDisabled = false
            }
            return false
        }
        return true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            if let error {
                self.phase = .failed("Scan processing failed: \(error.localizedDescription)")
                UIApplication.shared.isIdleTimerDisabled = false
                return
            }
            self.pendingRoom = processedResult
            self.phase = .review
        }
    }
}

extension ScanCoordinator: RoomCaptureSessionDelegate {
    nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String?
        switch instruction {
        case .moveCloseToWall: text = "Move closer to the wall"
        case .moveAwayFromWall: text = "Move farther from the wall"
        case .slowDown: text = "Move slower"
        case .turnOnLight: text = "Too dark — turn on a light"
        case .lowTexture: text = "Low detail — scan surrounding features"
        case .normal: text = nil
        @unknown default: text = nil
        }
        let kind = CapturedRoomBridge.adviceKind(for: instruction)
        Task { @MainActor in
            self.instructionText = text
            self.recorder?.setInstruction(kind)
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let walls = room.walls.count
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            self.liveWallCount = walls
            // The live room feeds wall coverage; once a second is plenty.
            if let recorder = self.recorder, now - self.lastLiveRoomForward >= 1.0 {
                self.lastLiveRoomForward = now
                recorder.updateLiveRoom(CapturedRoomBridge.dto(from: room, name: nil))
            }
        }
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error {
            AppLog.scan.error("Capture session ended with error: \(error.localizedDescription)")
            Task { @MainActor in
                if self.phase == .scanning || self.phase == .processing {
                    self.phase = .failed("Scanning stopped: \(error.localizedDescription)")
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }
}

struct RoomCaptureHostView: UIViewRepresentable {
    let coordinator: ScanCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        coordinator.captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

// MARK: - Scan flow screen

/// Complete scan workflow (spec §8): pick level → name room → scan → review →
/// accept/rescan → next room → finish level → merge → save → review findings.
struct ScanFlowView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let project: ProjectRecord

    @StateObject private var coordinator = ScanCoordinator()
    @State private var snapshot: PlanSnapshot? = nil
    @State private var selectedLevelID: UUID? = nil
    @State private var roomName = ""
    @State private var roomType: RoomType = .livingRoom
    @State private var showNameSheet = false
    @State private var saving = false
    @State private var saveError: String? = nil
    @State private var finished = false
    @State private var reviewLevel: LevelGeometry? = nil
    @State private var reviewFindings: [SpaceFinding] = []
    @State private var showReview = false

    var body: some View {
        Group {
            if ScanCapability.isRoomPlanSupported {
                scanBody
            } else {
                ManualModeIntroView(project: project)
            }
        }
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear { coordinator.endFlow() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                coordinator.handleInterruption()
            }
        }
    }

    @ViewBuilder
    private var scanBody: some View {
        switch coordinator.phase {
        case .ready:
            readyView
        case .scanning, .processing, .review:
            captureView
        case .merging:
            ProgressView("Merging rooms…")
                .controlSize(.large)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Continue") { coordinator.phase = .ready }
                    .buttonStyle(BigButtonStyle())
                    .padding(.horizontal, 40)
            }
        }
    }

    // MARK: Ready (between rooms)

    private var readyView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let snapshot {
                    Picker("Level", selection: Binding(
                        get: { selectedLevelID ?? snapshot.levels.first?.id },
                        set: { selectedLevelID = $0 })) {
                        ForEach(snapshot.levels.sorted(by: { $0.storyIndex < $1.storyIndex })) { level in
                            Text(level.name).tag(Optional(level.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                if !coordinator.acceptedRoomNames.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Captured this session")
                            .font(.headline)
                        ForEach(Array(coordinator.acceptedRoomNames.enumerated()), id: \.offset) { index, name in
                            Label(name.isEmpty ? "Room \(index + 1) — will auto-label" : name,
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: AppTheme.corner)
                        .fill(Color(.secondarySystemGroupedBackground)))
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("How to scan")
                        .font(.headline)
                    Text("Start on the lowest floor. Hold the phone at chest height, pointed where you are walking, 5–10 ft from the walls with the floor line in view. Walk along the walls rather than turning in the middle of the room; back out of small spaces instead of spinning. Pause and pan up for cabinets and windows. Scan closets from the doorway. Keep going room to room — the coverage map shows what has been seen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(RoundedRectangle(cornerRadius: AppTheme.corner)
                    .fill(Color(.secondarySystemGroupedBackground)))
                .padding(.horizontal)

                Button {
                    showNameSheet = true
                } label: {
                    Label(coordinator.acceptedRoomNames.isEmpty ? "Scan First Room" : "Scan Next Room",
                          systemImage: "camera.viewfinder")
                }
                .buttonStyle(BigButtonStyle())
                .padding(.horizontal)

                if !coordinator.acceptedRooms.isEmpty {
                    Button {
                        Task { await finishLevel() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Label("Finish & Save \(coordinator.acceptedRooms.count) Room(s)",
                                  systemImage: "checkmark.seal.fill")
                        }
                    }
                    .buttonStyle(BigButtonStyle(prominent: false))
                    .disabled(saving)
                    .padding(.horizontal)
                }

                NavigationLink {
                    ManualRoomView(project: project)
                } label: {
                    Label("Enter Room Manually Instead", systemImage: "square.and.pencil")
                        .font(.subheadline)
                }
                .padding(.top, 8)
            }
            .padding(.vertical)
        }
        .sheet(isPresented: $showNameSheet) {
            RoomNameSheet(roomName: $roomName, roomType: $roomType) {
                // Blank name = auto-label from the scan (room type detection
                // plus fixtures found inside), CubiCasa-style.
                coordinator.startRoom(
                    named: roomName.trimmingCharacters(in: .whitespaces),
                    projectID: project.id,
                    levelID: selectedLevelID ?? snapshot?.levels.first?.id)
                roomName = ""
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showReview) {
            if let reviewLevel {
                ScanReviewSheet(
                    level: reviewLevel,
                    findings: reviewFindings,
                    onScanMore: { showReview = false },
                    onDone: {
                        showReview = false
                        finished = true
                    })
            }
        }
        .alert("Save Error", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .navigationDestination(isPresented: $finished) {
            FloorPlanScreen(project: project)
        }
    }

    // MARK: Capture

    private var captureView: some View {
        ZStack {
            RoomCaptureHostView(coordinator: coordinator)
                .ignoresSafeArea()

            VStack {
                if let recorder = coordinator.recorder, coordinator.phase == .scanning {
                    ScanLiveOverlay(
                        recorder: recorder,
                        roomName: coordinator.currentRoomName,
                        wallCount: coordinator.liveWallCount,
                        onPhoto: { coordinator.takePhoto() })
                } else {
                    if let instruction = coordinator.instructionText, coordinator.phase == .scanning {
                        Text(instruction)
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .transition(.opacity)
                    }
                    Spacer()
                }

                switch coordinator.phase {
                case .scanning:
                    VStack(spacing: 10) {
                        if coordinator.recorder == nil {
                            Text("\(coordinator.currentRoomName.isEmpty ? "Scanning" : coordinator.currentRoomName) — \(coordinator.liveWallCount) walls detected")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(.ultraThinMaterial))
                        }
                        HStack(spacing: 12) {
                            Button {
                                coordinator.cancelRoom()
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                            .buttonStyle(BigButtonStyle(prominent: false))
                            Button {
                                coordinator.finishRoom()
                            } label: {
                                Label("Finish Room", systemImage: "checkmark")
                            }
                            .buttonStyle(BigButtonStyle())
                        }
                    }
                    .padding()
                case .processing:
                    ProgressView("Processing room…")
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                        .padding()
                case .review:
                    VStack(spacing: 10) {
                        if let room = coordinator.pendingRoom {
                            Text("\(room.walls.count) walls · \(room.doors.count) doors · \(room.windows.count) windows · \(room.objects.count) objects")
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(.ultraThinMaterial))
                            let low = room.walls.filter { $0.confidence == .low }.count
                            if low > 0 {
                                Text("\(low) wall(s) at low scanner confidence — consider rescanning")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(.ultraThinMaterial))
                            }
                        }
                        HStack(spacing: 12) {
                            Button {
                                coordinator.discardPendingRoom()
                            } label: {
                                Label("Rescan", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(BigButtonStyle(prominent: false))
                            Button {
                                coordinator.acceptPendingRoom()
                            } label: {
                                Label("Accept Room", systemImage: "checkmark.circle.fill")
                            }
                            .buttonStyle(BigButtonStyle())
                        }
                    }
                    .padding()
                default:
                    EmptyView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.instructionText)
    }

    // MARK: Data

    private func load() {
        do {
            let s = try ProjectStore.shared.activeSnapshot(for: project, context: context)
            snapshot = s
            if selectedLevelID == nil {
                selectedLevelID = s.levels.first?.id
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Persists everything: raw scans, USDZ, the sensor session, converted
    /// geometry with its evidence, positioned photos (spec §8, §10, §17, §21).
    private func finishLevel() async {
        guard let snapshot, let levelID = selectedLevelID ?? snapshot.levels.first?.id else { return }
        saving = true
        defer { saving = false }

        let store = ProjectStore.shared
        let scansDir = store.scansDir(project.id)

        // 0. Close the sensor session first; its evidence attaches below.
        let session = coordinator.finishRecorder()

        // 1. Persist raw per-room scans immediately (data preservation first).
        for (name, room) in coordinator.acceptedRooms {
            let scanID = room.identifier
            var rawName: String? = nil
            var usdzName: String? = nil
            do {
                let data = try CapturedRoomBridge.rawJSON(for: room)
                rawName = "\(scanID.uuidString).json"
                try data.write(to: scansDir.appendingPathComponent(rawName!), options: .atomic)
            } catch {
                AppLog.scan.error("Raw scan save failed: \(error.localizedDescription)")
            }
            do {
                let usdz = "\(scanID.uuidString).usdz"
                try room.export(to: scansDir.appendingPathComponent(usdz), exportOptions: .parametric)
                usdzName = usdz
            } catch {
                AppLog.scan.error("USDZ export failed: \(error.localizedDescription)")
            }
            let record = ScanRecord(
                id: scanID, levelID: levelID,
                roomName: name.isEmpty ? "Auto-labeled room" : name,
                rawDataFileName: rawName, usdzFileName: usdzName,
                sessionID: session?.log.id)
            record.project = project
            context.insert(record)
        }

        // 2. Merge into a structure for the combined USDZ (best effort).
        if coordinator.acceptedRooms.count > 1 {
            if let structure = await coordinator.mergedStructure() {
                do {
                    let url = scansDir.appendingPathComponent("structure-\(UUID().uuidString).usdz")
                    try structure.export(to: url, exportOptions: .parametric)
                } catch {
                    AppLog.scan.error("Structure USDZ export failed: \(error.localizedDescription)")
                }
            }
        }

        // 3. Convert to canonical geometry and merge into the level. Rooms
        // scanned without a name are auto-labeled from RoomPlan's own room
        // classification or the fixtures found inside (Bedroom, Bathroom, …).
        let dtos = coordinator.acceptedRooms.map {
            CapturedRoomBridge.dto(from: $0.room, name: $0.name.isEmpty ? nil : $0.name)
        }
        let conversion = ScanConversion.convert(rooms: dtos)
        for warning in conversion.warnings {
            AppLog.geometry.warning("\(warning, privacy: .public)")
        }

        do {
            var current = try store.loadSnapshot(projectID: project.id, snapshotID: snapshot.id)
            guard var level = current.levels.first(where: { $0.id == levelID }) else {
                saveError = "The selected level no longer exists."
                return
            }
            level = ScanConversion.merge(conversion, into: level)

            // 4. Evidence: coverage and tracking from the session score every
            // scanned element; the compass places north; the floor's height
            // records where this level sits in the scan frame.
            if let session {
                level = EvidenceAttachment.attach(
                    to: level,
                    grid: session.grid,
                    trackingNormalFraction: session.log.summary?.trackingNormalFraction,
                    sessionID: session.log.id)
                level.scanSessionIDs = (level.scanSessionIDs ?? []) + [session.log.id]
                if level.elevation == nil { level.elevation = session.grid?.floorElevation }
                if level.northAngle == nil,
                   let north = NorthEstimator.northAngle(from: session.log.headings) {
                    level.northAngle = north
                }
            }

            current = try store.updateLevel(level, in: current, projectID: project.id)
            if let session {
                store.importSessionPhotos(session.log, project: project, level: level, context: context)
            }
            project.updatedAt = Date()
            if project.status == .lead { project.status = .measured }
            try context.save()
            self.snapshot = current
            coordinator.clearAccepted()

            // 5. Before leaving the property: anything that looks unscanned?
            let findings = MissingSpaceDetector.findings(for: level, levels: current.levels)
            if findings.isEmpty {
                finished = true
            } else {
                reviewLevel = level
                reviewFindings = findings
                showReview = true
            }
        } catch {
            saveError = "Saving the scan failed: \(error.localizedDescription)"
            AppLog.scan.error("Scan save failed: \(error.localizedDescription)")
        }
    }
}

/// Room naming sheet shown before each room scan (spec §8, §9). Naming is
/// optional: left blank, the room is auto-labeled from the scan itself
/// (room type detection + recognized fixtures) with per-level numbering.
struct RoomNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var roomName: String
    @Binding var roomType: RoomType
    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional — e.g. Primary Bedroom)", text: $roomName)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $roomType) {
                        ForEach(RoomType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text("Room")
                } footer: {
                    Text("Leave the name blank and the room labels itself from what the scan finds — a room with a tub becomes Bathroom, one with a bed becomes Bedroom, duplicates are numbered. Walk several connected rooms in one go and they are split automatically.")
                }
                Section {
                    Button {
                        dismiss()
                        onStart()
                    } label: {
                        Label(roomName.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "Begin Scan (Auto-Label)"
                                : "Begin Scan",
                              systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .font(.headline)
                }
            }
            .navigationTitle("New Room Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: roomType) { _, newType in
                // Picking a type explicitly fills the name; typing wins.
                if roomName.isEmpty { roomName = newType.displayName }
            }
        }
    }
}

/// Shown on devices without RoomPlan support (spec §3 Mode B).
struct ManualModeIntroView: View {
    let project: ProjectRecord

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Automatic Scanning Unavailable")
                    .font(.title3.weight(.semibold))
                Text("This device does not support LiDAR room scanning. You can still capture complete, accurate floor plans by entering tape-measure or laser-meter dimensions.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                NavigationLink {
                    ManualRoomView(project: project)
                } label: {
                    Label("Enter Room Measurements", systemImage: "square.and.pencil")
                }
                .buttonStyle(BigButtonStyle())
                .padding(.horizontal)
            }
            .padding(.vertical, 40)
        }
    }
}
