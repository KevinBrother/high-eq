plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// China/HMS distribution is deliberately closed. An environment variable or a
// developer keystore must never turn a restricted Health Kit scope on.
val historyDistribution = providers.gradleProperty("t28Distribution").orElse("platform").get()
require(historyDistribution in setOf("platform", "huaweiRestricted")) {
    "T28: no approved Huawei Health Kit configuration for this release"
}
val huaweiRestricted = historyDistribution == "huaweiRestricted"
// Read the issuer value only for the restricted channel. A machine that also
// passes -Pt28HuaweiAppId must not leak it into an ordinary platform package.
val huaweiAppId =
    if (huaweiRestricted) providers.gradleProperty("t28HuaweiAppId").orElse("").get().trim() else ""
if (huaweiRestricted) {
    require(huaweiAppId.isNotEmpty()) {
        "T28: huaweiRestricted requires -Pt28HuaweiAppId=<approved app id>"
    }
    require(huaweiAppId.matches(Regex("[0-9]+"))) {
        "T28: huaweiRestricted app id must be numeric"
    }
    // The licensed AG Connect project file is injected by the issuer and is
    // deliberately excluded from source control. Applying the plugin only in
    // this branch keeps the ordinary Android build independent from AGCP.
    require(file("agconnect-services.json").isFile) {
        "T28: huaweiRestricted requires an issuer-provided agconnect-services.json"
    }
    apply(plugin = "com.huawei.agconnect")
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
        // huawei_health 6.17.0+300 declares minSdkVersion 26. Keep the app's
        // manifest merge compatible even when the restricted channel is off.
        minSdk = 26
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

android.defaultConfig.manifestPlaceholders["t28HuaweiAppId"] = huaweiAppId
android.defaultConfig.resValue("string", "t28_huawei_app_id", huaweiAppId)
android.defaultConfig.resValue("bool", "t28_platform_history", (historyDistribution == "platform").toString())
android.defaultConfig.resValue("bool", "t28_huawei_history", huaweiRestricted.toString())
