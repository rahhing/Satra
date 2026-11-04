import 'package:flutter/material.dart';

import '../services/device_performance.dart';
import '../theme/app_motion.dart';
import 'layout_constants.dart';

Route<T> fadeRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    // opaque must stay false: routes composite over the video player layer
    // below the transparent root scaffold. The reduced tier only drops the
    // fade (two full-screen layers blending for the whole transition).
    opaque: false,
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        AppMotion.transition(context, animation, child),
    transitionDuration: DevicePerformance.reducedDuration(AppDurations.animSlow),
    reverseTransitionDuration: DevicePerformance.reducedDuration(AppDurations.animSlow),
  );
}
