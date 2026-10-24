import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'data/models.dart';
import 'data/store.dart';
import 'screens/kiosk_screen.dart';
import 'screens/manager_screen.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Object? startupError;
  try {
    await Store.instance.init();
  } catch (e) {
    startupError = e;
  }
  // Keep the tablet screen on while the kiosk is open.
  try {
    await WakelockPlus.enable();
  } catch (_) {}
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(CrewClockApp(startupError: startupError));
}

class CrewClockApp extends StatelessWidget {
  const CrewClockApp({super.key, this.startupError});
  final Object? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crew Clock',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: startupError == null
          ? const HomeShell()
          : Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Crew Clock couldn\'t open its storage on this device.\n\n$startupError',
                      textAlign: TextAlign.center),
                ),
              ),
            ),
    );
  }
}

/// Top bar with the mode switch; shows either the kiosk or the manager screen.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  bool manager = false;
  Worker? enrollWorker;
  int kioskGeneration = 0; // forces a fresh kiosk when setup starts

  void _startSetup(Worker w) {
    setState(() {
      manager = false; // leaving the manager screen locks it
      enrollWorker = w;
      kioskGeneration++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              const Text('CREW CLOCK', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: .5)),
              const SizedBox(width: 10),
              const Flexible(
                child: Text('TIME & ATTENDANCE',
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, letterSpacing: 1.5, color: AppColors.muted)),
              ),
              const Spacer(),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, label: Text('Clock in / out')),
                  ButtonSegment(value: true, label: Text('Manager')),
                ],
                selected: {manager},
                onSelectionChanged: (s) => setState(() {
                  manager = s.first;
                  enrollWorker = null;
                }),
              ),
            ]),
          ),
          Expanded(
            child: manager
                ? ManagerScreen(onStartSetup: _startSetup)
                : KioskScreen(
                    key: ValueKey('kiosk-$kioskGeneration'),
                    enrollWorker: enrollWorker,
                    onEnrollStarted: () => enrollWorker = null,
                  ),
          ),
        ]),
      ),
    );
  }
}
