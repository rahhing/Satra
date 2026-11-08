#include "flutter_vsync.h"
#include "drag_motion.h"

#include <gdk/gdkwayland.h>
#include <wayland-client.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "pinned_engine_layout.h"

namespace {

constexpr char kStateKey[] = "satra-monitor-vsync";

struct VsyncState {
  explicit VsyncState(GtkWidget* view, FlutterEngineProcTable api) : api(api) {
    g_weak_ref_init(&widget, G_OBJECT(view));
    context = g_main_context_ref_thread_default();
    trace = g_strcmp0(g_getenv("SATRA_TRACE_VSYNC"), "1") == 0;
  }
  ~VsyncState() {
    g_weak_ref_clear(&widget);
    g_main_context_unref(context);
  }

  GWeakRef widget;
  GMainContext* context;
  FlutterEngineProcTable api;
  FlutterEngine engine = nullptr;  // GTK thread only.
  std::atomic<bool> stopped{false};
  std::mutex mutex;
  std::vector<intptr_t> batons;
  bool dispatch_queued = false;
  guint tick_id = 0;  // GTK thread only.
  bool mapped_once = false;
  wl_callback* surface_callback = nullptr;
  gpointer surface_callback_data = nullptr;
  int refresh_millihz = 0;
  bool trace;
  gint64 trace_start = 0;
  gint64 last_tick = 0;
  unsigned trace_frames = 0;
  unsigned trace_draws = 0;
  bool draw_trace_connected = false;
  std::atomic<uint64_t> presented_generation{0};
  FlutterCompositor compositor = {};
};

using State = std::shared_ptr<VsyncState>;
std::mutex engines_mutex;
std::unordered_map<FlutterEngine, State> engines;

State get_state(void* engine) {
  auto* state = static_cast<State*>(g_object_get_data(G_OBJECT(engine), kStateKey));
  return state == nullptr ? nullptr : *state;
}

void delete_state(gpointer data) { delete static_cast<State*>(data); }

gboolean on_tick(GtkWidget* widget, GdkFrameClock* clock, gpointer data) {
  auto state = *static_cast<State*>(data);
  if (state->stopped || state->engine == nullptr) {
    state->tick_id = 0;
    return G_SOURCE_REMOVE;
  }

  std::vector<intptr_t> batons;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    batons.swap(state->batons);
  }
  if (batons.empty()) {
    state->tick_id = 0;
    return G_SOURCE_REMOVE;
  }

  // Query the window's monitor each time: monitor moves, mode switches and
  // hotplug must not leave us running at the primary/fastest display's rate.
  GdkWindow* window = gtk_widget_get_window(widget);
  GdkMonitor* monitor =
      window == nullptr ? nullptr : gdk_display_get_monitor_at_window(gtk_widget_get_display(widget), window);
  int refresh = monitor == nullptr ? 0 : gdk_monitor_get_refresh_rate(monitor);
  gint64 interval_us = 0;
  gint64 presentation_us = 0;
  const gint64 monotonic_us = g_get_monotonic_time();
  gdk_frame_clock_get_refresh_info(clock, monotonic_us, &interval_us, &presentation_us);
  const gint64 clock_interval_us = interval_us;
  // GTK's refresh history defaults to 60 Hz until the first presentation.
  // The monitor mode supplies the correct interval from the first frame.
  if (refresh > 0) interval_us = std::llround(1e9 / refresh);
  if (interval_us <= 0) interval_us = 16667;

  if (refresh != state->refresh_millihz) {
    state->refresh_millihz = refresh;
    g_message("Satra VSync: window monitor %.3f Hz", refresh > 0 ? refresh / 1000.0 : 1e6 / interval_us);
  }

