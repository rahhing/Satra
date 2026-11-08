# Linux display-paced frames

Engine sources:
[fallback waiter](https://github.com/flutter/flutter/blob/5d531788691ec3404cac0cee66ead4007b177363/engine/src/flutter/shell/common/vsync_waiter_fallback.cc),
[GTK engine](https://github.com/flutter/flutter/blob/5d531788691ec3404cac0cee66ead4007b177363/engine/src/flutter/shell/platform/linux/fl_engine.cc).

Flutter 3.47.1's GTK engine does not install `FlutterProjectArgs.vsync_callback`.
Its `VsyncWaiterFallback` consequently runs at a fixed 60 Hz, independently of
the monitor rate. Reporting a different display rate to Dart cannot fix it.

This adapter installs the embedder's real VSync callback before engine startup.
On Wayland, on-demand `wl_surface.frame` callbacks follow the compositor for the
window's current surface. The next opportunity is reserved before waking Flutter
to overlap UI/raster work. An unused opportunity stops the clock. Hidden windows
are naturally throttled by the compositor. GTK ticks bootstrap unmapped windows
and supply the X11 path. The active monitor's mode supplies the frame deadline;
there is no global fastest-monitor setting or hardcoded high-refresh timer.

GTK can retain a 60 Hz fallback even while Flutter produces faster frames.
After the original compositor callback queues its redraw, the adapter flushes
that damage on the GTK thread. Completed frames share one pending flush, with
a generation counter re-arming presentation if another raster frame completes
during the paint. VSync requests run independently of those flushes, and visible
windows keep display-paced painting whether focused or not. Serializing VSync
behind GTK painting or using activation as a capture flag can throttle normal
navigation to GTK's 60 Hz fallback. Unmapping cancels the old surface callback
so it cannot stall a remapped view. Flutter's compositor, textures, input,
resizing and the separate mpv video plane remain intact.

The GTK wrapper hides its proc-table accessor. `pinned_engine_layout.h` mirrors
the layout from engine revision `5d531788691ec3404cac0cee66ead4007b177363`.
The build checks exact official GTK library SHA256s for x64/ARM64 in all three
build modes, and startup checks the GType instance and API table sizes. Engine
upgrades must review this bridge. The vendored `flutter_embedder.h` comes from
that revision's official embedder archive; Flutter's license is included.

All GTK and Wayland work runs on the platform context. VSync requests can arrive
from the engine's UI thread; their batons are marshalled through a protected
queue. Shutdown cancels GTK ticks and Wayland callbacks before stopping the
engine, and queued work uses weak widget references.

## Reproduce

With Flutter 3.47.1 and Ninja on PATH:

```sh
python3 scripts/perf/linux_frame_pacing.py --stock
python3 scripts/perf/linux_frame_pacing.py
python3 scripts/perf/linux_frame_pacing.py --idle
python3 scripts/perf/linux_frame_pacing.py --idle --capture
python3 scripts/perf/linux_frame_pacing.py --navigation
python3 scripts/perf/linux_frame_pacing.py --navigation --legacy-composition
```

Each run creates a temporary native project, runs a small animated Flutter
scene in profile mode for 17 seconds, reports engine frame timings, and closes
normally. It never replaces Satra's build or uses the user's profile. The idle
variant pauses its animation from seconds 4–11. The capture variant repeatedly
reads the GPU-rendered scene back, including during the pause, and checks each
captured frame for an intact square and opaque background. It exercises engine
readback, not the desktop's screenshot overlay. Move the probe window to another
display during a run to check the monitor-change diagnostics and frame cadence.

`SATRA_TRACE_VSYNC=1` also enables callback/draw counts in Satra itself. FPS is
measured during animation; an idle application is not expected to render at the
monitor rate. A correct clock removes the 60 FPS limit but cannot guarantee
every scene finishes within a 240 Hz monitor's 4.17 ms frame budget.

## Verified on 2026-11-06

On KDE Wayland with 240.084 Hz and 164.554 Hz outputs, the stock engine probe
reported 60.0 FPS / 16,667 µs frame intervals. The adapted probe reported 238.5
FPS on the 240 Hz output (median 4,163 µs) and 164.6 FPS on the second output
(median 6,076 µs), with matching native GTK draw counts. The idle interval
reported zero Flutter frames, followed by normal high-refresh rendering after
resume. Both probes closed normally. The release app also builds successfully;
the unknown-engine guard rejects an unrecognized binary.

The navigation fixture uses the production backdrop compositor and cached
readability shading alongside frosted chrome and scrolling image rows. It
reports UI/raster p95 times as well as frame intervals. `--legacy-composition`
compares the former double-blur crossfade. These are isolated synthetic scenes,
not a measurement of an authenticated server's library or network latency.
