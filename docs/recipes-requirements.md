# Recipes: requirements

Status: draft for review, 2026-11-08
Camera: Fujifilm X-T30 II, firmware 2.04 (final), legacy BLE pairing
Sources: the project research (`research/camera-apis/ble.md`, `capability-map.md`, `usb.md`, `crosscutting.md`, `research/seamless-camera-connection.md`, `plans/xt30ii-feasibility.md`) and the current code in `App/Features/Recipes`, `App/Features/Camera`, `App/Features/Sync` and `FujiKit`.

## 1. Summary

The recipes feature becomes its own product area with six parts: Bluetooth connection, camera backup and restore of C1–C7, export, share, a RAW-based preview, and a free/subscription split.

The asked-for scope is mostly buildable, but **three parts rest on things nobody has proven on an X-T30 II yet**. They are flagged here instead of dropped:

| Asked for | Verdict | Why |
|---|---|---|
| Bluetooth as the main link | **Feasible** for pairing, presence, reconnect | Legacy token pairing is verified on this body by resync. |
| Up-to-date (secure) pairing | **Not possible on the X-T30 II; planned for newer bodies** | The camera picks the scheme, and the X-T30 II never got the July 2025 secure-Bluetooth firmware. resync supports both so newer bodies work (§4.1.1). |
| Back up C1–C7 over Bluetooth | **Plausible, unverified** | The read protocol (BACKUP_REQUEST + file service, ~33 KB `backup.dat`) comes from an XApp decompile and has only run against a fake camera. The blob format, including where C1–C7 sit, is undocumented. |
| Restore / write C1–C7 over Bluetooth | **Not feasible today; blocked on reverse engineering** | The write direction of the file service is unpublished. FujiStyle claims it works on the X-T30 II, but no capture exists. A whole-blob restore also overwrites every menu setting, not one slot. |
| Back up and restore C1–C7 over USB | **Feasible, verified** | resync already reads and writes 0xD18C–0xD1A5 on this body in USB RAW CONV./BACKUP RESTORE mode. |
| Export, share | **Feasible** | Already partly built (JSON bundle, plain text, share sheet). |
| Recipe preview from a RAW file | **Feasible as an approximation; accurate only over USB** | No image data ever goes over Bluetooth. An on-phone preview can only approximate Fujifilm's film simulations. An exact render needs the camera's own RAW conversion over USB, and only for RAFs shot by this body. |
| Free: edit C1 only | **Feasible, with a loophole to close** | Gating is app-side only. A full-camera restore would write C2–C7 too, so restore must be gated as well (see §5). |
| Cloud sync, social: subscription only | **Feasible, needs a paid Apple developer account** | StoreKit, CloudKit and any backend need App Store distribution. The README's default free Personal Team build can't ship any of it. |

**Recommendation:** ship the feature on a transport-agnostic "slot write" layer. USB is the verified path for writes and backups from day one. Bluetooth backup turns on after the read-only on-camera test (§8, T1) passes, and Bluetooth restore only after a capture of XApp or FujiStyle shows the write sequence (T3/T4).

## 2. Goals and non-goals

**Goals**
- The user pairs the camera once over Bluetooth and never thinks about the connection again for recipe work.
- The user can see, save and put back what is in C1–C7 without losing anything.
- Recipes move freely between the app, files, other apps and other people.
- The user can judge a recipe on their own photo before putting it on the camera.
- A clear free tier that is useful on its own, and a subscription that unlocks all slots, cloud and social.

**Non-goals (this phase)**
- Recipe backup and writes on bodies other than the X-T30 II. Pairing supports both legacy and secure bodies (§4.1), and the model and codecs should not block adding recipe support for them later.
- Changing ISO, aperture, exposure compensation or drive over Bluetooth (claimed by Huginn, unproven, not part of custom settings).
- Moving images over Bluetooth. Not possible.
- Android, web.

## 3. User stories

### Bluetooth connection
- **US-1** As a user, I pair my X-T30 II once from the app, following the camera's PAIRING REGISTRATION prompt, so that it reconnects by itself afterwards.
- **US-2** As a user, I see at a glance whether the camera is linked, and the app tells me plainly when XApp or another phone has taken the link.
- **US-3** As a user, I can queue a recipe for a slot while the camera is off or away, and it is written the next time a working transport is up.

