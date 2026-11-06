#ifndef SATRA_FLUTTER_VSYNC_H_
#define SATRA_FLUTTER_VSYNC_H_

#include <flutter_linux/flutter_linux.h>

// Install before realizing the view (and thus before its engine starts).
void satra_install_flutter_vsync(FlView* view);

#endif
