# resync

A personal iPhone companion for the Fujifilm X-T30 II, styled with the [goksen.ing design system](https://goksen.ing/system).

| feature | how it talks to the camera |
|---|---|
| **recipes**: library, editor, import/export, write to C1–C7 | USB-C, PTP through ImageCaptureCore |
| **sync**: automatic location and time for geotags | Bluetooth LE, the camera asks and the phone answers |
| **remote**: live view and shutter | the camera's own Wi-Fi (`192.168.0.1`, ports 55740–55742) |

There's no official SDK, so the app relies on reverse-engineered protocols. Most of it now runs on a real X-T30 II and iPhone. See [what's verified](#status).

## build

Requirements: Xcode 26+ (the Mapbox SDK is built with Swift 6.2), iOS 17+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put your team ID in it (gitignored)
xcodegen generate
open Resync.xcodeproj
```

Run it on a device. Bluetooth, USB and Wi-Fi don't work in the simulator.

- **Signing:** set `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`. Any team, free or paid, can sign the default build. If the phone isn't on the camera's `FUJIFILM-…` network, join it in Settings → Wi-Fi before starting live view.
- **Paid developer team:** also set `RESYNC_ENTITLEMENTS = App/Support/Resync-Hotspot.entitlements` in `Config/Local.xcconfig` and run `xcodegen generate`. The app then joins the camera's network by itself when live view starts. Personal (free) teams can't sign this entitlement.
- **7-day limit:** apps signed by a personal team expire after 7 days. Build again from Xcode to refresh it.
- **UI tests:** `xcodebuild -project Resync.xcodeproj -scheme Resync -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test`. They launch the app with `-uitest`: a fresh library of the starter recipes, C1–C3 plus an unknown C5 as if read from the camera, and no permission prompts. Screenshots are attached to the result bundle.
- **Protocol tests:** `cd FujiKit && swift test`. These need no device.

## release

- **App Store text, privacy answers and review notes:** [`AppStore/metadata.md`](AppStore/metadata.md).
- **Privacy policy and support pages:** `docs/`, served by GitHub Pages (Settings → Pages → `main`, `/docs`).
- **Screenshots:** `scripts/screenshots.sh` on a Mac writes the 6.9" set from the simulator to `build/screenshots/`, with a 9:41 status bar. `RESYNC_SIM` picks another simulator.
- **TestFlight:** `scripts/archive.sh` archives a Release build with a timestamp build number and uploads it to App Store Connect. It needs `Config/Local.xcconfig` with the team, the Hotspot entitlements and the Mapbox token, and the app's record in App Store Connect. `ARCHIVE_ONLY=1` stops after the archive.
- **Privacy manifest:** `App/Support/PrivacyInfo.xcprivacy`. Add a reason there if the app starts using another [required-reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

## camera setup

- **recipes over USB:** MENU → SET UP → CONNECTION SETTING → PC CONNECTION MODE → **USB RAW CONV./BACKUP RESTORE**. Use a USB-C data cable no longer than 1.5 m.
- **GPS sync:** MENU → NETWORK/USB SETTING → Bluetooth settings → **pairing registration**, then tap *scan* in the app. Turn on *geotagging* and *location info*. Allow location "always" on the phone so it keeps syncing in the background.
- **photo map:** when the camera is on the cable, resync reads the GPS of every photo on the card it hasn't read before and pins it on the shoot tab's map. On the X-T30 II the card is listed only in **USB CARD READER** mode; RAW CONV./BACKUP RESTORE gives the custom settings and an empty card, so recipes and photos need different modes. Between reads, the map also trails each location resync sent the camera (the camera asks about every 10 s while linked).
- **Mapbox map:** with a public token in `Config/Local.xcconfig` (`MAPBOX_ACCESS_TOKEN = pk.…`), the map draws the style in `App/Resources/MapStyle.json` with the Mapbox Maps SDK. Without one (as on CI) it falls back to Apple's map in greyscale. Never commit the token.
- **shooting session:** *start shooting session* on the camera tab keeps location running in the background (iOS shows its location indicator) so the camera stays linked and geotagged with the phone in a pocket. A Live Activity on the lock screen and in the Dynamic Island shows the link, the last geotag, geotags sent and shots fired from resync. The camera reports no shot over Bluetooth (tested: no notification and no readable counter changes), so the camera tab counts a session's photos from the card the next time it is plugged in, by their EXIF time. A session also records the phone's route (fixes within 50 m, at least 5 m apart, in the background too) and keeps it on the phone; the shoot tab's map draws it as a line, and its *route* chip picks which session's route to show.
- **remote:** open **wireless communication** on the camera, then tap *connect* in the app. The first time, accept the "resync" request on the camera.

## import / export

- **JSON:** the app's own format (`fx-companion.recipes`), which round-trips everything.
- **Plain text:** the "Key: value" style used by Fuji X Weekly and most recipe sites. *Paste* reads it straight from the clipboard. To put several recipes in one file, separate them with a line containing only `---`.
- **ISO and exposure compensation** aren't stored in custom settings. They're kept as notes on the recipe.

## layout

```
FujiKit/            protocol core, pure Swift, unit tested
  PTP/              container codec, stream transport, session helpers
  Fuji/             C1–C7 codec + service, Bluetooth packets, Wi-Fi handshake
  Recipe/           model, text parser/formatter, JSON bundle
App/
  Design/           goksen.ing tokens + components (panel, path bar, leader rows, fault)
  Features/         recipes, camera (USB), sync (BLE + location), remote (Wi-Fi), shoot (map), session
Shared/             the Live Activity's attributes, built into the app and the widget
Widgets/            the widget extension: the shooting session's Live Activity
  Resources/Fonts   Martian Mono (instanced at wdth 112.5 / wght 300), Geist Mono, OFL
```

## status

Tested on an X-T30 II with an iPhone:

| part | source |
|---|---|
| Bluetooth pairing and GPS/time sync | from furble |
| recipe reads and writes over USB (C1–C7, 0xD18C–0xD1A5) | from filmkit's X100VI captures |
| remote shutter and live view over Wi-Fi | from libfuji |
| photo GPS over USB (ImageCaptureCore metadata) | |
| session photo count from the card's EXIF times | |

Not yet tested on the camera:

| part | note |
|---|---|
| one-tap pull of C1–C7 into the library | |
| the white balance C3, C6 and C7 use | auto white priority is sent as `0x8020`, a guess |
| route recording during a shooting session | runs on the phone only |
| the 8 on-camera tests in the capability map | Wi-Fi double shot, BLE read-poll, BLE backup download, Wi-Fi state snapshot, Wi-Fi gallery and EXIF, Wi-Fi recipe probe, USB RAW CONV extras, BLE power-off standby |

If the camera rejects a property, the write report lists its code and the value that was sent, which makes it straightforward to fix.

## credits

[eggricesoy/filmkit](https://github.com/eggricesoy/filmkit), [petabyt/libfuji](https://github.com/petabyt/libfuji), [gkoh/furble](https://github.com/gkoh/furble), [hkr/fuji-cam-wifi-tool](https://github.com/hkr/fuji-cam-wifi-tool). All MIT. This project is not affiliated with Fujifilm.
