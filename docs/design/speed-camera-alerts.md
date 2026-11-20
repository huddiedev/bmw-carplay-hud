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
