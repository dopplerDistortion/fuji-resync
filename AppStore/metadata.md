# App Store metadata

The text for App Store Connect, kept here so it changes with the app. Limits are App Store Connect's.
The URLs assume GitHub Pages serves `docs/` from `main`.

## App information

| field | value |
|---|---|
| name (30) | `resync: film recipes` |
| subtitle (30) | `Recipes, geotags and remote` |
| bundle ID | `ing.goksen.resync` |
| SKU | `resync-ios` |
| primary category | Photo & Video |
| secondary category | Utilities |
| age rating | 4+ (answer "none" to every question; no web access, no user content shared with others) |
| price | free |
| copyright | `2026 Göksenin` (use your full legal name) |
| privacy policy URL | https://dopplerdistortion.github.io/fuji-resync/privacy.html |
| support URL | https://dopplerdistortion.github.io/fuji-resync/support.html |
| marketing URL | https://dopplerdistortion.github.io/fuji-resync/ |

Keep "Fujifilm", "Fuji" and camera model names out of the name, subtitle and keywords (guideline 2.3.7 and 5.2.1). The description may say which camera it works with, with the disclaimer below.

## Promotional text (170)

```
Write film recipes to your camera's custom settings, keep photos geotagged with the phone in your pocket, and see where you shot on a map.
```

## Keywords (100)

```
film,recipes,simulation,geotag,gps,camera,remote,shutter,liveview,custom,settings,mirrorless,map
```

## Description (4000)

```
resync is a companion for the Fujifilm X-T30 II.

RECIPES
Keep a library of film simulation recipes. Edit every setting the camera's custom slots hold, paste a recipe from a website as text, import and export files, and write a recipe to any of C1–C7 over a USB-C cable. resync also reads back what's in the camera, so you can see which recipes are loaded and pull the ones you don't have yet.

GEOTAGS
Pair the camera over Bluetooth once. From then on the camera asks the phone for its location and the time, and writes them into every photo, while the phone stays in your pocket.

SHOOTING SESSIONS
Start a session before a walk. resync keeps the camera linked in the background, shows the link and the last geotag in a Live Activity on the lock screen and in the Dynamic Island, and records your route for the map.

MAP
Plug the camera in and resync pins where each photo was taken, next to the routes of your sessions.

REMOTE
Live view and the shutter over the camera's own Wi-Fi. resync joins the camera's network by itself.

PRIVATE BY DESIGN
No account, no ads, no analytics. Your recipes, routes and photo places stay on your phone.

resync needs a compatible camera for its camera features. Recipes, import and export work without one.

resync is an independent app and is not affiliated with, endorsed by or sponsored by FUJIFILM Corporation. FUJIFILM and X-T30 are trademarks of FUJIFILM Corporation.
```

## What's new (version 1.0.0)

```
First release.
```

## App Review information

Sign-in: not required.

Notes:

```
resync controls a Fujifilm X-T30 II camera, which talks to it over Bluetooth LE, its own Wi-Fi network (PTP/IP) and USB-C (PTP via ImageCaptureCore). A demo video of every camera feature on a real camera is linked below.

Without a camera you can still use the recipe library: open any recipe to edit it, tap "new" to create one, long-press a recipe to duplicate or share it, and use import to read a recipe from text. "send to camera" queues the write until a cable is connected.

Background modes:
- location: during a shooting session, which the user starts and stops on the camera tab, the app records the user's route and keeps answering the camera's location requests, so photos are geotagged with the phone locked. iOS shows the location indicator for the whole session, and a Live Activity shows the session. Outside a session, background location is used only while a paired camera is linked and only with "Always" permission, for the same geotagging.
- bluetooth-central: the camera asks the phone for location and time over Bluetooth about every ten seconds; the app answers in the background.

Hotspot Configuration: used only to join the camera's own "FUJIFILM-…" Wi-Fi network for live view and the remote shutter.

Demo video: <link>
```

## App Privacy (the questionnaire)

resync itself collects nothing. The Mapbox Maps SDK collects anonymous telemetry, which Apple counts as the app's collection. Check these against Mapbox's current guide before answering: https://docs.mapbox.com/ios/maps/guides/privacy/ (it lists the answers for the SDK version in `project.yml`).

| data type | collected by | linked to user | tracking | purpose |
|---|---|---|---|---|
| Location: coarse location | Mapbox SDK | no | no | Analytics |
| Usage data: product interaction | Mapbox SDK | no | no | Analytics |
| Diagnostics: crash data, performance data | Mapbox SDK | no | no | App functionality, analytics |

Everything else: not collected. Location sent to the camera and the routes and photo places kept on the phone don't count, because they never leave the device to a server.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `NO` in `App/Support/Info.plist`: the app uses only the encryption built into iOS (HTTPS for Mapbox tiles), so App Store Connect won't ask on each build.

## Screenshots

`scripts/screenshots.sh` on the Mac writes the 6.9" set (iPhone 18 Pro Max, 1320 × 2868) to `build/screenshots/`. iPhone only, so no iPad set is needed.
