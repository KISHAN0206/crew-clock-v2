/// A staff member who can clock in and out.
class Worker {
  Worker({
    required this.id,
    required this.name,
    this.role = '',
    this.active = true,
    required this.createdAt,
    this.pinSalt,
    this.pinHash,
    this.idPhoto,
    this.setupAt,
  });

  final String id; // e.g. JB-4821
  String name;
  String role;
  bool active;
  int createdAt; // ms since epoch
  String? pinSalt;
  String? pinHash;
  String? idPhoto; // file name inside the photos folder
  int? setupAt;

  /// True once the worker has created a PIN and taken an ID photo.
  bool get isSetUp => pinHash != null && pinSalt != null;

  String get firstName {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.isEmpty ? name : parts.first;
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'role': role,
        'active': active ? 1 : 0,
        'created_at': createdAt,
        'pin_salt': pinSalt,
        'pin_hash': pinHash,
        'id_photo': idPhoto,
        'setup_at': setupAt,
      };

  factory Worker.fromMap(Map<String, Object?> m) => Worker(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        role: (m['role'] as String?) ?? '',
        active: ((m['active'] as num?) ?? 1) != 0,
        createdAt: ((m['created_at'] as num?) ?? 0).toInt(),
        pinSalt: m['pin_salt'] as String?,
        pinHash: m['pin_hash'] as String?,
        idPhoto: m['id_photo'] as String?,
        setupAt: (m['setup_at'] as num?)?.toInt(),
      );
}

/// One clock-in or clock-out.
class Punch {
  const Punch({
    this.id,
    required this.workerId,
    required this.name,
    required this.type,
    required this.at,
    this.photo,
  });

  final int? id;
  final String workerId;
  final String name;
  final String type; // 'in' or 'out'
  final int at; // ms since epoch
  final String? photo; // file name inside the photos folder

  bool get isIn => type == 'in';
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(at);

  Map<String, Object?> toMap({bool withId = false}) => {
        if (withId && id != null) 'id': id,
        'worker_id': workerId,
        'name': name,
        'type': type,
        'at': at,
        'photo': photo,
      };

  factory Punch.fromMap(Map<String, Object?> m) => Punch(
        id: (m['id'] as num?)?.toInt(),
        workerId: m['worker_id'] as String,
        name: (m['name'] as String?) ?? '',
        type: m['type'] as String,
        at: (m['at'] as num).toInt(),
        photo: m['photo'] as String?,
      );
}