### Backup and restore
- **US-4** As a user, I back up all seven custom slots from the camera with one tap, so I never lose a recipe I built in the camera's menu.
- **US-5** As a user, the app takes a backup automatically before every write, so any write can be undone.
- **US-6** As a user, I browse my backups by date and camera, see which recipe is in each slot, and save any slot into my library.
- **US-7** As a user, I restore a single slot, or a whole backup, back onto the camera.

### Export and share
- **US-8** As a user, I export one recipe, a selection or my whole library as a file (resync JSON or plain text).
- **US-9** As a user, I export a camera backup as a file I can keep outside the app.
- **US-10** As a user, I share a recipe to Messages, AirDrop, Instagram or a notes app as text, a file or a recipe card image.
- **US-11** As a user, I import a recipe someone sent me by opening the file, pasting text or scanning a link.

### Preview
- **US-12** As a user, I import a RAW (RAF) or JPEG from Photos or Files and see it with a recipe applied.
- **US-13** As a user, I compare two recipes, or a recipe against the as-shot look, on the same photo.
- **US-14** As a user, I see the preview update as I change a recipe's settings in the editor.
- **US-15** As a user with the camera on a cable, I can ask the camera itself to render the exact result.

### Free and subscription
- **US-16** As a free user, I can build and keep any number of recipes in my library, and write them to C1.
- **US-17** As a free user, I see what C2–C7 hold and back them up, but writing to them asks me to subscribe.
- **US-18** As a subscriber, I write to all seven slots, sync my library and backups across devices, and use social features.
- **US-19** As a former subscriber, I keep everything I made. Nothing is deleted when the subscription lapses; only the paid actions lock again.

### Social (subscription)
- **US-20** As a subscriber, I publish a recipe with sample photos to a public feed.
- **US-21** As a subscriber, I browse, search, save and like other people's recipes, and follow their authors.

## 4. Functional requirements

IDs are stable so issues and PRs can refer to them. **M** = must for the first release, **S** = should, **L** = later.

### 4.1 Bluetooth connection (BT)

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| BT-1 | Pair using the legacy scheme: write the 4-byte advertised token to `aba356eb`, the client name to `85b9163e`. | M | Verified on X-T30 II. Exists in `BLECameraController`. |
| BT-2 | Detect the pairing scheme from the advertisement and route to the right flow: legacy (type `0x02` + 4-byte token, `117c4142`/`af854c2e`) or secure (5-byte ASCII serial, `a9d2b304` in pairing mode, `804daa8e`/`123d8f06` once bonded). | M | The camera picks the scheme; the app can't upgrade a legacy body. See §4.1.1. |
| BT-3 | Reconnect automatically when the camera turns on, using CoreBluetooth state restoration, in the foreground and background. | M | Already the "spine" design in seamless-camera-connection.md. |
| BT-4 | Read model, firmware and serial from DIS (`2a24`, `2a26`, `2a25`) on every connect and tie backups to that serial. | M | Only seen in the X-T4 GATT dump; confirm on this body (T1). |
| BT-5 | Run a full GATT inventory on first pairing and store it, to decide which recipe capabilities this body supports (backup service present or not). | M | `F14E7A88`, `11438C83`, the `af854c2e` FILE_* characteristics. |
| BT-6 | Tell the user when the link is lost to another central (XApp, another phone). Only one central is served at a time. | M | |
| BT-7 | Keep the link alive during a transfer: keep the app in the foreground with a progress screen and warn that locking the phone cuts the link. | M | FujiStyle reports idle drops after about 20 s and drops on phone lock. |
| BT-8 | Support connecting while the camera is powered off (IMAGE TRANSFER WHILE POWER OFF). | L | Claimed by FujiStyle and Huginn; untested (T5). |
| BT-9 | Write the camera clock (`b9bfd37f`) after NOT1. | S | Not recipes, but cheap while pairing work is open. |
| BT-10 | Harden legacy pairing: only start pairing when the camera is in PAIRING REGISTRATION mode (token present in the advert), remember the camera by serial and CoreBluetooth identifier, and warn before connecting to a camera that isn't the remembered one. | M | Legacy has no link-layer encryption, so the app is the only guard. |

#### 4.1.1 Secure pairing (newer bodies)

