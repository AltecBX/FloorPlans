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
        case interrupted         // stopped mid-room; the walk can be resumed
        case relocalizing        // restoring the world map before scanning on
        case failed(String)
    }

    @Published var phase: Phase = .ready
    @Published var instructionText: String? = nil
    @Published var acceptedRoomNames: [String] = []
    @Published var liveWallCount = 0
    @Published var currentRoomName = ""
    @Published private(set) var recorder: ScanRecorder? = nil
    /// Set when a room was accepted but could not be written to disk. The
    /// flow must not pretend that room is safe.
    @Published var checkpointFailure: String? = nil

    /// FieldPlan owns the ARSession and hands it to RoomPlan (build 15).
    let spatial = SpatialSession()
    lazy var captureView: RoomCaptureView = spatial.makeCaptureView()
    private(set) var pendingRoom: CapturedRoom? = nil
    private(set) var acceptedRooms: [(name: String, room: CapturedRoom)] = []
    private var sessionActive = false
    private var lastLiveRoomForward: TimeInterval = 0
    private var projectID: UUID?
    private var levelID: UUID?
    /// Checkpoints written during this flow, so Finish Level can fold in
    /// exactly what was saved rather than what happens to be in memory.
    private(set) var checkpointIDs: Set<UUID> = []

    override init() {
        super.init()
        captureView.delegate = self
        captureView.captureSession.delegate = self
    }

    func startRoom(named name: String, projectID: UUID, levelID: UUID?) {
        // A room started while ARKit is still finding itself would be built
        // in a coordinate system that is about to move.
        guard !spatial.isBusyRelocalizing else {
            phase = .failed("Still relocalizing — wait until tracking recovers before scanning another room.")
            return
        }
        self.projectID = projectID
        self.levelID = levelID
        currentRoomName = name
        pendingRoom = nil

        spatial.configure(
            projectID: projectID, levelID: levelID,
            scanSessionID: recorder?.sessionID,
            mapsDirectory: ScanCheckpointStore.shared.worldMapsDir(projectID))

        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
        sessionActive = true
        spatial.plantOriginAnchor()

        // One recorder per flow: it observes the session FieldPlan owns, so
        // every room scanned without leaving this screen lands in one log.
        if recorder == nil, SettingsStore.shared.recordSensorData {
            let recorder = ScanRecorder(
                projectID: projectID, levelID: levelID,
                directory: ProjectStore.shared.sessionsDir(projectID))
            recorder.spatial = spatial
            recorder.attach(to: spatial.arSession)
            self.recorder = recorder
            spatial.recorderDelegate = recorder
            // RoomPlan configures the session it was handed; if it also takes
            // the delegate, rejoin behind it. The re-attach is recorded as a
            // session event so the field visit shows whether it happens.
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

    /// Accepting a room writes it to disk *first*. If iOS terminates the app
    /// a second later, reopening the project still knows this room was
    /// captured — which was not true before build 15.
    func acceptPendingRoom() {
        guard let room = pendingRoom else { return }
        acceptedRooms.append((currentRoomName, room))
        acceptedRoomNames.append(currentRoomName)
        recorder?.noteAcceptedRoom(room.identifier)
        recorder?.record(.roomFinished, detail: currentRoomName)

        if let projectID {
            let grid = recorder?.coverageGrid
            let checkpoint = ScanCheckpointStore.shared.checkpoint(
                room: room,
                name: currentRoomName,
                projectID: projectID,
                levelID: levelID,
                scanSessionID: recorder?.sessionID,
                worldMapCheckpointID: spatial.bestCheckpoint?.id,
                cameraTransform: spatial.arSession.currentFrame
                    .map { SpatialSession.floats($0.camera.transform) },
                floorCoverage: grid?.observedFloorArea,
                wallCoverage: nil,
                meshChunkCount: recorder?.meshChunks.count)
            if let checkpoint {
                checkpointIDs.insert(checkpoint.id)
                recorder?.record(.checkpoint, detail: "room \(currentRoomName)")
            } else {
                // The one failure that must not be hidden: the room is in
                // memory only, and a termination would lose it.
                checkpointFailure = "“\(currentRoomName)” could not be saved to disk. Finish the level now — this room is only in memory."
            }
            // A map taken right after a room is the best place to resume from.
            spatial.checkpointWorldMap(
                acceptedRoomCount: acceptedRooms.count,
                lastAcceptedRoomID: room.identifier,
                referenceKeyframe: nil,
                minimumInterval: 0)
        }

        pendingRoom = nil
        phase = .ready
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func discardPendingRoom() {
        pendingRoom = nil
        recorder?.record(.roomDiscarded, detail: currentRoomName)
        phase = .ready
    }

    /// Picks up a walk that was interrupted before Finish Level ran (build 15
    /// §3). The rooms are read back from their checkpoints, so what the flow
    /// shows is what is actually on disk — not a count taken on trust. A room
    /// whose file will not decode is reported, never quietly dropped.
    func adoptUnfinished(_ unfinished: UnfinishedScan, projectID: UUID) {
        self.projectID = projectID
        let store = ScanCheckpointStore.shared
        let restored = store.restoreRooms(unfinished.checkpoints, projectID: projectID)
        for (checkpoint, room) in restored.rooms where !checkpointIDs.contains(checkpoint.id) {
            acceptedRooms.append((checkpoint.roomName, room))
            acceptedRoomNames.append(checkpoint.roomName)
            checkpointIDs.insert(checkpoint.id)
            if levelID == nil { levelID = checkpoint.levelID }
        }
        if !restored.failed.isEmpty {
            let names = restored.failed.map(\.roomName).joined(separator: ", ")
            checkpointFailure = "These saved rooms could not be read back: \(names). Their files are still in the project folder."
        }
        // Restoring the map is what lets the rest of the property be scanned
        // into the same coordinate space. Without one, continuing starts a
        // separate space that has to be aligned later — say so rather than
        // merging two frames as if they were one.
        spatial.configure(
            projectID: projectID, levelID: levelID, scanSessionID: recorder?.sessionID,
            mapsDirectory: store.worldMapsDir(projectID))
        if unfinished.worldMapAvailable, spatial.bestCheckpoint != nil {
            phase = .relocalizing
            spatial.beginRelocalization()
        } else {
            phase = .ready
        }
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
    ///
    /// Accepted rooms really are safe now: each was written to disk when it
    /// was accepted. Only the room in progress is lost, and the walk can be
    /// resumed rather than abandoned.
    func handleInterruption() {
        guard phase == .scanning else { return }
        captureView.captureSession.stop(pauseARSession: false)
        sessionActive = false
        recorder?.record(.interrupted, detail: "app inactive")
        // Take a map on the way out; it is what a resume relocalizes against.
        spatial.checkpointWorldMap(
            acceptedRoomCount: acceptedRooms.count,
            lastAcceptedRoomID: acceptedRooms.last?.room.identifier,
            referenceKeyframe: nil,
            minimumInterval: 0)
        phase = .interrupted
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Restores the last world map and waits for ARKit to recognise the
    /// place. Nothing is scanned or merged until it does.
    func resumeAfterInterruption() {
        guard spatial.bestCheckpoint != nil else {
            phase = .failed("No world map was saved, so this walk cannot be resumed in the same coordinate space. Finish with the rooms already saved, or start a separate scan.")
            return
        }
        recorder?.record(.interruptionEnded, detail: "resume requested")
        phase = .relocalizing
        spatial.beginRelocalization()
    }

    /// Called when relocalization settles. Success returns to scanning;
    /// failure never merges — it offers a separate session instead.
    func relocalizationSettled() {
        switch spatial.relocalization {
        case .succeeded:
            recorder?.record(.relocalized, detail: "coordinates verified")
            phase = .ready
        case .failed:
            recorder?.record(.relocalizationFailed, detail: "coordinates could not be verified")
            phase = .failed("Unable to relocalize. The rooms already saved are safe. Scanning more now would start a separate coordinate space that has to be aligned later.")
        default:
            break
        }
    }

    /// Closes the sensor session and hands back its log, coverage map and
    /// mesh. The next room starts a fresh session on the same AR frame.
    func finishRecorder() -> (log: ScanSessionLog, grid: CoverageGrid?, chunks: [MeshChunk])? {
        guard let recorder else { return nil }
        let grid = recorder.coverageGrid
        let chunks = recorder.meshChunks
        let log = recorder.finish()
        self.recorder = nil
        return (log, grid, chunks)
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
    /// Merges the rooms being folded in — which after build 15 come from the
    /// checkpoints on disk, not only from this flow's memory. A failure here
    /// costs the combined USDZ preview and nothing else; the rooms are
    /// already safe and the canonical model is built without it.
    func mergedStructure(_ rooms: [CapturedRoom]) async -> CapturedStructure? {
        guard !rooms.isEmpty else { return nil }
        phase = .merging
        defer { phase = .ready }
        do {
            let builder = StructureBuilder(options: [.beautifyObjects])
            return try await builder.capturedStructure(from: rooms)
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
    /// Where a multi-story capture's rooms ended up, told once before moving on.
    @State private var levelNotice: String? = nil
    @State private var noticeContinuesToReview = false
    @State private var finished = false
    @State private var reviewLevel: LevelGeometry? = nil
    @State private var reviewFindings: [SpaceFinding] = []
    @State private var showReview = false
    /// Rooms left on disk by a walk that never finished (build 15 §3).
    @State private var recovery: UnfinishedScan? = nil

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
        // A room that could not be written to disk is the one failure that
        // must not be silent — the owner has to know before walking away.
        .alert("Room Not Saved", isPresented: .constant(coordinator.checkpointFailure != nil)) {
            Button("OK") { coordinator.checkpointFailure = nil }
        } message: {
            Text(coordinator.checkpointFailure ?? "")
        }
        .sheet(item: $recovery) { unfinished in
            UnfinishedScanSheet(
                project: project,
                unfinished: unfinished,
                onContinue: {
                    recovery = nil
                    coordinator.adoptUnfinished(unfinished, projectID: project.id)
                },
                onFinish: {
                    recovery = nil
                    coordinator.adoptUnfinished(unfinished, projectID: project.id)
                    Task { await finishLevel() }
                },
                onDiscard: {
                    ScanCheckpointStore.shared.discardUnfinished(for: project.id)
                    recovery = nil
                })
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
        case .interrupted:
            interruptedView
        case .relocalizing:
            relocalizingView
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

    // MARK: Interruption and resume (build 15, priorities 1 and 3)

    /// A phone call does not end a property visit. Every accepted room is
    /// already on disk; the only question is whether to carry on in the same
    /// coordinate space or stop here. Nothing is discarded on its own.
    private var interruptedView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.orange)
                Text("Scan Interrupted")
                    .font(.title2.weight(.semibold))
                Text(coordinator.acceptedRoomNames.isEmpty
                     ? "The room in progress was lost. No rooms had been accepted yet."
                     : "\(coordinator.acceptedRoomNames.count) accepted room(s) are saved on this phone. Only the room in progress was lost.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if !coordinator.acceptedRoomNames.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(coordinator.acceptedRoomNames.enumerated()), id: \.offset) { index, name in
                            Label(name.isEmpty ? "Room \(index + 1)" : name,
                                  systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: AppTheme.corner)
                        .fill(Color(.secondarySystemGroupedBackground)))
                    .padding(.horizontal)
                }

                Button {
                    coordinator.resumeAfterInterruption()
                } label: {
                    Label("Continue This Scan", systemImage: "play.fill")
                }
                .buttonStyle(BigButtonStyle())
                .padding(.horizontal)

                if !coordinator.acceptedRooms.isEmpty {
                    Button {
                        Task { await finishLevel() }
                    } label: {
                        Label("Finish With Saved Rooms", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(BigButtonStyle(prominent: false))
                    .disabled(saving)
                    .padding(.horizontal)
                }

                Text("Continuing restores the saved world map first so the remaining rooms land in the same coordinate space. If the phone cannot recognise where it is, nothing is merged — you will be told and offered a separate scan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.vertical, 24)
        }
    }

    private var relocalizingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(coordinator.spatial.relocalization.message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("Walk back to somewhere you already scanned and point the phone at it. Nothing new is captured until the phone knows where it is again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Stop Trying") {
                coordinator.spatial.abandonRelocalization()
                coordinator.phase = .interrupted
            }
            .buttonStyle(BigButtonStyle(prominent: false))
            .padding(.horizontal, 40)
        }
        .onChange(of: coordinator.spatial.relocalization) { _, _ in
            coordinator.relocalizationSettled()
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
        .alert("Levels", isPresented: .constant(levelNotice != nil)) {
            Button("OK") {
                levelNotice = nil
                if noticeContinuesToReview {
                    showReview = true
                } else {
                    finished = true
                }
            }
        } message: {
            Text(levelNotice ?? "")
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
                    if SettingsStore.shared.fieldValidationMode {
                        FieldDiagnosticsPanel(
                            recorder: recorder,
                            spatial: coordinator.spatial,
                            acceptedRooms: coordinator.acceptedRooms.count,
                            checkpointedRooms: coordinator.checkpointIDs.count)
                            .padding(.horizontal, 10)
                    }
                    if let storage = recorder.live.storage, let message = storage.message {
                        Text(message)
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(storage.level == .critical
                                                       ? AnyShapeStyle(Color.red.opacity(0.85))
                                                       : AnyShapeStyle(.ultraThinMaterial)))
                            .foregroundStyle(storage.level == .critical ? Color.white : Color.primary)
                            .padding(.horizontal, 10)
                    }
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
        // Rooms saved by a walk that never reached Finish Level. Offered
        // once, on arrival, and never resolved without an explicit choice.
        if recovery == nil, coordinator.acceptedRooms.isEmpty {
            recovery = ScanCheckpointStore.shared.unfinished(for: project.id)
        }
    }

    /// Persists everything: raw scans, USDZ, the sensor session, converted
    /// geometry with its evidence, positioned photos (spec §8, §10, §17, §21).
    private func finishLevel() async {
        guard let snapshot, let selectedID = selectedLevelID ?? snapshot.levels.first?.id else { return }
        saving = true
        defer { saving = false }

        let store = ProjectStore.shared
        let scansDir = store.scansDir(project.id)

        // 0. Close the sensor session first; its evidence attaches below.
        let session = coordinator.finishRecorder()

        // 1. Which level does each captured room belong on? Rooms group by
        // floor height. The group holding the first room scanned is the
        // level the owner selected; any other group is a story up or down
        // from it — an existing level within reach, or a new one. Heights
        // are kept relative to the selected level, since every scan starts
        // its own frame.
        var current: PlanSnapshot
        do {
            current = try store.loadSnapshot(projectID: project.id, snapshotID: snapshot.id)
        } catch {
            saveError = "Saving the scan failed: \(error.localizedDescription)"
            return
        }
        guard let selectedIndex = current.levels.firstIndex(where: { $0.id == selectedID }) else {
            saveError = "The selected level no longer exists."
            return
        }
        // Rooms come from the checkpoints on disk, not from memory: that way
        // a walk interrupted earlier is folded in too, and a room that was
        // accepted before a termination is never left behind. Each is keyed
        // by its RoomPlan identifier, so a room already merged is skipped and
        // reprocessing cannot duplicate it.
        let checkpointStore = ScanCheckpointStore.shared
        let outstanding = CheckpointStore.outstanding(checkpointStore.checkpoints(for: project.id))
        let restored = checkpointStore.restoreRooms(outstanding, projectID: project.id)
        if !restored.failed.isEmpty {
            let names = restored.failed.map(\.roomName).joined(separator: ", ")
            saveError = "These saved rooms could not be read back and were left untouched: \(names). Their files are still in the project."
        }
        var byIdentifier: [UUID: (name: String, room: CapturedRoom)] = [:]
        for (checkpoint, room) in restored.rooms {
            byIdentifier[checkpoint.id] = (checkpoint.roomName, room)
        }
        // Anything still only in memory (its checkpoint write failed) is
        // included rather than dropped.
        for accepted in coordinator.acceptedRooms where byIdentifier[accepted.room.identifier] == nil {
            byIdentifier[accepted.room.identifier] = (accepted.name, accepted.room)
        }
        guard !byIdentifier.isEmpty else {
            saveError = "There are no captured rooms to save."
            return
        }
        let mergedCheckpointIDs = Set(byIdentifier.keys)
        let dtos = byIdentifier.values.map {
            CapturedRoomBridge.dto(from: $0.room, name: $0.name.isEmpty ? nil : $0.name)
        }
        let groups = LevelAssignment.groupByFloor(dtos)
        let firstRoomID = coordinator.acceptedRooms.first?.room.identifier
        let baseIndex = groups.firstIndex { $0.rooms.contains { $0.id == firstRoomID } } ?? 0
        let baseElevation = groups.isEmpty ? 0 : groups[baseIndex].elevation
        if current.levels[selectedIndex].elevation == nil { current.levels[selectedIndex].elevation = 0 }
        let selectedElevation = current.levels[selectedIndex].elevation ?? 0

        struct Placement {
            var levelID: UUID
            var rooms: [ScannedRoomDTO]
            /// Floor height in the scan's own frame (for its coverage map).
            var scanElevation: Double
            /// Floor height relative to the selected level (stored).
            var levelElevation: Double
            var message: String?
        }
        var placements: [Placement] = []
        for (index, group) in groups.enumerated() {
            let relative = selectedElevation + (group.elevation - baseElevation)
            if index == baseIndex {
                placements.append(Placement(levelID: selectedID, rooms: group.rooms,
                                            scanElevation: group.elevation, levelElevation: relative, message: nil))
                continue
            }
            guard let assignment = LevelAssignment.assign(
                elevation: relative, selectedLevelID: selectedID, levels: current.levels) else { continue }
            if let created = assignment.createdLevel { current.levels.append(created) }
            placements.append(Placement(levelID: assignment.levelID, rooms: group.rooms,
                                        scanElevation: group.elevation, levelElevation: relative,
                                        message: assignment.message))
        }
        var levelOfRoom: [UUID: UUID] = [:]
        for placement in placements {
            for room in placement.rooms { levelOfRoom[room.id] = placement.levelID }
        }

        // 2. The raw capture and USDZ were written when each room was
        // accepted, so nothing is re-encoded here. What is still needed is
        // the catalogue record — inserted only when it is missing, so
        // reprocessing a checkpoint cannot list the same scan twice.
        let existingScanIDs = Set(project.scans.map(\.id))
        for (identifier, entry) in byIdentifier where !existingScanIDs.contains(identifier) {
            let checkpoint = outstanding.first { $0.id == identifier }
            var rawName = checkpoint?.rawDataFileName
            var usdzName = checkpoint?.usdzFileName
            if rawName == nil {
                // Only reached when the checkpoint write failed earlier; this
                // is the last chance to get the capture onto disk.
                do {
                    let data = try CapturedRoomBridge.rawJSON(for: entry.room)
                    let file = "\(identifier.uuidString).json"
                    try data.write(to: scansDir.appendingPathComponent(file), options: .atomic)
                    rawName = file
                } catch {
                    AppLog.scan.error("Raw scan save failed: \(error.localizedDescription)")
                }
                do {
                    let usdz = "\(identifier.uuidString).usdz"
                    try entry.room.export(to: scansDir.appendingPathComponent(usdz), exportOptions: .parametric)
                    usdzName = usdz
                } catch {
                    AppLog.scan.error("USDZ export failed: \(error.localizedDescription)")
                }
            }
            let record = ScanRecord(
                id: identifier, levelID: levelOfRoom[identifier] ?? selectedID,
                roomName: entry.name.isEmpty ? "Auto-labeled room" : entry.name,
                rawDataFileName: rawName, usdzFileName: usdzName,
                sessionID: session?.log.id ?? checkpoint?.scanSessionID)
            record.project = project
            context.insert(record)
        }

        // 3. Merge into a structure for the combined USDZ (best effort).
        if byIdentifier.count > 1 {
            if let structure = await coordinator.mergedStructure(byIdentifier.values.map(\.room)) {
                do {
                    let url = scansDir.appendingPathComponent("structure-\(UUID().uuidString).usdz")
                    try structure.export(to: url, exportOptions: .parametric)
                } catch {
                    AppLog.scan.error("Structure USDZ export failed: \(error.localizedDescription)")
                }
            }
        }

        // 4. Convert each story's rooms to canonical geometry and merge them
        // into their level. Rooms scanned without a name are auto-labeled
        // from RoomPlan's own classification or the fixtures found inside.
        var touched: [LevelGeometry] = []
        var notices: [String] = []
        for placement in placements {
            let conversion = ScanConversion.convert(rooms: placement.rooms)
            for warning in conversion.warnings {
                AppLog.geometry.warning("\(warning, privacy: .public)")
            }
            guard let index = current.levels.firstIndex(where: { $0.id == placement.levelID }) else { continue }
            var level = ScanConversion.merge(conversion, into: current.levels[index])

            // 5. Evidence: coverage, mesh and tracking from the session score
            // every scanned element; the compass places north. The session's
            // own coverage map was built for the floor it started on; another
            // story gets one built for its own floor height.
            if let session {
                let isBase = placement.levelID == selectedID
                let grid: CoverageGrid?
                if isBase {
                    grid = session.grid
                } else if session.chunks.isEmpty {
                    grid = nil
                } else {
                    grid = CoverageGrid.build(chunks: session.chunks, poses: session.log.poses,
                                              floorElevation: placement.scanElevation)
                }
                level = EvidenceAttachment.attach(
                    to: level,
                    grid: grid,
                    chunks: session.chunks,
                    trackingNormalFraction: session.log.summary?.trackingNormalFraction,
                    sessionID: session.log.id)
                level.scanSessionIDs = (level.scanSessionIDs ?? []) + [session.log.id]
                if level.northAngle == nil,
                   let north = NorthEstimator.northAngle(from: session.log.headings) {
                    level.northAngle = north
                }
            }
            if level.elevation == nil { level.elevation = placement.levelElevation }
            current.levels[index] = level
            touched.append(level)
            if let message = placement.message { notices.append(message) }
        }

        do {
            try store.saveSnapshot(current, projectID: project.id)
            // The rooms are now in the canonical model: stamp their
            // checkpoints so a later Finish Level cannot import them again.
            checkpointStore.markMerged(mergedCheckpointIDs, snapshotID: current.id, projectID: project.id)
            if let session, let base = touched.first(where: { $0.id == selectedID }) ?? touched.first {
                store.importSessionPhotos(session.log, project: project, level: base, context: context)
            }
            project.updatedAt = Date()
            if project.status == .lead { project.status = .measured }
            try context.save()
            self.snapshot = current
            coordinator.clearAccepted()

            // 6. Before leaving the property: anything that looks unscanned?
            var pendingReview: (level: LevelGeometry, findings: [SpaceFinding])? = nil
            for level in touched {
                let findings = MissingSpaceDetector.findings(for: level, levels: current.levels)
                if !findings.isEmpty {
                    pendingReview = (level, findings)
                    break
                }
            }
            if let pending = pendingReview {
                reviewLevel = pending.level
                reviewFindings = pending.findings
            }
            if !notices.isEmpty {
                noticeContinuesToReview = pendingReview != nil
                levelNotice = notices.joined(separator: "\n\n")
            } else if pendingReview != nil {
                showReview = true
            } else {
                finished = true
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

// MARK: - Unfinished scan recovery (build 15, priority 3)

/// Shown when a project has rooms on disk from a walk that never reached
/// Finish Level. Three explicit choices, and no default that throws data
/// away: nothing is discarded unless the owner says so.
struct UnfinishedScanSheet: View {
    let project: ProjectRecord
    let unfinished: UnfinishedScan
    let onContinue: () -> Void
    let onFinish: () -> Void
    let onDiscard: () -> Void

    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 50))
                        .foregroundStyle(.orange)
                    Text("Unfinished Scan")
                        .font(.title2.weight(.semibold))
                    Text("\(unfinished.roomCount) room(s) saved")
                        .font(.headline)
                    if let name = unfinished.lastRoomName, let at = unfinished.lastCapturedAt {
                        Text("Last scan: \(name) · \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(unfinished.checkpoints.sorted(by: { $0.capturedAt < $1.capturedAt }), id: \.id) { checkpoint in
                            HStack {
                                Label(checkpoint.roomName, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Spacer()
                                if checkpoint.rawDataFileName == nil {
                                    Text("no raw file")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: AppTheme.corner)
                        .fill(Color(.secondarySystemGroupedBackground)))

                    Button(action: onContinue) {
                        Label("Continue Property Scan", systemImage: "play.fill")
                    }
                    .buttonStyle(BigButtonStyle())

                    Button(action: onFinish) {
                        Label("Finish With Saved Rooms", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(BigButtonStyle(prominent: false))

                    Button(role: .destructive) {
                        confirmDiscard = true
                    } label: {
                        Label("Discard Unfinished Session", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: AppTheme.bigButtonMinHeight)
                    }

                    Text(unfinished.worldMapAvailable
                         ? "A world map was saved, so continuing can put the remaining rooms in the same coordinate space as these ones."
                         : "No world map was saved. Rooms scanned now would be in a separate coordinate space that has to be aligned later — finishing with what is saved is usually the better choice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .confirmationDialog(
                "Discard \(unfinished.roomCount) saved room(s)? This cannot be undone.",
                isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive, action: onDiscard)
                Button("Keep", role: .cancel) {}
            }
        }
    }
}
