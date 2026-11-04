import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../data/sync.dart';
import '../ui.dart';
import '../util/format.dart';
import '../util/hours.dart';
import 'sync_settings.dart';

/// Manager side: PIN-protected. Add workers, start their setup, see timesheets, export and back up.
class ManagerScreen extends StatefulWidget {
  const ManagerScreen({super.key});


  @override
  State<ManagerScreen> createState() => _ManagerScreenState();
}

class _ManagerScreenState extends State<ManagerScreen> {
  final store = Store.instance;
  bool unlocked = false;

  final pinA = TextEditingController();
  final pinB = TextEditingController();
  String? pinError;

  @override
  void dispose() {
    pinA.dispose();
    pinB.dispose();
    super.dispose();
  }

  Future<void> _savePin() async {
    final a = pinA.text, b = pinB.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(a)) {
      setState(() => pinError = 'Use 4 to 8 digits.');
      return;
    }
    if (a != b) {
      setState(() => pinError = 'The two PINs don\'t match.');
      return;
    }
    await store.setAdminPin(a);
    pinA.clear();
    pinB.clear();
    setState(() {
      pinError = null;
      unlocked = true;
    });
  }

  void _unlock() {
    if (!store.checkAdminPin(pinA.text)) {
      pinA.clear();
      setState(() => pinError = 'Wrong PIN.');
      return;
    }
    pinA.clear();
    setState(() {
      pinError = null;
      unlocked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!unlocked) return _gate();
    return _ManagerBody(onLock: () => setState(() => unlocked = false));
  }

  Widget _gate() {
    final first = !store.hasAdminPin;
    Widget pinField(TextEditingController c, String label, {VoidCallback? onDone}) => TextField(
          controller: c,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 8,
          decoration: InputDecoration(labelText: label, counterText: ''),
          style: const TextStyle(fontSize: 22, letterSpacing: 8),
          onSubmitted: (_) => onDone?.call(),
        );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(first ? 'SET A MANAGER PIN' : 'MANAGER SIGN-IN',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: .5)),
              if (first) ...[
                const SizedBox(height: 6),
                const Text('This PIN protects worker accounts and timesheets. Use 4–8 digits.', style: TextStyle(color: AppColors.muted)),
              ],
              const SizedBox(height: 16),
              pinField(pinA, first ? 'New PIN' : 'PIN', onDone: first ? null : _unlock),
              if (first) ...[const SizedBox(height: 12), pinField(pinB, 'Confirm PIN', onDone: _savePin)],
              if (pinError != null) ...[const SizedBox(height: 12), ErrorText(pinError)],
              const SizedBox(height: 16),
              FilledButton(onPressed: first ? _savePin : _unlock, child: Text(first ? 'Save PIN' : 'Unlock')),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ManagerBody extends StatefulWidget {
  const _ManagerBody({required this.onLock});
  final VoidCallback onLock;

  @override
  State<_ManagerBody> createState() => _ManagerBodyState();
}

class _ManagerBodyState extends State<_ManagerBody> {
  final store = Store.instance;

  void _toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _saveBytes(String fileName, Uint8List bytes, List<String> exts, String done) async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save $fileName',
        fileName: fileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: exts,
      );
      if (path != null && mounted) _toast(done);
    } catch (_) {
      if (mounted) _toast('Couldn\'t save the file. Try again.');
    }
  }

  Future<void> _backup() async {
    final bytes = await store.backupBytes();
    await _saveBytes('crew-clock-backup-${fmtIsoDate(DateTime.now())}.json', bytes, ['json'],
        'Backup saved. Keep a copy off this tablet, for example in Google Drive.');
  }

  Future<void> _restore() async {
    final ok = await confirm(context,
        title: 'Restore a backup?',
        body: 'This replaces every worker, punch and photo on this tablet with the ones in the backup file.',
        yes: 'Choose backup file');
    if (!ok) return;
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json'], withData: true);
    final bytes = res?.files.single.bytes;
    if (bytes == null) return;
    try {
      final (w, p) = await store.restore(bytes);
      if (mounted) _toast('Backup restored: $w workers, $p punches.');
    } catch (_) {
      if (mounted) _toast('That file isn\'t a Crew Clock backup. Pick the .json file made with Back up.');
    }
  }

  Future<void> _exportCsv(String csv, String name) =>
      _saveBytes(name, Uint8List.fromList(utf8.encode(csv)), ['csv'], 'CSV saved. Open it in Excel or Google Sheets.');

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 8,
            spacing: 8,
            children: [
              const SizedBox(
                width: 320,
                child: TabBar(
                  labelColor: AppColors.ink,
                  unselectedLabelColor: AppColors.muted,
                  indicatorColor: AppColors.accent,
                  tabs: [Tab(text: 'Workers'), Tab(text: 'Timesheet')],
                ),
              ),
              Wrap(spacing: 6, runSpacing: 6, children: [
                const SyncButton(),
                _smallButton(Icons.save_alt, 'Back up', _backup),
                _smallButton(Icons.restore, 'Restore', _restore),
                _smallButton(Icons.lock_outline, 'Lock manager', widget.onLock),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: AnimatedBuilder(
            animation: store,
            builder: (context, _) => TabBarView(children: [
              const _WorkersTab(),
              _TimesheetTab(onExport: _exportCsv),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _smallButton(IconData icon, String label, VoidCallback onTap) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), textStyle: const TextStyle(fontSize: 14)),
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
}

// ---------------- Workers tab ----------------

class _WorkersTab extends StatefulWidget {
  const _WorkersTab();

  @override
  State<_WorkersTab> createState() => _WorkersTabState();
}

class _WorkersTabState extends State<_WorkersTab> {
  final store = Store.instance;
  final nameCtrl = TextEditingController();
  final roleCtrl = TextEditingController();
  Worker? justCreated;

  @override
  void dispose() {
    nameCtrl.dispose();
    roleCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    final w = await store.addWorker(name, roleCtrl.text);
    nameCtrl.clear();
    roleCtrl.clear();
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() => justCreated = w);
  }

  Future<void> _resetPhone(Worker w) async {
    final ok = await confirm(context,
        title: 'Reset ${w.firstName}\'s phone link?',
        body: 'Use this when ${w.firstName} gets a new phone or their scans are refused. '
            'Their next scan links whichever phone they use.',
        yes: 'Reset phone link');
    if (!ok || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SyncService.instance.unlinkPhone(w);
      messenger.showSnackBar(SnackBar(content: Text('${w.firstName}\'s phone link is reset. Their next scan links their phone.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t reset: ${SyncService.describe(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 760;
      final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('ADD A WORKER', style: sectionLabel),
            const SizedBox(height: 12),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full name', hintText: 'e.g. Priya Shah'),
                textCapitalization: TextCapitalization.words, maxLength: 60),
            const SizedBox(height: 10),
            TextField(controller: roleCtrl, decoration: const InputDecoration(labelText: 'Role (optional)', hintText: 'e.g. Packer'),
                textCapitalization: TextCapitalization.sentences, maxLength: 40, onSubmitted: (_) => _add()),
            const SizedBox(height: 12),
            FilledButton(onPressed: _add, child: const Text('Create worker ID')),
          ]),
        ),
        if (justCreated != null) ...[const SizedBox(height: 16), _createdCard(justCreated!)],
      ]);
      final list = _teamList();
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 340, child: left),
                const SizedBox(width: 20),
                Expanded(child: list),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, const SizedBox(height: 16), list]),
      );
    });
  }

  Widget _createdCard(Worker w) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppColors.accent, width: 2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('WORKER ADDED', style: sectionLabel),
          const SizedBox(height: 8),
          Text(w.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          Text(w.id, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600, letterSpacing: 2)),
          const SizedBox(height: 8),
          Text(
              '${w.firstName} can clock in now: tap their name on the Clock in / out screen and scan the QR code with their own phone. '
              'Their first scan links that phone to them.',
              style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: () => setState(() => justCreated = null), child: const Text('OK')),
        ]),
      );

  Widget _teamList() {
    final workers = store.sortedWorkers;
    final week = rangeFor(Period.thisWeek, DateTime.now());
    var onShift = 0;
    final rows = <Widget>[];
    for (final w in workers) {
      final last = store.lastPunch(w.id);
      final isOn = last != null && last.isIn;
      if (isOn) onShift++;
      final s = summarize(store.punches, w.id, week.from, week.to);
      final chip = !w.active
          ? const StatusChip('Switched off', ChipKind.off)
          : isOn
                  ? StatusChip('On shift · ${fmtTime(last.time)}', ChipKind.onShift)
                  : const StatusChip('Off shift', ChipKind.off);
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            WorkerAvatar(w, onTap: w.idPhoto == null ? null : () => showPhoto(context, w.idPhoto!)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(w.name,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: w.active ? AppColors.ink : AppColors.muted,
                        decoration: w.active ? null : TextDecoration.lineThrough)),
                Wrap(spacing: 12, children: [
                  Text(w.id, style: mono.copyWith(color: AppColors.muted, fontSize: 13)),
                  if (w.role.isNotEmpty) Text(w.role, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                  Text('${fmtHours(s.hours)} h this week', style: mono.copyWith(color: AppColors.muted, fontSize: 13)),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            chip,
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _act('Reset phone link', () => _resetPhone(w)),
            _act(w.active ? 'Switch off' : 'Switch on', () => store.setActive(w, !w.active)),
          ]),
        ]),
      ));
      rows.add(const Divider(height: 1, color: AppColors.line));
    }
    if (rows.isNotEmpty) rows.removeLast();

    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('TEAM${workers.isEmpty ? '' : ' (${workers.length})'}', style: sectionLabel),
          const Spacer(),
          if (workers.isNotEmpty) Text('$onShift on shift now', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        if (workers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Column(children: [
              Text('No workers yet', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              SizedBox(height: 4),
              Text('Add a worker. They clock in by tapping their name and scanning the QR code with their phone.',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
            ]),
          )
        else
          ...rows,
      ]),
    );
  }

  Widget _act(String label, VoidCallback onTap) => OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38), textStyle: const TextStyle(fontSize: 14)),
        onPressed: onTap,
        child: Text(label),
      );
}

