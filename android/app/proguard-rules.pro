# ── ML Kit text recognition ──────────────────────────────────────────────────
# We bundle the Latin and Devanagari recognizers (the latter added explicitly in
# app/build.gradle.kts for Hindi bills). The Chinese / Japanese / Korean modules
# remain compileOnly in the plugin and are not in the APK, so R8 sees them as
# missing — suppress only those warnings so release minification passes.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# Keep ML Kit's own classes (model loading uses reflection internally).
-keep class com.google.mlkit.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
