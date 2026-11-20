import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'data/models.dart';
import 'data/store.dart';
import 'data/sync.dart';
import 'screens/kiosk_screen.dart';
import 'screens/manager_screen.dart';
import 'ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const CrewClockApp());
}

class CrewClockApp extends StatelessWidget {
  const CrewClockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crew Clock',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const SplashScreen(),
    );
  }
}

/// Loading screen: Office Choice red with the logo while the tablet's data opens.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Object? error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final minimum = Future<void>.delayed(const Duration(milliseconds: 1400));
    try {
      await Store.instance.init();
      SyncService.instance.start();
      try {
        await WakelockPlus.enable(); // keep the tablet screen on
      } catch (_) {}
      await minimum;
      if (!mounted) return;
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, __, ___) => const HomeShell(),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
      ));
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.brandRed,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const BrandLogo(height: 96),
              const SizedBox(height: 28),
              const Text('CREW CLOCK',
                  style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 3)),
              const SizedBox(height: 4),
              const Text('Jaybel Office Choice · Time & attendance',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: .5)),
              const SizedBox(height: 36),
              if (error == null)
                const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
              else
                Text('Crew Clock couldn\'t open its storage on this tablet.\n\n$error',
                    textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Red Office Choice header with the mode switch; shows either the kiosk or the manager screen.
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
    final segmentStyle = ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : Colors.transparent),
      foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.brandRed : Colors.white),
      side: const WidgetStatePropertyAll(BorderSide(color: Colors.white70)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w600)),
    );
    return Scaffold(
      body: Column(children: [
        Material(
          color: AppColors.brandRed,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: LayoutBuilder(builder: (context, box) {
                final brand = Row(mainAxisSize: MainAxisSize.min, children: [
                  BrandLogo(height: box.maxWidth < 640 ? 32 : 40),
                  const SizedBox(width: 14),
                  Container(width: 1, height: 30, color: Colors.white38),
                  const SizedBox(width: 14),
                  const Flexible(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('CREW CLOCK',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: 1)),
                      Text('TIME & ATTENDANCE',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppColors.brandYellow, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ]);
                final modes = SegmentedButton<bool>(
                  style: segmentStyle,
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
                );
                if (box.maxWidth < 640) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [brand, const SizedBox(height: 10), modes]);
                }
                return Row(children: [Expanded(child: brand), const SizedBox(width: 12), modes]);
              }),
            ),
          ),
        ),
        Container(height: 4, color: AppColors.brandYellow),
        const SizedBox(height: 12),
        Expanded(
          child: SafeArea(
            top: false,
            child: manager
                ? ManagerScreen(onStartSetup: _startSetup)
                : KioskScreen(
                    key: ValueKey('kiosk-$kioskGeneration'),
                    enrollWorker: enrollWorker,
                    onEnrollStarted: () => enrollWorker = null,
                  ),
          ),
        ),
      ]),
    );
  }
}
