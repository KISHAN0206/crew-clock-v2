# Crew Clock

## Quick links (copy from here)

**Install the app on a tablet** (open in the tablet's Chrome, signed in to GitHub, because this repository is private):

```
https://github.com/KISHAN0206/crew-clock-v2/releases/latest/download/crew-clock-32bit.apk
```

Newer/64-bit devices:

```
https://github.com/KISHAN0206/crew-clock-v2/releases/latest/download/crew-clock-64bit.apk
```

Works on any device (bigger file):

```
https://github.com/KISHAN0206/crew-clock-v2/releases/latest/download/crew-clock-all-devices.apk
```

**Web version of the clock-in station** (no install, add to home screen from Chrome):

```
https://kishan0206.github.io/crew-clock-scan/station.html
```

**Google Sheet link for the app** (Manager → Cloud sync). Add your sync key to the end:

```
https://script.google.com/macros/s/AKfycbzxzbvDXtgiIy0Pi_hYcrmnSEPWxz7pzQCWUWBb4tnjsM2fICLh_1-klrTsPLbaceBMgQ/exec?key=YOUR_SYNC_KEY
```

The full link with the key is kept in the private `crew-clock` repository (`TABLET-LINK.md`), because this repository is public.

Staff clock in / clock out for a shared tablet.

- **Manager** (PIN-protected): add workers. Each gets an ID like `JB-4821`.
- **Clock in / out by QR**: the tablet shows one QR code for everyone, changing every 30 seconds. Workers scan it
  with their own phone and tap the link; the Google Sheet script records the punch and decides IN or OUT.
- **Phone linking**: a phone's first scan asks "Who are you?" and links that phone to the chosen worker (only
  workers without a linked phone are listed). After that the phone clocks them in or out straight away.
  Reset a link from Manager → Workers → Reset phone link (or clear it in the sheet).
- A second scan within 2 minutes doesn't flip IN/OUT, so double scans are harmless.
- The tablet shows who just clocked in or out, and how many people are on shift.
- **Timesheet** on the tablet (hours per worker, punch log, CSV export) and in the Google Sheet (Weekly hours tab).
- Needs internet on the tablet and on workers' phones.

## Run it

You need Flutter installed (https://docs.flutter.dev/get-started/install) and, for Android, Android Studio with the Android SDK.

```bash
cd crew_clock
dart run tool/setup.dart     # one time: creates android/ and ios/ folders, adds camera permissions, gets packages
flutter run --release        # with the tablet plugged in (USB debugging on)
```

Build an installable Android file instead:

```bash
flutter build apk --release
# copy build/app/outputs/flutter-apk/app-release.apk to the tablet and open it
```

iPad: open `ios/Runner.xcworkspace` in Xcode on a Mac, pick your Apple ID under Signing, then run.

## Project layout

```
lib/
  main.dart                 app start, top bar, mode switch
  ui.dart                   colours, theme, shared widgets
  data/models.dart          Worker, Punch
  data/store.dart           SQLite storage, photos, CSV, backup/restore
  screens/kiosk_screen.dart sign in, punch, first-day setup
  screens/camera_screen.dart live front camera
  screens/manager_screen.dart manager PIN, workers, timesheet
  util/hours.dart           shift pairing and week ranges
  util/security.dart        PIN hashing, ID format
  util/format.dart          date and time text
test/hours_test.dart        unit tests (flutter test)
tool/setup.dart             one-time platform setup
```

## Notes

- PINs are stored only as salted SHA-256 hashes.
- Records live only on this tablet. Use **Back up** regularly and keep the file somewhere else (Google Drive, email).
- To change the ID prefix, edit `idPrefix` in `lib/data/store.dart`.
- If `flutter pub get` reports a version conflict, run `flutter pub upgrade`.

## Cloud sync (Google Sheet)

Manager → **Cloud sync** connects the tablet to the Google Sheet. QR scans are recorded there, and worker changes are sent from the tablet
(tabs: Weekly hours, Punches, Workers; photos in a private Drive folder "Crew Clock photos").
The sheet side is a Google Apps Script (`Code.gs`, kept outside this repo because it holds the sync key).
Worker changes queue on the tablet when offline and upload when the connection is back.

## Branding

Styled for Jaybel Office Choice. The GitHub build downloads the logo and icon from
jaybel.officechoice.com.au and `tool/brand.py` sets the app icon and Android launch screen.
Colours live in `AppColors` in `lib/ui.dart`.

## GitHub build

Every push to `main` runs `.github/workflows/build.yml` and attaches the APK as the
**crew-clock-apk** artifact on the run.
