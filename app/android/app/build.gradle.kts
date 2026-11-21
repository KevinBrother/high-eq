plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "cn.higheq.high_eq"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cn.higheq.high_eq"
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
        }
    }
}

flutter {
    source = "../.."
}

// Optional licensed SDK artifacts supplied by the release team. The default
// contract build does not resolve or load any merchant SDK.
val vendorBuild = providers.gradleProperty("t17VendorSdk").orNull == "true"
android.sourceSets.getByName("main").apply {
    java.srcDir(if (vendorBuild) "src/vendor/kotlin" else "src/contract/kotlin")

}
if (vendorBuild) {
    android.defaultConfig.resValue("string", "wechat_app_id", providers.gradleProperty("wechatAppId").get())
    dependencies {
        implementation(files(providers.gradleProperty("wechatSdkAar").get()))
        implementation(files(providers.gradleProperty("alipaySdkAar").get()))
    }
}
if (vendorBuild) {
    // Debug/profile have existing INTERNET overlays; keep them (already in main).
    listOf("debug", "release", "profile").forEach {
        android.sourceSets.maybeCreate(it).manifest.srcFile("src/vendor/AndroidManifest.xml")
    }
}
