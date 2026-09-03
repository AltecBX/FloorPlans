import Foundation

// MARK: - Measurement QA engine (spec §29)
//
// Inspects a level's geometry and reports findings. The engine NEVER mutates
// geometry — it only reports. Fix-ups are explicit user actions in the editor.

public enum QASeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case pass
    case review
    case fail

    public var displayName: String {
        switch self {
        case .pass: return "Passed"
        case .review: return "Review"
        case .fail: return "Failed"
        }
    }

    private var rank: Int {
        switch self {
        case .pass: return 0
        case .review: return 1
        case .fail: return 2
        }
    }

    public static func < (a: QASeverity, b: QASeverity) -> Bool { a.rank < b.rank }
}

public enum QACode: String, Codable, CaseIterable, Sendable {
    case unclosedRoomBoundary
    case endpointGap
    case disconnectedWalls
    case overlappingWalls
    case duplicateWalls
    case openingWiderThanWall
    case openingOutsideWall
    case windowAboveWall
    case missingCeilingHeight
    case tinyWall
    case suspiciousDimension
    case roomPolygonInvalid
    case selfIntersectingRoom
    case invalidArea
    case noRooms
    case noWalls

    public var displayName: String {
        switch self {
        case .unclosedRoomBoundary: return "Unclosed Room Boundary"
        case .endpointGap: return "Wall Endpoint Gap"
        case .disconnectedWalls: return "Disconnected Walls"
        case .overlappingWalls: return "Overlapping Walls"
        case .duplicateWalls: return "Duplicate Walls"
        case .openingWiderThanWall: return "Opening Wider Than Wall"
        case .openingOutsideWall: return "Opening Outside Wall"
        case .windowAboveWall: return "Window Exceeds Wall Height"
        case .missingCeilingHeight: return "Missing Ceiling Height"
        case .tinyWall: return "Suspiciously Short Wall"
        case .suspiciousDimension: return "Suspicious Dimension"
        case .roomPolygonInvalid: return "Room Polygon Invalid"
        case .selfIntersectingRoom: return "Self-Intersecting Room"
        case .invalidArea: return "Invalid Calculated Area"
        case .noRooms: return "No Rooms Defined"
        case .noWalls: return "No Walls Captured"
        }
    }
}

public struct QAFinding: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var code: QACode
    public var severity: QASeverity
    public var message: String
    public var levelID: UUID?
    public var elementID: UUID?
    public var location: Vec2?

    public init(
        id: UUID = UUID(),
        code: QACode,
        severity: QASeverity,
        message: String,
        levelID: UUID? = nil,
        elementID: UUID? = nil,
        location: Vec2? = nil
    ) {
        self.id = id
        self.code = code
        self.severity = severity
        self.message = message
        self.levelID = levelID
        self.elementID = elementID
        self.location = location
    }
}

public enum QAEngine {

    public struct Thresholds: Sendable {
        public var endpointGapReview: Double = 0.03   // 3 cm
        public var endpointGapFail: Double = 0.15     // 15 cm
        public var tinyWallLength: Double = 0.10      // 10 cm
        public var maxWallLength: Double = 30.0       // 30 m
        public var maxRoomArea: Double = 500.0        // m²
        public var minRoomArea: Double = 0.5          // m²
        public var minCeilingHeight: Double = 1.2
        public var maxCeilingHeight: Double = 7.0

        public init() {}
    }

