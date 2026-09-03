import SwiftUI
import FieldPlanCore

// MARK: - Live scan overlay (spec §5, §6)
//
// What the owner sees while walking: one piece of advice at a time (the most
// urgent), a status strip that says whether tracking, light and LiDAR are
// fine, and a minimap of what has actually been observed — floor and wall
// mesh, the walk so far, and the walls RoomPlan has found so far, coloured by
// how much of each has evidence behind it.

struct ScanLiveOverlay: View {
    @ObservedObject var recorder: ScanRecorder
    let roomName: String
    let wallCount: Int
    let onPhoto: () -> Void

    @State private var minimapExpanded = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ScanStatusStrip(live: recorder.live, roomName: roomName, wallCount: wallCount)
                Spacer(minLength: 0)
                CoverageMinimap(live: recorder.live)
                    .frame(width: minimapExpanded ? 220 : 118, height: minimapExpanded ? 220 : 118)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { minimapExpanded.toggle() } }
                    .accessibilityLabel("Coverage map")
            }
            if let advice = recorder.live.quality.primaryAdvice {
                ScanAdviceChip(advice: advice)
                    .transition(.opacity)
            }
            Spacer()
            HStack {
                Spacer()
                Button(action: onPhoto) {
                    Image(systemName: "camera.fill")
                        .font(.title2)
                        .padding(14)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .accessibilityLabel("Take a positioned photo")
                .overlay(alignment: .topTrailing) {
                    if recorder.live.photoCount > 0 {
                        Text("\(recorder.live.photoCount)")
                            .font(.caption2.weight(.bold))
                            .padding(5)
                            .background(Circle().fill(Color.accentColor))
                            .foregroundStyle(.white)
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.trailing, 14)
            .padding(.bottom, 4)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: recorder.live.quality.primaryAdvice?.kind)
    }
}

struct ScanAdviceChip: View {
    let advice: ScanAdvice

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: advice.priority <= 2 ? "exclamationmark.triangle.fill" : "info.circle.fill")
            Text(advice.message)
                .font(.headline)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(advice.priority <= 2 ? Color.white : Color.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(advice.priority <= 2 ? AnyShapeStyle(Color.red.opacity(0.85)) : AnyShapeStyle(.ultraThinMaterial)))
    }
}

/// Tracking / speed / light / LiDAR at a glance. Green means nothing to do.
struct ScanStatusStrip: View {
    let live: ScanRecorder.LiveStatus
    let roomName: String
    let wallCount: Int

