import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../data/sync.dart';
import '../ui.dart';
import '../util/format.dart';

enum _Step { pick, qr, done }

/// The screen workers use: tap your name, scan the QR code with your own phone.
class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key});

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  final store = Store.instance;
  final sync = SyncService.instance;
  final searchCtrl = TextEditingController();

  _Step step = _Step.pick;
  Worker? worker;
  String? qrUrl;
  String? token;
  DateTime? expires;
  String? refused; // why the phone's scan was refused, if it was
  String? checkError; // tablet couldn't reach the sheet
  Timer? poll;
  Timer? tick;
  Timer? backTimer;
  bool polling = false;

  // done screen
  bool doneIn = true;
  String doneTime = '';
  String doneMsg = '';

  @override
  void dispose() {
    poll?.cancel();
    tick?.cancel();
    backTimer?.cancel();
    searchCtrl.dispose();
    super.dispose();
  }

  void _toList() {
    poll?.cancel();
    tick?.cancel();
    backTimer?.cancel();
    setState(() {
      step = _Step.pick;
      worker = null;
      qrUrl = null;
      token = null;
      refused = null;
      checkError = null;
      searchCtrl.clear();
    });
  }

  void _showQr(Worker w) {
    final qr = sync.qrFor(w);
    if (qr == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      worker = w;
      qrUrl = qr.url;
      token = qr.token;
      expires = qr.expires;
      refused = null;
      checkError = null;
      step = _Step.qr;
    });
    poll?.cancel();
    tick?.cancel();
    poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
    tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (expires != null && DateTime.now().isAfter(expires!.add(const Duration(seconds: 3)))) {
        _toList();
      } else {
        setState(() {}); // countdown
      }
    });
  }

  Future<void> _check() async {
    final t = token, w = worker;
    if (t == null || w == null || polling) return;
    polling = true;
    try {
      final r = await sync.send({'type': 'qr_status', 'token': t});
      if (!mounted || token != t) return;
      if (r['done'] == true && r['result'] is Map) {
        final res = Map<String, Object?>.from(r['result'] as Map);
        final type = res['punch'] == 'OUT' ? 'out' : 'in';
        final at = (res['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
        await store.recordScannedPunch(w, type, at);
        final hours = res['hours'];
        _finish(
          type == 'in',
          '${res['time'] ?? fmtTime(DateTime.fromMillisecondsSinceEpoch(at))}',
          type == 'in'
              ? 'Have a good shift, ${w.firstName}.'
              : 'See you next time, ${w.firstName}.${hours is num ? ' Shift length: ${fmtHours(hours.toDouble())} h.' : ''}',
        );
      } else {
        final why = '${r['refused'] ?? ''}';
        setState(() {
          refused = why.isEmpty ? null : why;
          checkError = null;
        });
      }
    } catch (e) {
      if (mounted && token == t) setState(() => checkError = SyncService.describe(e));
    } finally {
      polling = false;
    }
  }

  void _finish(bool isIn, String time, String msg) {
    poll?.cancel();
    tick?.cancel();
    setState(() {
      doneIn = isIn;
      doneTime = time;
      doneMsg = msg;
      step = _Step.done;
      token = null;
    });
    backTimer?.cancel();
    backTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) _toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([store, sync]),
      builder: (context, _) {
        if (!sync.isOn) return _notConnected();
        return switch (step) {
          _Step.pick => _picker(),
          _Step.qr => _qrPanel(),
          _Step.done => _donePanel(),
        };
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

  // ---------- name list ----------

  Widget _picker() {
    final q = searchCtrl.text.trim().toLowerCase();
    final list = store.sortedWorkers
        .where((w) => w.active)
        .where((w) => q.isEmpty || w.name.toLowerCase().contains(q) || w.id.toLowerCase().contains(q))
        .toList();
    final total = store.workers.values.where((w) => w.active).length;

    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 1100 ? 4 : box.maxWidth >= 800 ? 3 : box.maxWidth >= 520 ? 2 : 1;
      return CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          sliver: SliverToBoxAdapter(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 12,
              spacing: 16,
              children: [
                const LiveClock(big: false),
                if (total > 8)
                  SizedBox(
                    width: 340,
                    child: TextField(
                      controller: searchCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Find your name',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: q.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(Icons.close),
                                onPressed: () => setState(searchCtrl.clear),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          sliver: SliverToBoxAdapter(
            child: Text('TAP YOUR NAME TO CLOCK IN OR OUT', style: sectionLabel),
          ),
        ),
        if (list.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                total == 0 ? 'No workers yet. Your manager adds workers in the Manager screen.' : 'No one matches "${searchCtrl.text}".',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted, fontSize: 16),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                mainAxisExtent: 84,
              ),
              delegate: SliverChildBuilderDelegate((context, i) => _nameTile(list[i]), childCount: list.length),
            ),
          ),
      ]);
    });
  }

  Widget _nameTile(Worker w) {
    final last = store.lastPunch(w.id);
    final onShift = last != null && last.isIn;
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: onShift ? AppColors.inGreen : AppColors.line, width: onShift ? 2 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showQr(w),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            WorkerAvatar(w, size: 46),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  onShift ? 'On shift since ${fmtTime(last.time)}' : w.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: onShift ? AppColors.inGreen : AppColors.muted, fontSize: 13, fontWeight: onShift ? FontWeight.w600 : FontWeight.w400),
                ),
              ]),
            ),
            const Icon(Icons.qr_code_2, color: AppColors.muted),
          ]),
        ),
      ),
    );
  }

  // ---------- QR ----------

  Widget _qrPanel() {
    final w = worker!;
    final last = store.lastPunch(w.id);
    final goingOut = last != null && last.isIn;
    final left = expires == null ? 0 : expires!.difference(DateTime.now()).inSeconds.clamp(0, 999);
    final actionColor = goingOut ? AppColors.outAmber : AppColors.inGreen;

    final qrBox = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: AppColors.line)),
      child: QrImageView(
        data: qrUrl!,
        version: QrVersions.auto,
        size: 300,
        backgroundColor: Colors.white,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        semanticsLabel: 'QR code for ${w.name}',
      ),
    );

    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text('Hi, ${w.firstName}', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: AppColors.ink)),
      const SizedBox(height: 6),
      Text.rich(TextSpan(children: [
        const TextSpan(text: 'Scan with your phone to '),
        TextSpan(text: goingOut ? 'CLOCK OUT' : 'CLOCK IN', style: TextStyle(fontWeight: FontWeight.w800, color: actionColor)),
      ]), style: const TextStyle(fontSize: 20)),
      const SizedBox(height: 16),
      const _HowTo(),
      const SizedBox(height: 16),
      if (refused != null) ...[ErrorText('Scan refused: $refused'), const SizedBox(height: 12)],
      if (checkError != null) ...[ErrorText('Can\'t check for your scan. $checkError'), const SizedBox(height: 12)],
      Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Text('Waiting for your scan · code expires in ${left}s',
            style: const TextStyle(color: AppColors.muted, fontFeatures: [FontFeature.tabularFigures()])),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        OutlinedButton(onPressed: _toList, child: const Text('Cancel')),
        const SizedBox(width: 10),
        TextButton(onPressed: () => _showQr(w), child: const Text('New code')),
      ]),
    ]);

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 760;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Panel(
              padding: const EdgeInsets.all(24),
              child: wide
                  ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      qrBox,
                      const SizedBox(width: 32),
                      Expanded(child: info),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(child: qrBox),
                      const SizedBox(height: 20),
                      info,
                    ]),
            ),
          ),
        ),
      );
    });
  }

  // ---------- done ----------

  Widget _donePanel() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Panel(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle, size: 72, color: doneIn ? AppColors.inGreen : AppColors.outAmber),
                const SizedBox(height: 8),
                StatusChip(doneIn ? 'Clocked in' : 'Clocked out', doneIn ? ChipKind.onShift : ChipKind.out),
                const SizedBox(height: 8),
                Text(doneTime, style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w800, height: 1.1)),
                const SizedBox(height: 8),
                Text(doneMsg, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
                const SizedBox(height: 16),
                SizedBox(width: double.infinity, child: OutlinedButton(onPressed: _toList, child: const Text('Done'))),
              ]),
            ),
          ),
        ),
      );
}

