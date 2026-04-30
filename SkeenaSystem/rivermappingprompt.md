# River GPS Mapping, Water Stations & Tidal Stations — Reusable Prompt

**Version 3** — Supports US rivers (USGS), Canadian rivers (Water Survey of Canada), remote/Alaska rivers (NOAA NWPS), and tidal station identification. Outputs two separate files: a **Water Stations Import** and a **GPS Coordinates** file.

---

## How to Use

1. Copy everything in **"The Prompt"** section below
2. Paste it into a new session
3. Fill in the **[BRACKETED]** fields at the top with your river details
4. For multiple rivers, list them all in the River to Map section

---

## The Prompt

---

I need you to map GPS coordinates along a river, identify the best water monitoring station(s), and find the nearest tidal station if the river is tidal. Follow the methodology and output format exactly.

### River(s) to Map

- **River name:** [RIVER NAME]
- **Country/Region:** [US STATE, CANADIAN PROVINCE, or OTHER]
- **Starting point:** The river mouth (where it meets the ocean, a bay, or its confluence with a larger river)
- **Ending point:** [TOWN, LANDMARK, or "as far upstream as possible"]
- **Interval:** Every 5 river miles

---

### PHASE 1: Research Methodology

Follow these steps in order:

**Step 1 — Locate the river mouth.**
Search for the GNIS (US) or GeoNames/NRCan (Canada) coordinates for the river mouth. Confirm with USGS, Wikipedia, or government data.

**Step 2 — Gather verified anchor points.**
Search for real, published GPS coordinates along the river from these sources (prioritize in this order):
- Government gauging stations (USGS, Water Survey of Canada, NOAA) — these have exact lat/long
- County/state/provincial boat ramp databases with published coordinates
- Named campgrounds, parks, recreation sites, and day-use areas with published coordinates
- Highway bridge crossings (from DOT data, topo maps)
- Topographic map feature coordinates (TopoZone, GNIS, GeoNames)
- State/provincial environmental quality monitoring sites with coordinates (e.g., Oregon DEQ, BC ENV)
- Fishing lodges or access points with known coordinates

**Step 3 — Establish the river path.**
Using the anchor points above, trace the river's general course noting:
- The compass direction it flows (e.g., "flows generally east-to-west")
- Major bends or direction changes
- Key confluences with tributaries
- Which county/counties or regional districts it passes through
- Total river length in miles

**Step 4 — Interpolate between anchor points.**
For miles that fall between verified points, interpolate coordinates following the river's known course. These are approximations — note this clearly.

**Step 5 — Identify water monitoring stations.**
The type of station depends on the country:

**For US rivers (including Alaska) — check in this order:**

1. **USGS gauging stations** (waterdata.usgs.gov)
   - Search: `"[river name]" USGS site number monitoring location`
   - Station IDs are typically 8 digits (e.g., 15242000) or 15 digits for newer sites
   - Parameter codes:
     - **00065** = Gauge height / water level (feet)
     - **00060** = Streamflow / discharge (cubic ft/sec)
     - **00010** = Water temperature (°C)
     - **00045** = Precipitation
   - Identify which station has the MOST parameters — especially water level + temperature

2. **If no USGS station exists**, check for a **NOAA National Water Prediction Service** gauge:
   - Search: `"[river name]" NOAA water gauge`
   - These use short alphanumeric codes (e.g., "toga2")
   - Data URL format: `https://water.noaa.gov/gauges/[CODE]`
   - These typically provide water level and discharge but NOT temperature

3. **If neither exists**, identify the nearest river with a USGS gauge as a proxy (similar watershed size, adjacent drainage, similar elevation)

**For Canadian rivers (BC, AB, etc.):**

1. **Water Survey of Canada (WSC) hydrometric stations** (wateroffice.ec.gc.ca)
   - Search: `"[river name]" Water Survey of Canada station`
   - Station IDs use format like 08EF001, 08EC013, etc.
   - Operator: Water Survey of Canada / Environment and Climate Change Canada (ECCC)
   - Parameters: Water level (param 46), Discharge (param 47), Water temperature
   - Data URL: `https://wateroffice.ec.gc.ca/services/recent_real_time_data/csv/inline?stations[]=STATION_ID&parameters[]=46&parameters[]=47`

