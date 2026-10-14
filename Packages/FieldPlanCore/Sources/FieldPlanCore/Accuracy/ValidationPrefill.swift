import Foundation

// MARK: - Tap an element, type one number (build 15, priority 8)
//
// Collecting hundreds of samples only works if the phone fills in everything
// it already knows. Tapping a wall should leave exactly one thing to enter:
// what the laser said. Everything else — which room, which method produced
// which number, what evidence the element carried — is pulled from the model
// here, so the field workflow is one tap and one number.

public enum ValidationPrefill {

    /// What can be ground-truthed on a tapped element.
    public enum Target: Hashable, Sendable {
        case wall(UUID)
        case opening(wallID: UUID, openingID: UUID)
        case room(UUID)
        case fixture(UUID)
    }

    /// One offered measurement: the kind, a label, and every method's answer.
    public struct Option: Hashable, Identifiable, Sendable {
        /// One option per measurement of one element, which is exactly what
        /// the suggested key names — so it identifies the row in a list.
        public var id: String { suggestedPhysicalKey }

        public var kind: AccuracyMeasureKind
        public var label: String
        public var measurements: CompetingMeasurements
        public var evidence: SampleEvidence
        public var elementID: UUID?
        public var roomID: UUID?
        public var roomName: String
        /// The sensor session the element was captured in, when the evidence
        /// recorded one — so a sample can be traced back to the walk that
        /// produced it without the owner typing anything.
        public var scanSessionID: UUID?
        /// A stable name for the same real element across rescans, offered as
        /// the default link so repeatability can be computed without the
        /// owner inventing a key each time.
        public var suggestedPhysicalKey: String
    }

    /// Everything measurable about the tapped element, in the order a person
    /// would work through it.
    public static func options(
        for target: Target,
        in level: LevelGeometry,
        formatter: UnitFormatter = UnitFormatter()
    ) -> [Option] {
        switch target {
        case .wall(let id):
            guard let wall = level.wall(withID: id) else { return [] }
            return wallOptions(wall, in: level)
        case .opening(let wallID, let openingID):
            guard let wall = level.wall(withID: wallID),
                  let opening = wall.openings.first(where: { $0.id == openingID })
            else { return [] }
            return openingOptions(opening, on: wall, in: level)
        case .room(let id):
            guard let room = level.room(withID: id) else { return [] }
            return roomOptions(room, in: level)
        case .fixture(let id):
            guard let fixture = level.fixtures.first(where: { $0.id == id }) else { return [] }
            return fixtureOptions(fixture, in: level)
        }
    }

    // MARK: Walls

    static func wallOptions(_ wall: Wall, in level: LevelGeometry) -> [Option] {
        let room = level.rooms.first { $0.wallIDs.contains(wall.id) }
        let roomName = room?.name ?? ""
        let evidence = sampleEvidence(from: wall.evidence, thickness: wall.thicknessSource)
        let key = physicalKey(roomName, "wall", wall.id)

        // The mesh fit lives on the wall's evidence as the alternate
        // measurement — it was never allowed to replace the primary value,
        // which is exactly why it can be compared here.
        var lengths = CompetingMeasurements(
            canonical: wall.length,
            roomPlan: wall.source == .lidarScanned ? (wall.originalLength ?? wall.length) : nil,
            originalScanned: wall.originalLength,
            userEdited: wall.source == .edited ? wall.length : nil)
        if let alternate = wall.evidence?.alternate {
            lengths.meshFit = alternate.value
            lengths.meshResidual = alternate.residual
            lengths.meshInlierCount = alternate.sampleCount
        }

        var options = [Option(
            kind: .wallLength,
            label: roomName.isEmpty ? "Wall" : "\(roomName) wall",
            measurements: lengths,
            evidence: evidence,
            elementID: wall.id,
            roomID: room?.id,
            roomName: roomName,
            scanSessionID: wall.evidence?.sessionID ?? wall.sourceScanID,
            suggestedPhysicalKey: key)]

        // Thickness is only worth offering where the app claims to know it.
        if wall.thicknessSource != nil {
            options.append(Option(
                kind: .wallThickness,
                label: roomName.isEmpty ? "Wall thickness" : "\(roomName) wall thickness",
                measurements: CompetingMeasurements(canonical: wall.thickness),
                evidence: evidence,
                elementID: wall.id,
                roomID: room?.id,
                roomName: roomName,
                scanSessionID: wall.evidence?.sessionID ?? wall.sourceScanID,
                suggestedPhysicalKey: key + "-thickness"))
        }
        return options
    }

    // MARK: Openings

    static func openingOptions(_ opening: WallOpening, on wall: Wall, in level: LevelGeometry) -> [Option] {
        let room = level.rooms.first { $0.wallIDs.contains(wall.id) }
        let roomName = room?.name ?? ""
        let evidence = sampleEvidence(from: opening.evidence, thickness: nil)
        let base = physicalKey(roomName, opening.kind.rawValue, opening.id)
        let name = roomName.isEmpty ? opening.kind.displayName : "\(roomName) \(opening.kind.displayName.lowercased())"

        func option(_ kind: AccuracyMeasureKind, _ suffix: String, _ value: Double) -> Option {
            Option(kind: kind,
                   label: "\(name) \(suffix)",
                   measurements: CompetingMeasurements(canonical: value),
                   evidence: evidence,
                   elementID: opening.id,
                   roomID: room?.id,
                   roomName: roomName,
                   scanSessionID: opening.evidence?.sessionID ?? wall.evidence?.sessionID,
                   suggestedPhysicalKey: "\(base)-\(suffix)")
        }

        switch opening.kind {
        case .door:
            return [option(.doorWidth, "width", opening.width),
                    option(.doorHeight, "height", opening.height)]
        case .window:
            return [option(.windowWidth, "width", opening.width),
                    option(.windowHeight, "height", opening.height),
                    option(.windowSillHeight, "sill height", opening.sillHeight)]
        case .opening:
            return [option(.doorWidth, "width", opening.width),
                    option(.openingHeight, "height", opening.height)]
        }
    }

