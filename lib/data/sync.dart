import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'store.dart';

/// Uploads clock-ins, clock-outs and worker details to the Google Sheet.
/// Records wait in a queue on the tablet, so nothing is lost when the internet drops.
class SyncService extends ChangeNotifier with WidgetsBindingObserver {
  SyncService._();
  static final SyncService instance = SyncService._();

  final Store store = Store.instance;
  Timer? _timer;
  bool _running = false;

  int pending = 0;
  String? lastError;
  DateTime? lastSynced;
  bool get isOn => store.sheetUrl != null;
  bool get busy => _running;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    store.onQueued = () => unawaited(syncNow());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncNow());
  }

  Future<void> _count() async {
    pending = await store.pendingUploads();
    notifyListeners();
  }

  /// Sends everything waiting, oldest first. Stops at the first failure and tries again later.
  Future<void> syncNow() async {
    if (_running) return;
    if (!isOn) {
      await _count();
      return;
    }
    _running = true;
    notifyListeners();
    try {
      await _count();
      while (true) {
        final batch = await store.nextUploads(10);
        if (batch.isEmpty) break;
        for (final item in batch) {
          final body = Map<String, Object?>.from(jsonDecode(item.payload) as Map);
          final photo = body.remove('photo_file') as String?;
          if (photo != null) {
            final f = store.photoFile(photo);
            if (await f.exists()) body['photo'] = base64Encode(await f.readAsBytes());
          }
          await send(body);
          await store.markUploaded(item.id);
          pending = pending > 0 ? pending - 1 : 0;
          notifyListeners();
        }
      }
      lastError = null;
      lastSynced = DateTime.now();
    } catch (e) {
      lastError = describe(e);
    } finally {
      _running = false;
      await _count();
    }
  }

  /// Posts one record to the sheet script and returns its JSON reply.
  /// Google answers a POST with a redirect to the result, which is fetched with GET.
  Future<Map<String, Object?>> send(Map<String, Object?> body, {String? url}) async {
    final target = url ?? store.sheetUrl;
    if (target == null) throw const SyncException('Cloud sync is off.');
    final uri = Uri.parse(target);
    final client = http.Client();
    try {
      var res = await client
          .post(uri, headers: {'Content-Type': 'text/plain; charset=utf-8'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 60));
      var hops = 0;
      while (const [301, 302, 303, 307, 308].contains(res.statusCode) && hops < 5) {
        final loc = res.headers['location'];
        if (loc == null) break;
        res = await client.get(uri.resolve(loc)).timeout(const Duration(seconds: 60));
        hops++;
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const SyncException('Google refused the link. In the script, deploy again with "Who has access: Anyone".');
      }
      if (res.statusCode != 200) throw SyncException('The sheet replied with error ${res.statusCode}. Try again shortly.');
      Object? data;
      try {
        data = jsonDecode(res.body);
      } catch (_) {
        throw const SyncException('That link isn\'t the Crew Clock sheet script. Copy the Web app link from Deploy and add ?key=…');
      }
      if (data is! Map || data['ok'] != true) {
        throw SyncException(data is Map && data['error'] != null ? '${data['error']}' : 'The sheet refused the record.');
      }
      return Map<String, Object?>.from(data);
    } finally {
      client.close();
    }
  }

  static String describe(Object e) {
    if (e is SyncException) return e.message;
    if (e is SocketException || e is http.ClientException) {
      return 'No internet right now. Records are saved on the tablet and upload when it\'s back.';
    }
    if (e is TimeoutException) return 'Upload timed out. It will try again in a minute.';
    if (e is FormatException) return 'That doesn\'t look like a web link. It should start with https://script.google.com/';
    return 'Upload failed: $e';
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class SyncException implements Exception {
  const SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}
