# resync

A personal iPhone companion for the Fujifilm X-T30 II, styled with the [goksen.ing design system](https://goksen.ing/system).

| feature | how it talks to the camera |
|---|---|
| **recipes**: library, editor, import/export, write to C1–C7 | USB-C, PTP through ImageCaptureCore |
| **sync**: automatic location and time for geotags | Bluetooth LE, the camera asks and the phone answers |
| **remote**: live view and shutter | the camera's own Wi-Fi (`192.168.0.1`, ports 55740–55742) |

There's no official SDK, so the app relies on reverse-engineered protocols. Nothing here has been tested on a real X-T30 II yet. See [what's verified](#status).

## build

Requirements: Xcode 16+, iOS 17+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Resync.xcodeproj
```

Set your team under *Signing & Capabilities* and run it on a device. Bluetooth, USB and Wi-Fi don't work in the simulator.

- **Free Apple ID:** delete the `HotspotConfiguration` key from `App/Support/Resync.entitlements`. You then join the camera's `FUJIFILM-…` network yourself in Settings, and the rest works the same.
- **Protocol tests:** `cd FujiKit && swift test`. These need no device.

## camera setup

- **recipes over USB:** MENU → SET UP → CONNECTION SETTING → PC CONNECTION MODE → **USB RAW CONV./BACKUP RESTORE**. Use a USB-C data cable no longer than 1.5 m.
- **GPS sync:** MENU → NETWORK/USB SETTING → Bluetooth settings → **pairing registration**, then tap *scan* in the app. Turn on *geotagging* and *location info*. Allow location "always" on the phone so it keeps syncing in the background.
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
  Features/         recipes, camera (USB), sync (BLE + location), remote (Wi-Fi)
  Resources/Fonts   Martian Mono (instanced at wdth 112.5 / wght 300), Geist Mono, OFL
```

## status

| part | state |
|---|---|
| custom-setting property map (0xD18C–0xD1A5) | from filmkit's captures on an X100VI. The Fuji X Weekly app writes the same slots on an X-T30 II, so it should work. |
| auto white priority WB code `0x8020` | a guess, not yet verified |
| Bluetooth geotag/shutter | from furble, where it's verified on the X-T30, X-S10 and X-E4 |
| Wi-Fi remote handshake | from libfuji. Live view framing (18-byte header + JPEG) not yet tested on this body |

If the camera rejects a property, the write report lists its code and the value that was sent, which makes it straightforward to fix.

## credits

[eggricesoy/filmkit](https://github.com/eggricesoy/filmkit), [petabyt/libfuji](https://github.com/petabyt/libfuji), [gkoh/furble](https://github.com/gkoh/furble), [hkr/fuji-cam-wifi-tool](https://github.com/hkr/fuji-cam-wifi-tool). All MIT. This project is not affiliated with Fujifilm.