    private var formatter: UnitFormatter { SettingsStore.shared.formatter }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: live.quality.overall))
                    .frame(width: 10, height: 10)
                Text(roomName.isEmpty ? "Scanning" : roomName)
                    .font(.subheadline.weight(.semibold))
                Text("· \(wallCount) walls")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                statusItem("figure.walk", String(format: "%.1f m/s", live.quality.speed),
                           ok: live.quality.speed <= 1.4)
                statusItem("scope", live.quality.tracking.isNormal ? "Tracking" : live.quality.tracking.displayName,
                           ok: live.quality.tracking.isNormal)
                if let light = live.quality.ambientIntensity {
                    statusItem("sun.max", light >= 450 ? "Light OK" : "Dim", ok: light >= 300)
                }
                if live.quality.depthAvailable, let high = live.quality.depthHighFraction {
                    statusItem("sensor", "LiDAR \(Int((high * 100).rounded()))%", ok: high >= 0.55)
                }
            }
            HStack(spacing: 10) {
                Text("\(formatter.area(live.observedFloorArea)) floor seen")
                Text("\(live.meshAnchorCount) mesh")
                Text(elapsedText)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var elapsedText: String {
        let seconds = Int(live.quality.elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func statusItem(_ symbol: String, _ text: String, ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(ok ? Color.primary : Color.orange)
    }

    private func color(for quality: OverallScanQuality) -> Color {
        switch quality {
        case .good: return .green
        case .caution: return .orange
        case .poor: return .red
        }
    }
}

/// Observed floor and wall mesh, the walk, the live walls and the camera.
struct CoverageMinimap: View {
    let live: ScanRecorder.LiveStatus

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                var bounds = Rect2.null
                for c in live.floorCells { bounds.include(c) }
                for c in live.wallCells { bounds.include(c) }
                for p in live.path { bounds.include(p) }
                for w in live.liveWalls {
                    bounds.include(w.start)
                    bounds.include(w.end)
                }
                if let p = live.position { bounds.include(p) }
                guard !bounds.isNull else { return }
                bounds = bounds.expanded(by: 0.6)
                let transform = PlanViewTransform.fitting(bounds: bounds, in: size, padding: 6)
                let cell = CGFloat(0.25) * transform.scale

                func rect(_ center: Vec2) -> CGRect {
                    let p = transform.toView(center)
                    return CGRect(x: p.x - cell / 2, y: p.y - cell / 2, width: cell, height: cell)
                }
                for c in live.floorCells {
                    context.fill(Path(rect(c)), with: .color(Color.green.opacity(0.35)))
                }
                for c in live.wallCells {
                    context.fill(Path(rect(c)), with: .color(Color.primary.opacity(0.55)))
                }
                for wall in live.liveWalls {
                    var path = Path()
                    path.move(to: transform.toView(wall.start))
                    path.addLine(to: transform.toView(wall.end))
                    let coverage = live.wallCoverage[wall.id] ?? 1
                    let color: Color = coverage >= 0.6 ? .green : (coverage >= 0.3 ? .orange : .red)
                    context.stroke(path, with: .color(color), lineWidth: 2.5)
                }
                if live.path.count >= 2 {
                    var path = Path()
                    path.move(to: transform.toView(live.path[0]))
                    for p in live.path.dropFirst() { path.addLine(to: transform.toView(p)) }
                    context.stroke(path, with: .color(Color.accentColor.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                }
                if let position = live.position {
                    let p = transform.toView(position)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                                 with: .color(.accentColor))
                    if let heading = live.heading {
                        let tip = transform.toView(position + Vec2(cos(heading), sin(heading)) * 0.6)
                        var path = Path()
                        path.move(to: p)
                        path.addLine(to: tip)
                        context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Post-scan review (spec §15)

/// Shown after a level is saved when the detector found space that looks
/// unscanned: the plan with the suspect areas hatched, the list of findings,
/// and the choice to keep scanning or accept the plan as it is.
struct ScanReviewSheet: View {
    let level: LevelGeometry
    let findings: [SpaceFinding]
    let onScanMore: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PlanCanvasView(scene: scene)
                    .frame(maxHeight: 320)
                List {
                    Section {
                        ForEach(findings) { finding in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(finding.kind.displayName, systemImage: symbol(for: finding.kind))
                                    .font(.subheadline.weight(.semibold))
                                Text(finding.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Possible unscanned space")
                    } footer: {
                        Text("These come from the geometry, not from the camera having looked somewhere: enclosed areas no room explains, doorways that lead nowhere, room edges with no wall behind them. Walk them now if they are real rooms.")
                    }
                }
            }
            .navigationTitle("Scan Review")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(action: onScanMore) {
                        Label("Scan More", systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(BigButtonStyle())
                    Button(action: onDone) {
                        Label("Use As Is", systemImage: "checkmark")
                    }
                    .buttonStyle(BigButtonStyle(prominent: false))
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private var scene: PlanScene {
        var options = PlanGenerator.Options()
        options.findings = findings
        options.formatter = SettingsStore.shared.formatter
        return PlanGenerator.scene(for: level, options: options)
    }

    private func symbol(for kind: SpaceFinding.Kind) -> String {
        switch kind {
        case .doorwayToUnscannedSpace: return "door.left.hand.open"
        case .footprintVoid: return "square.dashed"
        case .openRoomEdge: return "rectangle.dashed"
        case .stairsToUnscannedLevel: return "stairs"
        }
    }
}

// MARK: - Field diagnostics (build 15, priority 6)
//
// In validation mode the walk is an experiment, so the numbers behind it are
// on screen rather than in a log: tracking, mapping, depth, mesh, what has
// been checkpointed, and how much recording time the phone has left. If
// something is going wrong it should be obvious at the property, not
// discovered at home.

struct FieldDiagnosticsPanel: View {
    @ObservedObject var recorder: ScanRecorder
    @ObservedObject var spatial: SpatialSession
    let acceptedRooms: Int
    let checkpointedRooms: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("FIELD DIAGNOSTICS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(recorder.sessionID.uuidString.prefix(8))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            row("Tracking", recorder.live.quality.tracking.displayName,
                ok: recorder.live.quality.tracking.isNormal)
            row("World map", mappingText, ok: spatial.mappingState == .mapped)
            row("Depth", depthText, ok: recorder.live.quality.depthAvailable)
            row("Mesh anchors", "\(recorder.live.meshAnchorCount)", ok: recorder.live.meshAnchorCount > 0)
            row("Poses / keyframes", "\(recorder.live.keyframeCount) kf", ok: recorder.live.keyframeCount > 0)
            row("Rooms saved to disk", "\(checkpointedRooms) of \(acceptedRooms)",
                ok: checkpointedRooms >= acceptedRooms)
            row("World map saved", spatial.bestCheckpoint == nil ? "None yet" : "Yes",
                ok: spatial.bestCheckpoint != nil)
            if spatial.coordinatesDiverged {
                Text("Coordinates could not be verified after relocalizing — a later scan would not line up.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if let storage = recorder.live.storage {
                row("Recording left", storageText(storage), ok: storage.level == .ok)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var mappingText: String {
        switch spatial.mappingState {
        case .mapped: return "Mapped"
        case .extending: return "Extending"
        case .limited: return "Limited"
        case .notAvailable: return "Not available"
        }
    }

    private var depthText: String {
        guard recorder.live.quality.depthAvailable else { return "No LiDAR frames" }
        guard let high = recorder.live.quality.depthHighFraction else { return "On" }
        return "\(Int((high * 100).rounded()))% high confidence"
    }

    private func storageText(_ storage: StorageEstimate) -> String {
        guard let minutes = storage.remainingMinutes else {
            return String(format: "%.1f GB free", Double(storage.freeBytes) / 1_000_000_000)
        }
        return "≈\(minutes) min"
    }

    private func row(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(ok ? Color.primary : Color.orange)
        }
        .font(.caption2.monospacedDigit())
    }
}