    // MARK: Rooms

    static func roomOptions(_ room: RoomShape, in level: LevelGeometry) -> [Option] {
        let evidence = sampleEvidence(from: room.evidence, thickness: nil)
        let key = physicalKey(room.name, "room", room.id)
        var options: [Option] = []

        if let extents = GeometryOps.orientedExtents(room.polygon) {
            options.append(Option(
                kind: .roomWidth, label: "\(room.name) width",
                measurements: CompetingMeasurements(canonical: extents.width),
                evidence: evidence, elementID: room.id, roomID: room.id,
                roomName: room.name, scanSessionID: room.evidence?.sessionID ?? room.sourceScanID,
                suggestedPhysicalKey: key + "-width"))
            options.append(Option(
                kind: .roomDepth, label: "\(room.name) depth",
                measurements: CompetingMeasurements(canonical: extents.depth),
                evidence: evidence, elementID: room.id, roomID: room.id,
                roomName: room.name, scanSessionID: room.evidence?.sessionID ?? room.sourceScanID,
                suggestedPhysicalKey: key + "-depth"))
        }
        options.append(Option(
            kind: .roomArea, label: "\(room.name) floor area",
            measurements: CompetingMeasurements(canonical: room.floorArea),
            evidence: evidence, elementID: room.id, roomID: room.id,
            roomName: room.name, suggestedPhysicalKey: key + "-area"))
        if let ceiling = room.ceilingHeight {
            options.append(Option(
                kind: .ceilingHeight, label: "\(room.name) ceiling height",
                measurements: CompetingMeasurements(canonical: ceiling),
                evidence: evidence, elementID: room.id, roomID: room.id,
                roomName: room.name, scanSessionID: room.evidence?.sessionID ?? room.sourceScanID,
                suggestedPhysicalKey: key + "-ceiling"))
        }
        return options
    }

    // MARK: Fixtures

    static func fixtureOptions(_ fixture: FixtureItem, in level: LevelGeometry) -> [Option] {
        guard fixture.category == .stairs else { return [] }
        let room = fixture.roomID.flatMap { id in level.rooms.first { $0.id == id } }
        let roomName = room?.name ?? ""
        let evidence = sampleEvidence(from: fixture.evidence, thickness: nil)
        let key = physicalKey(roomName, "stairs", fixture.id)
        let width = min(fixture.size.x, fixture.size.y)
        let run = max(fixture.size.x, fixture.size.y)
        return [
            Option(kind: .stairWidth, label: "Stair width",
                   measurements: CompetingMeasurements(canonical: width),
                   evidence: evidence, elementID: fixture.id, roomID: room?.id,
                   roomName: roomName, scanSessionID: fixture.evidence?.sessionID,
                   suggestedPhysicalKey: key + "-width"),
            Option(kind: .stairTreadDepth, label: "Stair total run",
                   measurements: CompetingMeasurements(canonical: run),
                   evidence: evidence, elementID: fixture.id, roomID: room?.id,
                   roomName: roomName, scanSessionID: fixture.evidence?.sessionID,
                   suggestedPhysicalKey: key + "-run"),
        ]
    }

    // MARK: Helpers

    static func sampleEvidence(from evidence: ElementEvidence?, thickness: ThicknessSource?) -> SampleEvidence {
        SampleEvidence(
            confidence: evidence?.confidence,
            coverage: evidence?.coverage,
            captureConfidence: evidence?.scannerConfidence,
            trackingQuality: evidence?.trackingQuality,
            observationCount: evidence?.observationCount,
            thicknessSource: thickness)
    }

    /// A readable, stable-ish key: the room and element kind plus a short id.
    /// Offered as a default the owner can replace with their own name when
    /// linking a rescan to the same physical wall.
    static func physicalKey(_ roomName: String, _ kind: String, _ id: UUID) -> String {
        let room = roomName.isEmpty ? "unassigned" : roomName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "\(room)-\(kind)-\(id.uuidString.prefix(4).lowercased())"
    }

    /// Builds the sample once the laser value is typed. Nothing about the
    /// plan changes — the sample is evidence recorded beside it.
    public static func sample(
        from option: Option,
        groundTruth: Double,
        method: GroundTruthMethod,
        note: String,
        validationSessionID: UUID,
        scanSessionID: UUID? = nil,
        levelID: UUID?,
        levelName: String,
        physicalElementKey: String?
    ) -> ValidationSample {
        ValidationSample(
            validationSessionID: validationSessionID,
            scanSessionID: scanSessionID ?? option.scanSessionID,
            levelID: levelID,
            levelName: levelName,
            roomID: option.roomID,
            roomName: option.roomName,
            elementID: option.elementID,
            kind: option.kind,
            elementLabel: option.label,
            measurements: option.measurements,
            groundTruth: groundTruth,
            method: method,
            note: note,
            evidence: option.evidence,
            physicalElementKey: (physicalElementKey?.isEmpty == false)
                ? physicalElementKey
                : option.suggestedPhysicalKey)
    }
}