2. **If no WSC station exists**, identify the nearest monitored river as a proxy

**Step 6 — Identify tidal station (if applicable).**
Determine if the river is tidal near its mouth:
- If the river enters the ocean, a bay, or a tidal estuary, it IS tidal near the mouth
- Note the approximate extent of tidal influence (e.g., "tidal influence extends ~7 miles upstream")
- If the river is entirely inland (e.g., meets another river far from the coast), note it as non-tidal

**For tidal rivers, find the nearest tidal station:**

**US rivers:**
- Search NOAA CO-OPS: `NOAA tide station [nearest coastal town] [state]`
- Station IDs are 7 digits (e.g., 9455760)
- Operator: NOAA CO-OPS
- Get: Station ID, name, and GPS coordinates
- Station URL: `https://tidesandcurrents.noaa.gov/stationhome.html?id=[STATION_ID]`
- API: `https://tidesandcurrents.noaa.gov/api/datagetter?station=[ID]&product=predictions&datum=MLLW&time_zone=lst_ldt&units=english&format=json&begin_date=YYYYMMDD&range=24`

**Canadian rivers:**
- Search Canadian Hydrographic Service (CHS): `tides.gc.ca [nearest coastal town]`
- Station IDs are typically 5 digits (e.g., 09354)
- Operator: Canadian Hydrographic Service (CHS)
- Get: Station ID, name, and GPS coordinates
- Station URL: `https://www.tides.gc.ca/en/stations/[STATION_ID]`

---

### PHASE 2: Output Format

Produce **two separate files** for each batch of rivers:

---

#### FILE 1: Water Stations Import (`water-stations-import.md`)

One row per river in this exact table format. If a river spans two states/provinces, split it into two rows (one per state).

**Column Reference:**

| Column | Required | Default | Description |
|---|---|---|---|
| name | ✅ | — | Display name of the water body (e.g. "Skagit River") |
| water_type | ✅ | river | One of: `river`, `canal`, `sound`, `other` |
| country | ✅ | US | ISO country code (e.g. `US`, `CA`) |
| state_province | ✅ | *(empty)* | State or province (e.g. `WA`, `BC`) |
| source | ✅ | USGS | Data source for conditions: `USGS`, `WSC`, etc. |
| station_id | ❌ | — | BEST station ID (most parameters). Leave blank if no dedicated gauge exists. |
| is_tidal | ✅ | false | `true` if the water is tidal near the mouth |
| tide_station_id | ❌ | — | Nearest tidal station ID. Leave blank if non-tidal. |
| tide_source | ❌ | NOAA | Tide data provider: `NOAA`, `CHS`. Leave blank if non-tidal. |
| latitude | ❌ | — | Decimal latitude of the river mouth (e.g. 48.5126) |
| longitude | ❌ | — | Decimal longitude of the river mouth (e.g. -121.9836) |

**Rules:**
- Use the **river mouth** coordinates for latitude/longitude
- Use the **BEST** monitoring station ID (most parameters — prioritize water level + temperature)
- If no dedicated gauge exists on the river, leave `station_id` blank
- For US rivers, `source` = `USGS`. For Canadian rivers, `source` = `WSC`
- If a river crosses state/province lines, create one row per state/province

**Example output:**

```
| name | water_type | country | state_province | source | station_id | is_tidal | tide_station_id | tide_source | latitude | longitude |
|---|---|---|---|---|---|---|---|---|---|---|
| Kispiox River | river | CA | BC | WSC | 08EB003 | false | | | 55.3456 | -127.6789 |
| Situk River | river | US | AK | USGS | 15129500 | true | 9453220 | NOAA | 59.4353 | -139.5467 |
| Ocean River | river | US | AK | USGS | | true | 9465374 | NOAA | 56.5619 | -159.7564 |
| Klamath River (California) | river | US | CA | USGS | 11516530 | true | 9419750 | NOAA | 41.5331 | -124.0811 |
| Klamath River (Oregon) | river | US | OR | USGS | 11509500 | false | | | 42.1332 | -121.9622 |
| Williamson River | river | US | OR | USGS | 11502500 | false | | | 42.4900 | -121.9300 |
```