    /// Evaluates a level and returns all findings, worst first.
    public static func evaluate(
        level: LevelGeometry,
        thresholds: Thresholds = Thresholds()
    ) -> [QAFinding] {
        var findings: [QAFinding] = []
        let formatter = UnitFormatter()
        let walls = level.walls

        func add(_ code: QACode, _ severity: QASeverity, _ message: String,
                 element: UUID? = nil, location: Vec2? = nil) {
            findings.append(QAFinding(
                code: code, severity: severity, message: message,
                levelID: level.id, elementID: element, location: location
            ))
        }

        if walls.isEmpty && level.rooms.isEmpty {
            add(.noWalls, .review, "No walls or rooms captured on \(level.name) yet.")
            return findings
        }
        if level.rooms.isEmpty {
            add(.noRooms, .review, "\(level.name) has walls but no room boundaries.")
        }

        // Wall-level checks.
        for wall in walls {
            let length = wall.length
            if length < thresholds.tinyWallLength {
                add(.tinyWall, .review,
                    "Wall is only \(formatter.length(length)) long — possible scan noise.",
                    element: wall.id, location: wall.midpoint)
            }
            if length > thresholds.maxWallLength {
                add(.suspiciousDimension, .review,
                    "Wall length \(formatter.length(length)) is unusually large.",
                    element: wall.id, location: wall.midpoint)
            }
            if wall.height < thresholds.minCeilingHeight || wall.height > thresholds.maxCeilingHeight {
                add(.suspiciousDimension, .review,
                    "Wall height \(formatter.length(wall.height)) is outside the expected range.",
                    element: wall.id, location: wall.midpoint)
            }

            for opening in wall.openings {
                if opening.width > length + 0.01 {
                    add(.openingWiderThanWall, .fail,
                        "\(opening.kind.displayName) is \(formatter.length(opening.width)) wide but its wall is only \(formatter.length(length)).",
                        element: opening.id, location: wall.point(atOffset: opening.centerOffset))
                } else if opening.startOffset < -0.01 || opening.endOffset > length + 0.01 {
                    add(.openingOutsideWall, .fail,
                        "\(opening.kind.displayName) extends past the end of its wall.",
                        element: opening.id, location: wall.point(atOffset: min(max(opening.centerOffset, 0), length)))
                }
                if opening.sillHeight + opening.height > wall.height + 0.01 {
                    add(.windowAboveWall, .review,
                        "\(opening.kind.displayName) height plus sill exceeds the wall height.",
                        element: opening.id)
                }
            }
        }

        // Graph-level checks.
        if walls.count >= 2 {
            let graph = WallGraph(walls: walls, tolerance: thresholds.endpointGapFail)

            // Endpoint gaps: free ends that are close-but-not-touching another
            // wall's endpoint (within fail distance but beyond review distance).
            let fineGraph = WallGraph(walls: walls, tolerance: thresholds.endpointGapReview)
            for node in fineGraph.nodes where node.degree == 1 {
                let (wi, isStart) = node.attachments[0]
                let p = isStart ? walls[wi].start : walls[wi].end
                // Distance to the nearest OTHER endpoint.
                var nearest = Double.greatestFiniteMagnitude
                for (j, other) in walls.enumerated() where j != wi {
                    nearest = min(nearest, other.start.distance(to: p))
                    nearest = min(nearest, other.end.distance(to: p))
                    nearest = min(nearest, GeometryOps.distanceToSegment(p, other.start, other.end))
                }
                if nearest > thresholds.endpointGapReview && nearest <= thresholds.endpointGapFail {
                    add(.endpointGap, .review,
                        "Wall end has a \(formatter.length(nearest)) gap to the nearest wall.",
                        element: walls[wi].id, location: p)
                }
            }

            let components = graph.connectedComponents()
            if components.count > 1 {
                // More than one island of walls; smaller islands are suspect
                // unless they are legitimately separate (e.g. a column).
                let sorted = components.sorted { $0.count > $1.count }
                for island in sorted.dropFirst() where island.count <= 2 {
                    let wallID = walls[island[0]].id
                    add(.disconnectedWalls, .review,
                        "\(island.count) wall(s) are not connected to the rest of the plan.",
                        element: wallID, location: walls[island[0]].midpoint)
                }
            }

            for (i, j) in graph.overlappingPairs() {
                let a = walls[i]
                let b = walls[j]
                let sameSpan = a.start.distance(to: b.start) < 0.1 && a.end.distance(to: b.end) < 0.1
                    || a.start.distance(to: b.end) < 0.1 && a.end.distance(to: b.start) < 0.1
                if sameSpan {
                    add(.duplicateWalls, .review,
                        "Two walls occupy the same span — likely a duplicate capture.",
                        element: b.id, location: b.midpoint)
                } else {
                    add(.overlappingWalls, .review,
                        "Two walls overlap along their length.",
                        element: b.id, location: b.midpoint)
                }
            }
        }

        // Room-level checks.
        for room in level.rooms {
            if room.polygon.count < 3 {
                add(.roomPolygonInvalid, .fail,
                    "\(room.name) has no valid boundary polygon.",
                    element: room.id)
                continue
            }
            if GeometryOps.polygonSelfIntersects(room.polygon) {
                add(.selfIntersectingRoom, .fail,
                    "\(room.name) boundary crosses itself.",
                    element: room.id, location: room.labelPoint)
            }
            let area = room.floorArea
            if area < thresholds.minRoomArea {
                add(.invalidArea, .review,
                    "\(room.name) area is only \(formatter.area(area)).",
                    element: room.id, location: room.labelPoint)
            } else if area > thresholds.maxRoomArea {
                add(.invalidArea, .review,
                    "\(room.name) area of \(formatter.area(area)) is unusually large.",
                    element: room.id, location: room.labelPoint)
            }
            if room.ceilingHeight == nil && level.walls(for: room).isEmpty {
                add(.missingCeilingHeight, .review,
                    "\(room.name) has no ceiling height.",
                    element: room.id, location: room.labelPoint)
            }
        }

        return findings.sorted { $0.severity > $1.severity }
    }

    /// Evaluates every level of a snapshot.
    public static func evaluate(snapshot: PlanSnapshot) -> [QAFinding] {
        snapshot.levels.flatMap { evaluate(level: $0) }
    }

    public static func overallStatus(_ findings: [QAFinding]) -> QASeverity {
        findings.map(\.severity).max() ?? .pass
    }
}