Fujifilm's July 2025 firmware moved X-T5 (4.30), X-S20 (3.30), X-T50 (1.30), X-M5 (1.20), X100VI (1.30), GFX100RF (1.10) and X half (1.20) to LE Secure Connections bonding. Bodies released later (X-E5, X-T30 III) likely ship with it. **The X-T30 II will never get it**: its last firmware is 2.04 (March 2024). Only the pairing step changes; shutter, geotag, Wi-Fi handover and the file service are the same characteristics on both schemes (ble.md §3, Q3).

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| BT-11 | Bond with a secure body using LE Secure Connections with numeric comparison. iOS shows the system pairing prompt with the six-digit number; the user confirms it on the phone and on the camera. | M | Triggered by iOS when the app first touches an encrypted characteristic. The app can't draw or skip the prompt. |
| BT-12 | After bonding, run the STATUS handshake: read `f557d96b` in `123d8f06`, write it back with byte 3 set to `0x20`, then write the client name (`85b9163e`) and `eb4166b0` as on legacy. | M | From furble and MaxRink's X100VI notes. Unverified on any body in this project. |
| BT-13 | Treat NOT1 (`f9150137`) as "registered" for both `02 00` (legacy) and `01 00` (X100VI). | M | |
| BT-14 | Reconnect bonded bodies by their CoreBluetooth identifier. Secure bodies rotate their resolvable private address; iOS resolves it with the bond's IRK, so never match by MAC or by the advert's serial fragment alone. | M | |
| BT-15 | Don't subscribe to NOT3 (`7170fd5a` in `804daa8e`). | M | Subscribing can disconnect X-H2-family bodies (MaxRink plan 159). |
| BT-16 | Handle a lost bond: when the camera has been reset or paired to another phone, iOS fails encryption. Detect it, explain that the camera must be re-registered, and tell the user to "Forget This Device" in iOS Settings → Bluetooth (an app can't remove a bond). | M | The most common support issue on bonded links. |
| BT-17 | Keep one pairing screen for both schemes. The user only sees a different step (confirm the number) when the camera is secure. | M | |

Secure pairing makes resync work with newer bodies for location, shutter and Wi-Fi from day one. Recipe backup and writes on those bodies still need their own blob and slot codecs (Q9).

### 4.2 Backup (BK)

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| BK-1 | Read all seven slots and their names over USB RAW CONV (0xD18C select, 0xD18D name, 0xD18E–0xD1A4 settings). | M | Verified. Exists in `PresetService`. |
| BK-2 | Read `backup.dat` over Bluetooth: `01 00` → `F14E7A88`, wait for `11438C83` = 1, set `7F3400FE` = 120 and `051DD980` = 0, read `AC0C799A` per `2E27ED9F` notify, check the u16 byte sum, write `3` → `68052E8A`. | S | **Unverified.** Ships behind a capability flag once T1 passes. |
| BK-3 | Decode C1–C7 out of `backup.dat`. | S | **Blob format unknown.** Needs the A/B diff experiment (T2). Until then, keep the blob opaque. |
| BK-4 | Store every backup with: camera serial, model, firmware, transport, time, the raw bytes (when there are any), and the decoded slots. | M | Raw bytes are kept even when decoding fails, so a future parser can read old backups. |
| BK-5 | Take an automatic backup of the target slot before every write, and of all slots before any whole restore. | M | Writes can't be undone on the camera. |
| BK-6 | Show a backup's slots side by side with the library, marking which slots are already library recipes. | M | `RecipeStore.libraryMatch` already does the matching. |
| BK-7 | Save any slot from a backup into the library without duplicates. | M | `saveFromCamera` already does this. |
| BK-8 | Keep backups forever on the device; let the user delete them. | M | |

### 4.3 Restore and slot write (RS)

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| RS-1 | Write one recipe to one slot over USB, then read it back and report per-property results. | M | Verified. Exists (`USBCameraController.write`). |
| RS-2 | Restore one slot from a backup (a slot write with the backed-up recipe and name). | M | Over USB, this is RS-1. |
| RS-3 | Restore a whole backup (all seven slots) as seven slot writes, with a single confirmation. | M | Over USB. |
| RS-4 | Write a slot over Bluetooth by read-modify-write of `backup.dat`. | L | **Blocked.** The write direction is unpublished. Needs T3/T4 captures, then a per-slot patch of the blob. Do not attempt a blind write: a bad blob could reset every menu setting. |
| RS-5 | Keep a "pending writes" queue: a recipe assigned to a slot is written on the next available transport, with read-back. | M | Matches the queue design in seamless-camera-connection.md. Over USB only until RS-4 lands. |
| RS-6 | Never write slots the user didn't pick. On a Bluetooth whole-blob restore (RS-4), send back every other byte unchanged from a fresh read. | M | The pattern Filmsim Recipes describes. |
| RS-7 | Show what will change before a write (old slot vs new recipe) and require one confirmation. | M | |
| RS-8 | Say which settings the X-T30 II can't store (smooth skin, ISO, exposure compensation) and keep them as notes. | M | Already modelled (`isoNote`, `exposureNote`; smooth skin ignored). |

### 4.4 Export (EX)

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| EX-1 | Export one, many or all recipes as resync JSON (`fx-companion.recipes`). | M | Exists. |
| EX-2 | Export as plain "Key: value" text, several recipes split by `---`. | M | Exists. |
| EX-3 | Export a camera backup as a file: resync JSON of the decoded slots, plus the raw blob when there is one. | M | New file type, e.g. `.resyncbackup` (zip of `slots.json` + `backup.dat`). |
| EX-4 | Register resync's file types so opening them in Files or Mail imports into the app. | M | |
| EX-5 | Import stays idempotent: importing the same thing twice changes nothing. | M | Already the rule in `RecipeStore.importData`. |

### 4.5 Share (SH)

Share means sending something outside the app. It is free. Social (§4.7) is the in-app community and is paid.

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| SH-1 | Share sheet for a recipe as text, as a file, or as both. | M | Partly exists (`RecipeBundleFile`). |
| SH-2 | Render a recipe card image (name, settings, optional sample photo) in the goksen.ing style for Instagram and Stories. | S | |
| SH-3 | Share a recipe as a link that opens resync, or a web page when the app isn't installed. | L | Needs a small backend or encoding the recipe in the URL. Encoding in the URL works with no server and should come first. |
| SH-4 | A shared recipe never contains the user's camera serial or location. | M | Privacy. |

### 4.6 Preview (PV)

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| PV-1 | Import RAF, DNG, HEIC and JPEG from Photos and Files. | M | Images never come over Bluetooth. They get to the phone through XApp, the USB card reader mode, or Files. |
| PV-2 | Decode RAF on the phone with Core Image (`CIRAWFilter`) and apply an approximation of the recipe: film simulation look, WB and shift, DR, highlight, shadow, color, clarity, sharpness, grain, color chrome. | M | **An approximation.** Fujifilm doesn't publish its film simulations. Label the preview as approximate. |
| PV-3 | Live preview in the editor at screen resolution, under about 100 ms per change on a recent iPhone. | M | Render a downscaled proxy; full-size only on export. |
| PV-4 | Split or swipe compare: recipe A vs B, or recipe vs as-shot. | S | |
| PV-5 | Read the as-shot recipe from the file's EXIF MakerNote (film mode, grain, color chrome, highlight, shadow, clarity, DR, WB shift) and offer to save it as a recipe. | S | MakerNote has these fields but no slot or recipe name. |
| PV-6 | Exact preview via the camera's in-body RAW conversion over USB RAW CONV: upload the RAF (0x900C/0x900D), set the 0xD185 profile, trigger 0xD183, poll 0xD212, fetch the JPEG. | L | Verified on the X-T30 (Mk I) only. RAF must be shot by this body, and the cable must be in. |
| PV-7 | Keep imported photos inside the app's container, with a size limit and a "clear previews" action. | M | RAFs are about 30 MB each. |

### 4.7 Social (SO), subscription only

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| SO-1 | Profiles: handle, avatar, bio. Sign in with Apple. | L | |
| SO-2 | Publish a recipe with up to N sample photos, tags and the camera model. | L | |
| SO-3 | Feed, search by film simulation and tag, save to library, like, follow. | L | |
| SO-4 | Report and remove content; block users. | L | Required by App Store guideline 1.2 for user-generated content. |
| SO-5 | Viewing public recipes through a shared link (SH-3) works for everyone; publishing, liking and following need a subscription. | L | |

### 4.8 Cloud sync (CS), subscription only

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| CS-1 | Sync the library, backups and preview metadata across the user's devices. | L | CloudKit private database is the simplest fit for an iOS-only app. |
| CS-2 | Free users' data stays on the device only. Turning on a subscription uploads the existing local library once. | L | |
| CS-3 | On lapse, stop syncing, keep the last local copy, never delete server data for at least 90 days. | L | |
| CS-4 | Conflict rule: newest `updatedAt` wins per recipe, the same rule the importer uses. Backups never conflict (they are immutable). | L | |

### 4.9 Entitlements (EN)

| ID | Requirement | Pri | Notes |
|---|---|---|---|
| EN-1 | Subscriptions through StoreKit 2, monthly and yearly, with family sharing off by default. | M | |
| EN-2 | One `Entitlements` service the features ask ("can write slot 4?", "can sync?"); no feature checks StoreKit directly. | M | |
| EN-3 | Entitlement state works offline (cached signed transaction), so writing C3 at a shoot with no signal still works for subscribers. | M | |
| EN-4 | Paywall shows at the moment of the locked action, with what it unlocks; never blocks reading or viewing. | M | |

## 5. Free vs subscription

| Capability | Free | Subscription |
|---|---|---|
| Pair camera, auto-reconnect | ✓ | ✓ |
| Library: create, edit, duplicate, delete recipes (unlimited) | ✓ | ✓ |
| Read C1–C7 from the camera | ✓ | ✓ |
| Save any slot into the library | ✓ | ✓ |
| **Write a recipe to C1** | ✓ | ✓ |
| **Write a recipe to C2–C7** | — | ✓ |
| Back up all seven slots (manual and automatic) | ✓ | ✓ |
| Restore C1 from a backup | ✓ | ✓ |
| Restore C2–C7, or a whole backup | **Own backups of the same camera only** (see below) | ✓ |
| Pending-write queue | C1 only | All slots |
| Export (JSON, text, backup file) | ✓ | ✓ |
| Import (file, paste, link) | ✓ | ✓ |
| Share via share sheet, recipe card image | ✓ | ✓ |
| Preview: import RAW and apply a recipe on the phone | ✓ (open question: limit count?) | ✓ |
| Preview: compare A/B | — (open question) | ✓ |
| Preview: exact in-camera render over USB | — (open question) | ✓ |
| Cloud sync of library and backups | — (local only) | ✓ |
| Social: publish, like, follow, feed | — | ✓ |
| View a public recipe from a link | ✓ | ✓ |

**Reading of "edit only C1".** The library is unrestricted for everyone; the gate is on **writing to the camera's slots**. The camera's own menu lets anyone edit any slot, so locking library editing would only frustrate users without protecting anything. If you meant something stricter (for example, free users can only keep one recipe), that changes the design; see Q1.

**The restore loophole.** A whole-backup restore writes all seven slots. If free users could restore any backup, they could import someone else's backup file and fill C2–C7 for free. So a free user may restore C2–C7 only from a backup **taken from the same camera serial by this app** (an undo, not a way to load new recipes). Imported backup files can be restored to C1 only on the free tier.

**Lapsed subscriber.** Everything stays. Slots C2–C7 already on the camera keep their recipes; the user can still read and back them up; only new writes to C2–C7, sync and social lock.

## 6. Data model

Extends the existing `Recipe` (FujiKit/Recipe/Recipe.swift) rather than replacing it.

```
Recipe                      (exists) id, name, film sim, grain, color chrome (+blue), smooth skin,
                            WB + kelvin + shift, DR, highlight, shadow, color, sharpness, NR, clarity,
                            mono WC/MG, isoNote, exposureNote, notes, source, tags, createdAt, updatedAt
  + origin                  enum: user | camera(serial, slot) | imported(file) | social(postID) | photo(exif)
  + previewImageID?         → PreviewImage, the sample photo shown on the card
  + syncState               local | synced | pendingUpload | conflict          (subscribers only)

CameraBody
  serial                    from DIS 2a25 or the USB blob header (0x34)
  model, firmware           DIS 2a24 / 2a26
  nickname
  pairing                   legacy(token) | secure(…)    secure unsupported for now
  capabilities              set: usbSlots, bleBackupRead, bleBackupWrite, bleStandby, inCameraRawConv
  gattInventory             raw list from first pairing (BT-5)
  lastSeen

CameraBackup               immutable once saved
  id, cameraSerial, model, firmware
  takenAt
  transport                 usb | ble
  trigger                   manual | beforeWrite | beforeRestore
  slots: [SlotEntry]        decoded C1–C7; may be empty when a BLE blob can't be decoded yet
  rawBlob?                  backup.dat bytes (BLE) or GetObject(0) bytes (USB); stored as a file
  blobChecksum?             u16 byte sum (BLE) / SHA-256
  formatVersion             parser version that produced `slots`

SlotEntry
  slot                      1…7
  name                      as stored on the camera (upper-case, short)
  recipe                    Recipe decoded by PresetCodec
  libraryRecipeID?          match at save time

PendingWrite
  id, cameraSerial, slot, recipeID, recipeSnapshot
  createdAt
  state                     queued | writing | verifying | done | failed(report)
  preWriteBackupID?

PreviewImage
  id, file (in app container), originalFormat (raf | dng | heic | jpeg)
  cameraModel?, asShotRecipe? (from MakerNote)
  renders: [recipeSettingsKey → cached proxy]

Entitlement                 cached from StoreKit 2
  tier                      free | subscriber
  expiresAt, lastVerified

(social, later) Profile, Post(recipeSnapshot, images, tags, cameraModel), Like, Follow, Report
```

Storage: the library stays a JSON bundle in Application Support (`recipes.json`), as `RecipeStore` does today. Backups move from the single `camera-slots.json` snapshot to one folder per backup (`backups/<id>/meta.json` + `backup.dat`), so history is kept. A migration turns the existing `camera-slots.json` into the first `CameraBackup`.

## 7. Technical constraints from the research

1. **Bluetooth never carries images.** Preview photos must come from Photos, Files or the USB card reader. (ble.md headline 4)
2. **One central at a time.** resync and XApp displace each other on the camera. Every transfer must handle "taken by another app". (ble.md §3, Q4)
3. **Transfers are slow and fragile.** About 33 KB in 120-byte chunks, with acknowledgements. The link drops on phone lock and after about 20 s idle. Transfers need a foreground progress screen and a resumable state. (ble.md §1; FujiStyle guide)
4. **Bluetooth backup read is from a decompile and untested on any real camera.** Treat it as a capability that is off until T1 passes on this body. (ble.md §2)
5. **Bluetooth restore is unpublished.** RS-4 is blocked until a capture. (ble.md §2, "Settings restore")
6. **The `backup.dat` layout is unknown.** Per-slot editing needs the diff experiment. A whole-blob write also replaces every menu setting. (seamless-camera-connection.md, "Several things argue against it")
7. **USB is the verified recipe path**, in USB RAW CONV./BACKUP RESTORE mode. In that mode the card is invisible and the camera can't shoot, and switching modes means unplug, change the menu, replug. (usb.md)
8. **X Acquire's USB backup may exclude C1–C7 on the X-T30 II** ("custom registration/edit" is excluded in Fujifilm's chart). So USB backups should be built from the slot properties (BK-1), not from GetObject(0). (crosscutting.md)
9. **The camera can't store ISO, exposure compensation or smooth skin** in custom settings on this body. (README; Recipe.swift)
10. **In-camera RAW conversion only accepts RAFs shot by the same body**, needs USB, and is verified only on the X-T30 Mk I. (usb.md)
11. **Distribution.** StoreKit subscriptions, CloudKit, Sign in with Apple and App Store review all need the paid Apple Developer Program. The current free Personal Team build (7-day signing) can't ship them. (README)
12. **Firmware is frozen at 2.04**, so once the X-T30 II protocol is captured it won't change under us. Other bodies will need their own blob parsers.
13. **The X-T30 II stays on legacy pairing for good.** Secure pairing exists only on bodies with the July 2025 firmware or later. resync can't test BT-11…16 without one of those bodies. (ble.md §3, Q3)

