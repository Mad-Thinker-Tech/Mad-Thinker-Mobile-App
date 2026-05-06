//
//  WaterBodyLocator.swift
//  SkeenaSystem
//
//  Polygon-based GPS lookup for water bodies (bays, sounds, canals).
//  Complements RiverLocator (which handles linear river spines).
//
//  When both a water body polygon and a river spine match, the closer
//  feature wins (compared by distance in km). See CatchPhotoAnalyzer.
//

import Foundation
import CoreLocation

/// A water body definition with its geofence polygon.
nonisolated struct WaterBodyDefinition: Sendable {
    let name: String
    let polygon: [CLLocationCoordinate2D]
}

/// Locates the user's position within known water body polygons.
///
/// The dataset is built dynamically from `WaterBodyAtlas.all`, filtered to only
/// include water bodies listed in `AppEnvironment.shared.lodgeWaterBodies`.
/// Check order follows `WaterBodyAtlas.checkOrder` (most specific first).
/// `nonisolated` so the upload pipeline can call `waterBodyName(at:)`
/// synchronously. Reads `CommunityService` via `activeCommunityConfigSnapshot`,
/// which is backed by a Sendable `CurrentValueSubject`.
nonisolated final class WaterBodyLocator: @unchecked Sendable {

    static let shared = WaterBodyLocator()

    /// Water bodies active for the current community, ordered by specificity.
    /// Recomputed each access so it reacts to community switches.
    private var waterBodies: [WaterBodyDefinition] {
        let configured = Set(CommunityService.shared.activeCommunityConfigSnapshot.resolvedLodgeWaterBodies)

        var bodies: [WaterBodyDefinition] = []

        // Build list in check order (most specific first), filtered to configured bodies
        for name in WaterBodyAtlas.checkOrder {
            guard configured.contains(name),
                  let polygon = WaterBodyAtlas.all[name],
                  polygon.count >= 3 else { continue }
            bodies.append(WaterBodyDefinition(name: name, polygon: polygon))
        }

        // Add any configured bodies not in checkOrder (append at end)
        for name in CommunityService.shared.activeCommunityConfigSnapshot.resolvedLodgeWaterBodies {
            guard !bodies.contains(where: { $0.name == name }),
                  let polygon = WaterBodyAtlas.all[name],
                  polygon.count >= 3 else { continue }
            bodies.append(WaterBodyDefinition(name: name, polygon: polygon))
        }

        return bodies
    }

    private init() {}

    // MARK: - Public API

    /// Returns true if any water bodies are configured.
    var hasWaterBodies: Bool { !waterBodies.isEmpty }

    /// Returns the name of the water body containing the given location, or nil.
    /// Checks more specific/smaller bodies first (per WaterBodyAtlas.checkOrder).
    func waterBodyName(at location: CLLocation?) -> String? {
        waterBodyMatch(at: location)?.name
    }

    /// Returns the matching water body and the distance (km) from the point to
    /// the nearest polygon edge. A larger distance means the point is deeper
    /// inside the water body — useful for tiebreaking against river spine matches.
    func waterBodyMatch(at location: CLLocation?) -> (name: String, distanceKm: Double)? {
        guard let location else {
            AppLogging.log("[WaterBodyLocator] location is nil, returning nil", level: .debug, category: .ml)
            return nil
        }

        let point = location.coordinate
        AppLogging.log("[WaterBodyLocator] Checking point (\(point.latitude), \(point.longitude)) against \(waterBodies.count) water bodies", level: .debug, category: .ml)
        for body in waterBodies {
            let result = Self.pointInPolygon(point: point, polygon: body.polygon)
            AppLogging.log("[WaterBodyLocator] '\(body.name)' polygon (\(body.polygon.count) vertices): pointInPolygon = \(result)", level: .debug, category: .ml)
            if result {
                let distKm = Self.distanceToNearestEdgeKm(point: point, polygon: body.polygon, from: location)
                AppLogging.log("[WaterBodyLocator] Matched '\(body.name)', distance to edge: \(String(format: "%.2f", distKm)) km", level: .debug, category: .ml)
                return (name: body.name, distanceKm: distKm)
            }
        }
        AppLogging.log("[WaterBodyLocator] No water body matched", level: .debug, category: .ml)
        return nil
    }

    // MARK: - Ray-casting point-in-polygon

    /// Epsilon for boundary tolerance (~11 metres of latitude/longitude).
    private static let epsilon: Double = 0.0001

    /// Ray-casting with boundary tolerance. Points exactly on a vertex or edge
    /// can produce incorrect results with pure ray-casting, so we also check
    /// proximity to every edge of the polygon.
    static func pointInPolygon(
        point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }

        // 1. Standard ray-casting
        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]

            if (pi.longitude > point.longitude) != (pj.longitude > point.longitude) {
                let intersectLat = pi.latitude
                    + (point.longitude - pi.longitude)
                    / (pj.longitude - pi.longitude)
                    * (pj.latitude - pi.latitude)

                if point.latitude < intersectLat {
                    inside.toggle()
                }
            }
            j = i
        }

        if inside { return true }

        // 2. Boundary tolerance — treat points within epsilon of any edge as inside
        j = polygon.count - 1
        for i in 0..<polygon.count {
            if distanceToSegment(point: point, a: polygon[j], b: polygon[i]) < epsilon {
                return true
            }
            j = i
        }

        return false
    }

    /// Minimum real-world distance (km) from a point to the nearest polygon edge.
    /// Uses coordinate-space projection to find the closest point on each edge,
    /// then measures real-world distance via CLLocation.
    private static func distanceToNearestEdgeKm(
        point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D],
        from location: CLLocation
    ) -> Double {
        var minKm = Double.greatestFiniteMagnitude
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let nearest = nearestPointOnSegment(point: point, a: polygon[j], b: polygon[i])
            let edgeLoc = CLLocation(latitude: nearest.latitude, longitude: nearest.longitude)
            let km = location.distance(from: edgeLoc) / 1000.0
            if km < minKm { minKm = km }
            j = i
        }
        return minKm
    }

    /// Returns the closest coordinate on segment a→b to the given point.
    private static func nearestPointOnSegment(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        let lengthSq = dx * dx + dy * dy

        if lengthSq < 1e-15 { return a }

        let t = max(0, min(1,
            ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / lengthSq
        ))
        return CLLocationCoordinate2D(
            latitude: a.latitude + t * dy,
            longitude: a.longitude + t * dx
        )
    }

    /// Minimum distance from a point to a line segment (in coordinate space).
    private static func distanceToSegment(
        point: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Double {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        let lengthSq = dx * dx + dy * dy

        // Degenerate segment (a == b): just return distance to the vertex
        if lengthSq < 1e-15 {
            let px = point.longitude - a.longitude
            let py = point.latitude - a.latitude
            return (px * px + py * py).squareRoot()
        }

        // Project point onto the line, clamped to [0,1]
        let t = max(0, min(1,
            ((point.longitude - a.longitude) * dx + (point.latitude - a.latitude) * dy) / lengthSq
        ))

        let projLon = a.longitude + t * dx
        let projLat = a.latitude + t * dy

        let ex = point.longitude - projLon
        let ey = point.latitude - projLat
        return (ex * ex + ey * ey).squareRoot()
    }
}
