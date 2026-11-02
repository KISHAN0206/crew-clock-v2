import 'package:crew_clock/data/models.dart';
import 'package:crew_clock/util/hours.dart';
import 'package:crew_clock/util/security.dart';
import 'package:flutter_test/flutter_test.dart';

Punch _p(String type, DateTime t) => Punch(workerId: 'JB-1000', name: 'Test', type: type, at: t.millisecondsSinceEpoch);

void main() {
  test('pairs clock-in with clock-out and totals hours', () {
    final punches = [
      _p('in', DateTime(2026, 10, 20, 9)),
      _p('out', DateTime(2026, 10, 20, 17, 30)),
      _p('in', DateTime(2026, 10, 21, 8)),
      _p('out', DateTime(2026, 10, 21, 12)),
    ];
    final s = summarize(punches, 'JB-1000', DateTime(2026, 10, 20), DateTime(2026, 10, 27));
    expect(s.count, 2);
    expect(s.hours, closeTo(12.5, 1e-9));
    expect(s.open, isNull);
  });

  test('reports an open shift', () {
    final punches = [_p('in', DateTime(2026, 10, 22, 9))];
    final s = summarize(punches, 'JB-1000', DateTime(2026, 10, 20), DateTime(2026, 10, 27));
    expect(s.count, 0);
    expect(s.open, isNotNull);
  });

  test('weeks run Monday to Sunday', () {
    final r = rangeFor(Period.thisWeek, DateTime(2026, 10, 24, 21)); // Saturday
    expect(r.from, DateTime(2026, 10, 19));
    expect(r.to, DateTime(2026, 10, 26));
  });

  test('worker IDs are normalised and weak PINs rejected', () {
    expect(normaliseWorkerId(' jb4821 '), 'JB-4821');
    expect(normaliseWorkerId('JB-4821'), 'JB-4821');
    expect(isWeakPin('1111'), isTrue);
    expect(isWeakPin('1234'), isTrue);
    expect(isWeakPin('3791'), isFalse);
  });
}
