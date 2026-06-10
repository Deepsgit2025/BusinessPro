plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.businesspro.app"
    compileSdk = flutter.compileSdkVersion
    // Plugins (printing, sqflite, image_picker, …) require NDK 28.2.
    ndkVersion = "28.2.13676358"

    // NDK 28's llvm-strip cannot process Flutter's libapp.so during the release
    // strip step ("not recognized as a valid object file"). Skip stripping only
    // that file (it's already optimised); all other native libs strip normally.
    packaging {
        jniLibs {
            keepDebugSymbols += "**/libapp.so"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.businesspro.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 trips on ML Kit's optional per-script recognizer modules
            // (Chinese/Devanagari/…) which we don't bundle. The keep rules below
            // suppress those missing-class warnings so minification completes.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    // The google_mlkit_text_recognition plugin bundles only the Latin recognizer
    // (it declares the other scripts compileOnly, so apps opt in to just what
    // they need). Scan Bill also reads Hindi bills, so we add the Devanagari
    // recognizer as a real dependency here — otherwise its classes are absent
    // from the release APK and constructing the Devanagari TextRecognizer
    // crashes at runtime (NoClassDefFoundError).
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
