#ifndef SATRA_LINUX_MPV_VIDEO_OVERLAY_BLUR_H_
#define SATRA_LINUX_MPV_VIDEO_OVERLAY_BLUR_H_

#include <epoxy/gl.h>
#include <glib.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace mpv {

// Physical coordinates in the Flutter view, with a top-left origin.
struct VideoBlurRegion {
  double left, top, width, height, sigma;
  double radii[4];  // top-left, top-right, bottom-right, bottom-left
};

// GPU-only backdrop blur for panes above the native video underlay. The normal
// frame stays in the window framebuffer; only the pane's rounded bounds are
// replaced. A downsample pyramid and separable blur retain the plane's precision
// for HDR. All GL calls run on the render thread.
// Resources are also owned by the isolated EGL context, so destroying that
// context releases them even when teardown happens on a different thread.
class VideoOverlayBlur {
 public:
  void Apply(int width, int height, int depth, const std::vector<VideoBlurRegion>& regions, double left, double top) {
    if (regions.empty()) {
      Reset();
      return;
    }
    if (failed_ || !Prepare(width, height, depth)) return;

    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    // Downsample in 2x steps to average fine detail rather than alias it into
    // the blurred pane. A single large linear blit samples only four pixels.
    int source_width = width, source_height = height;
    for (int i = 0; i < 3; ++i) {
      glBindFramebuffer(GL_READ_FRAMEBUFFER, i == 0 ? 0 : framebuffers_[i - 1]);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffers_[i]);
      glBlitFramebuffer(
          0, 0, source_width, source_height, 0, 0, widths_[i], heights_[i], GL_COLOR_BUFFER_BIT, GL_LINEAR);
      source_width = widths_[i];
      source_height = heights_[i];
    }

    glUseProgram(program_);
    glBindVertexArray(vao_);
    glActiveTexture(GL_TEXTURE0);
    glUniform1i(glGetUniformLocation(program_, "image"), 0);
    auto bounded_pixel = [](double value, int extent) {
      return static_cast<int>(std::max(0.0, std::min(value, double(extent))));
    };
    for (const auto& region : regions) {
      const double x = region.left - left;
      const double y = height - (region.top - top + region.height);
      const int x0 = bounded_pixel(std::floor(x), width);
      const int y0 = bounded_pixel(std::floor(y), height);
      const int x1 = bounded_pixel(std::ceil(x + region.width), width);
      const int y1 = bounded_pixel(std::ceil(y + region.height), height);
      if (x1 <= x0 || y1 <= y0 || region.sigma <= 0) continue;

      // Sample a dense Gaussian at reduced resolution in both directions.
      glUniform1f(glGetUniformLocation(program_, "sigma"), std::max(0.5, region.sigma / 8.0));
      glBindFramebuffer(GL_FRAMEBUFFER, framebuffers_[3]);
      glViewport(0, 0, texture_width_, texture_height_);
      glBindTexture(GL_TEXTURE_2D, textures_[2]);
      glUniform2f(glGetUniformLocation(program_, "stepUV"), 1.0f / texture_width_, 0);
      glUniform1i(glGetUniformLocation(program_, "mask"), 0);
      glDrawArrays(GL_TRIANGLES, 0, 3);

      glBindFramebuffer(GL_FRAMEBUFFER, framebuffers_[4]);
      glBindTexture(GL_TEXTURE_2D, textures_[3]);
      glUniform2f(glGetUniformLocation(program_, "stepUV"), 0, 1.0f / texture_height_);
      glDrawArrays(GL_TRIANGLES, 0, 3);

      glBindFramebuffer(GL_FRAMEBUFFER, 0);
      glViewport(0, 0, width, height);
      glBindTexture(GL_TEXTURE_2D, textures_[4]);
      glUniform1i(glGetUniformLocation(program_, "mask"), 1);
      glUniform4f(glGetUniformLocation(program_, "rect"), x, y, region.width, region.height);
      glUniform4f(
          glGetUniformLocation(program_, "radii"), region.radii[0], region.radii[1], region.radii[2], region.radii[3]);
      glEnable(GL_SCISSOR_TEST);
      glScissor(x0, y0, x1 - x0, y1 - y0);
      glEnable(GL_BLEND);
      glBlendEquation(GL_FUNC_ADD);
      glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
      glDrawArrays(GL_TRIANGLES, 0, 3);
      glDisable(GL_BLEND);
      glDisable(GL_SCISSOR_TEST);
    }
    glBindVertexArray(0);
    glBindTexture(GL_TEXTURE_2D, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glUseProgram(0);
    glViewport(0, 0, width, height);
  }

  void Reset() {
    if (!program_ && !textures_[0]) return;
    if (program_) glDeleteProgram(program_);
    if (vao_) glDeleteVertexArrays(1, &vao_);
    glDeleteTextures(5, textures_);
    glDeleteFramebuffers(5, framebuffers_);
    program_ = vao_ = 0;
    std::fill_n(textures_, 5, 0);
    std::fill_n(framebuffers_, 5, 0);
    texture_width_ = texture_height_ = 0;
    source_width_ = source_height_ = 0;
  }