  const bool compositor_tick = state->surface_callback != nullptr;
  gint64 start_us = compositor_tick ? monotonic_us : std::min(gdk_frame_clock_get_frame_time(clock), monotonic_us);
  gint64 target_us = start_us + interval_us;
  if (!compositor_tick && std::abs(clock_interval_us - interval_us) < interval_us / 8 &&
      presentation_us > monotonic_us && presentation_us <= monotonic_us + 2 * interval_us) {
    target_us = presentation_us;
    start_us = target_us - interval_us;
  }
  if (target_us <= monotonic_us) {
    start_us = monotonic_us;
    target_us = start_us + interval_us;
  }
  // GDK and Flutter both use monotonic clocks, but their epochs are not part
  // of the API contract. Translate the timestamps rather than assuming one.
  const auto engine_now = state->api.GetCurrentTime();
  const auto start_ns = static_cast<uint64_t>(static_cast<int64_t>(engine_now) + (start_us - monotonic_us) * 1000);
  const auto target_ns = start_ns + static_cast<uint64_t>((target_us - start_us) * 1000);
  for (const auto baton : batons) {
    if (state->api.OnVsync(state->engine, baton, start_ns, target_ns) != kSuccess) {
      g_warning("Satra VSync: engine rejected a frame callback");
    }
  }

  if (state->trace && !batons.empty()) {
    if (monotonic_us - state->last_tick > G_USEC_PER_SEC / 4) {
      state->trace_start = monotonic_us;
      state->trace_frames = 0;
      state->trace_draws = 0;
    }
    state->last_tick = monotonic_us;
    if (state->trace_start == 0) state->trace_start = monotonic_us;
    ++state->trace_frames;
    if (monotonic_us - state->trace_start >= G_USEC_PER_SEC) {
      g_message(
          "Satra VSync: %.1f callbacks/s, target %.3f Hz, GTK interval %lld us, draws %u",
          state->trace_frames * 1e6 / (monotonic_us - state->trace_start), 1e6 / interval_us,
          static_cast<long long>(clock_interval_us), state->trace_draws);
      state->trace_start = monotonic_us;
      state->trace_frames = 0;
      state->trace_draws = 0;
    }
  }
  // Keep the clock's animation sequence alive across consecutive requests.
  // Removing and re-adding the tick each frame resets GTK's refresh history.
  // The first tick without a new engine request stops it again.
  if (GDK_IS_WAYLAND_DISPLAY(gtk_widget_get_display(widget)) && gtk_widget_get_mapped(widget)) {
    state->tick_id = 0;
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

bool request_surface_frame(const State& state, GtkWidget* view);

void surface_frame(gpointer data, wl_callback* callback, uint32_t) {
  auto state = *static_cast<State*>(data);
  state->surface_callback = nullptr;
  state->surface_callback_data = nullptr;
  wl_callback_destroy(callback);
  g_autoptr(GObject) widget = static_cast<GObject*>(g_weak_ref_get(&state->widget));
  bool pending;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    pending = !state->batons.empty();
  }
  if (widget != nullptr && !state->stopped && pending) {
    // Reserve the following compositor opportunity before waking Flutter so
    // UI/raster work can overlap it. An unused opportunity stops the clock.
    request_surface_frame(state, GTK_WIDGET(widget));
    on_tick(GTK_WIDGET(widget), gtk_widget_get_frame_clock(GTK_WIDGET(widget)), data);
  }
  delete_state(data);
}

const wl_callback_listener frame_listener = {surface_frame};

bool request_surface_frame(const State& state, GtkWidget* view) {
  GdkDisplay* display = gtk_widget_get_display(view);
  if (!GDK_IS_WAYLAND_DISPLAY(display) || !gtk_widget_get_mapped(view)) return false;
  auto* surface = gdk_wayland_window_get_wl_surface(gdk_window_get_toplevel(gtk_widget_get_window(view)));
  if (surface == nullptr) return false;
  if (state->surface_callback != nullptr) return true;
  state->surface_callback = wl_surface_frame(surface);
  state->surface_callback_data = new State(state);
  wl_callback_add_listener(state->surface_callback, &frame_listener, state->surface_callback_data);
  // The empty commit submits only the frame callback. Do not serialize
  // engine VSync requests behind GTK's slower fallback paint clock.
  wl_surface_commit(surface);
  wl_display_flush(gdk_wayland_display_get_wl_display(display));
  return true;
}

gboolean dispatch_vsync(gpointer data) {
  auto state = *static_cast<State*>(data);
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->dispatch_queued = false;
    if (state->batons.empty()) return G_SOURCE_REMOVE;
  }
  if (state->stopped || state->tick_id != 0 || state->surface_callback != nullptr) return G_SOURCE_REMOVE;
  g_autoptr(GObject) widget = static_cast<GObject*>(g_weak_ref_get(&state->widget));
  if (widget != nullptr) {
    const bool mapped = gtk_widget_get_mapped(GTK_WIDGET(widget));
    if (!mapped && state->mapped_once) return G_SOURCE_REMOVE;
    state->mapped_once = state->mapped_once || mapped;
    if (state->trace && !state->draw_trace_connected) {
      state->draw_trace_connected = true;
      g_signal_connect_data(
          gtk_widget_get_toplevel(GTK_WIDGET(widget)), "draw",
          G_CALLBACK(+[](GtkWidget*, cairo_t*, gpointer data) -> gboolean {
            ++(*static_cast<State*>(data))->trace_draws;
            return FALSE;
          }),
          new State(state), +[](gpointer data, GClosure*) { delete_state(data); }, G_CONNECT_AFTER);
    }
    if (request_surface_frame(state, GTK_WIDGET(widget))) return G_SOURCE_REMOVE;
    state->tick_id = gtk_widget_add_tick_callback(GTK_WIDGET(widget), on_tick, new State(state), delete_state);
  }
  return G_SOURCE_REMOVE;
}

