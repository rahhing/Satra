#include "mpv_preview_plugin.h"

#include <mpv/client.h>
#include <mpv/render.h>

#include <atomic>
#include <clocale>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kPreviewWidth = 480;
constexpr uint32_t kPreviewHeight = 270;
constexpr size_t kPreviewStride = kPreviewWidth * 4;
constexpr size_t kPreviewPixelCount = static_cast<size_t>(kPreviewWidth) * kPreviewHeight;
constexpr size_t kPreviewByteCount = kPreviewPixelCount * 4;

struct PreviewBuffer {
  PreviewBuffer() : front(kPreviewByteCount, 0), staged(kPreviewByteCount, 0) {}

  std::mutex mutex;
  std::vector<uint8_t> front;
  std::vector<uint8_t> staged;
  bool dirty = false;
  std::atomic<bool> has_frame{false};
};

}  // namespace

#define SATRA_PREVIEW_TEXTURE_TYPE (satra_preview_texture_get_type())
G_DECLARE_FINAL_TYPE(SatraPreviewTexture,
                     satra_preview_texture,
                     SATRA,
                     PREVIEW_TEXTURE,
                     FlPixelBufferTexture)

struct _SatraPreviewTexture {
  FlPixelBufferTexture parent_instance;
  std::shared_ptr<PreviewBuffer> buffer;
};

G_DEFINE_TYPE(SatraPreviewTexture, satra_preview_texture, fl_pixel_buffer_texture_get_type())

static gboolean satra_preview_texture_copy_pixels(FlPixelBufferTexture* texture,
                                                  const uint8_t** out_buffer,
                                                  uint32_t* width,
                                                  uint32_t* height,
                                                  GError** /*error*/) {
  SatraPreviewTexture* self = SATRA_PREVIEW_TEXTURE(texture);
  if (!self->buffer) return FALSE;
  {
    std::lock_guard<std::mutex> lock(self->buffer->mutex);
    if (!self->buffer->has_frame) return FALSE;
    if (self->buffer->dirty) {
      std::swap(self->buffer->front, self->buffer->staged);
      self->buffer->dirty = false;
    }
  }
  *out_buffer = self->buffer->front.data();
  *width = kPreviewWidth;
  *height = kPreviewHeight;
  return TRUE;
}

static void satra_preview_texture_finalize(GObject* object) {
  SatraPreviewTexture* self = SATRA_PREVIEW_TEXTURE(object);
  self->buffer.~shared_ptr();
  G_OBJECT_CLASS(satra_preview_texture_parent_class)->finalize(object);
}

static void satra_preview_texture_class_init(SatraPreviewTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = satra_preview_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->finalize = satra_preview_texture_finalize;
}

static void satra_preview_texture_init(SatraPreviewTexture* self) {
  new (&self->buffer) std::shared_ptr<PreviewBuffer>();
}

static SatraPreviewTexture* satra_preview_texture_new(std::shared_ptr<PreviewBuffer> buffer) {
  SatraPreviewTexture* self =
      SATRA_PREVIEW_TEXTURE(g_object_new(SATRA_PREVIEW_TEXTURE_TYPE, nullptr));
  self->buffer = std::move(buffer);
  return self;
}

namespace {

struct PreviewSession {
  int64_t texture_id = 0;
  FlTextureRegistrar* registrar = nullptr;
  SatraPreviewTexture* texture = nullptr;
  FlMethodCall* pending_open_call = nullptr;
  std::shared_ptr<PreviewBuffer> buffer = std::make_shared<PreviewBuffer>();

  std::mutex cv_mutex;
  std::condition_variable cv;
  bool event_flagged = false;
  bool update_flagged = false;
  std::atomic<bool> stop_requested{false};
  std::atomic<bool> ready_to_reveal{false};
  std::atomic<bool> failed{false};
  std::atomic<bool> main_notify_queued{false};
  bool worker_started = false;

