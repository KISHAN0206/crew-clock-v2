import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/store.dart';
import '../data/sync.dart';
import '../ui.dart';
import '../util/format.dart';

/// The clock-in screen: one QR code for everyone. Workers scan it with their own phone,
/// and the list on the right shows who just clocked in or out.
class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key});

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  final store = Store.instance;
  final sync = SyncService.instance;

  String? qrUrl;
  DateTime? nextChange;
  Timer? tick;
  Timer? poll;
  bool polling = false;

  List<Map<String, Object?>> feed = const [];
  final Set<String> seen = {};
  bool firstLoad = true;
  String? offline;

  // Big confirmation shown on the tablet for a few seconds after each scan.
  Map<String, Object?>? flash;
  Timer? flashTimer;

  @override
  void initState() {
    super.initState();
    _refreshQr();
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (nextChange == null || !DateTime.now().isBefore(nextChange!)) {
        _refreshQr();
      } else {
        setState(() {}); // countdown
      }
    });
    _poll();
  }

  @override
  void dispose() {
    tick?.cancel();
    poll?.cancel();
    flashTimer?.cancel();
    super.dispose();
  }

  void _refreshQr() {
    final qr = sync.stationQr();
    setState(() {
      qrUrl = qr?.url;
      nextChange = qr?.nextChange;
    });
  }

  /// Checks often during the working day and rarely overnight.
  Duration get _pollEvery {
    final h = DateTime.now().hour;
    return h >= 5 ? const Duration(seconds: 3) : const Duration(seconds: 30);
  }

  Future<void> _poll() async {
    poll?.cancel();
    if (sync.isOn && !polling) {
      polling = true;
      try {
        final items = await sync.recentPunches();
        if (!mounted) return;
        await _absorb(items);
        setState(() {
          feed = items;
          offline = null;
        });
      } catch (e) {
        if (mounted) setState(() => offline = SyncService.describe(e));
      } finally {
        polling = false;
      }
    }
    if (mounted) poll = Timer(_pollEvery, _poll);
  }

  /// Saves new punches to the tablet's own timesheet and flashes the newest one.
  Future<void> _absorb(List<Map<String, Object?>> items) async {
    Map<String, Object?>? newest;
    for (final i in items.reversed) {
      final id = '${i['id'] ?? ''}';
      final at = (i['at'] as num?)?.toInt() ?? 0;
      final key = '$id-$at';
      if (id.isEmpty || at == 0 || !seen.add(key)) continue;
      final w = store.workers[id];
      if (w != null) await store.recordScannedPunch(w, i['punch'] == 'OUT' ? 'out' : 'in', at);
      final fresh = DateTime.now().millisecondsSinceEpoch - at < 60 * 1000;
      if (!firstLoad && fresh) newest = i;
    }
    firstLoad = false;
    if (newest != null) {
      flashTimer?.cancel();
      setState(() => flash = newest);
      flashTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => flash = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([store, sync]),
      builder: (context, _) {
        if (!sync.isOn || qrUrl == null) return _notConnected();
        return LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final qr = _qrCard(wide);
          final side = _sidePanel();
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(flex: 6, child: qr),
                    const SizedBox(width: 20),
                    Expanded(flex: 4, child: side),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [qr, const SizedBox(height: 16), side]),
          );
        });
      },
    );
  }

  // ---------- not connected ----------

  Widget _notConnected() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: const Panel(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.cloud_off_outlined, size: 48, color: AppColors.muted),
                SizedBox(height: 12),
                Text('Clock-in needs the Google Sheet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                SizedBox(height: 8),
                Text(
                  'Workers clock in by scanning a QR code with their phone, and the scan is recorded in the Google Sheet. '
                  'Ask your manager to open Manager → Cloud sync and connect the sheet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted),
                ),
              ]),
            ),
          ),
        ),
      );

  // ---------- QR ----------

  Widget _qrCard(bool wide) {
    final left = nextChange == null ? 0 : nextChange!.difference(DateTime.now()).inSeconds.clamp(0, SyncService.codeSeconds);
    final f = flash;
    return Panel(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        const Text('SCAN TO CLOCK IN OR OUT',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: .5, color: AppColors.ink)),
        const SizedBox(height: 4),
        const Text('Use your phone\'s camera, then tap the link.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted, fontSize: 16)),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: f != null
              ? _flashCard(f, wide ? 340 : 280)
              : Container(
                  key: ValueKey(qrUrl),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line, width: 2)),
                  child: QrImageView(
                    data: qrUrl!,
                    version: QrVersions.auto,
                    size: wide ? 340 : 280,
                    backgroundColor: Colors.white,
                    errorCorrectionLevel: QrErrorCorrectLevel.L,
                    semanticsLabel: 'Clock in QR code',
                  ),
                ),
        ),
        const SizedBox(height: 12),
        Text('New code in ${left}s',
            style: const TextStyle(color: AppColors.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(height: 16),
        const Divider(color: AppColors.line, height: 1),
        const SizedBox(height: 14),
        const Text(
          'First time? Your phone asks "Who are you?". Pick your name once and your phone is linked to you. '
          'After that, scanning clocks you in, and the next scan clocks you out.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.muted, fontSize: 14),
        ),
      ]),
    );
  }

  Widget _flashCard(Map<String, Object?> f, double size) {
    final isIn = f['punch'] != 'OUT';
    final color = isIn ? AppColors.inGreen : AppColors.outAmber;
    final first = '${f['name'] ?? ''}'.trim().split(RegExp(r'\s+')).first;
    return Container(
      key: ValueKey('flash-${f['at']}'),
      width: size + 24,
      height: size + 24,
      decoration: BoxDecoration(color: isIn ? AppColors.inBg : AppColors.outBg, borderRadius: BorderRadius.circular(16)),
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.check_circle, size: 88, color: color),
        const SizedBox(height: 8),
        Text(isIn ? 'Clocked in' : 'Clocked out', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 6),
        Text(first, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, color: AppColors.ink)),
        Text('${f['time'] ?? ''}', style: const TextStyle(fontSize: 18, color: AppColors.muted)),
      ]),
    );
  }

  // ---------- clock + who just clocked in ----------

  Widget _sidePanel() {
    final today = DateTime.now();
    final midnight = DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;
    final todays = feed.where((i) => ((i['at'] as num?)?.toInt() ?? 0) >= midnight).take(10).toList();
    final onShift = store.workers.values.where((w) {
      final last = store.lastPunch(w.id);
      return w.active && last != null && last.isIn;
    }).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const LiveClock(),
          const SizedBox(height: 10),
          StatusChip('$onShift on shift now', onShift > 0 ? ChipKind.onShift : ChipKind.off),
        ]),
      ),
      const SizedBox(height: 16),
      Panel(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('JUST NOW', style: sectionLabel),
          const SizedBox(height: 6),
          if (offline != null) ...[ErrorText('Can\'t see new scans. $offline'), const SizedBox(height: 8)],
          if (todays.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Text('No one has clocked in yet today.', style: TextStyle(color: AppColors.muted)),
            )
          else
            for (final i in todays) _feedRow(i),
        ]),
      ),
    ]);
  }

  Widget _feedRow(Map<String, Object?> i) {
    final isIn = i['punch'] != 'OUT';
    final hours = i['hours'];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(isIn ? Icons.login : Icons.logout, size: 20, color: isIn ? AppColors.inGreen : AppColors.outAmber),
        const SizedBox(width: 10),
        Expanded(
          child: Text('${i['name'] ?? ''}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        if (!isIn && hours is num) ...[
          Text('${fmtHours(hours.toDouble())} h', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(width: 10),
        ],
        StatusChip(isIn ? 'In' : 'Out', isIn ? ChipKind.onShift : ChipKind.out),
        const SizedBox(width: 10),
        SizedBox(
          width: 70,
          child: Text('${i['time'] ?? ''}',
              textAlign: TextAlign.right, style: const TextStyle(color: AppColors.muted, fontFeatures: [FontFeature.tabularFigures()])),
        ),
      ]),
    );
  }
}

/// Live clock and date.
class LiveClock extends StatefulWidget {
  const LiveClock({super.key});

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> {
  late Timer _t;
  DateTime now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => now = DateTime.now()));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text('$h:${two(now.minute)}',
            style: const TextStyle(
                fontSize: 64, fontWeight: FontWeight.w800, height: 1, letterSpacing: -1, color: AppColors.ink, fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(width: 6),
        Text(now.hour < 12 ? 'AM' : 'PM', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.muted)),
      ]),
      const SizedBox(height: 4),
      Text(fmtLongDate(now), style: const TextStyle(color: AppColors.muted, fontSize: 14)),
    ]);
  }
}