// ---------------- Timesheet tab ----------------

class _TimesheetTab extends StatefulWidget {
  const _TimesheetTab({required this.onExport});
  final Future<void> Function(String csv, String fileName) onExport;

  @override
  State<_TimesheetTab> createState() => _TimesheetTabState();
}

class _TimesheetTabState extends State<_TimesheetTab> {
  final store = Store.instance;
  Period period = Period.thisWeek;
  String? workerId; // null = everyone

  @override
  Widget build(BuildContext context) {
    final r = rangeFor(period, DateTime.now());
    final workers = [...store.workers.values]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (workerId != null && !store.workers.containsKey(workerId)) workerId = null;
    final shown = workers.where((w) => workerId == null || w.id == workerId);
    final summaries = [
      for (final w in shown) (w, summarize(store.punches, w.id, r.from, r.to)),
    ].where((e) => e.$2.count > 0 || e.$2.open != null || workerId != null).toList();
    final log = store.punchesBetween(r.from, r.to, workerId: workerId);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      child: Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.end, children: [
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<Period>(
                value: period,
                decoration: const InputDecoration(labelText: 'Period'),
                items: [for (final p in Period.values) DropdownMenuItem(value: p, child: Text(p.label))],
                onChanged: (v) => setState(() => period = v ?? period),
              ),
            ),
            SizedBox(
              width: 300,
              child: DropdownButtonFormField<String?>(
                value: workerId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Worker'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Everyone')),
                  for (final w in workers) DropdownMenuItem<String?>(value: w.id, child: Text('${w.name} (${w.id})', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => workerId = v),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => widget.onExport(
                  store.csvFor(log), 'crew-clock-${period.slug}-${fmtIsoDate(DateTime.now())}.csv'),
              icon: const Icon(Icons.table_view_outlined, size: 18),
              label: const Text('Export CSV'),
            ),
          ]),
          const SizedBox(height: 20),
          const Text('HOURS IN PERIOD', style: sectionLabel),
          const SizedBox(height: 8),
          _tableBox(
            summaries.isEmpty
                ? const _EmptyRow('No shifts in this period.')
                : DataTable(
                    headingTextStyle: sectionLabel,
                    columns: const [
                      DataColumn(label: Text('WORKER')),
                      DataColumn(label: Text('ID')),
                      DataColumn(label: Text('SHIFTS'), numeric: true),
                      DataColumn(label: Text('HOURS'), numeric: true),
                      DataColumn(label: Text('STATUS')),
                    ],
                    rows: [
                      for (final (w, s) in summaries)
                        DataRow(cells: [
                          DataCell(Text(w.name)),
                          DataCell(Text(w.id, style: mono)),
                          DataCell(Text('${s.count}')),
                          DataCell(Text(fmtHours(s.hours), style: mono)),
                          DataCell(s.open != null
                              ? StatusChip('On shift since ${fmtTime(s.open!.time)}', ChipKind.onShift)
                              : const StatusChip('Off', ChipKind.off)),
                        ]),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          const Text('PUNCH LOG', style: sectionLabel),
          const SizedBox(height: 8),
          _tableBox(
            log.isEmpty
                ? const _EmptyRow('No punches in this period. Punches appear here as workers clock in.')
                : DataTable(
                    headingTextStyle: sectionLabel,
                    columns: const [
                      DataColumn(label: Text('WORKER')),
                      DataColumn(label: Text('ID')),
                      DataColumn(label: Text('PUNCH')),
                      DataColumn(label: Text('DATE')),
                      DataColumn(label: Text('TIME')),
                    ],
                    rows: [
                      for (final p in log.take(300)) _logRow(p),
                    ],
                  ),
          ),
        ]),
      ),
    );
  }

  DataRow _logRow(Punch p) {
    return DataRow(cells: [
      DataCell(Text(p.name)),
      DataCell(Text(p.workerId, style: mono)),
      DataCell(StatusChip(p.isIn ? 'In' : 'Out', p.isIn ? ChipKind.onShift : ChipKind.out)),
      DataCell(Text(fmtDate(p.time))),
      DataCell(Text(fmtTime(p.time), style: mono)),
    ]);
  }

  Widget _tableBox(Widget child) => Container(
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: child is DataTable ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: child) : child,
      );
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
      );
}