## 8. Experiments that unblock the plan

In order. Each is read-only until it says otherwise.

| # | Test | Unblocks |
|---|---|---|
| T1 | GATT inventory on the X-T30 II, then a read-only `backup.dat` download with fuji-bridge's sequence. Verify the checksum. | BT-5, BK-2 |
| T2 | Dump A, change one C7 parameter in the camera menu, dump B, diff. Repeat for each parameter and the slot name. | BK-3, and the per-slot patch in RS-4 |
| T3 | Capture XApp Backup/Restore on this body (Android HCI snoop log or iOS PacketLogger). | RS-4 |
| T4 | Capture FujiStyle, and Fuji Recipes (fujirecipes.co, says "over Bluetooth or cable" and lists the X-T30 II), writing one known recipe to C7 on this camera. Record over the air with Apple's Bluetooth logging profile + PacketLogger; don't decompile the apps. | RS-4 (per-slot write) |
| T5 | Power-off standby: with IMAGE TRANSFER WHILE POWER OFF on, does the camera advertise, accept a connection and answer BACKUP_REQUEST? | BT-8 |
| T6 | Compare the on-phone preview (PV-2) with in-camera JPEGs of the same RAF for each film simulation, to tune the approximation. | PV-2 quality |
| T7 | Pair a secure-firmware body (e.g. X-T5 4.30 or X100VI 1.30): numeric comparison, STATUS handshake, NOT1 value, reconnect after an address rotation, behaviour after a camera-side reset. | BT-11…16 |