class _HowTo extends StatelessWidget {
  const _HowTo();

  @override
  Widget build(BuildContext context) {
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: AppColors.brandRed, shape: BoxShape.circle),
              child: Text(n, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
          ]),
        );
    return Column(children: [
      step('1', 'Open your phone\'s camera and point it at the code.'),
      step('2', 'Tap the link that appears.'),
      step('3', 'Wait for the green tick on your phone.'),
      const Padding(
        padding: EdgeInsets.only(left: 32),
        child: Text('First time? Your scan links this phone to you. Always use the same phone.',
            style: TextStyle(color: AppColors.muted, fontSize: 13)),
      ),
    ]);
  }
}

/// Big live clock shown on the kiosk.
class LiveClock extends StatefulWidget {
  const LiveClock({super.key, required this.big});
  final bool big;

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
    final size = widget.big ? 140.0 : 56.0;
    return Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 14, runSpacing: 4, children: [
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text('$h:${two(now.minute)}',
            style: TextStyle(
                fontSize: size, fontWeight: FontWeight.w800, height: 1, letterSpacing: -1, color: AppColors.ink, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 6),
        Text(now.hour < 12 ? 'AM' : 'PM', style: TextStyle(fontSize: size * .32, fontWeight: FontWeight.w700, color: AppColors.muted)),
      ]),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(fmtLongDate(now), style: const TextStyle(color: AppColors.muted, fontSize: 14)),
      ),
    ]);
  }
}
