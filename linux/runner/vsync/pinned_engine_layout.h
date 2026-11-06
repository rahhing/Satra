// Layout derived from Flutter's BSD-licensed fl_engine.cc at engine revision
// 5d531788691ec3404cac0cee66ead4007b177363. See LICENSE.flutter.
// GTK does not publish its embedder proc-table accessor. Mirror only its data
// layout, without dereferencing private objects. check_engine.cmake verifies
// the exact official engine binary before compilation; installation also checks
// GType instance size and the proc-table size before touching the table.
#ifndef SATRA_PINNED_ENGINE_LAYOUT_H_
#define SATRA_PINNED_ENGINE_LAYOUT_H_

#include <glib-object.h>
#define FLUTTER_ENGINE_NO_PROTOTYPES
#include "flutter_embedder.h"

struct SatraPinnedEngineLayout {
  GObject parent_instance;
  gpointer thread;
  gpointer project;
  gpointer display_monitor;
  FlutterRendererType renderer_type;
  gpointer opengl_manager;
  gpointer binary_messenger;
  gpointer settings_handler;
  gpointer platform_handler;
  gpointer accessibility_handler;
  gpointer keyboard_manager;
  gpointer text_input_handler;
  gpointer keyboard_handler;
  gpointer mouse_cursor_handler;
  gpointer texture_registrar;
  gpointer task_runner;
  FlutterEngineAOTData aot_data;
  FlutterEngine engine;
  FlutterEngineProcTable embedder_api;
  FlutterViewId next_view_id;
  gpointer renderables_by_view_id;
  GMutex renderables_mutex;
  void (*platform_message_handler)();
  gpointer platform_message_handler_data;
  GDestroyNotify platform_message_handler_destroy_notify;
};

#endif
