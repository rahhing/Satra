#ifndef SATRA_DRAG_MOTION_H_
#define SATRA_DRAG_MOTION_H_

#include <gtk/gtk.h>

namespace satra_input {

// GTK normally compresses pending motion events. Its frame clock can retain
// the 60 Hz fallback independently of Flutter's compositor-paced animations.
// Forward held-drag samples without that batching, restoring the exact prior
// setting on release, focus loss, unmap or destruction. No events are consumed.
// https://docs.gtk.org/gdk3/method.Window.set_event_compression.html
struct DragMotionState {
  GdkWindow* window = nullptr;
  gboolean original_compression = TRUE;

  void restore() {
    if (window == nullptr) return;
    if (!gdk_window_is_destroyed(window)) {
      gdk_window_set_event_compression(window, original_compression);
    }
    g_clear_object(&window);
  }

  ~DragMotionState() { restore(); }
};

inline gboolean on_drag_event(GtkWidget*, GdkEvent* event, gpointer data) {
  auto* state = static_cast<DragMotionState*>(data);
  if (event->type == GDK_BUTTON_PRESS && event->button.button == GDK_BUTTON_PRIMARY && event->any.window != nullptr) {
    if (state->window == nullptr) {
      state->window = GDK_WINDOW(g_object_ref(event->any.window));
      state->original_compression = gdk_window_get_event_compression(state->window);
      gdk_window_set_event_compression(state->window, FALSE);
    }
  } else if ((event->type == GDK_BUTTON_RELEASE && event->button.button == GDK_BUTTON_PRIMARY) ||
             (event->type == GDK_FOCUS_CHANGE && !event->focus_change.in) ||
             event->type == GDK_GRAB_BROKEN) {
    state->restore();
  }
  return FALSE;
}

inline void connect_focus_restore(GtkWidget* events) {
  GtkWidget* window = gtk_widget_get_toplevel(events);
  if (!GTK_IS_WINDOW(window) || g_object_get_data(G_OBJECT(events), "satra-drag-focus-handler") != nullptr) return;
  g_object_set_data(G_OBJECT(events), "satra-drag-focus-handler", GINT_TO_POINTER(1));
  g_signal_connect_object(window, "focus-out-event", G_CALLBACK(+[](GtkWidget* target, GdkEventFocus*, GtkWidget*) -> gboolean {
    auto* state = static_cast<DragMotionState*>(g_object_get_data(G_OBJECT(target), "satra-drag-motion"));
    if (state != nullptr) state->restore();
    return FALSE;
  }), G_OBJECT(events), G_CONNECT_SWAPPED);
}

inline void configure_drag_input(GtkWidget* widget, gpointer) {
  constexpr char key[] = "satra-drag-motion";
  if (GTK_IS_EVENT_BOX(widget) && g_object_get_data(G_OBJECT(widget), key) == nullptr) {
    auto* state = new DragMotionState();
    g_object_set_data_full(G_OBJECT(widget), key, state, [](gpointer data) { delete static_cast<DragMotionState*>(data); });
    // Generic event runs before GTK dispatches button/motion-specific signals
    // to Flutter. Returning FALSE retains its native gesture/velocity handling.
    g_signal_connect(widget, "event", G_CALLBACK(on_drag_event), state);
    g_signal_connect(widget, "realize", G_CALLBACK(+[](GtkWidget* target, gpointer) {
      connect_focus_restore(target);
    }), nullptr);
    if (gtk_widget_get_realized(widget)) connect_focus_restore(widget);
    g_signal_connect(widget, "unmap", G_CALLBACK(+[](GtkWidget*, gpointer data) {
      static_cast<DragMotionState*>(data)->restore();
    }), state);
  }
  if (GTK_IS_CONTAINER(widget)) gtk_container_foreach(GTK_CONTAINER(widget), configure_drag_input, nullptr);
}

}  // namespace satra_input

#endif  // SATRA_DRAG_MOTION_H_
