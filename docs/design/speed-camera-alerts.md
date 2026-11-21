# Speed-camera alerts on the HUD (experimental)

**Status:** design and investigation. Lives on branch `feature/speed-camera-alerts`, not in `main`, until it has
been tested on a car.

## Goal

Show a camera warning in the head-up display, with the distance counting down, when the car is within **700 m** of
a fixed speed camera ahead **and** travelling **above 100 km/h**. Below 100 km/h nothing is shown, so city driving
stays quiet. Both numbers are settings (`alert_distance_m = 700`, `min_speed_kmh = 100`).

## Legal note

Rules differ by country. GPS-based camera alerts are legal in some countries (Google Maps and Waze show them in
the UAE, for example) and illegal in others (for example Germany, France, Switzerland). Radar detectors are
something else and are not part of this. The feature ships **off by default**, and the README must say to check
local law.

## Factory option first

BMW sells **Traffic Camera Information** (ConnectedDrive Store), which warns about fixed speed and red-light
cameras, including on the head-up display, on supported cars. Availability depends on country, equipment,
software level and production date. Check whether it's offered for the car before building anything.

## Do-it-yourself design

| Part | Plan |
|---|---|
| Position and speed | From the head unit's own GPS / navigation (QNX PPS objects such as geolocation or navigation status). To be found with a read-only probe on the car. |
| Camera list | OpenStreetMap `highway=speed_camera` points (ODbL licence, attribution in NOTICE.md) and/or your own CSV file (lat, lon, limit, direction). Prepared on the laptop, copied into `/fs/sda0/opt/aa-cp`; the car never downloads anything. |
| Alert logic | **Start** when a camera is within 700 m and roughly ahead (bearing to the camera within about 30 degrees of the car's heading, and matching the camera's direction if known) **and** the speed is above 100 km/h. **Keep showing** it until the camera is passed, even if you slow below 100 km/h on the approach, so the warning doesn't vanish while braking. **Clear** when the camera is behind the car or 30 s after passing. Distance updated every 50 m. One alert per camera; the same camera can't trigger again for 5 minutes. Below 100 km/h no new alert ever starts. |
| Display | The instrument cluster's **navigation guidance** service, the same channel as the CarPlay arrows: straight-ahead arrow, distance countdown, text such as `SPEED CAMERA 100`. Never interrupts an active turn instruction; to be tuned after testing. It uses only the navigation display: no driver-assistance or speed-limit-sign channels. |
| Where it runs | A small helper on the head unit, started by the existing starter script while the iPhone is connected. No boot-script changes. |
| Build | Needs the QNX 6.5 cross-compiler (the same blocker as lane arrows: virtualization is off on the build laptop, or use GitHub Actions). |

## Test plan

1. Read-only probe: find where the head unit publishes position, heading and speed.
2. Memory-only test: helper copied to `/dev/shmem` and started by hand over SSH (a restart removes it), with a test
   "camera" placed on a known road. A passenger operates the laptop.
3. Real cameras on a familiar route, passenger watching the HUD.
4. Only then: a wizard step and a release.

## Open questions

- Decided: alert only within 700 m **and** above 100 km/h. Possible later option (off by default): also warn below
  100 km/h when above the camera's own limit, for city cameras.
- Should a camera alert show while Google Maps guidance is active, and how?
- Which camera sources to use for your region.

## Camera data sources (for use worldwide)

The project ships **no camera data**. The wizard downloads or imports it **on the user's laptop** for the
countries they choose, converts it, and copies a compact file into `/fs/sda0/opt/aa-cp`. The car never goes online.
Each source's licence and attribution travel with the converted file.

| Source | Coverage | Licence / use | Role |
|---|---|---|---|
| **OpenStreetMap**: `highway=speed_camera` nodes, `enforcement` relations (`enforcement=maxspeed`, `maxspeed`, device/from/to members), `highway=red_light_camera` | Worldwide, but uneven: in 2021, for example, France had about 600 tagged cameras, Germany about 490, the US about 50, the UK about 13 | ODbL 1.0: free to use; attribution "(c) OpenStreetMap contributors"; a database derived from it stays ODbL | **Default, global.** Fetched per country or region (Overpass API with fair use, or a Geofabrik extract) |
| **Government open data**, per country or state, for example Transport for NSW (Australia): fixed, red-light, school-zone and mobile camera locations | Only where a government publishes it; often very complete | Varies; NSW is CC BY 3.0 AU and is updated about yearly | **Optional adapters**, added country by country when a user asks and the licence allows it |
| **Your own file (CSV)**: `lat,lon,type,limit,direction` | Whatever you have the right to use, for example a database you bought for personal use | Your responsibility under that product's terms | **Import**, never redistributed by this project |
| Waze, Google, TomTom, HERE and other commercial databases | Good | Proprietary: no free API; TomTom and HERE are paid licences | **Not used**, unless a user imports a file they're licensed to use |

Data quality rules: drop duplicates within 30 m; use `direction` (OSM) when present so cameras for the opposite
carriageway don't trigger; keep the camera's own limit when known (for the possible later "above the camera's limit" option);
store when the data was fetched, and remind the user to refresh it after 90 days.

### Legality, per country

Camera alerts are **banned in some countries**: for example Germany and Switzerland ban devices that warn of
speed cameras, and France only allows warnings about general "danger zones". Elsewhere they're legal and built into
Google Maps and Waze. So the feature: ships **off**; asks for the country when you switch it on; shows that
country's rule if it's known to be restrictive; and leaves the decision and responsibility with the user. The list
of restrictive countries is kept in a data file people can correct by pull request.

## Turning it on and off in the iDrive

Not inside BMW's own Head-Up Display menu: that menu belongs to BMW's iDrive software, and adding items to it would
mean patching factory files for every software version. Instead it gets **its own iDrive app** under My Vehicle,
using the same community iDrive-app framework (ID6 apps) that already runs BoostDeck and MHD+ on NBT EVO cars:

1. **HUD camera alerts: On / Off** (off by default).
2. Switching it on asks, with the iDrive controller:
   - **Distance:** 300 / 500 / **700** / 1000 m
   - **Only above:** 60 / 80 / **100** / 120 / 140 km/h
   - **Country**, then shows that country's rule if camera alerts are restricted there, and needs a confirm.
3. The choices are saved on the head unit, and the camera helper reads them within a few seconds.

The settings page is static (no fast refresh), so it stays clear of the iDrive freezes seen with apps that redraw
every 16-25 ms. Building the app needs the same QNX build setup, plus a licence check of the ID6 apps framework
before anything that depends on it is published.