## 9. Suggested phasing

1. **Phase 1, free tier on verified paths:** BT-1…7/10, BK-1/4–8, RS-1–3/5–8 over USB, EX-*, SH-1/4, PV-1–3/7, EN-1–4, the gating in §5. Run T1 and T2 in parallel.
2. **Phase 2, Bluetooth backup and secure pairing:** BK-2/3 once T1/T2 pass. BT-11…17 once T7 runs on a secure body. PV-4/5, SH-2.
3. **Phase 3, Bluetooth write:** RS-4 once T3/T4 succeed. BT-8 if T5 passes.
4. **Phase 4, subscription services:** CS-*, SO-*, SH-3, PV-6.

## 10. Open questions

- **Q1. What exactly is free?** This doc reads "edit only C1" as "write only to C1, library editing is unlimited". Confirm, or say if the library should also be limited.
- **Q2. Free restore of a whole backup.** OK to allow free users to restore their own camera's backup to all slots (as an undo), as proposed in §5?
- **Q3. Preview on the free tier.** Unlimited, a monthly limit, or one photo at a time? Is A/B compare paid?
- **Q4. Ship before Bluetooth writes work?** If T3/T4 fail, the first release writes over USB only. Is that acceptable, or is Bluetooth writing a launch requirement?
- **Q5. Backend for social.** CloudKit public database (no server, iOS only, limited moderation and search) or a hosted backend (more work, needed for web links and real moderation)?
- **Q6. Pricing.** Monthly and yearly price, free trial length, and whether there's a lifetime option.
- **Q7. Apple Developer Program.** Subscriptions require it. Is the US$99/year account planned for this release? It also unlocks the Hotspot entitlement for Wi-Fi.
- **Q8. Film simulation names and looks.** Using Fujifilm's names for recipe settings is normal across recipe apps, but the preview's approximations should not be marketed as Fujifilm's. Any appetite for a legal check before launch?
- **Q9. Other bodies.** Pairing now plans for secure bodies too. Is the X-T30 II still the only body for recipe backup and writes at launch? A second body changes T1–T4 into per-model work.
- **Q10. A secure test body.** BT-11…16 can't be verified without a camera on the July 2025 firmware. Do you have access to one (borrowed or second-hand X-T5, X-S20, X-T50, X-M5 or X100VI)?

