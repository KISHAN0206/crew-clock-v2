import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final Random _rng = Random.secure();

String randomString(String alphabet, int length) =>
    List.generate(length, (_) => alphabet[_rng.nextInt(alphabet.length)]).join();

String newSalt() => randomString('abcdefghijklmnopqrstuvwxyz0123456789', 16);

/// PINs are never stored, only a salted SHA-256 hash.
String hashPin(String salt, String pin) => sha256.convert(utf8.encode('$salt|$pin')).toString();

/// Rejects PINs that are easy to guess, such as 1111, 1234 or 9876.
bool isWeakPin(String pin) {
  if (RegExp(r'^(\d)\1{3}$').hasMatch(pin)) return true;
  if ('0123456789'.contains(pin) || '9876543210'.contains(pin)) return true;
  return false;
}

/// Worker IDs are plain numbers like "4821". Older IDs like "JB-4821" still work:
/// "jb4821", "JB 4821" and "JB-4821" all become "JB-4821".
String normaliseWorkerId(String raw) {
  final s = raw.trim().toUpperCase().replaceAll(' ', '');
  final m = RegExp(r'^([A-Z]{2})-?(\d+)$').firstMatch(s);
  return m == null ? s : '${m.group(1)}-${m.group(2)}';
}

/// Finds a worker by what they typed. Typing just the number also finds an older "JB-4821" style ID.
String? matchWorkerId(String raw, Iterable<String> ids) {
  final id = normaliseWorkerId(raw);
  final all = ids.toSet();
  if (all.contains(id)) return id;
  if (RegExp(r'^\d+$').hasMatch(id)) {
    final older = all.where((x) => RegExp('^[A-Z]{2}-$id\$').hasMatch(x)).toList();
    if (older.length == 1) return older.first;
  }
  return null;
}
