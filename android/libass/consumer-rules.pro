# JNI exports bind by name (Java_com_rahhing_satra_libass_*); keep the names stable.
-keepclasseswithmembernames class com.rahhing.satra.libass.* {
    native <methods>;
}
