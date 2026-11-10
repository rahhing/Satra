package com.rahhing.satra.shared

import android.graphics.Color

object ThemeHelper {
  fun themeColor(mode: String?): Int? = when (mode) {
    "oled" -> Color.BLACK
    "dark" -> Color.BLACK
    "light" -> Color.parseColor("#F7F7F8")
    else -> null
  }
}
