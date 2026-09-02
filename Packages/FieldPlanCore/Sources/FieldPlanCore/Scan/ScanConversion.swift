import Foundation

// MARK: - Scan bridging DTOs
//
// The iOS app converts RoomPlan's CapturedRoom/CapturedStructure into these
// plain value types (a mechanical, few-line mapping), and ALL conversion
// logic lives here where it is unit-testable without ARKit. RoomPlan is an
// input source — never the data architecture (spec §11).

public enum ScannedSurfaceKind: String, Codable, Sendable {
    case wall, door, window, opening, floor
}

/// A curved surface's arc, in the surface's local frame (RoomPlan's
/// `CapturedRoom.Surface.Curve`): centre on the local XZ plane, angles in
/// radians.
public struct ScannedCurveDTO: Codable, Hashable, Sendable {
    public var center: Vec2
    public var radius: Double
    public var startAngle: Double
    public var endAngle: Double

    public init(center: Vec2, radius: Double, startAngle: Double, endAngle: Double) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.endAngle = endAngle
    }
}

/// A planar surface from a scan, in world space (meters, +Y up).
public struct ScannedSurfaceDTO: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ScannedSurfaceKind
    /// Surface center in world space.
    public var center: Vec3
    /// World direction of the surface's local X axis (its width direction).
    public var xAxis: Vec3
    /// dimensions: width along xAxis, height along world Y.
    public var width: Double
    public var height: Double
    public var thickness: Double?
    /// Non-rectangular outline in world space when the scanner provides one.
    public var polygonCorners: [Vec3]
    /// 0 = low, 1 = medium, 2 = high.
    public var confidenceLevel: Int
    /// Identifier of the wall hosting this door/window/opening.
    public var parentID: UUID?
    /// Doors only: whether the scanner saw the door open.
    public var isDoorOpen: Bool?
    /// Full local-to-world transform, 16 floats column-major, when bridged.
    public var transform: [Float]?
    /// The arc of a curved wall, when the scanner reported one.
    public var curve: ScannedCurveDTO?
    /// Story index the scanner assigned (0 = the first floor scanned).
    public var story: Int?

    public init(
        id: UUID = UUID(),
        kind: ScannedSurfaceKind,
        center: Vec3,
        xAxis: Vec3,
        width: Double,
        height: Double,
        thickness: Double? = nil,
        polygonCorners: [Vec3] = [],
        confidenceLevel: Int = 1,
        parentID: UUID? = nil,
        isDoorOpen: Bool? = nil,
        transform: [Float]? = nil,
        curve: ScannedCurveDTO? = nil,
        story: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.center = center
        self.xAxis = xAxis
        self.width = width
        self.height = height
        self.thickness = thickness
        self.polygonCorners = polygonCorners
        self.confidenceLevel = confidenceLevel
        self.parentID = parentID
        self.isDoorOpen = isDoorOpen
        self.transform = transform
        self.curve = curve
        self.story = story
    }

    public var captureConfidence: CaptureConfidence {
        switch confidenceLevel {
        case 2: return .high
        case 1: return .medium
        default: return .low
        }
    }
}

/// A recognized object (furniture, appliance, fixture) in world space.
public struct ScannedObjectDTO: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// RoomPlan category raw name, e.g. "bathtub", "refrigerator", "sofa".
    public var categoryName: String
    public var center: Vec3
    public var xAxis: Vec3
    /// Full extents: width (x), height (y), depth (z).
    public var dimensions: Vec3
    public var confidenceLevel: Int
    /// RoomPlan attribute names ("lShaped", "stool", …) when reported.
    public var attributes: [String]
    public var story: Int?
    /// Parent object/surface (a dishwasher's cabinet run, a chair's table).
    public var parentID: UUID?

    public init(
        id: UUID = UUID(),
        categoryName: String,
        center: Vec3,
        xAxis: Vec3,
        dimensions: Vec3,
        confidenceLevel: Int = 1,
        attributes: [String] = [],
        story: Int? = nil,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.categoryName = categoryName
        self.center = center
        self.xAxis = xAxis
        self.dimensions = dimensions
        self.confidenceLevel = confidenceLevel
        self.attributes = attributes
        self.story = story
        self.parentID = parentID
    }
}

