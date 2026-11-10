#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 u_size;
uniform vec4 u_radii;     // (bottomRight, topRight, bottomLeft, topLeft)
uniform float u_bevel;
uniform float u_intensity;
uniform float u_is_dark;

out vec4 frag_color;

float sdRoundBox(vec2 p, vec2 b, vec4 r) {
  r.xy = (p.x > 0.0) ? r.xy : r.zw;
  r.x = (p.y > 0.0) ? r.x : r.y;
  vec2 q = abs(p) - b + r.x;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

void main() {
  vec2 pos = FlutterFragCoord().xy;
  float bevel = max(u_bevel, 4.0);
  // When a sheet is docked flush against the top or bottom viewport edge
  // (0px corners on the anchored edge, rounded corners on the opposite edge),
  // extend the virtual SDF box past the anchored edge so the vertical glass
  // rims run cleanly into sharp 90° corners with no bottom/top miter crease.
  float padTop = (u_radii.y <= 0.5 && u_radii.w <= 0.5 && (u_radii.x > 0.5 || u_radii.z > 0.5))
      ? (bevel + 6.0)
      : 0.0;
  float padBottom = (u_radii.x <= 0.5 && u_radii.z <= 0.5 && (u_radii.y > 0.5 || u_radii.w > 0.5))
      ? (bevel + 6.0)
      : 0.0;
  vec2 boxMin = vec2(0.0, -padTop);
  vec2 boxMax = vec2(u_size.x, u_size.y + padBottom);
  vec2 halfSize = (boxMax - boxMin) * 0.5;
  vec2 p = pos - (boxMin + boxMax) * 0.5;

  float d = sdRoundBox(p, halfSize, u_radii);
  if (d > 0.5) {
    frag_color = vec4(0.0);
    return;
  }

  // Analytical finite-difference SDF gradient -> outward edge normal
  const float eps = 0.75;
  float dx = sdRoundBox(p + vec2(eps, 0.0), halfSize, u_radii) -
             sdRoundBox(p - vec2(eps, 0.0), halfSize, u_radii);
  float dy = sdRoundBox(p + vec2(0.0, eps), halfSize, u_radii) -
             sdRoundBox(p - vec2(0.0, eps), halfSize, u_radii);
  vec2 grad = normalize(vec2(dx, dy) + vec2(1e-5));

  float distIn = max(-d, 0.0);
  float rimFactor = clamp(1.0 - distIn / bevel, 0.0, 1.0);
  // Steep curve keeps sheen strictly near the outer bevel, leaving interior dark
  float slope = pow(rimFactor, 2.35);

  // Key light from top-left + subtle rim catch at bottom-right
  float keySpec = pow(max(dot(grad, normalize(vec2(-0.62, -0.78))), 0.0), 2.4);
  float rimSpec = pow(max(dot(grad, normalize(vec2(0.68, 0.73))), 0.0), 3.2);

  // Tight Fresnel lip reflection (~1.5px) without fogging the interior
  float outerLip = exp(-distIn * 1.55);
  float causticBand = exp(-pow((distIn - bevel * 0.26) / (bevel * 0.22), 2.0));

  float dispersionPhase = dot(grad, vec2(0.8, -0.6));
  vec3 prismTint = mix(
    vec3(0.68, 0.88, 1.0),
    vec3(1.0, 0.86, 0.96),
    clamp(dispersionPhase * 0.5 + 0.5, 0.0, 1.0)
  );

  float darkScale = mix(0.62, 0.72, u_is_dark);

  float lipAlpha = outerLip * (0.09 + 0.17 * keySpec + 0.08 * rimSpec) * darkScale;
  float bevelAlpha = slope * (0.010 + 0.026 * keySpec + 0.012 * rimSpec) * darkScale;
  float causticAlpha = causticBand * (0.006 + 0.012 * keySpec) * darkScale;

  // No white interior dome wash in dark mode so black levels stay deep obsidian
  vec2 uv = pos / max(u_size, vec2(1.0));
  float domeSheen = (1.0 - u_is_dark) * pow(clamp(1.0 - (uv.x * 0.55 + uv.y * 0.65), 0.0, 1.0), 3.0) * 0.018;

  float maxCap = mix(0.28, 0.22, u_is_dark);
  float totalAlpha = clamp((lipAlpha + bevelAlpha + causticAlpha + domeSheen) * u_intensity, 0.0, maxCap);
  vec3 baseWhite = vec3(1.0);
  vec3 color = mix(baseWhite, prismTint, clamp(slope * 0.24, 0.0, 0.24));

  // Premultiplied alpha output
  frag_color = vec4(color * totalAlpha, totalAlpha);
}
