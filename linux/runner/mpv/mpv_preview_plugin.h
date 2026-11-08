#ifndef MPV_PREVIEW_PLUGIN_H_
#define MPV_PREVIEW_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#define MPV_PREVIEW_PLUGIN_TYPE (mpv_preview_plugin_get_type())

G_DECLARE_FINAL_TYPE(MpvPreviewPlugin, mpv_preview_plugin, MPV, PREVIEW_PLUGIN, GObject)

void mpv_preview_plugin_register_with_registrar(FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // MPV_PREVIEW_PLUGIN_H_