/// RoomPlan's own idea of a room inside a capture (`CapturedRoom.Section`):
/// a label with the point it applies to. A continuous walk yields several.
public struct ScannedSectionDTO: Codable, Hashable, Sendable {
    public var label: String
    public var center: Vec3
    public var story: Int

    public init(label: String, center: Vec3, story: Int = 0) {
        self.label = label
        self.center = center
        self.story = story
    }
}

/// One captured room: surfaces + objects, in a shared world space.
public struct ScannedRoomDTO: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var suggestedName: String?
    public var suggestedType: String?
    public var surfaces: [ScannedSurfaceDTO]
    public var objects: [ScannedObjectDTO]
    public var capturedAt: Date
    public var sections: [ScannedSectionDTO]

    public init(
        id: UUID = UUID(),
        suggestedName: String? = nil,
        suggestedType: String? = nil,
        surfaces: [ScannedSurfaceDTO] = [],
        objects: [ScannedObjectDTO] = [],
        capturedAt: Date = Date(),
        sections: [ScannedSectionDTO] = []
    ) {
        self.id = id
        self.suggestedName = suggestedName
        self.suggestedType = suggestedType
        self.surfaces = surfaces
        self.objects = objects
        self.capturedAt = capturedAt
        self.sections = sections
    }
}

/// A room-type hint at a plan point, from a scanner section.
public struct RoomSectionHint: Codable, Hashable, Sendable {
    public var type: RoomType
    public var center: Vec2
    public var story: Int

    public init(type: RoomType, center: Vec2, story: Int = 0) {
        self.type = type
        self.center = center
        self.story = story
    }
}

// MARK: - Conversion

public enum ScanConversion {

    /// Maps a RoomPlan object category raw name to a fixture category.
    public static func fixtureCategory(forObjectNamed name: String) -> FixtureCategory {
        switch name.lowercased() {
        case "bathtub": return .bathtub
        case "toilet": return .toilet
        case "sink": return .sink
        case "shower": return .shower
        case "refrigerator": return .refrigerator
        case "stove": return .stove
        case "oven": return .oven
        case "dishwasher": return .dishwasher
        case "washerdryer": return .washerDryer
        case "fireplace": return .fireplace
        case "stairs": return .stairs
        case "bed": return .bed
        case "sofa": return .sofa
        case "chair": return .chair
        case "table": return .table
        case "storage": return .storage
        case "television": return .television
        default: return .custom
        }
    }

    public static func roomType(forSuggestion suggestion: String?) -> RoomType {
        guard let s = suggestion?.lowercased() else { return .other }
        if s.contains("living") { return .livingRoom }
        if s.contains("dining") { return .diningRoom }
        if s.contains("kitchen") { return .kitchen }
        if s.contains("bath") { return .bathroom }
        if s.contains("bed") { return .bedroom }
        if s.contains("office") { return .office }
        if s.contains("laundry") { return .laundry }
        if s.contains("closet") { return .closet }
        if s.contains("hall") { return .hallway }
        if s.contains("garage") { return .garage }
        if s.contains("stair") { return .stairHall }
        return .other
    }

    /// Automatic room classification from what the scanner recognized inside
    /// the room. Used when neither the user nor the scanner supplied a label,
    /// so every room still arrives named on the plan (CubiCasa-style).
    public static func inferRoomType(objectNames: [String], floorArea: Double? = nil) -> RoomType? {
        let names = Set(objectNames.map { $0.lowercased() })
        // Wet rooms first — their fixtures are unambiguous.
        if names.contains("toilet") || names.contains("bathtub") || names.contains("shower") {
            if let area = floorArea, area < 3.0, !names.contains("bathtub"), !names.contains("shower") {
                return .powderRoom
            }
            return .bathroom
        }
        if names.contains("stove") || names.contains("oven") || names.contains("dishwasher")
            || names.contains("refrigerator") {
            return .kitchen
        }
        if names.contains("washerdryer") { return .laundry }
        if names.contains("bed") { return .bedroom }
        if names.contains("sofa") { return .livingRoom }
        if names.contains("fireplace") || names.contains("television") { return .livingRoom }
        if names.contains("table") && names.contains("chair") { return .diningRoom }
        if names.contains("stairs") { return .stairHall }
        if let area = floorArea, area < 4.0, names.isEmpty || names == ["storage"] {
            return .closet
        }
        return nil
    }