struct QueuedPresentation {
  State state;
  uint64_t generation;
};

void delete_queued_presentation(gpointer data) { delete static_cast<QueuedPresentation*>(data); }

gboolean flush_presented_frame(gpointer data) {
  auto* queued = static_cast<QueuedPresentation*>(data);
  const State& state = queued->state;
  if (state->stopped || state->presented_generation.load() != queued->generation) return G_SOURCE_REMOVE;
  g_autoptr(GObject) widget = static_cast<GObject*>(g_weak_ref_get(&state->widget));
  if (widget != nullptr && gtk_widget_get_mapped(GTK_WIDGET(widget))) {
    // A visible unfocused window still needs display-paced presentation.
    // Window activation is not a reliable indication of screenshot capture.
    GdkWindow* window = gtk_widget_get_window(GTK_WIDGET(widget));
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gdk_window_process_updates(window, TRUE);
    G_GNUC_END_IGNORE_DEPRECATIONS
  }
  return G_SOURCE_REMOVE;
}

bool present_view(const FlutterPresentViewInfo* info) {
  auto state = get_state(info->user_data);
  const auto result = state->compositor.present_view_callback(info);
  if (state != nullptr && !state->stopped) {
    const uint64_t generation = ++state->presented_generation;
    GSource* source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_DEFAULT_IDLE);
    g_source_set_callback(
        source, flush_presented_frame, new QueuedPresentation{state, generation}, delete_queued_presentation);
    g_source_attach(source, state->context);
    g_source_unref(source);
  }
  return result;
}

void request_vsync(void* user_data, intptr_t baton) {
  auto state = get_state(user_data);
  if (state == nullptr || state->stopped) return;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->batons.push_back(baton);
    if (state->dispatch_queued) return;
    state->dispatch_queued = true;
  }
  // The engine can ask from its UI thread. Always marshal to GTK, even when
  // its main context is momentarily unowned (g_main_context_invoke may inline).
  GSource* source = g_idle_source_new();
  g_source_set_priority(source, G_PRIORITY_HIGH);
  g_source_set_callback(source, dispatch_vsync, new State(state), delete_state);
  g_source_attach(source, state->context);
  g_source_unref(source);
}

