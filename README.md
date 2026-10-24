# Crew Clock (Flutter)

Staff clock in / clock out for a shared tablet.

- **Manager** (PIN-protected): add workers. Each gets an ID like `JB-4821`.
- **First-day setup**: the worker creates their own 4-digit PIN and takes an ID photo on the tablet.
- **Clock in / out**: worker ID + PIN, then a live front-camera photo, then punch. Clocking out shows the shift length.
- **Timesheet**: hours per worker (today, this week, last week, all), punch log with ID photo beside each punch photo, CSV export.
- **Back up / Restore**: one `.json` file with all workers, punches and photos.
- Everything is stored on the tablet (SQLite + photo files). Works offline. The screen stays awake.

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
