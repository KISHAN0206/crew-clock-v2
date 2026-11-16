import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../util/security.dart';
import 'models.dart';
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

  /// A one-time QR link for [w]: the worker opens it on their phone to clock in or out.
  /// Signed with the sync key so the sheet knows it came from this tablet. Valid for [life].
  ({String url, String token, DateTime expires})? qrFor(Worker w, {Duration life = const Duration(seconds: 90)}) {
    final link = store.sheetUrl;
    if (link == null) return null;
    final base = Uri.parse(link);
    final key = base.queryParameters['key'];
    if (key == null || key.isEmpty) return null;
    final token = randomString('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789', 20);
    final expires = DateTime.now().add(life);
    final x = expires.millisecondsSinceEpoch.toString();
    final sig = Hmac(sha256, utf8.encode(key)).convert(utf8.encode('$token|${w.id}|${w.name}|$x')).toString();
    final url = Uri(
      scheme: base.scheme,
      host: base.host,
      path: base.path,
      queryParameters: {'a': 'scan', 't': token, 'w': w.id, 'n': w.name, 'x': x, 's': sig},
    ).toString();
    return (url: url, token: token, expires: expires);
  }

  /// The web page workers' phones open after scanning (index.html in the public crew-clock-scan repo, on GitHub Pages).
  static const scanPage = 'https://kishan0206.github.io/crew-clock-scan/';

  /// Seconds each station QR code lasts before the tablet shows a new one (must match the sheet script).
  static const codeSeconds = 30;

  /// The single QR code everyone scans. Changes every [codeSeconds]; signed so it can't be made up.
  ({String url, DateTime nextChange})? stationQr() {
    final link = store.sheetUrl;
    if (link == null) return null;
    final base = Uri.parse(link);
    final key = base.queryParameters['key'];
    if (key == null || key.isEmpty) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final w = now ~/ (codeSeconds * 1000);
    final sig = Hmac(sha256, utf8.encode(key)).convert(utf8.encode('w|$w')).toString().substring(0, 12);
    // The phone opens the scan page (a normal website), which sends the scan to the sheet script.
    // This avoids Google's account switching on phones signed into several Google accounts.
    final segs = base.pathSegments;
    final i = segs.indexOf('s');
    final deployment = (i >= 0 && i + 1 < segs.length) ? segs[i + 1] : '';
    final url = Uri.parse(scanPage).replace(queryParameters: {'s': deployment, 'q': '$w.$sig'}).toString();
    return (url: url, nextChange: DateTime.fromMillisecondsSinceEpoch((w + 1) * codeSeconds * 1000));
  }

  /// Latest punches recorded by the sheet (newest first), for the "just clocked in" list.
  Future<List<Map<String, Object?>>> recentPunches() async {
    final r = await send({'type': 'recent'});
    final items = r['items'];
    if (items is! List) return const [];
    return [for (final i in items) if (i is Map) Map<String, Object?>.from(i)];
  }

  /// Removes the phone link for a worker in the sheet, so their next scan links a new phone.
  Future<void> unlinkPhone(Worker w) async {
    await send({'type': 'unlink', 'id': w.id});
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
