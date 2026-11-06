// Machine-readable diagnostics for the native frame-pacing probe.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:ui' show FrameTiming, FramePhase;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final frames = <FrameTiming>[];
  SchedulerBinding.instance.addTimingsCallback(frames.addAll);
  Timer.periodic(const Duration(seconds: 5), (_) {
    if (frames.length < 2) {
      print('SATRA_PROBE idle frames=${frames.length}');
      frames.clear();
      return;
    }
    final gaps = <int>[];
    for (var i = 1; i < frames.length; ++i) {
      gaps.add(
        frames[i].timestampInMicroseconds(FramePhase.vsyncStart) -
            frames[i - 1].timestampInMicroseconds(FramePhase.vsyncStart),
      );
    }
    final elapsed =
        frames.last.timestampInMicroseconds(FramePhase.vsyncStart) -
        frames.first.timestampInMicroseconds(FramePhase.vsyncStart);
    gaps.sort();
    print(
      'SATRA_PROBE frames=${frames.length} fps=${((frames.length - 1) * 1000000 / elapsed).toStringAsFixed(1)} median_interval_us=${gaps[gaps.length ~/ 2]} p95_interval_us=${gaps[(gaps.length * .95).floor()]}',
    );
    frames.clear();
  });
  Timer(const Duration(seconds: 17), SystemNavigator.pop);
  runApp(const MaterialApp(home: Probe()));
}

class Probe extends StatefulWidget {
  const Probe({super.key});
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> with SingleTickerProviderStateMixin {
  late final animation = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  final timers = <Timer>[];
  @override
  void initState() {
    super.initState();
    if (const bool.fromEnvironment('PROBE_IDLE')) {
      timers.add(Timer(const Duration(seconds: 4), animation.stop));
      timers.add(Timer(const Duration(seconds: 11), () => animation.repeat(reverse: true)));
    }
  }

  @override
  void dispose() {
    for (final timer in timers) {
      timer.cancel();
    }
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: SizedBox(
        width: 500,
        height: 150,
        child: RepaintBoundary(child: CustomPaint(painter: MovingSquare(animation))),
      ),
    ),
  );
}

class MovingSquare extends CustomPainter {
  MovingSquare(this.animation) : super(repaint: animation);
  final Animation<double> animation;
  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawRect(Rect.fromLTWH(animation.value * (size.width - 40), 45, 40, 40), Paint()..color = Colors.white);
  @override
  bool shouldRepaint(MovingSquare oldDelegate) => false;
}
