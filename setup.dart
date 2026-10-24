// One-time setup: generates the Android and iOS folders and adds the camera settings.
// Run from the project folder:  dart run tool/setup.dart
import 'dart:io';

Future<void> main() async {
  stdout.writeln('1/4  Creating Android and iOS project files...');
  final create = await Process.run(
    'flutter',
    ['create', '--org', 'com.crewclock', '--project-name', 'crew_clock', '--platforms=android,ios', '.'],
    runInShell: true,
  );
  stdout.write(create.stdout);
  if (create.exitCode != 0) {
    stderr.write(create.stderr);
    stderr.writeln('\n"flutter create" failed. Check that Flutter is installed: run "flutter doctor".');
    exit(1);
  }

  // flutter create adds a sample test that refers to its demo app; it doesn't apply here.
  final sampleTest = File('test/widget_test.dart');
  if (sampleTest.existsSync() && sampleTest.readAsStringSync().contains('MyApp')) {
    sampleTest.deleteSync();
  }

  stdout.writeln('2/4  Android: app name and minimum Android version...');
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (manifest.existsSync()) {
    var m = manifest.readAsStringSync();
    m = m.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Crew Clock"');
    if (!m.contains('android.permission.CAMERA')) {
      m = m.replaceFirst('<application', '<uses-permission android:name="android.permission.CAMERA" />\n    <application');
    }
    manifest.writeAsStringSync(m);
  }
  for (final path in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final f = File(path);
    if (!f.existsSync()) continue;
    var g = f.readAsStringSync();
    // The camera plugin needs Android 7.0 (API 24) or newer.
    g = g.replaceAllMapped(RegExp(r'minSdk(Version)?\s*=?\s*(flutter\.minSdkVersion|\d+)'), (m) {
      final current = int.tryParse(m.group(2)!);
      if (current != null && current >= 24) return m.group(0)!;
      return m.group(0)!.contains('=') ? 'minSdk = 24' : 'minSdkVersion 24';
    });
    f.writeAsStringSync(g);
  }

  stdout.writeln('3/4  iOS: camera permission text and app name...');
  final plist = File('ios/Runner/Info.plist');
  if (plist.existsSync()) {
    var p = plist.readAsStringSync();
    void addKey(String key, String valueXml) {
      if (p.contains('<key>$key</key>')) return;
      final i = p.lastIndexOf('</dict>');
      p = '${p.substring(0, i)}\t<key>$key</key>\n\t$valueXml\n${p.substring(i)}';
    }
    addKey('NSCameraUsageDescription', '<string>Crew Clock takes a photo when staff clock in or out, and an ID photo at setup.</string>');
    addKey('NSMicrophoneUsageDescription', '<string>Crew Clock does not record audio.</string>');
    addKey('NSPhotoLibraryUsageDescription', '<string>Crew Clock saves backups and timesheet exports where you choose.</string>');
    addKey('UIFileSharingEnabled', '<true/>');
    p = p.replaceFirstMapped(RegExp(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)'),
        (m) => '${m.group(1)}Crew Clock${m.group(2)}');
    plist.writeAsStringSync(p);
  }

  stdout.writeln('4/4  Downloading packages...');
  final get = await Process.run('flutter', ['pub', 'get'], runInShell: true);
  stdout.write(get.stdout);
  if (get.exitCode != 0) {
    stderr.write(get.stderr);
    exit(1);
  }
  stdout.writeln('\nDone. Plug in the tablet (USB debugging on) and run:  flutter run --release');
}