## 11. API sources and reference apps

Checked 9 November 2026. The question was whether an official API covers these features, and which existing apps the requirements can be checked against.

### 11.1 There is no official API for this

Fujifilm's [Camera Control SDK](https://www.fujifilm-x.com/en-ca/camera-control-sdk/) (v1.34) is the only official one, and it doesn't fit:

- **No iOS.** Windows, macOS, Linux, and Android over USB only.
- **No Bluetooth.** USB, or TCP/IP through a Wi-Fi access point.
- **No X-T30 II.** The list is X-M5, X-T3, X-T4, X-Pro3, X-S10, X-H2S, X-H2, X-T5, X-S20 and GFX bodies.
- **No recipes.** It covers tethered shooting and image transfer. The page says RAW conversion information is not provided, and custom settings aren't mentioned.

Every recipe app on the market, including the ones below, works from the reverse-engineered protocol. Fujifilm's SDK page says unlicensed control voids the camera's limited warranty; Fuji X Weekly and FujiShare both repeat that warning to their users. resync should show the same notice before the first write (new requirement **RS-9**).

### 11.2 Protocol sources, best first

| Source | Covers | Licence | Use for |
|---|---|---|---|
| [eggricesoy/filmkit](https://github.com/eggricesoy/filmkit) | USB PTP: slot select `D18C`, name `D18D`, 24 settings `D18E`–`D1A5`; in-camera RAW conversion through the `D185` profile; encoding tables in `src/profile/`. From Wireshark captures of X RAW Studio. Tested on the X100VI only. | MIT | RS-1…3 over USB, PV in-camera conversion, the value tables (grain is a flat 1–5 enum for off, weak/strong × small/large) |
| [petabyt/libfuji](https://github.com/petabyt/libfuji) | C library: Wi-Fi (XApp mode), Bluetooth pairing in legacy and secure modes, PC AutoSave, tethering, RAW conversion. Replaces the archived [petabyt/fp](https://github.com/petabyt/fp) profile parser. | MIT | BT-11…16 secure pairing, cross-checks |
| [pinpox/rawji](https://github.com/pinpox/rawji), libgphoto2 | The older `D185` layout and the PTP basics FilmKit builds on. | open | Cross-checks |
| fuji-bridge | The Bluetooth `backup.dat` sequence. Verified on this X-T30 II in T1. | — | BK-2 |
| resync's own dumps | The `backup.dat` layout and the 13 mapped settings (T1, T2). No public source documents this file. | ours | BK-3, RS-4 |

Nothing public documents a per-slot recipe write over Bluetooth. That still needs the captures in T3 and T4.

### 11.3 Reference apps and what they confirm

| App | Transport | X-T30 II | What to take from it |
|---|---|---|---|
| [Fuji X Weekly](https://fujixweekly.com/2026/08/20/new-send-recipes-to-your-camera-directly-from-the-fuji-x-weekly-app/) (iOS, Android) | USB only, in USB RAW CONV./BACKUP RESTORE mode | Listed | One recipe to one slot is free; sets of recipes are paid. Same split as §5. It skips ISO and exposure compensation (constraint 9), warns that DR and clarity can be rejected depending on ISO or drive mode, and needs a cable under 1.5 m. |
| [FujiShare](https://www.notebookcheck.net/New-FujiShare-beta-writes-7-Fujifilm-film-recipes-to-C1-C7-over-USB-with-read-back-checks.1378419.0.html) (iOS beta) | USB only | Not listed (X100V and X-Processor 5 bodies) | Checks which settings the body supports before writing, writes each setting on its own, reads every one back, reports a failed write, and saves a restore point first. Builds a shared post from a JPEG's metadata. |
| FilmKit (web) | USB (WebUSB) | "Likely", untested | Detects which preset shot a loaded RAF, drag between camera and library, export as file, link or pasted text, quick compare. |
| Fuji Recipes (fujirecipes.co), FujiStyle | Bluetooth or cable | Listed by Fuji Recipes | The only apps claiming Bluetooth writes. Closed source: capture them over the air (T4). |

### 11.4 Changes this makes to the requirements

- **RS-9 (new).** Before the first write to a camera, show that resync is not licensed by Fujifilm and that Fujifilm says unlicensed control voids the limited warranty. Ask once per camera.
- **RS-10 (new).** Before writing a slot, read the camera's supported values for each setting and skip or flag the ones this body rejects, as FujiShare does. Read every setting back after the write (already in RS-3), and name the settings that didn't take.
- **RS-11 (new).** Tell the user when DR or clarity was refused because of the camera's current ISO or drive mode, with what to change.
- **PV-8 (new, optional).** Offer in-camera RAW conversion over USB as the exact preview, using FilmKit's `D185` flow. T6's on-phone approximation stays the default because it needs no cable. Constraint 10 still applies.
- **EX-/SH-.** Add "paste as text" beside file and link, as FilmKit has.
- **Q4 gets easier.** Every shipping competitor except two is USB only, so a first release that writes over USB and backs up over Bluetooth is at least level with the market.
- **T2 can be shorter.** FilmKit's tables give the value sets for grain, NR and the film simulations, so the calibration run only has to find where `backup.dat` stores them, not what the values mean.
