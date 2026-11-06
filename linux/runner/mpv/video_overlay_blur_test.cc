// Run with EGL_PLATFORM=surfaceless on a headless Mesa host.
#include "video_overlay_blur.h"

#include <epoxy/egl.h>

#include <cstdio>
#include <cstdlib>

namespace {
void Check(bool value, const char* message) {
  if (!value) {
    std::fprintf(stderr, "%s (GL error 0x%x, EGL error 0x%x)\n", message, glGetError(), eglGetError());
    std::exit(1);
  }
}

// Vertical bars retain their contrast without blur and average to grey with it.
void DrawBars(int width, int height, bool horizontal = false) {
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, width, height);
  glEnable(GL_SCISSOR_TEST);
  for (int x = 0; x < (horizontal ? height : width); ++x) {
    const float value = (x / 4) % 2 ? 1.0f : 0.0f;
    glClearColor(value, value, value, 1);
    if (horizontal)
      glScissor(0, x, width, 1);
    else
      glScissor(x, 0, 1, height);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  glDisable(GL_SCISSOR_TEST);
}

int Pixel(int x, int y) {
  unsigned char pixel[4] = {};
  glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
  return pixel[0];
}
}  // namespace

int main() {
  const EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  Check(display != EGL_NO_DISPLAY && eglInitialize(display, nullptr, nullptr), "Initialize EGL");
  Check(eglBindAPI(EGL_OPENGL_ES_API), "Bind GLES");
  const EGLint attributes[] = {
      EGL_SURFACE_TYPE,
      EGL_PBUFFER_BIT,
      EGL_RENDERABLE_TYPE,
      EGL_OPENGL_ES3_BIT,
      EGL_RED_SIZE,
      8,
      EGL_GREEN_SIZE,
      8,
      EGL_BLUE_SIZE,
      8,
      EGL_ALPHA_SIZE,
      8,
      EGL_NONE};
  EGLConfig config;
  EGLint count = 0;
  Check(eglChooseConfig(display, attributes, &config, 1, &count) && count == 1, "Choose EGL config");
  const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  const EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
  const EGLint surface_attributes[] = {EGL_WIDTH, 256, EGL_HEIGHT, 192, EGL_NONE};
  const EGLSurface surface = eglCreatePbufferSurface(display, config, surface_attributes);
  Check(context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE, "Create EGL resources");
  Check(eglMakeCurrent(display, surface, surface, context), "Make EGL current");

  mpv::VideoOverlayBlur blur;
  // A nonzero video origin catches accidental use of view coordinates directly.
  const mpv::VideoBlurRegion region = {72, 58, 128, 128, 20, {24, 24, 24, 24}};
  DrawBars(256, 192);
  const int outside = Pixel(20, 80);
  const int corner = Pixel(32, 32);
  blur.Apply(256, 192, 8, {region}, 40, 26);
  Check(glGetError() == GL_NO_ERROR, "Blur GL operations");
  Check(Pixel(20, 80) == outside, "Pixels outside the pane must be unchanged");
  Check(Pixel(32, 32) == corner, "Rounded corner must be unchanged");
  Check(Pixel(96, 96) > 80 && Pixel(96, 96) < 175, "Pane interior must be blurred");
  Check(std::abs(Pixel(96, 96) - Pixel(100, 96)) < 30, "Blur must remove bar contrast");

  // Resizing reallocates textures; clearing the regions restores the normal frame.
  DrawBars(128, 96);
  blur.Apply(128, 96, 8, {{0, 0, 128, 96, 12, {0, 0, 0, 0}}}, 0, 0);
  Check(glGetError() == GL_NO_ERROR, "Resize blur textures");
  Check(Pixel(64, 48) > 80 && Pixel(64, 48) < 175, "Resized pane must be blurred");
  DrawBars(128, 96);
  const int original = Pixel(64, 48);
  blur.Apply(128, 96, 8, {}, 0, 0);
  Check(Pixel(64, 48) == original && glGetError() == GL_NO_ERROR, "Closing must restore unblurred video");
  for (const int depth : {8, 10, 16}) {
    DrawBars(128, 96, true);
    blur.Apply(128, 96, depth, {{0, 0, 128, 96, 12, {0, 0, 0, 0}}}, 0, 0);
    Check(glGetError() == GL_NO_ERROR, "Reopen with HDR precision textures");
    Check(Pixel(64, 48) > 80 && Pixel(64, 48) < 175, "Vertical pass must blur horizontal bars after reopening");
  }
  // A sharp edge must become a smooth ramp. Sparse, widely spaced taps make
  // visible bands here even though they pass a high-frequency bars test.
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glClearColor(0, 0, 0, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glEnable(GL_SCISSOR_TEST);
  glScissor(128, 0, 128, 192);
  glClearColor(1, 1, 1, 1);
  glClear(GL_COLOR_BUFFER_BIT);
  glDisable(GL_SCISSOR_TEST);
  blur.Apply(256, 192, 8, {{0, 0, 256, 192, 20, {0, 0, 0, 0}}}, 0, 0);
  for (int x = 65; x < 192; ++x) {
    const int delta = Pixel(x, 96) - Pixel(x - 1, 96);
    Check(delta >= 0 && delta <= 6, "Gaussian edge must be smooth without sample bands");
  }
  blur.Reset();

  eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroySurface(display, surface);
  eglDestroyContext(display, context);
  eglTerminate(display);
  std::puts("Video overlay blur GPU tests passed");
}
