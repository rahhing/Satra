import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:satra/utils/app_logger.dart';
import 'package:satra/utils/memory_pressure_breadcrumbs.dart';

class _MemoryPressureTestBinding extends AutomatedTestWidgetsFlutterBinding with MemoryPressureBreadcrumbs {}

void main() {
  final binding = _MemoryPressureTestBinding();

  test('memory pressure remains available in the local log and is rate limited', () {
    MemoryLogOutput.clearLogs();
    binding.debugResetMemoryPressureBreadcrumbs();
    final start = DateTime.utc(2026, 1, 1);
    withClock(Clock.fixed(start), binding.handleMemoryPressure);
    withClock(Clock.fixed(start.add(const Duration(seconds: 1))), binding.handleMemoryPressure);
    var entries = MemoryLogOutput.getLogs().where((entry) => entry.message.startsWith('Memory pressure:')).toList();
    expect(entries, hasLength(1));
    expect(entries.single.message, contains('imageCacheMb='));
    withClock(Clock.fixed(start.add(const Duration(seconds: 30))), binding.handleMemoryPressure);
    entries = MemoryLogOutput.getLogs().where((entry) => entry.message.startsWith('Memory pressure:')).toList();
    expect(entries, hasLength(2));
    expect(entries.first.message, contains('suppressed=1'));
  });
}