  ~PreviewSession() {
    if (pending_open_call != nullptr) {
      g_object_unref(pending_open_call);
      pending_open_call = nullptr;
    }
    if (texture != nullptr) {
      g_object_unref(texture);
      texture = nullptr;
    }
    if (registrar != nullptr) {
      g_object_unref(registrar);
      registrar = nullptr;
    }
  }
};

void StopSessionOnMainThread(const std::shared_ptr<PreviewSession>& session) {
  if (!session) return;
  {
    std::lock_guard<std::mutex> lock(session->cv_mutex);
    session->stop_requested.store(true, std::memory_order_release);
  }
  session->cv.notify_all();

  if (session->pending_open_call != nullptr) {
    FlMethodCall* call = session->pending_open_call;
    session->pending_open_call = nullptr;
    g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
    fl_method_call_respond_success(call, result, nullptr);
    g_object_unref(call);
  }

  if (session->texture != nullptr && session->registrar != nullptr) {
    fl_texture_registrar_unregister_texture(session->registrar, FL_TEXTURE(session->texture));
    g_object_unref(session->texture);
    session->texture = nullptr;
    g_object_unref(session->registrar);
    session->registrar = nullptr;
  }
}

gboolean OnMainThreadSessionNotify(gpointer data) {
  auto* session_ptr = static_cast<std::shared_ptr<PreviewSession>*>(data);
  const std::shared_ptr<PreviewSession>& session = *session_ptr;
  session->main_notify_queued.store(false, std::memory_order_release);

  if (!session->stop_requested.load(std::memory_order_acquire)) {
    if (session->texture != nullptr && session->registrar != nullptr &&
        session->buffer->has_frame) {
      fl_texture_registrar_mark_texture_frame_available(session->registrar,
                                                       FL_TEXTURE(session->texture));
    }
    if (session->pending_open_call != nullptr) {
      if (session->ready_to_reveal.load(std::memory_order_acquire)) {
        FlMethodCall* call = session->pending_open_call;
        session->pending_open_call = nullptr;
        g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
        fl_method_call_respond_success(call, result, nullptr);
        g_object_unref(call);
      } else if (session->failed.load(std::memory_order_acquire)) {
        FlMethodCall* call = session->pending_open_call;
        session->pending_open_call = nullptr;
        g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
        fl_method_call_respond_success(call, result, nullptr);
        g_object_unref(call);
      }
    }
  }
  return G_SOURCE_REMOVE;
}

void DeleteSessionPtr(gpointer data) {
  delete static_cast<std::shared_ptr<PreviewSession>*>(data);
}

void ScheduleMainThreadNotification(const std::shared_ptr<PreviewSession>& session) {
  if (session->stop_requested.load(std::memory_order_acquire)) return;
  if (session->main_notify_queued.exchange(true, std::memory_order_acq_rel)) return;
  g_idle_add_full(G_PRIORITY_DEFAULT_IDLE,
                  OnMainThreadSessionNotify,
                  new std::shared_ptr<PreviewSession>(session),
                  DeleteSessionPtr);
}

void RunPreviewWorker(std::shared_ptr<PreviewSession> session,
                      std::string url,
                      std::vector<std::string> headers,
                      int64_t start_ms) {
  std::setlocale(LC_NUMERIC, "C");
  mpv_handle* mpv = mpv_create();
  if (mpv == nullptr) {
    session->failed.store(true, std::memory_order_release);
    ScheduleMainThreadNotification(session);
    return;
  }

  mpv_set_option_string(mpv, "config", "no");
  mpv_set_option_string(mpv, "load-scripts", "no");
  mpv_set_option_string(mpv, "ytdl", "no");
  mpv_set_option_string(mpv, "terminal", "no");
  mpv_set_option_string(mpv, "msg-level", "all=no");
  mpv_set_option_string(mpv, "osc", "no");
  mpv_set_option_string(mpv, "input-default-bindings", "no");
  mpv_set_option_string(mpv, "input-vo-keyboard", "no");
  mpv_set_option_string(mpv, "aid", "no");
  mpv_set_option_string(mpv, "ao", "null");
  mpv_set_option_string(mpv, "sid", "no");
  mpv_set_option_string(mpv, "vo", "libmpv");
  mpv_set_option_string(mpv, "hwdec", "no");
  mpv_set_option_string(mpv, "vd-lavc-fast", "yes");
  mpv_set_option_string(mpv, "vd-lavc-skiploopfilter", "all");
  mpv_set_option_string(mpv, "vd-lavc-threads", "2");
  mpv_set_option_string(mpv, "sws-scaler", "fast-bilinear");
  mpv_set_option_string(mpv, "demuxer-max-bytes", "4MiB");
  mpv_set_option_string(mpv, "demuxer-max-back-bytes", "1MiB");
  mpv_set_option_string(mpv, "cache-secs", "4");
  mpv_set_option_string(mpv, "keep-open", "yes");
  mpv_set_option_string(mpv, "loop-file", "inf");

  if (start_ms > 0) {
    char start_buf[64];
    g_ascii_formatd(start_buf, sizeof(start_buf), "+%.3f", static_cast<double>(start_ms) / 1000.0);
    mpv_set_option_string(mpv, "start", start_buf);
  }

  if (!headers.empty()) {
    std::vector<mpv_node> nodes(headers.size());
    for (size_t i = 0; i < headers.size(); ++i) {
      nodes[i].format = MPV_FORMAT_STRING;
      nodes[i].u.string = const_cast<char*>(headers[i].c_str());
    }
    mpv_node_list list{};
    list.num = static_cast<int>(nodes.size());
    list.values = nodes.data();
    mpv_node root{};
    root.format = MPV_FORMAT_NODE_ARRAY;
    root.u.list = &list;
    mpv_set_option(mpv, "http-header-fields", MPV_FORMAT_NODE, &root);
  }

  if (mpv_initialize(mpv) < 0) {
    mpv_terminate_destroy(mpv);
    session->failed.store(true, std::memory_order_release);
    ScheduleMainThreadNotification(session);
    return;
  }

  mpv_render_param create_params[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_SW)},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  mpv_render_context* render_ctx = nullptr;
  if (mpv_render_context_create(&render_ctx, mpv, create_params) < 0 || render_ctx == nullptr) {
    mpv_terminate_destroy(mpv);
    session->failed.store(true, std::memory_order_release);
    ScheduleMainThreadNotification(session);
    return;
  }

