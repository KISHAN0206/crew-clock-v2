import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../ui.dart';
import '../util/format.dart';
import '../util/security.dart';
import 'camera_screen.dart';

enum _Step { login, punch, done, enrollPin, enrollPhoto }

/// The screen workers use: sign in with ID + PIN, take a photo, clock in or out.
/// Also runs first-day setup when the manager hands over the tablet.
class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key, this.enrollWorker, this.onEnrollStarted});

  /// When set, the kiosk opens straight into first-day setup for this worker.
  final Worker? enrollWorker;
  final VoidCallback? onEnrollStarted;

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  final store = Store.instance;
  _Step step = _Step.login;

  final idCtrl = TextEditingController();
  final pinCtrl = TextEditingController();
  final pin1Ctrl = TextEditingController();
  final pin2Ctrl = TextEditingController();

  Worker? worker;
  String nextType = 'in';
  Uint8List? photo;
  String? error;
  bool busy = false;
  String? enrollPin;

  // done screen
  Uint8List? donePhoto;
  String doneChip = '';
  bool doneIsIn = true;
  String doneBig = '';
  String doneMsg = '';
  Timer? doneTimer;

  @override
  void initState() {
    super.initState();
    final w = widget.enrollWorker;
    if (w != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onEnrollStarted?.call();
        _startEnroll(w);
      });
    }
  }

  @override
  void dispose() {
    doneTimer?.cancel();
    for (final c in [idCtrl, pinCtrl, pin1Ctrl, pin2Ctrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _reset() {
    doneTimer?.cancel();
    setState(() {
      step = _Step.login;
      worker = null;
      photo = null;
      error = null;
      busy = false;
      enrollPin = null;
      idCtrl.clear();
      pinCtrl.clear();
      pin1Ctrl.clear();
      pin2Ctrl.clear();
    });
  }

  // ---------- sign in ----------

  void _signIn() {
    final id = matchWorkerId(idCtrl.text, store.workers.keys) ?? normaliseWorkerId(idCtrl.text);
    final pin = pinCtrl.text.trim();
    final w = store.workers[id];
    if (w != null && !w.isSetUp) {
      pinCtrl.clear();
      setState(() => error = 'This ID isn\'t set up yet. Ask your manager to start your first-day setup.');
      return;
    }
    if (w == null || !store.checkWorkerPin(w, pin)) {
      pinCtrl.clear();
      setState(() => error = 'ID or PIN is wrong. Try again, or ask your manager to reset your PIN.');
      return;
    }
    if (!w.active) {
      setState(() => error = 'This account is switched off. Ask your manager to turn it back on.');
      return;
    }
    final last = store.lastPunch(w.id);
    FocusScope.of(context).unfocus();
    setState(() {
      worker = w;
      nextType = (last != null && last.isIn) ? 'out' : 'in';
      photo = null;
      error = null;
      step = _Step.punch;
    });
  }

  Future<void> _takePunchPhoto() async {
    final bytes = await takePhoto(context, 'Clock-${nextType == 'in' ? 'in' : 'out'} photo: look at the camera');
    if (bytes != null && mounted) setState(() => photo = bytes);
  }

  Future<void> _punch() async {
    final w = worker, img = photo;
    if (w == null || img == null || busy) return;
    setState(() => busy = true);
    try {
      final previous = store.lastPunch(w.id);
      final p = await store.addPunch(w, nextType, img);
      var msg = p.isIn ? 'Have a good shift, ${w.firstName}.' : 'See you next time, ${w.firstName}.';
      if (!p.isIn && previous != null && previous.isIn) {
        msg += ' Shift length: ${fmtHours((p.at - previous.at) / 3600000.0)} h.';
      }
      _showDone(img, p.isIn ? 'Clocked in' : 'Clocked out', p.isIn, fmtTime(p.time), msg, const Duration(seconds: 8));
    } catch (_) {
      setState(() {
        busy = false;
        error = 'Punch not saved. Try again.';
      });
    }
  }

  void _showDone(Uint8List img, String chip, bool isIn, String big, String msg, Duration back) {
    setState(() {
      donePhoto = img;
      doneChip = chip;
      doneIsIn = isIn;
      doneBig = big;
      doneMsg = msg;
      busy = false;
      step = _Step.done;
    });
    doneTimer?.cancel();
    doneTimer = Timer(back, () {
      if (mounted) _reset();
    });
  }

  // ---------- first-day setup ----------

  void _startEnroll(Worker w) {
    doneTimer?.cancel();
    setState(() {
      worker = w;
      step = _Step.enrollPin;
      error = null;
      photo = null;
      enrollPin = null;
      pin1Ctrl.clear();
      pin2Ctrl.clear();
    });
  }

  void _enrollPinNext() {
    final a = pin1Ctrl.text.trim(), b = pin2Ctrl.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(a)) {
      setState(() => error = 'Your PIN must be exactly 4 digits.');
      return;
    }
    if (isWeakPin(a)) {
      setState(() => error = 'Pick a PIN that\'s harder to guess than $a.');
      return;
    }
    if (a != b) {
      pin2Ctrl.clear();
      setState(() => error = 'The two PINs don\'t match. Enter it again.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      enrollPin = a;
      error = null;
      step = _Step.enrollPhoto;
    });
  }

  Future<void> _takeIdPhoto() async {
    final bytes = await takePhoto(context, 'ID photo: face the camera, no hat or sunglasses');
    if (bytes != null && mounted) setState(() => photo = bytes);
  }

  Future<void> _finishEnroll() async {
    final w = worker, pin = enrollPin, img = photo;
    if (w == null || pin == null || img == null || busy) return;
    setState(() => busy = true);
    try {
      await store.completeSetup(w, pin, img);
      _showDone(img, 'Setup complete', true, w.id,
          'You\'re all set, ${w.firstName}. Clock in with ${w.id} and your PIN.', const Duration(seconds: 10));
    } catch (_) {
      setState(() {
        busy = false;
        error = 'Setup not saved. Try again.';
      });
    }
  }

  // ---------- layout ----------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 900;
      final panel = ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: _panel());
      if (wide) {
        return Row(children: [
          const Expanded(child: Center(child: LiveClock(big: true))),
          Expanded(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: panel))),
        ]);
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Column(children: [const LiveClock(big: false), const SizedBox(height: 20), Center(child: panel)]),
      );
    });
  }

  Widget _panel() => switch (step) {
        _Step.login => _loginPanel(),
        _Step.punch => _punchPanel(),
        _Step.done => _donePanel(),
        _Step.enrollPin || _Step.enrollPhoto => _enrollPanel(),
      };

  Widget _title(String t) => Text(t.toUpperCase(),
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: .5, color: AppColors.ink));

  InputDecoration _dec(String label, {String? hint}) => InputDecoration(labelText: label, hintText: hint, counterText: '');

  Widget _pinField(TextEditingController c, String label, {TextInputAction action = TextInputAction.done, VoidCallback? onDone}) {
    return TextField(
      controller: c,
      decoration: _dec(label, hint: '••••'),
      obscureText: true,
      keyboardType: TextInputType.number,
      maxLength: 4,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 28, letterSpacing: 16),
      textInputAction: action,
      onSubmitted: (_) => onDone?.call(),
    );
  }

  Widget _loginPanel() => Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('Sign in to punch'),
          const SizedBox(height: 16),
          TextField(
            controller: idCtrl,
            decoration: _dec('Worker ID', hint: Store.idExample),
            keyboardType: TextInputType.number,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            style: const TextStyle(fontSize: 20, letterSpacing: 2),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          _pinField(pinCtrl, '4-digit PIN', onDone: _signIn),
          if (error != null) ...[const SizedBox(height: 12), ErrorText(error)],
          const SizedBox(height: 16),
          FilledButton(onPressed: _signIn, child: const Text('Continue')),
          const SizedBox(height: 12),
          const Text('Use the ID your manager gave you and the PIN you created on your first day.',
              style: TextStyle(color: AppColors.muted, fontSize: 13)),
        ]),
      );

  Widget _punchPanel() {
    final w = worker!;
    final last = store.lastPunch(w.id);
    final since = last == null
        ? 'First punch on this account.'
        : last.isIn
            ? 'Clocked in at ${fmtTime(last.time)}, ${fmtDate(last.time)}.'
            : 'Last clocked out at ${fmtTime(last.time)}, ${fmtDate(last.time)}.';
    final isIn = nextType == 'in';
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          WorkerAvatar(w, size: 52),
          const SizedBox(width: 12),
          Expanded(child: _title('Hi, ${w.firstName}')),
          StatusChip(isIn ? 'Off shift' : 'On shift', isIn ? ChipKind.off : ChipKind.onShift),
        ]),
        const SizedBox(height: 8),
        Text(since, style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 16),
        PhotoBox(
          photo: photo,
          title: 'Tap to take a photo',
          hint: 'Face the camera. A photo is required to punch.',
          icon: Icons.photo_camera_outlined,
          onTap: _takePunchPhoto,
        ),
        if (error != null) ...[const SizedBox(height: 12), ErrorText(error)],
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _reset, child: const Text('Cancel'))),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: isIn ? AppColors.inGreen : AppColors.outAmber),
              onPressed: photo == null || busy ? null : _punch,
              child: Text(isIn ? 'Clock in' : 'Clock out'),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _donePanel() => Panel(
        child: Column(children: [
          if (donePhoto != null)
            ClipOval(child: Image.memory(donePhoto!, width: 120, height: 120, fit: BoxFit.cover)),
          const SizedBox(height: 12),
          StatusChip(doneChip, doneIsIn ? ChipKind.onShift : ChipKind.out),
          const SizedBox(height: 8),
          Text(doneBig, style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w800, height: 1.1)),
          const SizedBox(height: 8),
          Text(doneMsg, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: OutlinedButton(onPressed: _reset, child: const Text('Done'))),
        ]),
      );

  Widget _enrollPanel() {
    final w = worker!;
    final onPin = step == _Step.enrollPin;
    TextStyle stepStyle(bool current) => TextStyle(
        fontSize: 12, letterSpacing: 1, fontWeight: current ? FontWeight.w700 : FontWeight.w500,
        color: current ? AppColors.accent : AppColors.muted);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('1 · CREATE PIN', style: stepStyle(onPin)),
          const Text('  →  ', style: TextStyle(color: AppColors.muted)),
          Text('2 · ID PHOTO', style: stepStyle(!onPin)),
        ]),
        const SizedBox(height: 10),
        _title('Welcome, ${w.firstName}'),
        const SizedBox(height: 6),
        Text.rich(TextSpan(children: [
          const TextSpan(text: 'Your worker ID is '),
          TextSpan(text: w.id, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1)),
          const TextSpan(text: '. You\'ll use it with your PIN every time you clock in or out.'),
        ]), style: const TextStyle(color: AppColors.muted)),
        const SizedBox(height: 16),
        if (onPin) ...[
          _pinField(pin1Ctrl, 'Create a 4-digit PIN', action: TextInputAction.next),
          const SizedBox(height: 12),
          _pinField(pin2Ctrl, 'Enter it again', onDone: _enrollPinNext),
          if (error != null) ...[const SizedBox(height: 12), ErrorText(error)],
          const SizedBox(height: 16),
          FilledButton(onPressed: _enrollPinNext, child: const Text('Next: ID photo')),
        ] else ...[
          PhotoBox(
            photo: photo,
            title: 'Tap to take your ID photo',
            hint: 'Face the camera in good light, no hat or sunglasses. Your manager uses this to check your clock-in photos.',
            icon: Icons.account_circle_outlined,
            onTap: _takeIdPhoto,
          ),
          if (error != null) ...[const SizedBox(height: 12), ErrorText(error)],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() {
                  step = _Step.enrollPin;
                  error = null;
                }),
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: FilledButton(onPressed: photo == null || busy ? null : _finishEnroll, child: const Text('Finish setup'))),
          ]),
        ],
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _reset, child: const Text('Cancel setup'))),
      ]),
    );
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
    final size = widget.big ? 140.0 : 88.0;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text('$h:${two(now.minute)}',
            style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, height: 1, letterSpacing: -2, color: AppColors.ink,
                fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(width: 8),
        Text(now.hour < 12 ? 'AM' : 'PM', style: TextStyle(fontSize: size * .3, fontWeight: FontWeight.w700, color: AppColors.muted)),
      ]),
      const SizedBox(height: 8),
      Text(fmtLongDate(now).toUpperCase(), style: const TextStyle(letterSpacing: 2, color: AppColors.muted, fontSize: 13)),
    ]);
  }
}