 private:
  GLuint Compile(GLenum type, const char* source) {
    const GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled) return shader;
    char log[1024] = {};
    glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
    g_warning("Video overlay blur shader: %s", log);
    glDeleteShader(shader);
    return 0;
  }

  bool Fail() {
    g_warning("Video overlay blur unavailable in this EGL context");
    Reset();
    failed_ = true;
    return false;
  }

  bool Prepare(int width, int height, int depth) {
    if (!program_) {
      if (epoxy_gl_version() < 30) return Fail();
      const char* vertex = R"(#version 300 es
        out vec2 uv;
        void main() {
          uv = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
          gl_Position = vec4(uv * 2.0 - 1.0, 0.0, 1.0);
        })";
      const char* fragment = R"(#version 300 es
        precision highp float;
        uniform sampler2D image;
        uniform vec2 stepUV;
        uniform float sigma;
        uniform bool mask;
        uniform vec4 rect;
        uniform vec4 radii;
        in vec2 uv;
        out vec4 color;
        void main() {
          float alpha = 1.0;
          if (mask) {
            vec2 p = gl_FragCoord.xy - rect.xy - rect.zw * 0.5;
            float radius = p.y > 0.0 ? (p.x > 0.0 ? radii.y : radii.x)
                                       : (p.x > 0.0 ? radii.z : radii.w);
            radius = min(radius, min(rect.z, rect.w) * 0.5);
            vec2 q = abs(p) - rect.zw * 0.5 + radius;
            float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
            alpha = 1.0 - smoothstep(-0.75, 0.75, distance);
            if (alpha <= 0.0) discard;
          }
          if (mask) {
            color = vec4(texture(image, uv).rgb, alpha);
            return;
          }
          vec3 result = vec3(0.0);
          float total = 0.0;
          for (int i = -48; i <= 48; ++i) {
            float offset = float(i);
            if (abs(offset) > ceil(3.0 * sigma)) continue;
            float weight = exp(-0.5 * offset * offset / (sigma * sigma));
            result += texture(image, uv + stepUV * offset).rgb * weight;
            total += weight;
          }
          result /= total;
          color = vec4(result, alpha);
        })";
      const GLuint vs = Compile(GL_VERTEX_SHADER, vertex);
      const GLuint fs = Compile(GL_FRAGMENT_SHADER, fragment);
      if (!vs || !fs) {
        if (vs) glDeleteShader(vs);
        if (fs) glDeleteShader(fs);
        return Fail();
      }
      program_ = glCreateProgram();
      glAttachShader(program_, vs);
      glAttachShader(program_, fs);
      glLinkProgram(program_);
      glDeleteShader(vs);
      glDeleteShader(fs);
      GLint linked = GL_FALSE;
      glGetProgramiv(program_, GL_LINK_STATUS, &linked);
      if (!linked) return Fail();
      glGenVertexArrays(1, &vao_);
    }

    const int tw = std::max(1, (width + 7) / 8);
    const int th = std::max(1, (height + 7) / 8);
    if (width == source_width_ && height == source_height_ && depth == depth_) return true;
    glDeleteTextures(5, textures_);
    glDeleteFramebuffers(5, framebuffers_);
    glGenTextures(5, textures_);
    glGenFramebuffers(5, framebuffers_);
    glActiveTexture(GL_TEXTURE0);
    for (int i = 0; i < 5; ++i) {
      const int divisor = 1 << std::min(i + 1, 3);
      widths_[i] = std::max(1, (width + divisor - 1) / divisor);
      heights_[i] = std::max(1, (height + divisor - 1) / divisor);
      glBindTexture(GL_TEXTURE_2D, textures_[i]);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      const GLenum format = depth >= 16 ? GL_RGBA16F : depth >= 10 ? GL_RGB10_A2 : GL_RGBA8;
      glTexStorage2D(GL_TEXTURE_2D, 1, format, widths_[i], heights_[i]);
      glBindFramebuffer(GL_FRAMEBUFFER, framebuffers_[i]);
      glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures_[i], 0);
      if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindTexture(GL_TEXTURE_2D, 0);
        return Fail();
      }
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    texture_width_ = tw;
    texture_height_ = th;
    source_width_ = width;
    source_height_ = height;
    depth_ = depth;
    return true;
  }

  GLuint program_ = 0, vao_ = 0;
  GLuint textures_[5] = {}, framebuffers_[5] = {};
  int widths_[5] = {}, heights_[5] = {};
  int source_width_ = 0, source_height_ = 0;
  int texture_width_ = 0, texture_height_ = 0, depth_ = 0;
  bool failed_ = false;
};

}  // namespace mpv

#endif  // SATRA_LINUX_MPV_VIDEO_OVERLAY_BLUR_H_
