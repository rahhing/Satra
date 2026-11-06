cmake_minimum_required(VERSION 3.13)
# This private GTK bridge is deliberately limited to the official 3.47.1 engine.
# An engine upgrade must review fl_engine.cc's layout and then refresh these
# hashes. Never guess offsets or silently restore the 60 Hz fallback.
file(SHA256 "${ENGINE_LIBRARY}" engine_sha256)
set(supported_hashes
  abf9b1aab4168bca3a216adaf3b244a35298df4e90d2a590f31d7fe7f8a8d840
  b39bdb6eea084f47d1dbec1730fa8af695dff57f11685e97682499df4cda1cfe
  40c5946290bc9d8b43181f301538ea351130775ae56b9f41d57077f94c0ff47c
  e1b81e854d6d600d738c0b4094f4ba357c7168921799031e05e6f94611a689d7
  a8d2b4e517c81262a56a4794d481e5e265037612c76b70f1c9203086c51a54d7
  a668b6a595a5330a46551f8b15d6f124346b35112f203601c1f8e3128ada988a
)
if(NOT engine_sha256 IN_LIST supported_hashes)
  message(FATAL_ERROR
    "Satra's Linux VSync adapter requires the pinned Flutter 3.47.1 engine. "
    "Unknown GTK engine SHA256: ${engine_sha256}. Review the adapter before upgrading.")
endif()