FlutterEngineResult initialize(
    size_t version, const FlutterRendererConfig* config, const FlutterProjectArgs* args, void* user_data,
    FlutterEngine* engine_out) {
  auto state = get_state(user_data);
  auto patched = *args;
  patched.vsync_callback = request_vsync;
  state->compositor = *args->compositor;
  auto compositor = state->compositor;
  compositor.present_view_callback = present_view;
  patched.compositor = &compositor;
  const auto result = state->api.Initialize(version, config, &patched, user_data, engine_out);
  if (result == kSuccess) {
    state->engine = *engine_out;
    std::lock_guard<std::mutex> lock(engines_mutex);
    engines[*engine_out] = state;
  }
  return result;
}

FlutterEngineResult shutdown(FlutterEngine engine) {
  State state;
  {
    std::lock_guard<std::mutex> lock(engines_mutex);
    auto it = engines.find(engine);
    if (it == engines.end()) return kInvalidArguments;
    state = it->second;
    engines.erase(it);
  }
  state->stopped = true;
  if (state->surface_callback != nullptr) {
    wl_callback_destroy(state->surface_callback);
    state->surface_callback = nullptr;
    delete_state(state->surface_callback_data);
    state->surface_callback_data = nullptr;
  }
  g_autoptr(GObject) widget = static_cast<GObject*>(g_weak_ref_get(&state->widget));
  if (widget != nullptr && state->tick_id != 0) {
    gtk_widget_remove_tick_callback(GTK_WIDGET(widget), state->tick_id);
    state->tick_id = 0;
  }
  state->engine = nullptr;
  return state->api.Shutdown(engine);
}

}  // namespace

void satra_install_flutter_vsync(FlView* view) {
  satra_input::configure_drag_input(GTK_WIDGET(view), nullptr);
  FlEngine* engine = fl_view_get_engine(view);
  if (get_state(engine) != nullptr) return;
  GTypeQuery type;
  g_type_query(fl_engine_get_type(), &type);
  if (type.instance_size != sizeof(SatraPinnedEngineLayout)) {
    g_error("Satra VSync: incompatible Flutter engine layout");
  }
  auto* api = reinterpret_cast<FlutterEngineProcTable*>(
      reinterpret_cast<unsigned char*>(engine) + offsetof(SatraPinnedEngineLayout, embedder_api));
  if (api->struct_size != sizeof(FlutterEngineProcTable) || api->Initialize == nullptr || api->OnVsync == nullptr ||
      api->GetCurrentTime == nullptr || api->Shutdown == nullptr) {
    g_error("Satra VSync: incompatible Flutter embedder API");
  }
  auto state = std::make_shared<VsyncState>(GTK_WIDGET(view), *api);
  g_object_set_data_full(G_OBJECT(engine), kStateKey, new State(state), delete_state);
  // A minimized view may retain an outstanding request. Resume it when mapped
  // again without driving a synthetic clock while it is hidden.
  g_signal_connect_data(
      view, "map", G_CALLBACK(+[](GtkWidget*, gpointer data) { dispatch_vsync(data); }), new State(state),
      +[](gpointer data, GClosure*) { delete_state(data); }, G_CONNECT_DEFAULT);
  g_signal_connect_data(
      view, "unmap", G_CALLBACK(+[](GtkWidget*, gpointer data) {
        auto state = *static_cast<State*>(data);
        if (state->surface_callback != nullptr) {
          wl_callback_destroy(state->surface_callback);
          state->surface_callback = nullptr;
          delete_state(state->surface_callback_data);
          state->surface_callback_data = nullptr;
        }
      }), new State(state),
      +[](gpointer data, GClosure*) { delete_state(data); }, G_CONNECT_DEFAULT);
  api->Initialize = initialize;
  api->Shutdown = shutdown;
}
