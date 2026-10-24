import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../util/format.dart';
import '../util/security.dart';
import 'models.dart';

/// All app data, kept on this tablet: SQLite for records, JPEG files for photos.
class Store extends ChangeNotifier {
  Store._();
  static final Store instance = Store._();

  static const idPrefix = 'JB-';

  late Database _db;
  late Directory _photos;

  final Map<String, Worker> workers = {};
  List<Punch> punches = []; // newest first
  String? _adminSalt;
  String? _adminHash;

  bool get hasAdminPin => _adminHash != null;

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _photos = Directory(p.join(docs.path, 'photos'));
    if (!await _photos.exists()) await _photos.create(recursive: true);

    _db = await openDatabase(
      p.join(docs.path, 'crew_clock.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE workers(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, role TEXT, active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL, pin_salt TEXT, pin_hash TEXT, id_photo TEXT, setup_at INTEGER)''');
        await db.execute('''
          CREATE TABLE punches(
            id INTEGER PRIMARY KEY AUTOINCREMENT, worker_id TEXT NOT NULL, name TEXT,
            type TEXT NOT NULL, at INTEGER NOT NULL, photo TEXT)''');
        await db.execute('CREATE INDEX punches_worker_at ON punches(worker_id, at)');
        await db.execute('CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)');
      },
    );
    await _load();
  }

  Future<void> _load() async {
    workers
      ..clear()
      ..addEntries((await _db.query('workers')).map((m) {
        final w = Worker.fromMap(m);
        return MapEntry(w.id, w);
      }));
    punches = (await _db.query('punches', orderBy: 'at DESC')).map(Punch.fromMap).toList();
    final s = await _db.query('settings');
    final map = {for (final r in s) r['key'] as String: r['value'] as String?};
    _adminSalt = map['admin_salt'];
    _adminHash = map['admin_hash'];
    notifyListeners();
  }

  // ---------- photos ----------

  File photoFile(String name) => File(p.join(_photos.path, name));

  Future<String> _savePhoto(Uint8List bytes) async {
    final name = '${DateTime.now().millisecondsSinceEpoch}_${randomString('abcdefghijkmnpqrstuvwxyz23456789', 6)}.jpg';
    await photoFile(name).writeAsBytes(bytes, flush: true);
    return name;
  }

  Future<void> _deletePhoto(String? name) async {
    if (name == null) return;
    final f = photoFile(name);
    if (await f.exists()) await f.delete();
  }

  // ---------- manager PIN ----------

  Future<void> setAdminPin(String pin) async {
    final salt = newSalt();
    final hash = hashPin(salt, pin);
    await _db.insert('settings', {'key': 'admin_salt', 'value': salt}, conflictAlgorithm: ConflictAlgorithm.replace);
    await _db.insert('settings', {'key': 'admin_hash', 'value': hash}, conflictAlgorithm: ConflictAlgorithm.replace);
    _adminSalt = salt;
    _adminHash = hash;
    notifyListeners();
  }

  bool checkAdminPin(String pin) => _adminSalt != null && hashPin(_adminSalt!, pin) == _adminHash;

  // ---------- workers ----------

  String _newWorkerId() {
    String id;
    do {
      id = '$idPrefix${randomString('0123456789', 4)}';
    } while (workers.containsKey(id));
    return id;
  }

  List<Worker> get sortedWorkers {
    final list = workers.values.toList()
      ..sort((a, b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return list;
  }

  Future<Worker> addWorker(String name, String role) async {
    final w = Worker(id: _newWorkerId(), name: name.trim(), role: role.trim(), createdAt: DateTime.now().millisecondsSinceEpoch);
    await _db.insert('workers', w.toMap());
    workers[w.id] = w;
    notifyListeners();
    return w;
  }

  Future<void> _saveWorker(Worker w) async {
    await _db.update('workers', w.toMap(), where: 'id = ?', whereArgs: [w.id]);
    workers[w.id] = w;
    notifyListeners();
  }

  /// First-day setup: the worker's own PIN and ID photo.
  Future<void> completeSetup(Worker w, String pin, Uint8List idPhoto) async {
    final old = w.idPhoto;
    w.pinSalt = newSalt();
    w.pinHash = hashPin(w.pinSalt!, pin);
    w.idPhoto = await _savePhoto(idPhoto);
    w.setupAt = DateTime.now().millisecondsSinceEpoch;
    await _saveWorker(w);
    if (old != null && old != w.idPhoto) await _deletePhoto(old);
  }

  /// Clears PIN and ID photo so the worker goes through setup again.
  Future<void> resetSetup(Worker w) async {
    final old = w.idPhoto;
    w.pinSalt = null;
    w.pinHash = null;
    w.idPhoto = null;
    w.setupAt = null;
    await _saveWorker(w);
    await _deletePhoto(old);
  }

  Future<void> setActive(Worker w, bool active) async {
    w.active = active;
    await _saveWorker(w);
  }

  bool checkWorkerPin(Worker w, String pin) => w.isSetUp && hashPin(w.pinSalt!, pin) == w.pinHash;

  // ---------- punches ----------

  Punch? lastPunch(String workerId) {
    for (final p in punches) {
      if (p.workerId == workerId) return p;
    }
    return null;
  }

  Future<Punch> addPunch(Worker w, String type, Uint8List photo) async {
    final name = await _savePhoto(photo);
    final punch = Punch(workerId: w.id, name: w.name, type: type, at: DateTime.now().millisecondsSinceEpoch, photo: name);
    final id = await _db.insert('punches', punch.toMap());
    final saved = Punch(id: id, workerId: punch.workerId, name: punch.name, type: punch.type, at: punch.at, photo: punch.photo);
    punches.insert(0, saved);
    notifyListeners();
    return saved;
  }

  List<Punch> punchesBetween(DateTime from, DateTime to, {String? workerId}) {
    final f = from.millisecondsSinceEpoch, t = to.millisecondsSinceEpoch;
    return punches.where((p) => p.at >= f && p.at < t && (workerId == null || p.workerId == workerId)).toList();
  }

  // ---------- export / backup ----------

  String csvFor(List<Punch> list) {
    String q(String s) => '"${s.replaceAll('"', '""')}"';
    final rows = [...list]..sort((a, b) => a.at.compareTo(b.at));
    final b = StringBuffer('Worker ID,Name,Punch,Date,Time\n');
    for (final p in rows) {
      b.writeln([q(p.workerId), q(p.name), p.isIn ? 'IN' : 'OUT', fmtIsoDate(p.time), fmt24(p.time)].join(','));
    }
    return b.toString();
  }

  Future<String?> _photoB64(String? name) async {
    if (name == null) return null;
    final f = photoFile(name);
    return await f.exists() ? base64Encode(await f.readAsBytes()) : null;
  }

  /// Everything, including photos, as one JSON file.
  Future<Uint8List> backupBytes() async {
    final ws = <Map<String, Object?>>[];
    for (final w in workers.values) {
      ws.add({...w.toMap(), 'id_photo_data': await _photoB64(w.idPhoto)});
    }
    final ps = <Map<String, Object?>>[];
    for (final pu in punches) {
      ps.add({...pu.toMap(), 'photo_data': await _photoB64(pu.photo)});
    }
    final data = {
      'app': 'crew-clock',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'admin_salt': _adminSalt,
      'admin_hash': _adminHash,
      'workers': ws,
      'punches': ps,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(data)));
  }

  /// Replaces all data on this tablet with a backup. Returns (workers, punches) counts.
  Future<(int, int)> restore(Uint8List bytes) async {
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map || data['app'] != 'crew-clock' || data['workers'] is! List || data['punches'] is! List) {
      throw const FormatException('Not a Crew Clock backup');
    }
    // Decode every photo first so a bad file changes nothing.
    final ws = <(Map<String, Object?>, Uint8List?)>[];
    for (final raw in data['workers'] as List) {
      final m = Map<String, Object?>.from(raw as Map);
      final b64 = m.remove('id_photo_data') as String?;
      ws.add((m, b64 == null ? null : base64Decode(b64)));
    }
    final ps = <(Map<String, Object?>, Uint8List?)>[];
    for (final raw in data['punches'] as List) {
      final m = Map<String, Object?>.from(raw as Map);
      final b64 = m.remove('photo_data') as String?;
      ps.add((m, b64 == null ? null : base64Decode(b64)));
    }

    // Write new photos, then swap the database contents in one transaction.
    final newWorkers = <Map<String, Object?>>[];
    for (final (m, img) in ws) {
      m['id_photo'] = img == null ? null : await _savePhoto(img);
      newWorkers.add(m);
    }
    final newPunches = <Map<String, Object?>>[];
    for (final (m, img) in ps) {
      m.remove('id');
      m['photo'] = img == null ? null : await _savePhoto(img);
      newPunches.add(m);
    }
    final keep = <String>{
      for (final m in newWorkers) if (m['id_photo'] != null) m['id_photo'] as String,
      for (final m in newPunches) if (m['photo'] != null) m['photo'] as String,
    };
    await _db.transaction((txn) async {
      await txn.delete('workers');
      await txn.delete('punches');
      for (final m in newWorkers) {
        await txn.insert('workers', Worker.fromMap(m).toMap());
      }
      for (final m in newPunches) {
        await txn.insert('punches', Punch.fromMap({...m, 'id': null}).toMap());
      }
      if (data['admin_hash'] is String && data['admin_salt'] is String) {
        await txn.insert('settings', {'key': 'admin_salt', 'value': data['admin_salt']}, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert('settings', {'key': 'admin_hash', 'value': data['admin_hash']}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
    // Remove photo files no longer referenced.
    await for (final e in _photos.list()) {
      if (e is File && !keep.contains(p.basename(e.path))) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
    await _load();
    return (newWorkers.length, newPunches.length);
  }
}
