# Jsoup keeps no reflective state we rely on, but its nodes use some
# introspection — keep the package intact to be safe under R8.
-keeppackagenames org.jsoup.**
-keep class org.jsoup.** { *; }

# OkHttp / Okio: platform classes are referenced reflectively; suppress warnings.
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# kotlinx.serialization: keep generated serializers for @Serializable types.
-keepclassmembers class io.github.yennster.fanficly.model.** {
    *** Companion;
}
-keepclasseswithmembers class io.github.yennster.fanficly.model.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Room generates implementations at compile time; defaults handle it. Keep
# entities' no-arg shape just in case.
-keep class io.github.yennster.fanficly.data.db.** { *; }
