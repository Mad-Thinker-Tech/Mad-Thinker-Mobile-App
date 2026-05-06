//
//  RiverCoordinates.swift
//  SkeenaSystem
//
//  Global river atlas — GPS spine data for all communities.
//  Add new rivers here as they're onboarded; never remove existing entries.
//  The active set for each app instance is controlled by LODGE_RIVERS in xcconfig.
//

import CoreLocation

/// Central atlas of river GPS spine data keyed by full river name (e.g. "Nehalem River").
/// RiverLocator reads from this atlas, filtered by the community's `lodgeRivers` config.
nonisolated enum RiverAtlas {

    /// Master dictionary: key = full river name (must match LODGE_RIVERS in xcconfig),
    /// value = ordered array of spine coordinates from mouth → headwaters.
    static let all: [String: [CLLocationCoordinate2D]] = [

        // ─────────────────────────────────────────────
        // Oregon Coast — Tillamook / Bend Fly Shop
        // ─────────────────────────────────────────────

        "Nehalem River": [
            // Mile 0 — Nehalem Bay mouth at the Pacific coast
            CLLocationCoordinate2D(latitude: 45.6580, longitude: -123.9348),
            // Mile 5 — Near Wheeler / Hwy 101 bridge
            CLLocationCoordinate2D(latitude: 45.7010, longitude: -123.8860),
            // Mile 10 — Between Mohler and Nehalem Falls (upper tidal zone)
            CLLocationCoordinate2D(latitude: 45.7150, longitude: -123.8300),
            // Mile 15 — Nehalem Falls area
            CLLocationCoordinate2D(latitude: 45.7267, longitude: -123.7719),
            // Mile 20 — Near Salmonberry River confluence
            CLLocationCoordinate2D(latitude: 45.7450, longitude: -123.7000),
            // Mile 25 — Between Salmonberry and Spruce Run
            CLLocationCoordinate2D(latitude: 45.7750, longitude: -123.6500),
            // Mile 30 — Near Henry Rierson Spruce Run Campground
            CLLocationCoordinate2D(latitude: 45.8126, longitude: -123.6117),
            // Mile 35 — Between Spruce Run and Grand Rapids
            CLLocationCoordinate2D(latitude: 45.8550, longitude: -123.5600),
            // Mile 40 — Approaching Grand Rapids (near Hwy 26/103)
            CLLocationCoordinate2D(latitude: 45.8900, longitude: -123.5150),
            // Mile 45 — Grand Rapids
            CLLocationCoordinate2D(latitude: 45.9010, longitude: -123.5040),
        ],

        "Wilson River": [
            // Mile 0 — Mouth at Tillamook Bay
            CLLocationCoordinate2D(latitude: 45.4790, longitude: -123.8901),
            // Mile 5 — Sollie Smith Boat Launch area, lower river
            CLLocationCoordinate2D(latitude: 45.4775, longitude: -123.8075),
            // Mile 10 — USGS gauge / Mills Bridge area (Hwy 6)
            CLLocationCoordinate2D(latitude: 45.4760, longitude: -123.7250),
            // Mile 15 — Mid-river, entering Tillamook State Forest
            CLLocationCoordinate2D(latitude: 45.4900, longitude: -123.6500),
            // Mile 20 — Jones Creek Campground area (Hwy 6 MP 22)
            CLLocationCoordinate2D(latitude: 45.5500, longitude: -123.5800),
            // Mile 25 — Elk Creek Campground / Wilson River Trail
            CLLocationCoordinate2D(latitude: 45.5900, longitude: -123.5100),
            // Mile 30 — Upper river, approaching headwaters
            CLLocationCoordinate2D(latitude: 45.6090, longitude: -123.4670),
        ],

        "Trask River": [
            // Mile 0 — Mouth at Tillamook Bay (near Memaloose Point)
            CLLocationCoordinate2D(latitude: 45.4704, longitude: -123.8826),
            // Mile 5 — Between Steiner and Loren's Drift launches
            CLLocationCoordinate2D(latitude: 45.4310, longitude: -123.8000),
            // Mile 10 — USGS gauge above Cedar Creek
            CLLocationCoordinate2D(latitude: 45.4462, longitude: -123.7104),
            // Mile 15 — Upper main stem, approaching fork confluence
            CLLocationCoordinate2D(latitude: 45.4420, longitude: -123.6400),
            // Mile 18 — North Fork / South Fork confluence
            CLLocationCoordinate2D(latitude: 45.4398, longitude: -123.6115),
            // Mile 25 — North Fork, mid-reach in Tillamook State Forest
            CLLocationCoordinate2D(latitude: 45.4600, longitude: -123.5500),
            // Mile 30 — North Fork, upper forest
            CLLocationCoordinate2D(latitude: 45.4800, longitude: -123.5000),
            // Mile 35 — North Fork headwaters area
            CLLocationCoordinate2D(latitude: 45.5000, longitude: -123.4500),
        ],

        "Nestucca River": [
            // Mile 0 — Mouth at Nestucca Bay (Pacific City)
            CLLocationCoordinate2D(latitude: 45.1843, longitude: -123.9573),
            // Mile 5 — Lower river, above Pacific City
            CLLocationCoordinate2D(latitude: 45.2100, longitude: -123.9400),
            // Mile 10 — Three Rivers / Hebo area (near Hwy 101)
            CLLocationCoordinate2D(latitude: 45.2350, longitude: -123.8750),
            // Mile 15 — Between Hebo and Beaver
            CLLocationCoordinate2D(latitude: 45.2550, longitude: -123.8400),
            // Mile 20 — Beaver / Bixby Boat Launch area
            CLLocationCoordinate2D(latitude: 45.2730, longitude: -123.8340),
            // Mile 25 — Upstream of Beaver, BLM Nestucca Backcountry Byway
            CLLocationCoordinate2D(latitude: 45.2900, longitude: -123.7800),
            // Mile 30 — Blaine area, mid-river
            CLLocationCoordinate2D(latitude: 45.3000, longitude: -123.7200),
            // Mile 35 — Upper Nestucca, National Forest land
            CLLocationCoordinate2D(latitude: 45.3050, longitude: -123.6500),
            // Mile 40 — Approaching Yamhill County line
            CLLocationCoordinate2D(latitude: 45.3100, longitude: -123.5800),
            // Mile 45 — Upper river valley
            CLLocationCoordinate2D(latitude: 45.3180, longitude: -123.5100),
            // Mile 50 — Near USGS gauge / McMinnville headwaters area
            CLLocationCoordinate2D(latitude: 45.3248, longitude: -123.4512),
        ],

        "Kilchis River": [
            // Mile 0 — Mouth at Tillamook Bay (Idaville)
            CLLocationCoordinate2D(latitude: 45.4962, longitude: -123.8648),
            // Mile 5 — Mapes Creek / Logger Bridge area
            CLLocationCoordinate2D(latitude: 45.5200, longitude: -123.8280),
            // Mile 10 — Kilchis River County Campground
            CLLocationCoordinate2D(latitude: 45.5390, longitude: -123.7840),
            // Mile 15 — Upper river, North/South Fork confluence area
            CLLocationCoordinate2D(latitude: 45.5550, longitude: -123.7500),
        ],

        // ─────────────────────────────────────────────
        // Add new community rivers below this line.
        // Key must match the full name in LODGE_RIVERS xcconfig
        // (e.g. "Hoh River", "Bogachiel River").
        // ─────────────────────────────────────────────

        "Hoh River": [
            // Mile 0 — River mouth at Pacific Ocean, Hoh Indian Reservation (Verified — GNIS)
            CLLocationCoordinate2D(latitude: 47.7494, longitude: -124.4401),
            // Mile 5 — Lower Hoh valley, between USGS Mile 4.3 and Mile 8.9 stations (Interpolated)
            CLLocationCoordinate2D(latitude: 47.7399, longitude: -124.3598),
            // Mile 10 — Lower-middle Hoh valley, downstream of US Highway 101 (Interpolated)
            CLLocationCoordinate2D(latitude: 47.7698, longitude: -124.3044),
            // Mile 15 — Near US Highway 101 bridge crossing (Verified — USGS 12041200)
            CLLocationCoordinate2D(latitude: 47.8069, longitude: -124.2497),
            // Mile 20 — Middle Hoh valley, near Willoughby Creek confluence (Verified — USGS 12041100)
            CLLocationCoordinate2D(latitude: 47.8217, longitude: -124.1941),
            // Mile 25 — Upper-middle Hoh valley (Interpolated)
            CLLocationCoordinate2D(latitude: 47.8121, longitude: -124.1131),
            // Mile 30 — Near South Fork Hoh confluence, approaching Olympic NP boundary (Interpolated)
            CLLocationCoordinate2D(latitude: 47.8155, longitude: -124.0480),
            // Mile 35 — Olympic National Park, Hoh Rain Forest, above South Fork (Interpolated)
            CLLocationCoordinate2D(latitude: 47.8444, longitude: -123.9551),
            // Mile 40 — Hoh Rain Forest, above Visitor Center area (Interpolated)
            CLLocationCoordinate2D(latitude: 47.8460, longitude: -123.8892),
            // Mile 45 — Upper Hoh valley, approaching Olympus Guard Station (Interpolated)
            CLLocationCoordinate2D(latitude: 47.8279, longitude: -123.8355),
            // Mile 50 — Upper Hoh valley, approaching Glacier Meadows (Interpolated)
            CLLocationCoordinate2D(latitude: 47.8098, longitude: -123.7818),
            // Mile 55 — Near Hoh Glacier terminus, headwaters on Mount Olympus (Interpolated)
            CLLocationCoordinate2D(latitude: 47.7918, longitude: -123.7280),
        ],

        "Sauk River": [
            // Mile 0 — Mouth at Skagit River confluence, Rockport (V — GNIS)
            CLLocationCoordinate2D(latitude: 48.4850, longitude: -121.5920),
            // Mile 5 — Lower Sauk, south of Rockport
            CLLocationCoordinate2D(latitude: 48.4500, longitude: -121.5750),
            // Mile 10 — Near USGS 12189500 gauge (V)
            CLLocationCoordinate2D(latitude: 48.4246, longitude: -121.5685),
            // Mile 15 — Between Sauk and Darrington
            CLLocationCoordinate2D(latitude: 48.3700, longitude: -121.5750),
            // Mile 20 — Approaching Darrington
            CLLocationCoordinate2D(latitude: 48.3100, longitude: -121.5900),
            // Mile 25 — Near Darrington (V — town GPS)
            CLLocationCoordinate2D(latitude: 48.2540, longitude: -121.6020),
            // Mile 30 — South of Darrington, above White Chuck River confluence
            CLLocationCoordinate2D(latitude: 48.2000, longitude: -121.5200),
            // Mile 35 — Near USGS 12186000, above Whitechuck River (V)
            CLLocationCoordinate2D(latitude: 48.1687, longitude: -121.4707),
            // Mile 40 — Between Whitechuck and forks
            CLLocationCoordinate2D(latitude: 48.1200, longitude: -121.4100),
            // Mile 45 — Near North/South Fork confluence, headwaters area (V — GNIS)
            CLLocationCoordinate2D(latitude: 48.0900, longitude: -121.3800),
        ],

        "Skykomish River": [
            // Mile 0 — Mouth at Snoqualmie River confluence, Monroe (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.8554, longitude: -121.9690),
            // Mile 5 — Between Monroe and Sultan
            CLLocationCoordinate2D(latitude: 47.8580, longitude: -121.9000),
            // Mile 10 — Near Sultan (V — town GPS)
            CLLocationCoordinate2D(latitude: 47.8620, longitude: -121.8130),
            // Mile 15 — Between Sultan and Gold Bar
            CLLocationCoordinate2D(latitude: 47.8500, longitude: -121.7400),
            // Mile 20 — Near Gold Bar, USGS 12134500 (V)
            CLLocationCoordinate2D(latitude: 47.8375, longitude: -121.6656),
            // Mile 25 — Between Gold Bar and Index
            CLLocationCoordinate2D(latitude: 47.8280, longitude: -121.5900),
            // Mile 30 — Near Index, North/South Fork confluence (V — town GPS)
            CLLocationCoordinate2D(latitude: 47.8200, longitude: -121.5600),
            // Mile 35 — South Fork, between Index and Skykomish
            CLLocationCoordinate2D(latitude: 47.7900, longitude: -121.4800),
            // Mile 40 — Between Index and Skykomish town
            CLLocationCoordinate2D(latitude: 47.7500, longitude: -121.4000),
            // Mile 45 — Near Skykomish town (V — town GPS)
            CLLocationCoordinate2D(latitude: 47.7100, longitude: -121.3500),
            // Mile 50 — Tye River, Deception Falls area
            CLLocationCoordinate2D(latitude: 47.7180, longitude: -121.2400),
            // Mile 55 — Upper Tye River valley
            CLLocationCoordinate2D(latitude: 47.7300, longitude: -121.1500),
            // Mile 60 — Near Stevens Pass, headwaters (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.7470, longitude: -121.0890),
        ],

        "Green River": [
            // Mile 0 — Duwamish River mouth at Elliott Bay, Seattle (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.5650, longitude: -122.3450),
            // Mile 5 — Lower Duwamish Waterway
            CLLocationCoordinate2D(latitude: 47.5350, longitude: -122.3250),
            // Mile 10 — Tukwila area, Green/Duwamish name transition
            CLLocationCoordinate2D(latitude: 47.4750, longitude: -122.2700),
            // Mile 15 — Renton area
            CLLocationCoordinate2D(latitude: 47.4400, longitude: -122.2500),
            // Mile 20 — Kent area
            CLLocationCoordinate2D(latitude: 47.3900, longitude: -122.2400),
            // Mile 25 — Between Kent and Auburn
            CLLocationCoordinate2D(latitude: 47.3500, longitude: -122.2200),
            // Mile 30 — Near Auburn, USGS 12113000 at RM 32 (V)
            CLLocationCoordinate2D(latitude: 47.3125, longitude: -122.2028),
            // Mile 35 — Flaming Geyser State Park area
            CLLocationCoordinate2D(latitude: 47.3000, longitude: -122.1300),
            // Mile 40 — Near Black Diamond
            CLLocationCoordinate2D(latitude: 47.3100, longitude: -122.0200),
            // Mile 45 — Green River Gorge
            CLLocationCoordinate2D(latitude: 47.3200, longitude: -121.9300),
            // Mile 50 — Palmer / Kanaskat-Palmer State Park area
            CLLocationCoordinate2D(latitude: 47.3200, longitude: -121.8600),
            // Mile 55 — Eagle Gorge area
            CLLocationCoordinate2D(latitude: 47.3300, longitude: -121.7800),
            // Mile 60 — Approaching Howard Hanson Dam
            CLLocationCoordinate2D(latitude: 47.3350, longitude: -121.7200),
            // Mile 65 — Howard Hanson Dam (V — USGS 12105900)
            CLLocationCoordinate2D(latitude: 47.3278, longitude: -121.6742),
            // Mile 70 — Upper Green River above dam
            CLLocationCoordinate2D(latitude: 47.3200, longitude: -121.5800),
            // Mile 75 — Headwaters area, near Blowout Creek / Stampede Pass (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.3100, longitude: -121.4800),
        ],

        "Cowlitz River": [
            // Mile 0 — Mouth at Columbia River, Longview/Kelso (V — GNIS)
            CLLocationCoordinate2D(latitude: 46.1050, longitude: -122.9550),
            // Mile 5 — Lower Cowlitz valley
            CLLocationCoordinate2D(latitude: 46.1400, longitude: -122.9400),
            // Mile 10 — Approaching Castle Rock
            CLLocationCoordinate2D(latitude: 46.2100, longitude: -122.9300),
            // Mile 15 — Near Castle Rock, USGS 14243000 at RM 17.3 (V)
            CLLocationCoordinate2D(latitude: 46.2748, longitude: -122.9146),
            // Mile 20 — Above Castle Rock
            CLLocationCoordinate2D(latitude: 46.3100, longitude: -122.8800),
            // Mile 25 — Near Toutle River confluence
            CLLocationCoordinate2D(latitude: 46.3500, longitude: -122.8400),
            // Mile 30 — Near Toledo
            CLLocationCoordinate2D(latitude: 46.4100, longitude: -122.8000),
            // Mile 35 — Between Toledo and Mayfield Dam
            CLLocationCoordinate2D(latitude: 46.4500, longitude: -122.7200),
            // Mile 40 — Mayfield Dam area (V — USGS 14238000)
            CLLocationCoordinate2D(latitude: 46.5104, longitude: -122.6162),
            // Mile 45 — Mayfield Lake
            CLLocationCoordinate2D(latitude: 46.5200, longitude: -122.5500),
            // Mile 50 — Mossyrock Dam area
            CLLocationCoordinate2D(latitude: 46.5300, longitude: -122.4700),
            // Mile 55 — Lower Riffe Lake
            CLLocationCoordinate2D(latitude: 46.5350, longitude: -122.3800),
            // Mile 60 — Mid Riffe Lake
            CLLocationCoordinate2D(latitude: 46.5350, longitude: -122.2900),
            // Mile 65 — Upper Riffe Lake
            CLLocationCoordinate2D(latitude: 46.5300, longitude: -122.2000),
            // Mile 70 — Above Riffe Lake, approaching Randle
            CLLocationCoordinate2D(latitude: 46.5280, longitude: -122.0800),
            // Mile 75 — Near Randle (V — USGS 14231000)
            CLLocationCoordinate2D(latitude: 46.5319, longitude: -121.9569),
            // Mile 80 — East of Randle
            CLLocationCoordinate2D(latitude: 46.5400, longitude: -121.8500),
            // Mile 85 — Between Randle and Packwood
            CLLocationCoordinate2D(latitude: 46.5600, longitude: -121.7500),
            // Mile 90 — Near Packwood (V — town GPS)
            CLLocationCoordinate2D(latitude: 46.6050, longitude: -121.6700),
            // Mile 95 — Above Packwood, approaching La Wis Wis
            CLLocationCoordinate2D(latitude: 46.6300, longitude: -121.5800),
            // Mile 100 — Near La Wis Wis, Ohanapecosh area
            CLLocationCoordinate2D(latitude: 46.6600, longitude: -121.5000),
            // Mile 105 — Headwaters, Mount Rainier glacial streams (V — GNIS)
            CLLocationCoordinate2D(latitude: 46.7300, longitude: -121.4500),
        ],

        "Bogachiel River": [
            // Mile 0 — Mouth at Sol Duc confluence, forming Quillayute River (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.9050, longitude: -124.5600),
            // Mile 5 — Lower Bogachiel, near USGS 12043015 (V)
            CLLocationCoordinate2D(latitude: 47.9029, longitude: -124.5455),
            // Mile 10 — Near Highway 101 crossing, south of Forks
            CLLocationCoordinate2D(latitude: 47.9100, longitude: -124.3800),
            // Mile 15 — Bogachiel State Park area
            CLLocationCoordinate2D(latitude: 47.9000, longitude: -124.2900),
            // Mile 20 — Approaching Olympic National Park boundary
            CLLocationCoordinate2D(latitude: 47.8900, longitude: -124.2000),
            // Mile 25 — Inside Olympic National Park, rainforest
            CLLocationCoordinate2D(latitude: 47.8800, longitude: -124.1100),
            // Mile 30 — Upper Bogachiel valley
            CLLocationCoordinate2D(latitude: 47.8600, longitude: -124.0200),
            // Mile 35 — Near Bogachiel Peak, headwaters area (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.8400, longitude: -123.9500),
        ],

        // ─────────────────────────────────────────────
        // Haida Gwaii — The Conservation Angler
        // ─────────────────────────────────────────────

        "Copper Creek": [
            CLLocationCoordinate2D(latitude: 53.16219534, longitude: -131.80042844),
            CLLocationCoordinate2D(latitude: 53.15748664, longitude: -131.80322742),
            CLLocationCoordinate2D(latitude: 53.15421141, longitude: -131.80617354),
            CLLocationCoordinate2D(latitude: 53.14524859, longitude: -131.80948560),
            CLLocationCoordinate2D(latitude: 53.13885792, longitude: -131.81920169),
            CLLocationCoordinate2D(latitude: 53.12612960, longitude: -131.83059880),
            CLLocationCoordinate2D(latitude: 53.11961154, longitude: -131.83684699),
            CLLocationCoordinate2D(latitude: 53.11056736, longitude: -131.84711616),
            CLLocationCoordinate2D(latitude: 53.10854459, longitude: -131.85454482),
            CLLocationCoordinate2D(latitude: 53.10895783, longitude: -131.86198772),
            CLLocationCoordinate2D(latitude: 53.10714048, longitude: -131.86801358),
        ],

        "Mamin": [
            CLLocationCoordinate2D(latitude: 53.62235570, longitude: -132.30535108),
            CLLocationCoordinate2D(latitude: 53.61369572, longitude: -132.29692978),
            CLLocationCoordinate2D(latitude: 53.60458839, longitude: -132.28781172),
            CLLocationCoordinate2D(latitude: 53.59664809, longitude: -132.30058656),
            CLLocationCoordinate2D(latitude: 53.59092495, longitude: -132.30596706),
            CLLocationCoordinate2D(latitude: 53.58334987, longitude: -132.31486196),
            CLLocationCoordinate2D(latitude: 53.57574597, longitude: -132.32013449),
            CLLocationCoordinate2D(latitude: 53.57335998, longitude: -132.32543308),
            CLLocationCoordinate2D(latitude: 53.57047992, longitude: -132.32839581),
            CLLocationCoordinate2D(latitude: 53.56697148, longitude: -132.32272745),
            CLLocationCoordinate2D(latitude: 53.56460393, longitude: -132.32189305),
            CLLocationCoordinate2D(latitude: 53.56326953, longitude: -132.32265372),
            CLLocationCoordinate2D(latitude: 53.56214806, longitude: -132.32387719),
            CLLocationCoordinate2D(latitude: 53.56196444, longitude: -132.32562913),
        ],

        "Pallant Creek": [
            CLLocationCoordinate2D(latitude: 53.05020396, longitude: -132.02722038),
            CLLocationCoordinate2D(latitude: 53.05109473, longitude: -132.03130431),
            CLLocationCoordinate2D(latitude: 53.05251082, longitude: -132.03380966),
            CLLocationCoordinate2D(latitude: 53.05312558, longitude: -132.03681246),
            CLLocationCoordinate2D(latitude: 53.05311909, longitude: -132.03901417),
            CLLocationCoordinate2D(latitude: 53.05906530, longitude: -132.05909085),
            CLLocationCoordinate2D(latitude: 53.05664645, longitude: -132.04827141),
        ],

        "Tlell": [
            CLLocationCoordinate2D(latitude: 53.56602409, longitude: -131.93391551),
            CLLocationCoordinate2D(latitude: 53.55952757, longitude: -131.94284105),
            CLLocationCoordinate2D(latitude: 53.55147195, longitude: -131.94500087),
            CLLocationCoordinate2D(latitude: 53.55456949, longitude: -131.95080004),
            CLLocationCoordinate2D(latitude: 53.55290278, longitude: -131.95946898),
            CLLocationCoordinate2D(latitude: 53.54701831, longitude: -131.96426943),
            CLLocationCoordinate2D(latitude: 53.54543727, longitude: -131.95751372),
            CLLocationCoordinate2D(latitude: 53.54135292, longitude: -131.96176421),
            CLLocationCoordinate2D(latitude: 53.54135109, longitude: -131.96960733),
            CLLocationCoordinate2D(latitude: 53.54315103, longitude: -131.97791201),
            CLLocationCoordinate2D(latitude: 53.53959191, longitude: -131.99246545),
            CLLocationCoordinate2D(latitude: 53.53159860, longitude: -131.99298235),
            CLLocationCoordinate2D(latitude: 53.52267261, longitude: -132.00304293),
            CLLocationCoordinate2D(latitude: 53.51842026, longitude: -132.00771530),
            CLLocationCoordinate2D(latitude: 53.51750324, longitude: -132.01702109),
        ],

        "Yakoun": [
            CLLocationCoordinate2D(latitude: 53.67145964, longitude: -132.20484788),
            CLLocationCoordinate2D(latitude: 53.65806147, longitude: -132.20842867),
            CLLocationCoordinate2D(latitude: 53.64826429, longitude: -132.20188791),
            CLLocationCoordinate2D(latitude: 53.63898263, longitude: -132.20839589),
            CLLocationCoordinate2D(latitude: 53.63065000, longitude: -132.21029391),
            CLLocationCoordinate2D(latitude: 53.62315340, longitude: -132.21093323),
            CLLocationCoordinate2D(latitude: 53.61631524, longitude: -132.20535403),
            CLLocationCoordinate2D(latitude: 53.60735775, longitude: -132.20963372),
            CLLocationCoordinate2D(latitude: 53.59716938, longitude: -132.19857212),
            CLLocationCoordinate2D(latitude: 53.59105001, longitude: -132.18032002),
            CLLocationCoordinate2D(latitude: 53.58243620, longitude: -132.16014224),
            CLLocationCoordinate2D(latitude: 53.57107698, longitude: -132.15106428),
            CLLocationCoordinate2D(latitude: 53.55470426, longitude: -132.15033626),
            CLLocationCoordinate2D(latitude: 53.54531354, longitude: -132.13658292),
            CLLocationCoordinate2D(latitude: 53.53813782, longitude: -132.13140609),
            CLLocationCoordinate2D(latitude: 53.52963468, longitude: -132.12821481),
            CLLocationCoordinate2D(latitude: 53.52550152, longitude: -132.13108942),
            CLLocationCoordinate2D(latitude: 53.52156965, longitude: -132.13847318),
            CLLocationCoordinate2D(latitude: 53.51929448, longitude: -132.13900541),
            CLLocationCoordinate2D(latitude: 53.51756112, longitude: -132.13955027),
            CLLocationCoordinate2D(latitude: 53.51150740, longitude: -132.13820748),
            CLLocationCoordinate2D(latitude: 53.50789139, longitude: -132.14387012),
            CLLocationCoordinate2D(latitude: 53.50581909, longitude: -132.14881227),
            CLLocationCoordinate2D(latitude: 53.50333292, longitude: -132.14544649),
            CLLocationCoordinate2D(latitude: 53.50187774, longitude: -132.15029541),
            CLLocationCoordinate2D(latitude: 53.51249887, longitude: -132.18544030),
            CLLocationCoordinate2D(latitude: 53.51134930, longitude: -132.22092786),
            CLLocationCoordinate2D(latitude: 53.50398615, longitude: -132.24599926),
            CLLocationCoordinate2D(latitude: 53.49093023, longitude: -132.25073498),
            CLLocationCoordinate2D(latitude: 53.47043692, longitude: -132.25435481),
            CLLocationCoordinate2D(latitude: 53.45491273, longitude: -132.26076329),
            CLLocationCoordinate2D(latitude: 53.44543251, longitude: -132.26416425),
            CLLocationCoordinate2D(latitude: 53.43861339, longitude: -132.26783279),
            CLLocationCoordinate2D(latitude: 53.43496540, longitude: -132.27675830),
            CLLocationCoordinate2D(latitude: 53.42735946, longitude: -132.26541183),
            CLLocationCoordinate2D(latitude: 53.41803769, longitude: -132.26486695),
            CLLocationCoordinate2D(latitude: 53.41068487, longitude: -132.26749244),
            CLLocationCoordinate2D(latitude: 53.40675934, longitude: -132.26974776),
            CLLocationCoordinate2D(latitude: 53.40228896, longitude: -132.27564943),
            CLLocationCoordinate2D(latitude: 53.39372135, longitude: -132.27570305),
            CLLocationCoordinate2D(latitude: 53.38536438, longitude: -132.27482222),
            CLLocationCoordinate2D(latitude: 53.37946266, longitude: -132.27587465),
        ],

        // ─────────────────────────────────────────────
        // Alaska — Togiak National Wildlife Refuge
        // ─────────────────────────────────────────────

        "Togiak River": [
            // Mile 0 — Mouth: Togiak River at Togiak Bay (near village of Togiak)
            CLLocationCoordinate2D(latitude: 59.0608, longitude: -160.3772),
            // Mile 5 — Lower river, tidal estuary / wetland marsh zone
            CLLocationCoordinate2D(latitude: 59.0900, longitude: -160.3100),
            // Mile 10 — Above tidal influence, lower canyon
            CLLocationCoordinate2D(latitude: 59.1200, longitude: -160.2400),
            // Mile 15 — Mid-lower river, Togiak NWR wilderness
            CLLocationCoordinate2D(latitude: 59.1600, longitude: -160.1700),
            // Mile 20 — Pungokepuk River confluence area (upper/lower river division)
            CLLocationCoordinate2D(latitude: 59.2100, longitude: -160.1000),
            // Mile 25 — Upper river, below Kemuk River confluence
            CLLocationCoordinate2D(latitude: 59.2700, longitude: -160.0300),
            // Mile 30 — Kemuk River confluence area
            CLLocationCoordinate2D(latitude: 59.3740, longitude: -160.0075),
            // Mile 35 — Upper river, approaching Togiak Lake outlet
            CLLocationCoordinate2D(latitude: 59.4500, longitude: -159.9000),
            // Mile 40 — Near Togiak Lake outlet
            CLLocationCoordinate2D(latitude: 59.5200, longitude: -159.8000),
            // Mile 45 — Togiak Lake (lower / southwest end)
            CLLocationCoordinate2D(latitude: 59.5800, longitude: -159.7000),
            // Mile 48 — Togiak Lake (source, mid-lake)
            CLLocationCoordinate2D(latitude: 59.6261, longitude: -159.6122),
        ],

        "Kasilof River": [
            // Mile 0 — Mouth: Kasilof River at Cook Inlet (Kasilof River Flats)
            CLLocationCoordinate2D(latitude: 60.3400, longitude: -151.2800),
            // Mile 5 — Lower river, Kasilof village / Sterling Highway bridge area
            CLLocationCoordinate2D(latitude: 60.3350, longitude: -151.2340),
            // Mile 8 — ADF&G Sonar site (RM 7.8) / Kasilof River State Rec Site
            CLLocationCoordinate2D(latitude: 60.3280, longitude: -151.2200),
            // Mile 10 — Crooked Creek confluence / Crooked Creek State Rec Site
            CLLocationCoordinate2D(latitude: 60.3215, longitude: -151.2856),
            // Mile 15 — Mid-river, approaching Tustumena Lake outlet
            CLLocationCoordinate2D(latitude: 60.2800, longitude: -151.0800),
            // Mile 18 — Tustumena Lake outlet (source)
            CLLocationCoordinate2D(latitude: 60.2243, longitude: -150.9380),
        ],

        // ─────────────────────────────────────────────
        // Northern BC — Skeena Region
        // ─────────────────────────────────────────────

        "Middle Skeena River": [
            // Mile 0 — Mouth: Skeena River entering Chatham Sound (south of Prince Rupert)
            CLLocationCoordinate2D(latitude: 54.2500, longitude: -130.2500),
            // Mile 5 — Port Edward / lower estuary
            CLLocationCoordinate2D(latitude: 54.2333, longitude: -130.2833),
            // Mile 10 — Tidal reach, approaching Hwy 16
            CLLocationCoordinate2D(latitude: 54.2600, longitude: -130.1500),
            // Mile 15 — Lower Skeena, Kasiks area (upper tidal limit)
            CLLocationCoordinate2D(latitude: 54.2900, longitude: -130.0200),
            // Mile 20 — Exchamsiks River Park area
            CLLocationCoordinate2D(latitude: 54.3200, longitude: -129.8800),
            // Mile 25 — Mid-lower Skeena, Hwy 16 corridor
            CLLocationCoordinate2D(latitude: 54.3500, longitude: -129.7200),
            // Mile 30 — Approaching Terrace from the west
            CLLocationCoordinate2D(latitude: 54.3900, longitude: -129.5500),
            // Mile 35 — Terrace area
            CLLocationCoordinate2D(latitude: 54.5099, longitude: -128.5932),
            // Mile 40 — East of Terrace, Kitselas Canyon area
            CLLocationCoordinate2D(latitude: 54.5400, longitude: -128.4800),
            // Mile 45 — Usk (WSC gauge 08EF001)
            CLLocationCoordinate2D(latitude: 54.6346, longitude: -128.4090),
            // Mile 50 — East of Usk, heading toward Cedarvale
            CLLocationCoordinate2D(latitude: 54.6800, longitude: -128.3000),
            // Mile 55 — Cedarvale area
            CLLocationCoordinate2D(latitude: 54.7200, longitude: -128.2000),
            // Mile 60 — Between Cedarvale and Kitwanga
            CLLocationCoordinate2D(latitude: 54.7800, longitude: -128.1500),
            // Mile 65 — Kitwanga area (Hwy 37 junction)
            CLLocationCoordinate2D(latitude: 55.1000, longitude: -128.0667),
            // Mile 70 — Between Kitwanga and Hazelton
            CLLocationCoordinate2D(latitude: 55.1500, longitude: -127.9000),
            // Mile 75 — Approaching Hazelton / Bulkley confluence
            CLLocationCoordinate2D(latitude: 55.2000, longitude: -127.7500),
            // Mile 80 — Hazelton: Skeena-Bulkley confluence
            CLLocationCoordinate2D(latitude: 55.2568, longitude: -127.6720),
        ],

        "Upper Skeena River": [
            // Mile 85 — Above Babine River confluence (WSC 08EB005)
            CLLocationCoordinate2D(latitude: 55.3000, longitude: -127.6000),
            // Mile 90 — Kispiox area
            CLLocationCoordinate2D(latitude: 55.3500, longitude: -127.5500),
            // Mile 95 — Upper Skeena, heading northeast
            CLLocationCoordinate2D(latitude: 55.4200, longitude: -127.4500),
            // Mile 100 — Upper Skeena wilderness
            CLLocationCoordinate2D(latitude: 55.5000, longitude: -127.3500),
        ],

        "Bulkley River": [
            // Mile 0 — Mouth: Bulkley-Skeena confluence at Hazelton
            CLLocationCoordinate2D(latitude: 55.2556, longitude: -127.6753),
            // Mile 5 — South Hazelton / New Hazelton area
            CLLocationCoordinate2D(latitude: 55.2414, longitude: -127.5834),
            // Mile 10 — Between Hazelton and Moricetown
            CLLocationCoordinate2D(latitude: 55.1800, longitude: -127.5000),
            // Mile 15 — Approaching Moricetown/Witset
            CLLocationCoordinate2D(latitude: 55.1000, longitude: -127.4200),
            // Mile 20 — Moricetown Canyon / Moricetown Falls
            CLLocationCoordinate2D(latitude: 55.0332, longitude: -127.3332),
            // Mile 25 — Between Moricetown and Smithers
            CLLocationCoordinate2D(latitude: 54.9500, longitude: -127.2800),
            // Mile 30 — Approaching Smithers (WSC 08EE005)
            CLLocationCoordinate2D(latitude: 54.8500, longitude: -127.2200),
            // Mile 35 — Smithers
            CLLocationCoordinate2D(latitude: 54.7820, longitude: -127.1720),
            // Mile 40 — Between Smithers and Telkwa
            CLLocationCoordinate2D(latitude: 54.7400, longitude: -127.1100),
            // Mile 45 — Telkwa (Telkwa River confluence)
            CLLocationCoordinate2D(latitude: 54.6940, longitude: -127.0480),
            // Mile 50 — Quick area (WSC gauge 08EE004)
            CLLocationCoordinate2D(latitude: 54.6500, longitude: -126.9800),
            // Mile 55 — Bulkley River Recreation Site
            CLLocationCoordinate2D(latitude: 54.6000, longitude: -126.9200),
            // Mile 60 — Between Quick and Houston (WSC 08EE003)
            CLLocationCoordinate2D(latitude: 54.5500, longitude: -126.8500),
            // Mile 65 — Approaching Houston
            CLLocationCoordinate2D(latitude: 54.4800, longitude: -126.7800),
            // Mile 70 — Houston (Morice River confluence)
            CLLocationCoordinate2D(latitude: 54.3998, longitude: -126.6701),
            // Mile 75 — South of Houston, upper Bulkley
            CLLocationCoordinate2D(latitude: 54.3500, longitude: -126.7500),
            // Mile 80 — Approaching Bulkley Lake (source)
            CLLocationCoordinate2D(latitude: 54.3000, longitude: -126.8500),
            // Mile 85 — Bulkley Lake (source)
            CLLocationCoordinate2D(latitude: 54.2500, longitude: -126.9500),
        ],

        "Morice River": [
            // Mile 0 — Mouth: Morice-Bulkley confluence at Houston
            //          (Lamprey Creek joins from the east at the same point)
            CLLocationCoordinate2D(latitude: 54.3998, longitude: -126.6701),
            // Mile 5 — Lower Morice, Morice River FSR ~km 8 (interpolated)
            CLLocationCoordinate2D(latitude: 54.3715, longitude: -126.7458),
            // Mile 10 — Lower Morice, Morice River FSR ~km 16 (interpolated)
            CLLocationCoordinate2D(latitude: 54.3432, longitude: -126.8214),
            // Mile 15 — Mid-lower Morice, Morice River FSR ~km 22 (interpolated)
            CLLocationCoordinate2D(latitude: 54.3149, longitude: -126.8970),
            // Mile 20 — Mid Morice, FSR ~km 27 (interpolated)
            CLLocationCoordinate2D(latitude: 54.2866, longitude: -126.9727),
            // Mile 25 — Owen Flats Rec Site vicinity, FSR ~km 27.5 (interpolated)
            CLLocationCoordinate2D(latitude: 54.2583, longitude: -127.0483),
            // Mile 30 — Gosnell Creek confluence area (interpolated; key fishery boundary)
            CLLocationCoordinate2D(latitude: 54.2300, longitude: -127.1240),
            // Mile 35 — Mid-upper Morice (interpolated)
            CLLocationCoordinate2D(latitude: 54.2017, longitude: -127.1996),
            // Mile 40 — Thautil River / Atna River confluence area (interpolated)
            CLLocationCoordinate2D(latitude: 54.1734, longitude: -127.2753),
            // Mile 45 — Nanika River confluence area (interpolated)
            CLLocationCoordinate2D(latitude: 54.1451, longitude: -127.3509),
            // Mile 50 — Source: Morice Lake outlet (WSC 08ED002)
            CLLocationCoordinate2D(latitude: 54.1168, longitude: -127.4266),
        ],

        "Babine River": [
            // Mile 0 — Mouth: Babine River confluence with the Skeena River (near Kisgegas)
            CLLocationCoordinate2D(latitude: 55.6831, longitude: -127.7000),
            // Mile 5 — Lower river, above Kisgegas Canyon
            CLLocationCoordinate2D(latitude: 55.6500, longitude: -127.6100),
            // Mile 10 — Lower canyon stretch, Babine River Corridor Park
            CLLocationCoordinate2D(latitude: 55.6150, longitude: -127.5200),
            // Mile 13 — Mid-canyon, river bends east
            CLLocationCoordinate2D(latitude: 55.6050, longitude: -127.4200),
            // Mile 15 — Mid-lower river, Silver Hilton Lodge vicinity (lower camp)
            CLLocationCoordinate2D(latitude: 55.5800, longitude: -127.4300),
            // Mile 18 — Between Silver Hilton camps, river corridor
            CLLocationCoordinate2D(latitude: 55.6000, longitude: -127.3000),
            // Mile 20 — Silver Hilton Lodge vicinity (upper camp, ~7 mi from lower)
            CLLocationCoordinate2D(latitude: 55.5500, longitude: -127.3500),
            // Mile 23 — East bend, mid-wilderness corridor
            CLLocationCoordinate2D(latitude: 55.5800, longitude: -127.1800),
            // Mile 25 — Mid-river, wilderness corridor
            CLLocationCoordinate2D(latitude: 55.5150, longitude: -127.2600),
            // Mile 30 — Mid-river, deep in Babine River Corridor Park
            CLLocationCoordinate2D(latitude: 55.4800, longitude: -127.1700),
            // Mile 35 — Upper-mid river, approaching Babine Steelhead Lodge area
            CLLocationCoordinate2D(latitude: 55.4500, longitude: -127.0800),
            // Mile 40 — Babine Steelhead Lodge vicinity (~15 km below weir)
            CLLocationCoordinate2D(latitude: 55.4200, longitude: -127.0000),
            // Mile 45 — Upper river, between lodge and Babine Norlakes Camp
            CLLocationCoordinate2D(latitude: 55.4000, longitude: -126.9200),
            // Mile 48 — Upper river, Nilkitkwa Lake north end
            CLLocationCoordinate2D(latitude: 55.5365, longitude: -126.7683),
            // Mile 50 — Babine Norlakes Camp vicinity (~3 mi below lake outlet)
            CLLocationCoordinate2D(latitude: 55.3850, longitude: -126.8400),
            // Mile 55 — DFO salmon counting fence (~1 km below Nilkitkwa Lake)
            CLLocationCoordinate2D(latitude: 55.3750, longitude: -126.7600),
            // Mile 60 — Source: Outlet of Nilkitkwa Lake / Babine Lake system
            CLLocationCoordinate2D(latitude: 55.3660, longitude: -126.6600),
        ],

        "Damdochax River": [
            // Small (~12 mi) wilderness river ~140 km NE of Hazelton.
            // Geographically a Nass tributary (drains to upper Nass), but
            // grouped here under the Skeena region per lodge convention. No
            // dedicated WSC gauge — uses Skeena above Babine (08EB005) as
            // the regional proxy.
            // Mile 0 — Mouth: Damdochax-Nass confluence (BC GeoNames)
            CLLocationCoordinate2D(latitude: 56.5316, longitude: -128.3206),
            // Mile 5 — Mid-river, Damdochax Protected Area (interpolated)
            CLLocationCoordinate2D(latitude: 56.5217, longitude: -128.2291),
            // Mile 10 — Approaching Damdochax Lake outlet (interpolated)
            CLLocationCoordinate2D(latitude: 56.5118, longitude: -128.1377),
            // Mile 12 — Source: Damdochax Lake outlet (BC GeoNames)
            CLLocationCoordinate2D(latitude: 56.5078, longitude: -128.1011),
        ],

        // ─────────────────────────────────────────────
        // Northern BC — Copper / Zymoetz River
        // ─────────────────────────────────────────────

        // "Upper Copper River" is the lodge-name for the Zymoetz River (BC),
        // a 90-mile Skeena tributary originating in the Bulkley Ranges of the
        // Hazelton Mountains. WSC gauge 08EF005 ("Zymoetz River Above O.K. Creek")
        // is located in the remote upper reach. The Copper River Road parallels
        // the lower ~28 miles from near Terrace.
        "Upper Copper River": [
            // Mile 0 — Mouth at Skeena River confluence, ~12 km east of downtown Terrace (Verified — Wikipedia 54°32′42″N 128°29′9″W)
            CLLocationCoordinate2D(latitude: 54.5450, longitude: -128.4858),
            // Mile 5 — Lower Copper River Road, Eight Mile Creek area (interpolated)
            CLLocationCoordinate2D(latitude: 54.5580, longitude: -128.4358),
            // Mile 10 — Copper River Road, mid-lower reach (interpolated)
            CLLocationCoordinate2D(latitude: 54.5710, longitude: -128.3858),
            // Mile 15 — Copper River Road, approaching canyon (interpolated)
            CLLocationCoordinate2D(latitude: 54.5840, longitude: -128.3358),
            // Mile 20 — Near Clore River confluence, largest south-bank tributary (interpolated)
            CLLocationCoordinate2D(latitude: 54.5970, longitude: -128.2858),
            // Mile 25 — Upper Copper River Road, approaching road end (interpolated)
            CLLocationCoordinate2D(latitude: 54.6100, longitude: -128.2358),
            // Mile 30 — Near road end (~45 km from Terrace), river enters roadless wilderness (interpolated)
            CLLocationCoordinate2D(latitude: 54.6230, longitude: -128.1858),
            // Mile 35 — Lower wilderness, river bends northward toward plateau (interpolated)
            CLLocationCoordinate2D(latitude: 54.6430, longitude: -128.1258),
            // Mile 40 — Mid-river wilderness (interpolated)
            CLLocationCoordinate2D(latitude: 54.6630, longitude: -128.0658),
            // Mile 45 — Approaching O.K. Creek, WSC gauge 08EF005 vicinity (interpolated)
            CLLocationCoordinate2D(latitude: 54.6820, longitude: -128.0058),
            // Mile 50 — Above O.K. Creek, WSC gauge 08EF005 general area (interpolated)
            CLLocationCoordinate2D(latitude: 54.7000, longitude: -127.9458),
            // Mile 55 — Upper river, below lake chain (interpolated)
            CLLocationCoordinate2D(latitude: 54.7160, longitude: -127.8858),
            // Mile 60 — Approaching McDonell Lake; river enters upper lake system (interpolated)
            CLLocationCoordinate2D(latitude: 54.7240, longitude: -127.8128),
            // Mile 65 — Near McDonell Lake, river flows east through lake chain (interpolated)
            CLLocationCoordinate2D(latitude: 54.7300, longitude: -127.7398),
            // Mile 70 — Between McDonell and Dennis Lakes (interpolated)
            CLLocationCoordinate2D(latitude: 54.7340, longitude: -127.6668),
            // Mile 75 — Dennis Lake area, upper Zymoetz lake chain (interpolated)
            CLLocationCoordinate2D(latitude: 54.7360, longitude: -127.5938),
            // Mile 80 — Between Dennis and Aldrich Lakes (interpolated)
            CLLocationCoordinate2D(latitude: 54.7360, longitude: -127.5208),
            // Mile 85 — Near Aldrich Lake, approaching headwaters (interpolated)
            CLLocationCoordinate2D(latitude: 54.7350, longitude: -127.4478),
            // Mile 90 — Source: Aldrich Lake outlet, Bulkley Ranges / Hazelton Mountains (Verified — Wikipedia 54°44′1″N 127°22′25″W)
            CLLocationCoordinate2D(latitude: 54.7336, longitude: -127.3736),
        ],

        // ─────────────────────────────────────────────
        // Olympic Peninsula — Emerald Waters Angler
        // ─────────────────────────────────────────────

        "Sol Duc River": [
            // Mile 0 — Mouth at Bogachiel confluence, forming Quillayute River (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.9050, longitude: -124.5600),
            // Mile 5 — Lower Sol Duc valley
            CLLocationCoordinate2D(latitude: 47.9200, longitude: -124.5000),
            // Mile 10 — Approaching Forks
            CLLocationCoordinate2D(latitude: 47.9400, longitude: -124.4300),
            // Mile 15 — Near Forks, USGS 12042400 at Hwy 101 (V)
            CLLocationCoordinate2D(latitude: 47.9500, longitude: -124.3800),
            // Mile 20 — East of Forks
            CLLocationCoordinate2D(latitude: 47.9550, longitude: -124.3000),
            // Mile 25 — Sol Duc valley
            CLLocationCoordinate2D(latitude: 47.9600, longitude: -124.2200),
            // Mile 30 — Mid-valley
            CLLocationCoordinate2D(latitude: 47.9650, longitude: -124.1400),
            // Mile 35 — Upper valley
            CLLocationCoordinate2D(latitude: 47.9700, longitude: -124.0600),
            // Mile 40 — Near Klahowya Campground area
            CLLocationCoordinate2D(latitude: 47.9700, longitude: -123.9800),
            // Mile 45 — Approaching Olympic National Park
            CLLocationCoordinate2D(latitude: 47.9700, longitude: -123.9000),
            // Mile 50 — Sol Duc Hot Springs area (V — NPS)
            CLLocationCoordinate2D(latitude: 47.9693, longitude: -123.8620),
            // Mile 55 — Above Sol Duc Falls, upper valley
            CLLocationCoordinate2D(latitude: 47.9500, longitude: -123.8000),
            // Mile 60 — Headwaters, Sol Duc Park area (V — GNIS)
            CLLocationCoordinate2D(latitude: 47.9400, longitude: -123.7500),
        ],

        // ─────────────────────────────────────────────
        // Alaska Peninsula
        // ─────────────────────────────────────────────

        "Ocean River": [
            CLLocationCoordinate2D(latitude: 56.5619, longitude: -159.7564),
            CLLocationCoordinate2D(latitude: 56.5520, longitude: -159.6800),
            CLLocationCoordinate2D(latitude: 56.5380, longitude: -159.6100),
            CLLocationCoordinate2D(latitude: 56.5250, longitude: -159.5400),
        ],

        "Sandy River": [
            CLLocationCoordinate2D(latitude: 56.1700, longitude: -159.9500),
            CLLocationCoordinate2D(latitude: 56.1450, longitude: -159.9300),
            CLLocationCoordinate2D(latitude: 56.1200, longitude: -159.9100),
            CLLocationCoordinate2D(latitude: 56.0950, longitude: -159.8800),
            CLLocationCoordinate2D(latitude: 56.0700, longitude: -159.8500),
        ],

        "King Salmon River": [
            CLLocationCoordinate2D(latitude: 57.4972, longitude: -157.6417),
            CLLocationCoordinate2D(latitude: 57.4700, longitude: -157.6000),
            CLLocationCoordinate2D(latitude: 57.4430, longitude: -157.5600),
            CLLocationCoordinate2D(latitude: 57.4150, longitude: -157.5300),
            CLLocationCoordinate2D(latitude: 57.3900, longitude: -157.5100),
            CLLocationCoordinate2D(latitude: 57.3650, longitude: -157.5000),
            CLLocationCoordinate2D(latitude: 57.3450, longitude: -157.4900),
            CLLocationCoordinate2D(latitude: 57.3330, longitude: -157.5000),
        ],

        // ─────────────────────────────────────────────
        // Yakutat, Alaska
        // ─────────────────────────────────────────────

        "Situk River": [
            CLLocationCoordinate2D(latitude: 59.4353, longitude: -139.5467),
            CLLocationCoordinate2D(latitude: 59.4700, longitude: -139.5200),
            CLLocationCoordinate2D(latitude: 59.5100, longitude: -139.5000),
            CLLocationCoordinate2D(latitude: 59.5500, longitude: -139.4800),
            CLLocationCoordinate2D(latitude: 59.5864, longitude: -139.4600),
        ],

        // ─────────────────────────────────────────────
        // Klamath Basin — California / Oregon
        // ─────────────────────────────────────────────

        // Split at the CA/OR state line (latitude 42.0°N). Seiad Valley,
        // Happy Camp, Somes Bar, and the mainstem through Siskiyou County
        // all fall in the California entry; Keno, Klamath Falls, and the
        // Upper Klamath Lake outlet fall in the Oregon entry.
        "Klamath River (California)": [
            CLLocationCoordinate2D(latitude: 41.5331, longitude: -124.0811),
            CLLocationCoordinate2D(latitude: 41.5330, longitude: -123.9900),
            CLLocationCoordinate2D(latitude: 41.5330, longitude: -123.8989),
            CLLocationCoordinate2D(latitude: 41.5330, longitude: -123.8078),
            CLLocationCoordinate2D(latitude: 41.5200, longitude: -123.7400),
            CLLocationCoordinate2D(latitude: 41.5050, longitude: -123.6700),
            CLLocationCoordinate2D(latitude: 41.3575, longitude: -123.6035),
            CLLocationCoordinate2D(latitude: 41.3300, longitude: -123.5680),
            CLLocationCoordinate2D(latitude: 41.3028, longitude: -123.5369),
            CLLocationCoordinate2D(latitude: 41.3350, longitude: -123.5000),
            CLLocationCoordinate2D(latitude: 41.3550, longitude: -123.4870),
            CLLocationCoordinate2D(latitude: 41.3764, longitude: -123.4753),
            CLLocationCoordinate2D(latitude: 41.4500, longitude: -123.4300),
            CLLocationCoordinate2D(latitude: 41.5700, longitude: -123.3900),
            CLLocationCoordinate2D(latitude: 41.6800, longitude: -123.3500),
            CLLocationCoordinate2D(latitude: 41.7350, longitude: -123.3650),
            CLLocationCoordinate2D(latitude: 41.7931, longitude: -123.3814),
            CLLocationCoordinate2D(latitude: 41.7980, longitude: -123.3590),
            CLLocationCoordinate2D(latitude: 41.8015, longitude: -123.3395),
            CLLocationCoordinate2D(latitude: 41.8050, longitude: -123.3200),
            CLLocationCoordinate2D(latitude: 41.8200, longitude: -123.2760),
            CLLocationCoordinate2D(latitude: 41.8370, longitude: -123.2540),
            CLLocationCoordinate2D(latitude: 41.8542, longitude: -123.2320),
            CLLocationCoordinate2D(latitude: 41.8450, longitude: -123.1400),
            CLLocationCoordinate2D(latitude: 41.8380, longitude: -123.0950),
            CLLocationCoordinate2D(latitude: 41.8300, longitude: -123.0500),
            CLLocationCoordinate2D(latitude: 41.8400, longitude: -122.9500),
            CLLocationCoordinate2D(latitude: 41.8700, longitude: -122.8000),
            CLLocationCoordinate2D(latitude: 41.8900, longitude: -122.6800),
            CLLocationCoordinate2D(latitude: 41.9100, longitude: -122.5600),
            CLLocationCoordinate2D(latitude: 41.9200, longitude: -122.5000),
            CLLocationCoordinate2D(latitude: 41.9254, longitude: -122.4715),
            CLLocationCoordinate2D(latitude: 41.9306, longitude: -122.4431),
            CLLocationCoordinate2D(latitude: 41.9500, longitude: -122.3900),
            CLLocationCoordinate2D(latitude: 41.9600, longitude: -122.3600),
            CLLocationCoordinate2D(latitude: 41.9700, longitude: -122.3300),
            CLLocationCoordinate2D(latitude: 41.9800, longitude: -122.2800),
            CLLocationCoordinate2D(latitude: 41.9900, longitude: -122.2400),
        ],

        "Klamath River (Oregon)": [
            CLLocationCoordinate2D(latitude: 42.0000, longitude: -122.2000),
            CLLocationCoordinate2D(latitude: 42.0420, longitude: -122.1367),
            CLLocationCoordinate2D(latitude: 42.0633, longitude: -122.1050),
            CLLocationCoordinate2D(latitude: 42.0846, longitude: -122.0733),
            CLLocationCoordinate2D(latitude: 42.1089, longitude: -122.0177),
            CLLocationCoordinate2D(latitude: 42.1211, longitude: -121.9900),
            CLLocationCoordinate2D(latitude: 42.1332, longitude: -121.9622),
            CLLocationCoordinate2D(latitude: 42.1400, longitude: -121.9300),
            CLLocationCoordinate2D(latitude: 42.1574, longitude: -121.8645),
            CLLocationCoordinate2D(latitude: 42.1747, longitude: -121.7987),
            CLLocationCoordinate2D(latitude: 42.1990, longitude: -121.7964),
            CLLocationCoordinate2D(latitude: 42.2235, longitude: -121.7942),
            CLLocationCoordinate2D(latitude: 42.3108, longitude: -121.8589),
            CLLocationCoordinate2D(latitude: 42.3545, longitude: -121.8912),
            CLLocationCoordinate2D(latitude: 42.3982, longitude: -121.9236),
        ],

        "Williamson River": [
            CLLocationCoordinate2D(latitude: 42.4900, longitude: -121.9300),
            CLLocationCoordinate2D(latitude: 42.5272, longitude: -121.9048),
            CLLocationCoordinate2D(latitude: 42.5644, longitude: -121.8797),
            CLLocationCoordinate2D(latitude: 42.5700, longitude: -121.8700),
            CLLocationCoordinate2D(latitude: 42.5750, longitude: -121.8650),
            CLLocationCoordinate2D(latitude: 42.5800, longitude: -121.8600),
            CLLocationCoordinate2D(latitude: 42.5850, longitude: -121.8550),
            CLLocationCoordinate2D(latitude: 42.6100, longitude: -121.8450),
            CLLocationCoordinate2D(latitude: 42.6700, longitude: -121.8365),
            CLLocationCoordinate2D(latitude: 42.7403, longitude: -121.8333),
            CLLocationCoordinate2D(latitude: 42.7500, longitude: -121.8267),
            CLLocationCoordinate2D(latitude: 42.7550, longitude: -121.8000),
            CLLocationCoordinate2D(latitude: 42.7600, longitude: -121.7733),
            CLLocationCoordinate2D(latitude: 42.7700, longitude: -121.7467),
            CLLocationCoordinate2D(latitude: 42.7800, longitude: -121.7200),
            CLLocationCoordinate2D(latitude: 42.8075, longitude: -121.6850),
            CLLocationCoordinate2D(latitude: 42.8250, longitude: -121.6675),
            CLLocationCoordinate2D(latitude: 42.8375, longitude: -121.6575),
            CLLocationCoordinate2D(latitude: 42.8438, longitude: -121.6537),
            CLLocationCoordinate2D(latitude: 42.8500, longitude: -121.6500),
        ],

        "Wood River": [
            CLLocationCoordinate2D(latitude: 42.5500, longitude: -121.9500),
            CLLocationCoordinate2D(latitude: 42.5900, longitude: -121.9550),
            CLLocationCoordinate2D(latitude: 42.6400, longitude: -121.9600),
            CLLocationCoordinate2D(latitude: 42.6900, longitude: -121.9700),
            CLLocationCoordinate2D(latitude: 42.7381, longitude: -121.9800),
        ],

        "Sprague River": [
            CLLocationCoordinate2D(latitude: 42.5712, longitude: -121.8745),
            CLLocationCoordinate2D(latitude: 42.5779, longitude: -121.8616),
            CLLocationCoordinate2D(latitude: 42.5847, longitude: -121.8486),
            CLLocationCoordinate2D(latitude: 42.5798, longitude: -121.8193),
            CLLocationCoordinate2D(latitude: 42.5750, longitude: -121.7900),
            CLLocationCoordinate2D(latitude: 42.5700, longitude: -121.7600),
            CLLocationCoordinate2D(latitude: 42.5650, longitude: -121.7300),
            CLLocationCoordinate2D(latitude: 42.5575, longitude: -121.6900),
            CLLocationCoordinate2D(latitude: 42.5500, longitude: -121.6500),
            CLLocationCoordinate2D(latitude: 42.5400, longitude: -121.6100),
            CLLocationCoordinate2D(latitude: 42.5300, longitude: -121.5700),
            CLLocationCoordinate2D(latitude: 42.5200, longitude: -121.5300),
            CLLocationCoordinate2D(latitude: 42.5100, longitude: -121.4900),
            CLLocationCoordinate2D(latitude: 42.5000, longitude: -121.4500),
            CLLocationCoordinate2D(latitude: 42.4900, longitude: -121.4000),
            CLLocationCoordinate2D(latitude: 42.4378, longitude: -121.1094),
        ],

        // ─────────────────────────────────────────────
        // Alaska — Southeast / Tongass National Forest
        // ─────────────────────────────────────────────

        // Chuck River: ~10-mile river in the Chuck River Wilderness (Tongass NF),
        // flows north from headwaters near Port Houghton divide to Windham Bay,
        // ~64 mi SE of Juneau. No dedicated USGS or NOAA NWPS gauge; nearest
        // tidal reference is the Port Houghton subordinate NOAA station.
        "Chuck River": [
            // Mile 0 — Mouth at Windham Bay, former Chuck Mining Camp site (Verified — GNIS 57°35'12"N 133°21'20"W)
            CLLocationCoordinate2D(latitude: 57.5867, longitude: -133.3556),
            // Mile 5 — Mid-river, Chuck River Wilderness corridor (interpolated)
            CLLocationCoordinate2D(latitude: 57.5150, longitude: -133.3500),
            // Mile 10 — Headwaters near Port Houghton divide, Coast Mountains foothills (interpolated)
            CLLocationCoordinate2D(latitude: 57.4430, longitude: -133.3480),
        ],

        // Kadake Creek: ~10-mile stream on northeast Kuiu Island (Tongass NF).
        // Drains interior Kuiu muskeg / forest ponds NE into Kadake Bay, which
        // opens onto Keku Strait across from Kake. Kuiu's largest pink-salmon
        // producer; no USGS or NOAA NWPS gauge on the system. Official GNIS
        // name is "Kadake Creek"; locally also called "Kadake River".
        "Kadake Creek": [
            // Mile 0 — Mouth at Kadake Bay, Kadake Bay USFS Cabin (Verified — cabin sits at stream mouth)
            CLLocationCoordinate2D(latitude: 56.7831, longitude: -133.9822),
            // Mile 5 — Mid-creek valley, NE Kuiu interior (interpolated)
            CLLocationCoordinate2D(latitude: 56.7500, longitude: -134.0800),
            // Mile 10 — Headwaters, interior Kuiu muskeg ponds (interpolated, no published source)
            CLLocationCoordinate2D(latitude: 56.7200, longitude: -134.1700),
        ],

        // Farragut River: ~15-mile mainland river in the Coast Mountains east
        // of Frederick Sound (Tongass NF, Petersburg Ranger District). Heads
        // at Glory Lake and flows southwest through a glacial U-valley to
        // Francis Anchorage at the south end of Farragut Bay. No USGS or
        // NOAA NWPS gauge; nearest tide reference is NOAA Petersburg (9451204).
        "Farragut River": [
            // Mile 0 — Mouth at Francis Anchorage, SW arm of Farragut Bay (interpolated from NOAA Chart 17367 and bay geometry)
            CLLocationCoordinate2D(latitude: 57.1200, longitude: -133.0800),
            // Mile 5 — Lower valley, tidal / braided reach (interpolated)
            CLLocationCoordinate2D(latitude: 57.1900, longitude: -133.0200),
            // Mile 10 — Upper valley, approaching Coast Mountains front (interpolated)
            CLLocationCoordinate2D(latitude: 57.2800, longitude: -132.9500),
            // Mile 15 — Headwaters at Glory Lake (Verified — GNIS source coords 57°21'28"N 132°54'39"W)
            CLLocationCoordinate2D(latitude: 57.3578, longitude: -132.9108),
        ],

        // ─────────────────────────────────────────────
        // British Columbia — Skeena Region
        // ─────────────────────────────────────────────

        // Copper River (official WSC name: Zymoetz River): ~90-mile tributary
        // of the Skeena River near Terrace, BC. Flows SW from headwaters in
        // the Bulkley Ranges (Hazelton Mountains) to the Skeena at Zaimoetz
        // IR No. 5. Active WSC gauge 08EF005 "above O.K. Creek." Not tidal
        // (Skeena confluence is ~80 km inland). Major tributaries: Clore River,
        // Kitnayakwa River, Limonite Creek. Class II angling water below
        // Limonite Creek; Class I above.
        "Copper River": [
            // Mile 0 — Mouth at Skeena River confluence, Zaimoetz IR No. 5, east of Terrace (Verified — Wikipedia/GNIS)
            CLLocationCoordinate2D(latitude: 54.5450, longitude: -128.4858),
            // Mile 5 — Lower river, downstream of former WSC 08EF003 site (interpolated from OSM)
            CLLocationCoordinate2D(latitude: 54.5250, longitude: -128.4200),
            // Mile 10 — WSC 08EF005 gauge, above O.K. Creek (Verified — ECCC, drainage 2919 km²)
            CLLocationCoordinate2D(latitude: 54.4940, longitude: -128.3250),
            // Mile 15 — Below Limonite Creek, Class II angling water (interpolated from OSM)
            CLLocationCoordinate2D(latitude: 54.4820, longitude: -128.2400),
            // Mile 20 — Approaching Limonite Creek area (interpolated)
            CLLocationCoordinate2D(latitude: 54.4720, longitude: -128.1700),
            // Mile 25 — Limonite Creek confluence area, Class I/II boundary (interpolated)
            CLLocationCoordinate2D(latitude: 54.4660, longitude: -128.1000),
            // Mile 30 — Mid-river, course bending eastward (interpolated from OSM way junction)
            CLLocationCoordinate2D(latitude: 54.4612, longitude: -128.0059),
            // Mile 35 — River turning northward through valley (interpolated from OSM)
            CLLocationCoordinate2D(latitude: 54.4700, longitude: -127.9600),
            // Mile 40 — Mid-upper river (interpolated from OSM)
            CLLocationCoordinate2D(latitude: 54.4900, longitude: -127.9400),
            // Mile 45 — Upper river valley (interpolated from OSM)
            CLLocationCoordinate2D(latitude: 54.5200, longitude: -127.9300),
            // Mile 50 — Clore River confluence area (interpolated)
            CLLocationCoordinate2D(latitude: 54.5500, longitude: -127.9400),
            // Mile 55 — Above Clore River (interpolated from OSM)
            CLLocationCoordinate2D(latitude: 54.5900, longitude: -127.9500),
            // Mile 60 — Upper valley, Kitnayakwa River approach (interpolated)
            CLLocationCoordinate2D(latitude: 54.6300, longitude: -127.9300),
            // Mile 65 — Kitnayakwa River confluence area (interpolated)
            CLLocationCoordinate2D(latitude: 54.6700, longitude: -127.8800),
            // Mile 70 — Upper river, approaching Bornite Range (interpolated)
            CLLocationCoordinate2D(latitude: 54.7000, longitude: -127.7800),
            // Mile 75 — O.K. Range foothills (interpolated)
            CLLocationCoordinate2D(latitude: 54.7200, longitude: -127.6800),
            // Mile 80 — Upper headwaters reach (interpolated from OSM)
            CLLocationCoordinate2D(latitude: 54.7400, longitude: -127.5500),
            // Mile 85 — Near headwaters, Bulkley Ranges approach (interpolated)
            CLLocationCoordinate2D(latitude: 54.7500, longitude: -127.4500),
            // Mile 90 — Headwaters, Bulkley Ranges, Hazelton Mountains, elev 1078m (Verified — Wikipedia)
            CLLocationCoordinate2D(latitude: 54.7336, longitude: -127.3736),
        ],

        // ─────────────────────────────────────────────
        // Washington — Columbia Basin / Yakima River
        // ─────────────────────────────────────────────

        "Yakima River": [
            // Mile 0 — Mouth at Columbia River confluence, Bateman Island, Richland
            CLLocationCoordinate2D(latitude: 46.2497, longitude: -119.2287),
            // Mile 5 — West Richland, Van Giesen St area (interpolated)
            CLLocationCoordinate2D(latitude: 46.2730, longitude: -119.3050),
            // Mile 10 — Horn Rapids ORV park area (interpolated)
            CLLocationCoordinate2D(latitude: 46.2870, longitude: -119.3700),
            // Mile 15 — North loop toward Kiona (interpolated)
            CLLocationCoordinate2D(latitude: 46.2950, longitude: -119.4280),
            // Mile 20 — River bends back south through wetlands (interpolated)
            CLLocationCoordinate2D(latitude: 46.2750, longitude: -119.4500),
            // Mile 25 — Approaching Kiona from north (interpolated)
            CLLocationCoordinate2D(latitude: 46.2580, longitude: -119.4700),
            // Mile 30 — USGS 12510500 Yakima R at Kiona, WA (Verified — USGS)
            CLLocationCoordinate2D(latitude: 46.2528, longitude: -119.4803),
            // Mile 35 — Heading SW toward Benton City (interpolated)
            CLLocationCoordinate2D(latitude: 46.2350, longitude: -119.5800),
            // Mile 40 — Benton City vicinity (interpolated)
            CLLocationCoordinate2D(latitude: 46.2400, longitude: -119.6700),
            // Mile 45 — Approaching Prosser (interpolated)
            CLLocationCoordinate2D(latitude: 46.2240, longitude: -119.7400),
            // Mile 50 — Prosser, Hwy 221 bridge
            CLLocationCoordinate2D(latitude: 46.2069, longitude: -119.7639),
            // Mile 55 — West of Prosser, river bends NW (interpolated)
            CLLocationCoordinate2D(latitude: 46.2200, longitude: -119.8400),
            // Mile 60 — Toward Mabton (interpolated)
            CLLocationCoordinate2D(latitude: 46.2300, longitude: -119.9100),
            // Mile 65 — Mabton
            CLLocationCoordinate2D(latitude: 46.2086, longitude: -119.9917),
            // Mile 70 — North of Mabton, NW course (interpolated)
            CLLocationCoordinate2D(latitude: 46.2400, longitude: -120.0500),
            // Mile 75 — Between Sunnyside and Granger (interpolated)
            CLLocationCoordinate2D(latitude: 46.2900, longitude: -120.1100),
            // Mile 80 — Granger
            CLLocationCoordinate2D(latitude: 46.3415, longitude: -120.1859),
            // Mile 85 — Granger to Zillah (interpolated)
            CLLocationCoordinate2D(latitude: 46.3700, longitude: -120.2700),
            // Mile 90 — North of Zillah (interpolated)
            CLLocationCoordinate2D(latitude: 46.4150, longitude: -120.3100),
            // Mile 95 — Wapato vicinity (interpolated)
            CLLocationCoordinate2D(latitude: 46.4500, longitude: -120.3700),
            // Mile 100 — South Union Gap approaches (interpolated)
            CLLocationCoordinate2D(latitude: 46.5000, longitude: -120.4400),
            // Mile 105 — Union Gap
            CLLocationCoordinate2D(latitude: 46.5530, longitude: -120.4760),
            // Mile 110 — Yakima city
            CLLocationCoordinate2D(latitude: 46.6020, longitude: -120.5100),
            // Mile 115 — Selah, north of Yakima
            CLLocationCoordinate2D(latitude: 46.6540, longitude: -120.5400),
            // Mile 117 — Naches River confluence
            CLLocationCoordinate2D(latitude: 46.6690, longitude: -120.5860),
            // Mile 120 — Entering Yakima River Canyon at Selah Gap (interpolated)
            CLLocationCoordinate2D(latitude: 46.6960, longitude: -120.5000),
            // Mile 125 — Roza Dam, head of canyon
            CLLocationCoordinate2D(latitude: 46.7370, longitude: -120.4610),
            // Mile 130 — Mid-canyon (interpolated)
            CLLocationCoordinate2D(latitude: 46.7850, longitude: -120.4700),
            // Mile 135 — Umtanum Recreation Area (interpolated)
            CLLocationCoordinate2D(latitude: 46.8500, longitude: -120.4900),
            // Mile 140 — Canyon exit, Thrall area (interpolated)
            CLLocationCoordinate2D(latitude: 46.9000, longitude: -120.5200),
            // Mile 145 — South Ellensburg approaches (interpolated)
            CLLocationCoordinate2D(latitude: 46.9500, longitude: -120.5400),
            // Mile 150 — Ellensburg, I-90 bridge
            CLLocationCoordinate2D(latitude: 46.9890, longitude: -120.5410),
            // Mile 155 — West Ellensburg, NW (interpolated)
            CLLocationCoordinate2D(latitude: 47.0250, longitude: -120.6100),
            // Mile 160 — Toward Thorp (interpolated)
            CLLocationCoordinate2D(latitude: 47.0500, longitude: -120.6900),
            // Mile 165 — Thorp
            CLLocationCoordinate2D(latitude: 47.0720, longitude: -120.8040),
            // Mile 170 — Thorp to Cle Elum (interpolated)
            CLLocationCoordinate2D(latitude: 47.1000, longitude: -120.8400),
            // Mile 175 — South of Cle Elum (interpolated)
            CLLocationCoordinate2D(latitude: 47.1450, longitude: -120.8800),
            // Mile 180 — USGS 12484500 Yakima R at Cle Elum, WA (Verified — USGS)
            CLLocationCoordinate2D(latitude: 47.1955, longitude: -120.9398),
            // Mile 185 — West of Cle Elum (interpolated)
            CLLocationCoordinate2D(latitude: 47.2150, longitude: -121.0100),
            // Mile 190 — Approaching Easton (interpolated)
            CLLocationCoordinate2D(latitude: 47.2350, longitude: -121.0900),
            // Mile 195 — Easton
            CLLocationCoordinate2D(latitude: 47.2410, longitude: -121.1870),
            // Mile 200 — Easton to Keechelus (interpolated)
            CLLocationCoordinate2D(latitude: 47.2700, longitude: -121.2400),
            // Mile 205 — Keechelus dam approach (interpolated)
            CLLocationCoordinate2D(latitude: 47.3050, longitude: -121.3000),
            // Mile 214 — Headwaters, Keechelus Lake outlet / dam, Cascade Mountains
            CLLocationCoordinate2D(latitude: 47.3270, longitude: -121.3300),
        ],
    ]

    /// Default search radius (km) from any spine point to count as "on" a river.
    static let defaultMaxDistanceKm: Double = 10.0
}