    /// Splits a captured space into the rooms it actually contains.
    ///
    /// RoomPlan merges a continuous walk into ONE captured room: scanning a
    /// living room, hallway, bathroom and kitchen in a single pass arrives as
    /// one 400-sq-ft space, classified from every object at once — which is why
    /// the whole apartment came back labelled "Living Room".
    ///
    /// The rooms are in the geometry, though. The wall graph's interior faces
    /// *are* the enclosed spaces, so each face becomes a room and is typed from
    /// the fixtures standing inside that face: a toilet makes a bathroom, a
    /// range makes a kitchen. Fixtures are reassigned to the room that contains
    /// them so per-room quantities follow.
    ///
    /// Conservative by design: if the walls do not close into more faces than
    /// there are rooms already (a single room, or a scan with gaps), the level
    /// is returned untouched rather than losing rooms to a failed detection.
    public static func splitIntoRooms(
        _ level: LevelGeometry,
        hints: [RoomSectionHint] = [],
        minimumArea: Double = 0.8
    ) -> LevelGeometry {
        // Partitions meet exterior walls mid-span, so the walls have to be cut
        // at those junctions before the graph can see the enclosed spaces.
        let planar = GeometryCleaner.splitAtJunctions(level.walls)
        let faces = WallGraph(walls: planar).interiorFaces(minArea: minimumArea)
        guard faces.count > level.rooms.count else { return level }

        var result = level
        var rooms: [RoomShape] = []
        for face in faces {
            // The face runs along wall centerlines; the room is the space
            // inside the wall faces.
            let interior = GeometryCleaner.interiorPolygon(fromCenterlineLoop: face, walls: planar)
            let contained = level.fixtures.filter { GeometryOps.polygonContains(face, $0.center) }
            let area = GeometryOps.area(interior)
            let fixtureType = inferRoomType(
                objectNames: contained.map { $0.category.rawValue },
                floorArea: area)
            // The scanner's own section label for this face, when it put one
            // inside it.
            let hintType = hints.first { GeometryOps.polygonContains(face, $0.center) }?.type
            let type = resolvedRoomType(fixture: fixtureType, hint: hintType)

            // Walls bounding this face, and the ceiling height they agree on.
            let bounding = level.walls.filter {
                GeometryOps.distanceToPolygonBoundary(face, $0.midpoint) <= $0.thickness / 2 + 0.10
            }
            let heights = bounding.map(\.height).sorted()
            // Carry provenance from whichever scanned room covered this face.
            let origin = level.rooms.first { GeometryOps.polygonContains($0.polygon, GeometryOps.centroid(face)) }

            rooms.append(RoomShape(
                // Empty name: `merge` numbers them once every type is known.
                name: "",
                type: type,
                polygon: interior,
                ceilingHeight: heights.isEmpty ? origin?.ceilingHeight : heights[heights.count / 2],
                ceilingHeightSource: origin?.ceilingHeightSource ?? .lidarScanned,
                wallIDs: bounding.map(\.id),
                sourceScanID: origin?.sourceScanID,
                changeStatus: .existing))
        }

        result.rooms = rooms
        for index in result.fixtures.indices {
            let center = result.fixtures[index].center
            // A fixture against a wall may sit inside the wall's half
            // thickness; the nearest room within that band still owns it.
            result.fixtures[index].roomID = rooms.first { GeometryOps.polygonContains($0.polygon, center) }?.id
                ?? rooms.min { GeometryOps.distanceToPolygonBoundary($0.polygon, center) < GeometryOps.distanceToPolygonBoundary($1.polygon, center) }
                    .flatMap { GeometryOps.distanceToPolygonBoundary($0.polygon, center) <= 0.2 ? $0.id : nil }
        }
        return result
    }

