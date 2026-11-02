import 'package:flutter/material.dart';

import '../data/store.dart';
import '../data/sync.dart';
import '../ui.dart';
import '../util/format.dart';

/// Manager toolbar button that shows the upload status and opens the Cloud sync settings.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        final (icon, label, color) = !sync.isOn
            ? (Icons.cloud_off_outlined, 'Cloud sync: off', AppColors.muted)
            : sync.lastError != null && sync.pending > 0
                ? (Icons.cloud_queue, '${sync.pending} waiting to upload', AppColors.outAmber)
                : sync.pending > 0
                    ? (Icons.cloud_upload_outlined, 'Uploading ${sync.pending}…', AppColors.accent)
                    : (Icons.cloud_done_outlined, 'Synced to Google Sheet', AppColors.inGreen);
        return OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 40),
            foregroundColor: color,
            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          onPressed: () => showDialog<void>(context: context, builder: (_) => const SyncSettingsDialog()),
          icon: Icon(icon, size: 18),
          label: Text(label),
        );
      },
    );
  }
}

class SyncSettingsDialog extends StatefulWidget {
  const SyncSettingsDialog({super.key});

  @override
  State<SyncSettingsDialog> createState() => _SyncSettingsDialogState();
}

class _SyncSettingsDialogState extends State<SyncSettingsDialog> {
  final store = Store.instance;
  final sync = SyncService.instance;
  late final TextEditingController linkCtrl = TextEditingController(text: store.sheetUrl ?? '');
  bool testing = false;
  String? error;
  String? success;

  @override
  void dispose() {
    linkCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final link = linkCtrl.text.trim();
    if (!link.startsWith('https://script.google.com/') || !link.contains('key=')) {
      setState(() {
        error = 'Paste the full tablet link. It starts with https://script.google.com/ and ends with ?key= and your key.';
        success = null;
      });
      return;
    }
    setState(() {
      testing = true;
      error = null;
      success = null;
    });
    try {
      final reply = await sync.send({'type': 'ping'}, url: link);
      final firstTime = store.sheetUrl != link;
      await store.setSheetUrl(link);
      final queued = firstTime ? await store.enqueueEverything() : 0;
      if (!mounted) return;
      setState(() {
        testing = false;
        success = 'Connected to "${reply['sheet'] ?? 'your sheet'}".'
            '${queued > 0 ? ' Uploading $queued existing records now.' : ''}';
      });
      await sync.syncNow();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        testing = false;
        error = SyncService.describe(e);
      });
    }
  }

  Future<void> _turnOff() async {
    final ok = await confirm(context,
        title: 'Turn off cloud sync?',
        body: 'New clock-ins stay on this tablet only. Anything not uploaded yet is dropped from the upload list. The Google Sheet keeps what it already has.',
        yes: 'Turn off');
    if (!ok) return;
    await store.setSheetUrl(null);
    await sync.syncNow();
    if (mounted) setState(() => success = 'Cloud sync is off.');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cloud sync'),
      content: SizedBox(
        width: 520,
        child: AnimatedBuilder(
          animation: sync,
          builder: (context, _) => SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text(
                'Every clock-in, clock-out and new worker is sent to your Google Sheet, so you can see the timesheet from anywhere. '
                'If the internet drops, records wait on the tablet and upload later.',
                style: TextStyle(color: AppColors.muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: linkCtrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'Tablet link',
                  hintText: 'https://script.google.com/macros/s/…/exec?key=…',
                ),
              ),
              const SizedBox(height: 12),
              if (error != null) ErrorText(error),
              if (success != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppColors.inBg, borderRadius: BorderRadius.circular(8)),
                  child: Text(success!, style: const TextStyle(color: AppColors.inGreen)),
                ),
              if (sync.isOn) ...[
                const SizedBox(height: 12),
                Text(
                  sync.pending > 0
                      ? '${sync.pending} records waiting to upload.${sync.lastError != null ? ' ${sync.lastError}' : ''}'
                      : sync.lastSynced != null
                          ? 'Everything uploaded. Last upload ${fmtTime(sync.lastSynced!)}.'
                          : 'Nothing waiting to upload.',
                  style: TextStyle(color: sync.lastError != null && sync.pending > 0 ? AppColors.outAmber : AppColors.muted),
                ),
              ],
            ]),
          ),
        ),
      ),
      actions: [
        if (store.sheetUrl != null) TextButton(onPressed: testing ? null : _turnOff, child: const Text('Turn off')),
        if (store.sheetUrl != null)
          TextButton(onPressed: testing || sync.busy ? null : () => sync.syncNow(), child: const Text('Upload now')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(
          onPressed: testing ? null : _connect,
          child: Text(testing ? 'Testing…' : 'Test and connect'),
        ),
      ],
    );
  }
}
