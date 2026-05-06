//
//  WaterBodyCoordinates.swift
//  SkeenaSystem
//
//  Global water body atlas — polygon geofence data for bays, sounds, canals, etc.
//  Add new water bodies here as they're onboarded; never remove existing entries.
//  The active set for each app instance is controlled by LODGE_WATER_BODIES in xcconfig.
//
//  Polygons are simplified (~15–30 vertices) and ordered clockwise.
//  Close each polygon by connecting the last point back to the first.
//

import CoreLocation

/// Central atlas of water body polygon data keyed by name (e.g. "Puget Sound").
/// WaterBodyLocator reads from this atlas, filtered by the community's config.
nonisolated enum WaterBodyAtlas {

    /// Recommended check order: more specific/smaller areas first, then larger.
    /// This prevents a point in Hood Canal from matching "Puget Sound" first.
    static let checkOrder: [String] = [
        "Hood Canal",
        "Puget Sound",
        "Lake Washington",
        "Lake of the Woods",
        // Add new entries here in specificity order (most specific first)
    ]

    /// Master dictionary: key = water body name (must match LODGE_WATER_BODIES in xcconfig),
    /// value = clockwise polygon vertices.
    static let all: [String: [CLLocationCoordinate2D]] = [

        // ─────────────────────────────────────────────
        // Washington State — Puget Sound Region
        // ─────────────────────────────────────────────

        "Puget Sound": [
            // Simplified outer boundary, clockwise from NW
            // --- North (Admiralty Inlet / Possession Sound) ---
            CLLocationCoordinate2D(latitude: 48.170, longitude: -122.760),  // Point Wilson, Port Townsend
            CLLocationCoordinate2D(latitude: 48.160, longitude: -122.680),  // Admiralty Head, Whidbey
            CLLocationCoordinate2D(latitude: 48.030, longitude: -122.550),  // Double Bluff, Whidbey S
            CLLocationCoordinate2D(latitude: 47.905, longitude: -122.384),  // Possession Point, Whidbey S tip
            // --- East shore (going south) ---
            CLLocationCoordinate2D(latitude: 47.977, longitude: -122.224),  // Everett waterfront
            CLLocationCoordinate2D(latitude: 47.948, longitude: -122.305),  // Mukilteo
            CLLocationCoordinate2D(latitude: 47.811, longitude: -122.383),  // Edmonds
            CLLocationCoordinate2D(latitude: 47.694, longitude: -122.400),  // Shilshole Bay
            CLLocationCoordinate2D(latitude: 47.625, longitude: -122.387),  // Magnolia Bluff
            CLLocationCoordinate2D(latitude: 47.605, longitude: -122.338),  // Seattle waterfront / Pier 91
            CLLocationCoordinate2D(latitude: 47.576, longitude: -122.352),  // Harbor Island
            CLLocationCoordinate2D(latitude: 47.570, longitude: -122.421),  // Alki Point
            CLLocationCoordinate2D(latitude: 47.530, longitude: -122.400),  // Lincoln Park
            CLLocationCoordinate2D(latitude: 47.461, longitude: -122.383),  // Three Tree Point
            CLLocationCoordinate2D(latitude: 47.388, longitude: -122.370),  // Dash Point area
            CLLocationCoordinate2D(latitude: 47.310, longitude: -122.395),  // Federal Way shoreline
            CLLocationCoordinate2D(latitude: 47.285, longitude: -122.422),  // Tacoma, Commencement Bay
            // --- South (Tacoma Narrows) ---
            CLLocationCoordinate2D(latitude: 47.270, longitude: -122.548),  // Tacoma Narrows east
            CLLocationCoordinate2D(latitude: 47.270, longitude: -122.560),  // Tacoma Narrows west
            // --- West shore (going north) ---
            CLLocationCoordinate2D(latitude: 47.305, longitude: -122.533),  // Point Defiance
            CLLocationCoordinate2D(latitude: 47.335, longitude: -122.582),  // Gig Harbor area
            CLLocationCoordinate2D(latitude: 47.430, longitude: -122.555),  // Olalla
            CLLocationCoordinate2D(latitude: 47.530, longitude: -122.540),  // Manchester
            CLLocationCoordinate2D(latitude: 47.563, longitude: -122.625),  // Bremerton
            CLLocationCoordinate2D(latitude: 47.650, longitude: -122.573),  // Brownsville
            CLLocationCoordinate2D(latitude: 47.700, longitude: -122.560),  // Agate Passage area
            CLLocationCoordinate2D(latitude: 47.730, longitude: -122.553),  // Suquamish
            CLLocationCoordinate2D(latitude: 47.796, longitude: -122.497),  // Kingston
            CLLocationCoordinate2D(latitude: 47.912, longitude: -122.527),  // Point No Point
            CLLocationCoordinate2D(latitude: 47.930, longitude: -122.620),  // Foulweather Bluff
            CLLocationCoordinate2D(latitude: 48.030, longitude: -122.760),  // Marrowstone Point area
        ],

        "Hood Canal": [
            // East shore south, then west shore north, clockwise
            // --- North entrance ---
            CLLocationCoordinate2D(latitude: 47.930, longitude: -122.620),  // Foulweather Bluff (east side)
            CLLocationCoordinate2D(latitude: 47.910, longitude: -122.660),  // Tala Point (west side)
            // --- West shore (Olympic/Jefferson side, going south) ---
            CLLocationCoordinate2D(latitude: 47.850, longitude: -122.700),  // Shine area
            CLLocationCoordinate2D(latitude: 47.760, longitude: -122.755),  // Coyle
            CLLocationCoordinate2D(latitude: 47.660, longitude: -122.850),  // Pleasant Harbor
            CLLocationCoordinate2D(latitude: 47.560, longitude: -122.900),  // Eldon
            CLLocationCoordinate2D(latitude: 47.480, longitude: -122.940),  // Lilliwaup
            CLLocationCoordinate2D(latitude: 47.410, longitude: -122.960),  // Hoodsport
            CLLocationCoordinate2D(latitude: 47.365, longitude: -122.930),  // Potlatch area
            CLLocationCoordinate2D(latitude: 47.340, longitude: -122.880),  // Union / Great Bend south
            // --- Hook (turning east/northeast toward Belfair) ---
            CLLocationCoordinate2D(latitude: 47.370, longitude: -122.830),  // Lynch Cove
            CLLocationCoordinate2D(latitude: 47.427, longitude: -122.795),  // Belfair (south tip of hook)
            // --- East shore (Kitsap side, going north) ---
            CLLocationCoordinate2D(latitude: 47.445, longitude: -122.860),  // Dewatto
            CLLocationCoordinate2D(latitude: 47.530, longitude: -122.870),  // Holly
            CLLocationCoordinate2D(latitude: 47.630, longitude: -122.830),  // Seabeck
            CLLocationCoordinate2D(latitude: 47.748, longitude: -122.727),  // Bangor (NOAA station)
            CLLocationCoordinate2D(latitude: 47.820, longitude: -122.680),  // Lofall
            CLLocationCoordinate2D(latitude: 47.890, longitude: -122.640),  // Vinland
            CLLocationCoordinate2D(latitude: 47.928, longitude: -122.618),  // Near Foulweather Bluff
        ],

        // ─────────────────────────────────────────────
        // Add new water bodies below this line.
        // Key must match the name in LODGE_WATER_BODIES xcconfig.
        // ─────────────────────────────────────────────

        "Lake Washington": [
            // Large freshwater lake east of Seattle, WA. Clockwise from the
            // north end (Kenmore), down the east shore, south end (Renton),
            // back up the west shore (Seward Park, Madison Park, Sand Point).
            // NOTE: Mercer Island sits inside this polygon — not cut out; the
            // simplified outline treats the island as part of the lake extent,
            // consistent with the Puget Sound / Hood Canal simplifications.
            // --- North end (Kenmore / Sammamish River mouth) ---
            CLLocationCoordinate2D(latitude: 47.760, longitude: -122.245),  // Kenmore, Sammamish River mouth
            CLLocationCoordinate2D(latitude: 47.745, longitude: -122.230),  // Arrowhead Point / Inglewood, interpolated
            // --- East shore (going south) ---
            CLLocationCoordinate2D(latitude: 47.705, longitude: -122.215),  // Juanita Bay, Kirkland
            CLLocationCoordinate2D(latitude: 47.676, longitude: -122.208),  // Kirkland waterfront / Marina Park
            CLLocationCoordinate2D(latitude: 47.646, longitude: -122.215),  // Yarrow Point
            CLLocationCoordinate2D(latitude: 47.618, longitude: -122.225),  // Medina waterfront
            CLLocationCoordinate2D(latitude: 47.612, longitude: -122.202),  // Meydenbauer Bay, Bellevue
            CLLocationCoordinate2D(latitude: 47.589, longitude: -122.200),  // Enatai / I-90 east approach
            CLLocationCoordinate2D(latitude: 47.558, longitude: -122.195),  // Newcastle Beach / Coal Creek, interpolated
            CLLocationCoordinate2D(latitude: 47.535, longitude: -122.198),  // Newport Shores area, interpolated
            // --- South end (Renton / Cedar River mouth) ---
            CLLocationCoordinate2D(latitude: 47.509, longitude: -122.206),  // Gene Coulon Park, Renton
            CLLocationCoordinate2D(latitude: 47.502, longitude: -122.217),  // Cedar River mouth, Renton (south tip)
            // --- West shore (going north) ---
            CLLocationCoordinate2D(latitude: 47.525, longitude: -122.270),  // Rainier Beach / Pritchard Island, interpolated
            CLLocationCoordinate2D(latitude: 47.552, longitude: -122.248),  // Seward Park tip (Bailey Peninsula)
            CLLocationCoordinate2D(latitude: 47.560, longitude: -122.265),  // Andrews Bay / Lakewood, interpolated
            CLLocationCoordinate2D(latitude: 47.601, longitude: -122.285),  // Leschi waterfront
            CLLocationCoordinate2D(latitude: 47.636, longitude: -122.280),  // Madison Park
            CLLocationCoordinate2D(latitude: 47.656, longitude: -122.272),  // Webster Point / Union Bay entrance
            CLLocationCoordinate2D(latitude: 47.683, longitude: -122.250),  // Sand Point / Magnuson Park
            CLLocationCoordinate2D(latitude: 47.698, longitude: -122.270),  // Matthews Beach, interpolated
            CLLocationCoordinate2D(latitude: 47.735, longitude: -122.278),  // Lake Forest Park waterfront
            CLLocationCoordinate2D(latitude: 47.759, longitude: -122.260),  // Kenmore west shore, closing polygon
        ],

        // ─────────────────────────────────────────────
        // Ontario / Manitoba / Minnesota — Lake of the Woods
        // ─────────────────────────────────────────────

        "Lake of the Woods": [
            // Large international freshwater lake straddling ON / MB / MN.
            // Clockwise from Kenora (N) → ON east shore S → MN south shore W →
            // MB west shore N → wraps Northwest Angle (MN exclave) → back to Kenora.
            // The Northwest Angle peninsula sits inside the polygon (not cut out),
            // matching the simplification used for Mercer Island in Lake Washington.
            // --- North end (Kenora area, Ontario) ---
            CLLocationCoordinate2D(latitude: 49.767, longitude: -94.483),  // Kenora waterfront, ON (WSC 05PE016)
            CLLocationCoordinate2D(latitude: 49.730, longitude: -94.420),  // Devil's Gap / Winnipeg River outlet, interpolated
            // --- East shore, Ontario (going south) ---
            CLLocationCoordinate2D(latitude: 49.580, longitude: -94.250),  // Yellow Girl Bay area, interpolated
            CLLocationCoordinate2D(latitude: 49.413, longitude: -94.098),  // Sioux Narrows Bridge, ON
            CLLocationCoordinate2D(latitude: 49.131, longitude: -93.927),  // Nestor Falls, ON
            CLLocationCoordinate2D(latitude: 49.080, longitude: -94.270),  // Morson / Big Island area, ON, interpolated
            CLLocationCoordinate2D(latitude: 48.720, longitude: -94.450),  // Rainy River, ON (south end of east shore, near border)
            // --- South shore (Minnesota, going west) ---
            CLLocationCoordinate2D(latitude: 48.712, longitude: -94.600),  // Baudette, MN (Rainy River inflow)
            CLLocationCoordinate2D(latitude: 48.730, longitude: -94.800),  // Pine Island / Bostic Bay, interpolated
            CLLocationCoordinate2D(latitude: 48.700, longitude: -95.000),  // Big Traverse Bay south shore, interpolated
            CLLocationCoordinate2D(latitude: 48.770, longitude: -95.150),  // Garden Island area, interpolated
            CLLocationCoordinate2D(latitude: 48.905, longitude: -95.315),  // Warroad waterfront, MN (USGS 05140520)
            // --- West shore (Manitoba, going north) ---
            CLLocationCoordinate2D(latitude: 48.950, longitude: -95.300),  // Springsteel Island vicinity, interpolated
            CLLocationCoordinate2D(latitude: 49.000, longitude: -95.300),  // 49th-parallel border crossing, interpolated
            CLLocationCoordinate2D(latitude: 49.001, longitude: -95.233),  // Buffalo Point First Nation, MB
            CLLocationCoordinate2D(latitude: 49.100, longitude: -95.250),  // Buffalo Bay west shore, MB, interpolated
            CLLocationCoordinate2D(latitude: 49.250, longitude: -95.250),  // MB west shore, interpolated
            // --- Northwest Angle wrap (lake bulges around the MN exclave) ---
            CLLocationCoordinate2D(latitude: 49.390, longitude: -95.150),  // NW corner of lake (northernmost extent)
            CLLocationCoordinate2D(latitude: 49.350, longitude: -95.050),  // Angle Inlet, MN (NW Angle)
            CLLocationCoordinate2D(latitude: 49.250, longitude: -94.950),  // East side of NW Angle bulge, interpolated
            // --- North shore back toward Kenora ---
            CLLocationCoordinate2D(latitude: 49.500, longitude: -94.800),  // Shoal Lake / Clearwater Bay area, ON, interpolated
            CLLocationCoordinate2D(latitude: 49.700, longitude: -94.650),  // Kenora west approach, interpolated
            CLLocationCoordinate2D(latitude: 49.770, longitude: -94.555),  // Keewatin, ON
            CLLocationCoordinate2D(latitude: 49.770, longitude: -94.500),  // Closing point near Kenora
        ],
    ]
}