  mpv_set_wakeup_callback(
      mpv,
      +[](void* ctx) {
        auto* s = static_cast<PreviewSession*>(ctx);
        {
          std::lock_guard<std::mutex> lock(s->cv_mutex);
          s->event_flagged = true;
        }
        s->cv.notify_one();
      },
      session.get());

  mpv_render_context_set_update_callback(
      render_ctx,
      +[](void* ctx) {
        auto* s = static_cast<PreviewSession*>(ctx);
        {
          std::lock_guard<std::mutex> lock(s->cv_mutex);
          s->update_flagged = true;
        }
        s->cv.notify_one();
      },
      session.get());

  const char* load_cmd[] = {"loadfile", url.c_str(), "replace", nullptr};
  if (mpv_command_async(mpv, 0, load_cmd) < 0) {
    mpv_render_context_set_update_callback(render_ctx, nullptr, nullptr);
    mpv_set_wakeup_callback(mpv, nullptr, nullptr);
    mpv_render_context_free(render_ctx);
    mpv_terminate_destroy(mpv);
    session->failed.store(true, std::memory_order_release);
    ScheduleMainThreadNotification(session);
    return;
  }

  std::vector<uint8_t> render_buf(kPreviewByteCount, 0);
  bool playback_restarted = false;
  int frames_after_restart = 0;

