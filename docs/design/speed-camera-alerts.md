# Speed-camera alerts on the HUD (experimental)

**Status:** design and investigation. Lives on branch `feature/speed-camera-alerts`, not in `main`, until it has
been tested on a car.

## Goal

When the car is within **700 m** of a fixed speed camera ahead, at **100 km/h or more** (both configurable),
show a camera warning in the head-up display with the distance counting down.

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
| Alert logic | Camera within 700 m, roughly ahead (bearing to the camera within about 30 degrees of the car's heading, and matching the camera's direction if known), speed at or above the threshold. One alert per camera; distance updated every 50 m; cleared after passing it or after 30 s. |
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

- The exact trigger: at or above 100 km/h, or above the camera's own limit?
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
carriageway don't trigger; keep the camera's own limit when known (for the "above the camera's limit" trigger);
store when the data was fetched, and remind the user to refresh it after 90 days.

### Legality, per country

Camera alerts are **banned in some countries**: for example Germany and Switzerland ban devices that warn of
speed cameras, and France only allows warnings about general "danger zones". Elsewhere they're legal and built into
Google Maps and Waze. So the feature: ships **off**; asks for the country when you switch it on; shows that
country's rule if it's known to be restrictive; and leaves the decision and responsibility with the user. The list
of restrictive countries is kept in a data file people can correct by pull request.
