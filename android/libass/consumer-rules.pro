# JNI exports bind by name (Java_com_edde746_satra_libass_*); keep the names stable.
-keepclasseswithmembernames class com.edde746.satra.libass.* {
    native <methods>;
}