  while (!session->stop_requested.load(std::memory_order_acquire)) {
    bool do_events = false;
    bool do_update = false;
    {
      std::unique_lock<std::mutex> lock(session->cv_mutex);
      session->cv.wait(lock, [&session]() {
        return session->stop_requested.load(std::memory_order_acquire) || session->event_flagged ||
               session->update_flagged;
      });
      if (session->stop_requested.load(std::memory_order_acquire)) break;
      do_events = session->event_flagged;
      do_update = session->update_flagged;
      session->event_flagged = false;
      session->update_flagged = false;
    }

    if (do_events) {
      while (!session->stop_requested.load(std::memory_order_acquire)) {
        mpv_event* ev = mpv_wait_event(mpv, 0);
        if (ev == nullptr || ev->event_id == MPV_EVENT_NONE) break;
        if (ev->event_id == MPV_EVENT_PLAYBACK_RESTART) {
          playback_restarted = true;
        } else if (ev->event_id == MPV_EVENT_END_FILE) {
          auto* ef = static_cast<mpv_event_end_file*>(ev->data);
          if (ef != nullptr && ef->reason == MPV_END_FILE_REASON_ERROR) {
            session->failed.store(true, std::memory_order_release);
            ScheduleMainThreadNotification(session);
          }
        }
      }
    }

    if (do_update && !session->stop_requested.load(std::memory_order_acquire)) {
      const uint64_t flags = mpv_render_context_update(render_ctx);
      if ((flags & MPV_RENDER_UPDATE_FRAME) != 0) {
        int size[2] = {static_cast<int>(kPreviewWidth), static_cast<int>(kPreviewHeight)};
        const char* fmt = "rgb0";
        size_t stride = kPreviewStride;
        void* ptr = render_buf.data();
        mpv_render_param sw_params[] = {
            {MPV_RENDER_PARAM_SW_SIZE, size},
            {MPV_RENDER_PARAM_SW_FORMAT, const_cast<char*>(fmt)},
            {MPV_RENDER_PARAM_SW_STRIDE, &stride},
            {MPV_RENDER_PARAM_SW_POINTER, ptr},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        if (mpv_render_context_render(render_ctx, sw_params) >= 0) {
          uint32_t* pixels = reinterpret_cast<uint32_t*>(render_buf.data());
          for (size_t i = 0; i < kPreviewPixelCount; ++i) {
            pixels[i] |= 0xFF000000u;
          }
          if (!playback_restarted) {
            double time_pos = 0.0;
            if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &time_pos) >= 0 &&
                time_pos + 0.5 >= static_cast<double>(start_ms) / 1000.0) {
              playback_restarted = true;
            }
          }
          if (playback_restarted) {
            ++frames_after_restart;
          }
          {
            std::lock_guard<std::mutex> lock(session->buffer->mutex);
            std::swap(render_buf, session->buffer->staged);
            session->buffer->dirty = true;
            session->buffer->has_frame = true;
          }
          if (frames_after_restart >= 2) {
            session->ready_to_reveal.store(true, std::memory_order_release);
          }
          ScheduleMainThreadNotification(session);
        }
      }
    }
  }

  mpv_render_context_set_update_callback(render_ctx, nullptr, nullptr);
  mpv_set_wakeup_callback(mpv, nullptr, nullptr);
  mpv_render_context_free(render_ctx);
  mpv_terminate_destroy(mpv);
}

}  // namespace

struct _MpvPreviewPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar = nullptr;
  FlTextureRegistrar* texture_registrar = nullptr;
  FlMethodChannel* method_channel = nullptr;
  std::unordered_map<int64_t, std::shared_ptr<PreviewSession>> sessions;
};

G_DEFINE_TYPE(MpvPreviewPlugin, mpv_preview_plugin, G_TYPE_OBJECT)

