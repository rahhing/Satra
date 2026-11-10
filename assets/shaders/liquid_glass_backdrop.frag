#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec4 u_radii;     // (topRight, bottomRight, topLeft, bottomLeft)
uniform float u_strength;
uniform float u_is_dark;
uniform sampler2D u_texture_input;

out vec4 frag_color;

float sdRoundBox(vec2 p, vec2 b, vec4 r) {
  r.xy = (p.x > 0.0) ? r.xy : r.zw;
  r.x = (p.y > 0.0) ? r.x : r.y;
  vec2 q = abs(p) - b + r.x;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

vec2 sampleUv(vec2 uv) {
  return clamp(uv, vec2(0.002), vec2(0.998));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 safeSize = max(u_size, vec2(1.0));
  vec2 halfSize = safeSize * 0.5;
  vec2 p = frag - halfSize;

  float d = sdRoundBox(p, halfSize, u_radii);
  const float eps = 1.25;
  float dx = sdRoundBox(p + vec2(eps, 0.0), halfSize, u_radii) -
             sdRoundBox(p - vec2(eps, 0.0), halfSize, u_radii);
  float dy = sdRoundBox(p + vec2(0.0, eps), halfSize, u_radii) -
             sdRoundBox(p - vec2(0.0, eps), halfSize, u_radii);
  vec2 normal2d = normalize(vec2(dx, dy) + vec2(1e-5));

  // Sleek, understated meniscus bevel (HiDPI-aware)
  float minSide = min(safeSize.x, safeSize.y);
  float bevel = clamp(minSide * 0.16, 10.0, 34.0);
  float distIn = max(-d, 0.0);
  float rim = clamp(1.0 - distIn / bevel, 0.0, 1.0);
  // Keep optical bend concentrated softly along the curved outer edge
  float meniscus = pow(rim, 2.45);

  // Subtle dome refraction + gentle Snell's-law meniscus bend at the glass lip
  vec2 centerOffset = -p * (0.013 * u_strength * (1.0 - meniscus * 0.7));
  vec2 rimOffset = -normal2d * (meniscus * bevel * 0.32 * u_strength);
  vec2 baseCoord = frag + centerOffset + rimOffset;

  // Delicate micro-chromatic dispersion strictly on the outer meniscus
  vec2 chromaShift = normal2d * (meniscus * (bevel * 0.028) * u_strength);
  float r = texture(u_texture_input, sampleUv((baseCoord + chromaShift) / safeSize)).r;
  vec4 gSample = texture(u_texture_input, sampleUv(baseCoord / safeSize));
  float b = texture(u_texture_input, sampleUv((baseCoord - chromaShift) / safeSize)).b;

  vec3 sampled = vec3(r, gSample.g, b);
  // Rich smoked-glass optical absorption + highlight roll-off so bright anime
  // skies deepen into moody color pools rather than washing out dark glass.
  float luma = dot(sampled, vec3(0.2126, 0.7152, 0.0722));
  float highlightRoll = mix(1.0, 0.74, smoothstep(0.42, 0.98, luma) * u_is_dark * u_strength);
  float targetShade = mix(0.94, 0.62, u_is_dark);
  float depthShade = mix(1.0, targetShade, u_strength * (0.80 + 0.20 * (1.0 - meniscus)));
  frag_color = vec4(sampled * depthShade * highlightRoll, gSample.a);
}
