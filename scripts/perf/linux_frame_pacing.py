#!/usr/bin/env python3
"""Measure real Linux Flutter frame pacing in an isolated native window.

Use --stock for a baseline, then rerun without it. Never overwrites the app's
bundle or opens a user's profile. Requires the pinned Flutter SDK and Ninja.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--stock", action="store_true")
    parser.add_argument("--idle", action="store_true", help="Pause animation for five seconds midway")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="satra-frame-probe-") as directory:
        project = Path(directory)
        def run(*command, **kwargs):
            subprocess.run(command, cwd=project, check=True, **kwargs)

        run(args.flutter, "--suppress-analytics", "create", "--platforms=linux",
            "--project-name=satra_frame_probe", str(project))
        shutil.copyfile(root / "scripts/perf/fixtures/linux_frame_pacing.dart", project / "lib/main.dart")
        runner = project / "linux/runner"
        source = runner / "my_application.cc"
        code = source.read_text()
        # Match Satra's native startup: map the window before the first frame.
        code = code.replace("gtk_widget_realize(GTK_WIDGET(view));",
                            "gtk_widget_realize(GTK_WIDGET(view));\n  gtk_widget_show(GTK_WIDGET(window));")
        if not args.stock:
            shutil.copytree(root / "linux/runner/vsync", runner / "vsync")
            code = code.replace('#include "my_application.h"',
                                '#include "my_application.h"\n#include "vsync/flutter_vsync.h"')
            code = code.replace("FlView* view = fl_view_new(project);",
                                "FlView* view = fl_view_new(project);\n  satra_install_flutter_vsync(view);")
            cmake = runner / "CMakeLists.txt"
            cmake.write_text(cmake.read_text().replace('"my_application.cc"',
                             '"my_application.cc"\n  "vsync/flutter_vsync.cc"') + """
pkg_check_modules(WAYLAND_CLIENT REQUIRED IMPORTED_TARGET wayland-client)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::WAYLAND_CLIENT)
add_custom_target(satra_vsync_check COMMAND ${CMAKE_COMMAND}
  -DENGINE_LIBRARY=${FLUTTER_LIBRARY} -P ${CMAKE_CURRENT_SOURCE_DIR}/vsync/check_engine.cmake)
add_dependencies(satra_vsync_check flutter_assemble)
add_dependencies(${BINARY_NAME} satra_vsync_check)
""")
        source.write_text(code)
        run(args.flutter, "--suppress-analytics", "build", "linux", "--profile", "--no-pub",
            f"--dart-define=PROBE_IDLE={'true' if args.idle else 'false'}")
        executable = next((project / "build/linux").glob("*/profile/bundle/satra_frame_probe"))
        run(str(executable), env={**os.environ, "SATRA_TRACE_VSYNC": "1"}, timeout=35)


if __name__ == "__main__":
    main()
