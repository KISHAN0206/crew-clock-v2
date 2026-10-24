import '../data/models.dart';

/// Time periods the timesheet can show.
enum Period { today, thisWeek, lastWeek, all }

extension PeriodLabel on Period {
  String get label => switch (this) {
        Period.today => 'Today',
        Period.thisWeek => 'This week (Mon–Sun)',
        Period.lastWeek => 'Last week',
        Period.all => 'All records',
      };

  String get slug => switch (this) {
        Period.today => 'today',
        Period.thisWeek => 'this-week',
        Period.lastWeek => 'last-week',
        Period.all => 'all',
      };
}

/// Start (inclusive) and end (exclusive) of a period. Weeks run Monday to Sunday.
({DateTime from, DateTime to}) rangeFor(Period p, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final monday = DateTime(today.year, today.month, today.day - (today.weekday - 1));
  return switch (p) {
    Period.today => (from: today, to: DateTime(today.year, today.month, today.day + 1)),
    Period.thisWeek => (from: monday, to: DateTime(monday.year, monday.month, monday.day + 7)),
    Period.lastWeek => (from: DateTime(monday.year, monday.month, monday.day - 7), to: monday),
    Period.all => (from: DateTime(2000), to: DateTime(3000)),
  };
}

class ShiftSummary {
  const ShiftSummary({required this.count, required this.hours, this.open});

  /// Completed shifts (clock in followed by clock out) that started in the period.
  final int count;

  /// Total hours of those completed shifts.
  final double hours;

  /// The clock-in of a shift still running, if it started in the period.
  final Punch? open;
}

/// Pairs each clock-in with the next clock-out for one worker.
ShiftSummary summarize(Iterable<Punch> allPunches, String workerId, DateTime from, DateTime to) {
  final punches = allPunches.where((p) => p.workerId == workerId).toList()
    ..sort((a, b) => a.at.compareTo(b.at));
  final f = from.millisecondsSinceEpoch;
  final t = to.millisecondsSinceEpoch;
  Punch? open;
  var count = 0;
  var ms = 0;
  for (final p in punches) {
    if (p.isIn) {
      open = p;
    } else if (open != null) {
      if (open.at >= f && open.at < t) {
        count++;
        ms += p.at - open.at;
      }
      open = null;
    }
  }
  final stillOpen = (open != null && open.at >= f && open.at < t) ? open : null;
  return ShiftSummary(count: count, hours: ms / 3600000.0, open: stillOpen);
}
