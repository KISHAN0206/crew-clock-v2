const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];

String two(int n) => n.toString().padLeft(2, '0');

/// 9:05 am
String fmtTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${two(d.minute)} ${d.hour < 12 ? 'am' : 'pm'}';
}

/// Sat, 24 Oct
String fmtDate(DateTime d) => '${_days[d.weekday - 1].substring(0, 3)}, ${d.day} ${_months[d.month - 1].substring(0, 3)}';

/// Saturday, 24 October 2026
String fmtLongDate(DateTime d) => '${_days[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year}';

/// 2026-10-24
String fmtIsoDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

/// 21:05
String fmt24(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

String fmtHours(double h) => h.toStringAsFixed(2);