---

#### FILE 2: GPS Coordinates (`river-gps-coordinates.md`)

One block per river listing every 5-mile coordinate from mouth to headwaters. Use plain text, not code blocks.

**Rules:**
- Use 4 decimal places for all coordinates
- Longitude is negative for the Western Hemisphere
- Label Point 1 as `(mouth)` and the final point as `(headwaters)`
- If a river spans two states, keep the points in one continuous block but note the state line transition
- If the river is shorter than the 5-mile interval would suggest, stop at headwaters and note total length

**Format:**

```
River Name: [River Name] ([State/Province])
  Point 1 (mouth):        XX.XXXX, -XXX.XXXX
  Point 2:                XX.XXXX, -XXX.XXXX
  Point 3:                XX.XXXX, -XXX.XXXX
  ...
  Point N (headwaters):   XX.XXXX, -XXX.XXXX
```

**Example output:**

```
River Name: Kispiox River (British Columbia)
  Point 1 (mouth):        55.3456, -127.6789
  Point 2:                55.3600, -127.6500
  Point 3:                55.3800, -127.6200
  Point 4:                55.3950, -127.5900
  Point 5 (headwaters):   55.4100, -127.5800

River Name: Situk River (Alaska)
  Point 1 (mouth):        59.4353, -139.5467
  Point 2:                59.4700, -139.5200
  Point 3:                59.5100, -139.5000
  Point 4:                59.5500, -139.4800
  Point 5 (headwaters):   59.5864, -139.4600

River Name: Klamath River (California / Oregon)
  Point 1 (mouth):        41.5331, -124.0811
  Point 2:                41.5330, -123.9900
  Point 3:                41.5330, -123.8989
  ...
  Point 33 (OR/CA line):  41.9306, -122.4431
  Point 34:               41.9500, -122.3900
  ...
  Point 53 (headwaters):  42.3982, -121.9236
```

---

### Important Notes

- **Accuracy caveat:** Interpolated coordinates are approximations based on known reference points and should be verified against satellite imagery.
- **River length:** If the river is shorter than 50 miles, say so and only provide coordinates for its actual length.
- **Forks:** Follow the main stem. If it ends at a fork confluence, note it and continue up the longer fork, clearly marking the transition.
- **Multiple rivers:** Process all rivers, then output both files covering the full batch.
- **Remote rivers:** Some rivers (especially in Alaska and northern BC) may have no gauge at all, or only a NOAA water prediction gauge. Note this clearly in the fisheries configuration file by leaving `station_id` blank.
- **Canadian vs US:** Use the correct agency names and source codes — `WSC` for Canadian rivers, `USGS` for US rivers. Don't mix them up.
- **Cross-border rivers:** If a river crosses state/province boundaries, create one row per state/province in the fisheries configuration file, but keep the GPS coordinates as a single continuous block with the boundary noted.

---

## Example Usage

**Example 1 — US coastal river:**
> River name: Rogue River
> Country/Region: Oregon, US
> Ending point: Grants Pass

**Example 2 — Canadian river:**
> River name: Skeena River
> Country/Region: British Columbia, Canada
> Ending point: As far upstream as possible

**Example 3 — Remote Alaska river:**
> River name: Togiak River
> Country/Region: Alaska, US
> Ending point: Togiak Lake (source)

**Example 4 — Multiple rivers at once:**
> Map the following rivers using the methodology above:
> 1. Wilson River (Oregon) — mouth to headwaters
> 2. Bulkley River (British Columbia) — mouth to Bulkley Lake
> 3. Kasilof River (Alaska) — mouth to Tustumena Lake