static void mpv_preview_plugin_handle_method_call(MpvPreviewPlugin* self,
                                                  FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (g_strcmp0(method, "create") == 0) {
    // Only one hover preview is active at a time; retire any previous session.
    for (auto& kv : self->sessions) {
      StopSessionOnMainThread(kv.second);
    }
    self->sessions.clear();

    auto session = std::make_shared<PreviewSession>();
    session->texture = satra_preview_texture_new(session->buffer);
    session->registrar = FL_TEXTURE_REGISTRAR(g_object_ref(self->texture_registrar));
    if (!fl_texture_registrar_register_texture(self->texture_registrar,
                                               FL_TEXTURE(session->texture))) {
      g_autoptr(FlValue) result = fl_value_new_null();
      fl_method_call_respond_success(method_call, result, nullptr);
      return;
    }
    session->texture_id = fl_texture_get_id(FL_TEXTURE(session->texture));
    self->sessions[session->texture_id] = session;

    g_autoptr(FlValue) result = fl_value_new_int(session->texture_id);
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }

  if (g_strcmp0(method, "open") == 0) {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
      fl_method_call_respond_success(method_call, result, nullptr);
      return;
    }
    FlValue* id_val = fl_value_lookup_string(args, "textureId");
    FlValue* url_val = fl_value_lookup_string(args, "url");
    if (id_val == nullptr || fl_value_get_type(id_val) != FL_VALUE_TYPE_INT ||
        url_val == nullptr || fl_value_get_type(url_val) != FL_VALUE_TYPE_STRING) {
      g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
      fl_method_call_respond_success(method_call, result, nullptr);
      return;
    }

    const int64_t texture_id = fl_value_get_int(id_val);
    auto it = self->sessions.find(texture_id);
    if (it == self->sessions.end() || it->second->worker_started) {
      g_autoptr(FlValue) result = fl_value_new_bool(FALSE);
      fl_method_call_respond_success(method_call, result, nullptr);
      return;
    }

    std::shared_ptr<PreviewSession> session = it->second;
    session->worker_started = true;
    session->pending_open_call = FL_METHOD_CALL(g_object_ref(method_call));

    std::string url = fl_value_get_string(url_val);
    int64_t start_ms = 0;
    FlValue* start_val = fl_value_lookup_string(args, "startMs");
    if (start_val != nullptr && fl_value_get_type(start_val) == FL_VALUE_TYPE_INT) {
      start_ms = fl_value_get_int(start_val);
    }

    std::vector<std::string> headers;
    FlValue* headers_val = fl_value_lookup_string(args, "headers");
    if (headers_val != nullptr && fl_value_get_type(headers_val) == FL_VALUE_TYPE_MAP) {
      const size_t len = fl_value_get_length(headers_val);
      for (size_t i = 0; i < len; ++i) {
        FlValue* k = fl_value_get_map_key(headers_val, i);
        FlValue* v = fl_value_get_map_value(headers_val, i);
        if (k != nullptr && fl_value_get_type(k) == FL_VALUE_TYPE_STRING &&
            v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
          std::string line = fl_value_get_string(k);
          line.append(": ");
          line.append(fl_value_get_string(v));
          headers.push_back(std::move(line));
        }
      }
    }

    std::thread(RunPreviewWorker, std::move(session), std::move(url), std::move(headers), start_ms)
        .detach();
    return;
  }

  if (g_strcmp0(method, "dispose") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* id_val = fl_value_lookup_string(args, "textureId");
      if (id_val != nullptr && fl_value_get_type(id_val) == FL_VALUE_TYPE_INT) {
        const int64_t texture_id = fl_value_get_int(id_val);
        auto it = self->sessions.find(texture_id);
        if (it != self->sessions.end()) {
          StopSessionOnMainThread(it->second);
          self->sessions.erase(it);
        }
      }
    } else {
      for (auto& kv : self->sessions) {
        StopSessionOnMainThread(kv.second);
      }
      self->sessions.clear();
    }
    g_autoptr(FlValue) result = fl_value_new_null();
    fl_method_call_respond_success(method_call, result, nullptr);
    return;
  }

  fl_method_call_respond_not_implemented(method_call, nullptr);
}

static void method_call_cb(FlMethodChannel* /*channel*/,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  MpvPreviewPlugin* self = MPV_PREVIEW_PLUGIN(user_data);
  mpv_preview_plugin_handle_method_call(self, method_call);
}

static void mpv_preview_plugin_dispose(GObject* object) {
  MpvPreviewPlugin* self = MPV_PREVIEW_PLUGIN(object);
  for (auto& kv : self->sessions) {
    StopSessionOnMainThread(kv.second);
  }
  self->sessions.clear();
  if (self->method_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->method_channel, nullptr, nullptr, nullptr);
    g_clear_object(&self->method_channel);
  }
  g_clear_object(&self->texture_registrar);
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(mpv_preview_plugin_parent_class)->dispose(object);
}

static void mpv_preview_plugin_finalize(GObject* object) {
  MpvPreviewPlugin* self = MPV_PREVIEW_PLUGIN(object);
  self->sessions.~unordered_map();
  G_OBJECT_CLASS(mpv_preview_plugin_parent_class)->finalize(object);
}

static void mpv_preview_plugin_class_init(MpvPreviewPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = mpv_preview_plugin_dispose;
  G_OBJECT_CLASS(klass)->finalize = mpv_preview_plugin_finalize;
}

static void mpv_preview_plugin_init(MpvPreviewPlugin* self) {
  new (&self->sessions) std::unordered_map<int64_t, std::shared_ptr<PreviewSession>>();
}

void mpv_preview_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  MpvPreviewPlugin* plugin = MPV_PREVIEW_PLUGIN(g_object_new(MPV_PREVIEW_PLUGIN_TYPE, nullptr));
  plugin->registrar = FL_PLUGIN_REGISTRAR(g_object_ref(registrar));
  plugin->texture_registrar =
      FL_TEXTURE_REGISTRAR(g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->method_channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "com.plezy/hover_preview",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->method_channel,
                                            method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);
  g_object_unref(plugin);
}