    /// Combines fixture inference with the scanner's section label. A wet room
    /// or kitchen is decided by its fixtures — a toilet is not a guess — while
    /// living, dining and bedroom labels from the scanner beat weak fixture
    /// evidence (a single chair proves nothing).
    static func resolvedRoomType(fixture: RoomType?, hint: RoomType?) -> RoomType {
        switch fixture {
        case .bathroom?, .powderRoom?, .kitchen?, .laundry?:
            return fixture!
        default:
            break
        }
        if let hint, hint != .other { return hint }
        return fixture ?? .other
    }

    /// Next available auto name for a room type: "Bedroom", "Bedroom 2", ….
    public static func autoName(for type: RoomType, avoiding existing: Set<String>) -> String {
        let base = type == .other ? "Room" : type.displayName
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Result of converting one or more scanned rooms into canonical geometry.
    public struct ConversionResult: Sendable {
        public var rooms: [RoomShape] = []
        public var walls: [Wall] = []
        public var fixtures: [FixtureItem] = []
        /// Non-fatal notes about what could not be converted cleanly.
        public var warnings: [String] = []
        /// Scanner section labels, used to type the rooms recovered by
        /// `splitIntoRooms`.
        public var sectionHints: [RoomSectionHint] = []

        public init(rooms: [RoomShape] = [], walls: [Wall] = [], fixtures: [FixtureItem] = [],
                    warnings: [String] = [], sectionHints: [RoomSectionHint] = []) {
            self.rooms = rooms
            self.walls = walls
            self.fixtures = fixtures
            self.warnings = warnings
            self.sectionHints = sectionHints
        }
    }

    /// Converts scanned rooms (single scan or a merged multiroom structure)
    /// into canonical walls, rooms and fixtures in plan coordinates.
    ///
    /// Walls duplicated across rooms (shared partitions captured once per
    /// room) are deduplicated; both rooms then reference the surviving wall.
    public static func convert(rooms scannedRooms: [ScannedRoomDTO]) -> ConversionResult {
        var result = ConversionResult()

        for scanned in scannedRooms {
            let wallSurfaces = scanned.surfaces.filter { $0.kind == .wall }
            let floorSurfaces = scanned.surfaces.filter { $0.kind == .floor }
            let openingSurfaces = scanned.surfaces.filter {
                $0.kind == .door || $0.kind == .window || $0.kind == .opening
            }

            // Floor elevation: bottom of the walls (world Y).
            let floorY: Double = {
                if let f = floorSurfaces.first { return f.center.y }
                let bottoms = wallSurfaces.map { $0.center.y - $0.height / 2 }
                return bottoms.min() ?? 0
            }()

            // Convert walls. A curved wall becomes a chain of segments that
            // follow its arc; its openings attach to the nearest segment.
            var roomWalls: [Wall] = []
            var segmentsBySurface: [UUID: [UUID]] = [:]
            let floorOutline = floorSurfaces.first.map { $0.polygonCorners.map(\.planProjection) } ?? []
            for surface in wallSurfaces {
                guard surface.width > 0.02 else { continue }
                let axisPlan = planDirection(surface.xAxis)
                guard axisPlan.length > 0.5 else {
                    result.warnings.append("Skipped a wall with a vertical width axis.")
                    continue
                }
                let thickness = surface.thickness ?? 0.1143
                let thicknessSource: ThicknessSource = surface.thickness == nil ? .assumed : .measured

                if surface.curve != nil {
                    if let arc = curvedWallSegments(surface, floorOutline: floorOutline) {
                        var ids: [UUID] = []
                        for (index, segment) in arc.enumerated() {
                            let wall = Wall(
                                id: index == 0 ? surface.id : UUID(),
                                start: segment.start,
                                end: segment.end,
                                height: max(surface.height, 0.1),
                                thickness: thickness,
                                openings: [],
                                changeStatus: .existing,
                                source: .lidarScanned,
                                confidence: surface.captureConfidence,
                                sourceScanID: scanned.id,
                                thicknessSource: thicknessSource)
                            roomWalls.append(wall)
                            ids.append(wall.id)
                        }
                        segmentsBySurface[surface.id] = ids
                        continue
                    }
                    result.warnings.append("A curved wall could not be traced from the scanner's arc and was drawn straight.")
                }

                let centerPlan = surface.center.planProjection
                let half = axisPlan * (surface.width / 2)
                let wall = Wall(
                    id: surface.id,
                    start: centerPlan - half,
                    end: centerPlan + half,
                    height: max(surface.height, 0.1),
                    thickness: thickness,
                    openings: [],
                    changeStatus: .existing,
                    source: .lidarScanned,
                    confidence: surface.captureConfidence,
                    sourceScanID: scanned.id,
                    thicknessSource: thicknessSource
                )
                roomWalls.append(wall)
            }

            // Attach doors/windows/openings to their host walls.
            for surface in openingSurfaces {
                let kind: OpeningKind = {
                    switch surface.kind {
                    case .door: return .door
                    case .window: return .window
                    default: return .opening
                    }
                }()

                // Host wall: explicit parent first (nearest segment when the
                // parent was a curve), else nearest wall line.
                var hostIndex: Int? = nil
                let openingPlanCenter = surface.center.planProjection
                if let parentID = surface.parentID {
                    if let segmentIDs = segmentsBySurface[parentID] {
                        var bestDist = Double.greatestFiniteMagnitude
                        for (i, wall) in roomWalls.enumerated() where segmentIDs.contains(wall.id) {
                            let d = GeometryOps.distanceToSegment(openingPlanCenter, wall.start, wall.end)
                            if d < bestDist {
                                bestDist = d
                                hostIndex = i
                            }
                        }
                    } else {
                        hostIndex = roomWalls.firstIndex { $0.id == parentID }
                    }
                }
                if hostIndex == nil {
                    var bestDist = 0.5
                    for (i, wall) in roomWalls.enumerated() {
                        let d = GeometryOps.distanceToSegment(openingPlanCenter, wall.start, wall.end)
                        if d < bestDist {
                            bestDist = d
                            hostIndex = i
                        }
                    }
                }
                guard let host = hostIndex else {
                    result.warnings.append("A \(kind.displayName.lowercased()) could not be matched to a wall.")
                    continue
                }

                let wall = roomWalls[host]
                let along = (openingPlanCenter - wall.start).dot(wall.direction)
                let sill = kind == .window
                    ? max(0, (surface.center.y - surface.height / 2) - floorY)
                    : 0
                let opening = WallOpening(
                    id: surface.id,
                    kind: kind,
                    centerOffset: min(max(along, surface.width / 2), max(surface.width / 2, wall.length - surface.width / 2)),
                    width: min(surface.width, wall.length),
                    height: surface.height,
                    sillHeight: sill,
                    // A scan sees the hole, never the hinges: leaving this nil
                    // lets the plan derive the swing from the rooms around the
                    // door, and a hand-set swing in the editor overrides it.
                    swing: nil,
                    changeStatus: .existing,
                    source: .lidarScanned,
                    confidence: surface.captureConfidence,
                    isOpenAtCapture: kind == .door ? surface.isDoorOpen : nil
                )
                roomWalls[host].openings.append(opening)
                roomWalls[host].openings.sort { $0.centerOffset < $1.centerOffset }
            }

            // Room polygon: floor outline when available, else the wall loop.
            var polygon: [Vec2] = []
            if let floor = floorSurfaces.first, floor.polygonCorners.count >= 3 {
                polygon = GeometryOps.counterClockwise(
                    GeometryOps.simplified(floor.polygonCorners.map(\.planProjection))
                )
            }
            if polygon.count < 3 {
                polygon = GeometryCleaner.loopPolygon(from: roomWalls, tolerance: 0.35) ?? []
            }
            if polygon.count < 3, !roomWalls.isEmpty {
                result.warnings.append("Room boundary for \(scanned.suggestedName ?? "a scanned room") did not close; review in the editor.")
            }

            // Ceiling height from wall heights (median resists outliers).
            let heights = roomWalls.map(\.height).sorted()
            let ceiling = heights.isEmpty ? nil : heights[heights.count / 2]

            // Room classification: the scanner's section nearest the room's
            // centre first, then its overall label, then inference from the
            // fixtures found inside the room.
            var type = roomType(forSuggestion: scanned.suggestedType)
            if polygon.count >= 3, !scanned.sections.isEmpty {
                let centroid = GeometryOps.centroid(polygon)
                if let nearest = scanned.sections.min(by: {
                    $0.center.planProjection.distance(to: centroid) < $1.center.planProjection.distance(to: centroid)
                }) {
                    let sectionType = roomType(forSuggestion: nearest.label)
                    if sectionType != .other { type = sectionType }
                }
            }
            result.sectionHints.append(contentsOf: scanned.sections.map {
                RoomSectionHint(type: roomType(forSuggestion: $0.label),
                                center: $0.center.planProjection, story: $0.story)
            })
            if type == .other {
                let floorArea = polygon.count >= 3 ? GeometryOps.area(polygon) : nil
                type = inferRoomType(
                    objectNames: scanned.objects.map(\.categoryName),
                    floorArea: floorArea
                ) ?? .other
            }

            let room = RoomShape(
                id: scanned.id,
                // Empty name = auto-name during merge, once the level's
                // existing room names are known ("Bedroom 2", "Bathroom"…).
                name: scanned.suggestedName ?? "",
                type: type,
                polygon: polygon,
                ceilingHeight: ceiling,
                ceilingHeightSource: .lidarScanned,
                wallIDs: roomWalls.map(\.id),
                sourceScanID: scanned.id,
                changeStatus: .existing
            )
            result.rooms.append(room)
            result.walls.append(contentsOf: roomWalls)

            // Objects → fixtures. "Storage" is read from its measured box:
            // counter-height and counter-deep is a base cabinet, wall-hung
            // is an upper, anything else stays storage. `floorY` is the
            // room's floor height found above.
            for object in scanned.objects {
                let axisPlan = planDirection(object.xAxis)
                let rotation = axisPlan.length > 0.5 ? axisPlan.angle : 0
                let category = object.categoryName.lowercased() == "storage"
                    ? FixtureCleanup.storageCategory(object, floorY: floorY)
                    : fixtureCategory(forObjectNamed: object.categoryName)
                let fixture = FixtureItem(
                    id: object.id,
                    category: category,
                    label: nil,
                    center: object.center.planProjection,
                    size: Vec2(max(object.dimensions.x, 0.05), max(object.dimensions.z, 0.05)),
                    rotation: rotation,
                    height: object.dimensions.y,
                    roomID: polygon.count >= 3 && GeometryOps.polygonContains(polygon, object.center.planProjection)
                        ? room.id : nil,
                    changeStatus: .existing,
                    source: .lidarScanned,
                    confidence: object.confidenceLevel >= 2 ? .high : (object.confidenceLevel == 1 ? .medium : .low)
                )
                result.fixtures.append(fixture)
            }
        }

        // Faces → walls: partitions seen from both sides become one centerline
        // with a measured thickness; lone faces are offset outward with an
        // assumed one (`WallAssembly`).
        let assembled = WallAssembly.assemble(walls: result.walls, rooms: result.rooms)
        result.walls = assembled.walls
        for r in result.rooms.indices {
            var seen = Set<UUID>()
            result.rooms[r].wallIDs = result.rooms[r].wallIDs
                .map { assembled.replaced[$0] ?? $0 }
                .filter { seen.insert($0).inserted }
        }
        return result
    }

    /// Merges a conversion result into an existing level, keeping previously
    /// captured rooms. Rooms re-scanned (same scan ID) are replaced.
    public static func merge(_ conversion: ConversionResult, into level: LevelGeometry) -> LevelGeometry {
        var result = level
        let newRoomIDs = Set(conversion.rooms.map(\.id))
        // Drop replaced rooms and their walls/fixtures.
        let replacedWallIDs = Set(result.rooms.filter { newRoomIDs.contains($0.id) }.flatMap(\.wallIDs))
        result.rooms.removeAll { newRoomIDs.contains($0.id) }
        result.walls.removeAll { replacedWallIDs.contains($0.id) }
        let newFixtureRoomIDs = newRoomIDs
        result.fixtures.removeAll { f in
            guard let rid = f.roomID else { return false }
            return newFixtureRoomIDs.contains(rid) && f.source == .lidarScanned
        }
        result.rooms.append(contentsOf: conversion.rooms)
        result.walls.append(contentsOf: conversion.walls)
        result.fixtures.append(contentsOf: conversion.fixtures)

        // A single capture usually covers several rooms; recover them from the
        // wall graph so each is typed and named on its own fixtures and the
        // scanner's section labels.
        result = splitIntoRooms(result, hints: conversion.sectionHints)

        // Base cabinets that continue each other become one run; a run with
        // no wall behind it is an island.
        result.fixtures = FixtureCleanup.mergeCabinetRuns(result.fixtures, walls: result.walls)

        // Auto-name rooms captured without a user-entered name, numbering
        // duplicates per level: Bedroom, Bedroom 2, Bathroom, …
        for i in result.rooms.indices where result.rooms[i].name.isEmpty {
            let taken = Set(result.rooms.filter { !$0.name.isEmpty }.map(\.name))
            result.rooms[i].name = autoName(for: result.rooms[i].type, avoiding: taken)
        }
        return result
    }

    // MARK: - Internals

    /// Projects a world direction onto the plan plane (drops Y, flips Z).
    static func planDirection(_ v: Vec3) -> Vec2 {
        Vec2(v.x, -v.z).normalized
    }

    public struct ArcSegment: Hashable, Sendable {
        public var start: Vec2
        public var end: Vec2
    }

    /// Traces a curved wall's arc into plan segments about `segmentLength`
    /// long, or nil when the arc cannot be reconciled with the surface.
    ///
    /// RoomPlan gives the arc's centre on the surface's local XZ plane with
    /// start and end angles; the surface transform maps that to the world.
    /// Two checks guard against a misread convention: the arc's ends must
    /// land near the ends of the surface's own chord, and when the scanner's
    /// floor outline is available it decides which way the wall bulges (the
    /// mirrored arc has the same ends, so the ends alone cannot tell).
    static func curvedWallSegments(
        _ surface: ScannedSurfaceDTO,
        floorOutline: [Vec2],
        segmentLength: Double = 0.4
    ) -> [ArcSegment]? {
        guard let curve = surface.curve, let t = surface.transform, t.count == 16,
              curve.radius > 0.05 else { return nil }
        let sweep = curve.endAngle - curve.startAngle
        guard abs(sweep) > 0.02 else { return nil }

        func world(_ local: Vec3) -> Vec3 {
            Vec3(
                Double(t[0]) * local.x + Double(t[4]) * local.y + Double(t[8]) * local.z + Double(t[12]),
                Double(t[1]) * local.x + Double(t[5]) * local.y + Double(t[9]) * local.z + Double(t[13]),
                Double(t[2]) * local.x + Double(t[6]) * local.y + Double(t[10]) * local.z + Double(t[14]))
        }
        let arcLength = abs(sweep) * curve.radius
        let count = max(2, min(32, Int((arcLength / segmentLength).rounded(.up))))
        var points: [Vec2] = []
        for i in 0...count {
            let angle = curve.startAngle + sweep * Double(i) / Double(count)
            let local = Vec3(curve.center.x + curve.radius * cos(angle), 0,
                             curve.center.y + curve.radius * sin(angle))
            points.append(world(local).planProjection)
        }

        // The arc's ends must be the chord's ends.
        let axisPlan = planDirection(surface.xAxis)
        let centerPlan = surface.center.planProjection
        let half = axisPlan * (surface.width / 2)
        let chordA = centerPlan - half
        let chordB = centerPlan + half
        let tolerance = max(0.5, surface.width * 0.3)
        guard let first = points.first, let last = points.last else { return nil }
        let forward = first.distance(to: chordA) <= tolerance && last.distance(to: chordB) <= tolerance
        let backward = first.distance(to: chordB) <= tolerance && last.distance(to: chordA) <= tolerance
        guard forward || backward else { return nil }

        // Bulge direction from the floor outline when there is one.
        if floorOutline.count >= 6 {
            let mid = points[points.count / 2]
            let chordDir = (chordB - chordA).normalized
            let mirrored = mirror(mid, acrossLineThrough: chordA, direction: chordDir)
            let asIs = GeometryOps.distanceToPolygonBoundary(floorOutline, mid)
            let flipped = GeometryOps.distanceToPolygonBoundary(floorOutline, mirrored)
            if flipped + 0.05 < asIs {
                points = points.map { mirror($0, acrossLineThrough: chordA, direction: chordDir) }
            }
        }
        return zip(points, points.dropFirst()).map { ArcSegment(start: $0, end: $1) }
    }

    static func mirror(_ p: Vec2, acrossLineThrough a: Vec2, direction: Vec2) -> Vec2 {
        let d = p - a
        let along = d.dot(direction)
        let perpendicular = d - direction * along
        return p - perpendicular * 2
    }

    /// Removes duplicate walls that occupy the same span (partitions captured
    /// from both sides). The higher-confidence wall survives; openings from
    /// both are merged onto it and room references are rewritten.
    static func dedupeSharedWalls(_ input: ConversionResult) -> ConversionResult {
        var result = input
        var removed: [UUID: UUID] = [:] // removed wall ID -> surviving wall ID
        var walls = result.walls

        var i = 0
        while i < walls.count {
            var j = i + 1
            while j < walls.count {
                let a = walls[i]
                let b = walls[j]
                let sameSpan =
                    (a.start.distance(to: b.start) < 0.15 && a.end.distance(to: b.end) < 0.15) ||
                    (a.start.distance(to: b.end) < 0.15 && a.end.distance(to: b.start) < 0.15)
                if sameSpan {
                    // Keep the higher-confidence wall; merge openings.
                    let keepFirst = confidenceRank(a.confidence) >= confidenceRank(b.confidence)
                    let keep = keepFirst ? i : j
                    let drop = keepFirst ? j : i
                    var survivor = walls[keep]
                    let dropped = walls[drop]
                    for opening in dropped.openings {
                        let world = dropped.point(atOffset: opening.centerOffset)
                        let along = (world - survivor.start).dot(survivor.direction)
                        let overlapsExisting = survivor.openings.contains { existing in
                            abs(existing.centerOffset - along) < max(existing.width, opening.width) / 2
                        }
                        if !overlapsExisting {
                            var moved = opening
                            moved.centerOffset = min(max(along, moved.width / 2), max(moved.width / 2, survivor.length - moved.width / 2))
                            survivor.openings.append(moved)
                        }
                    }
                    survivor.openings.sort { $0.centerOffset < $1.centerOffset }
                    removed[dropped.id] = survivor.id
                    walls[keep] = survivor
                    walls.remove(at: drop)
                    if drop == i { i -= 1; break } else { continue }
                }
                j += 1
            }
            i += 1
        }

        // Rewrite room wall references to survivors.
        for r in result.rooms.indices {
            result.rooms[r].wallIDs = result.rooms[r].wallIDs.map { removed[$0] ?? $0 }
        }
        result.walls = walls
        return result
    }

    private static func confidenceRank(_ c: CaptureConfidence) -> Int {
        switch c {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}
