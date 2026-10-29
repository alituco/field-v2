plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Only the protected production builder supplies these values. Ordinary CI
// compiles unsigned production releases; it must never fall back to a debug key.
val uploadSigning = listOf(
    "ANDROID_UPLOAD_KEYSTORE_PATH",
    "ANDROID_UPLOAD_STORE_PASSWORD",
    "ANDROID_UPLOAD_KEY_ALIAS",
    "ANDROID_UPLOAD_KEY_PASSWORD",
).associateWith { providers.environmentVariable(it).orNull }
check(uploadSigning.values.all { it.isNullOrBlank() } ||
    uploadSigning.values.all { !it.isNullOrBlank() }) {
    "Provide all Android upload signing inputs, or none for an unsigned CI build."
}

android {
    namespace = "com.field.field"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    flavorDimensions += "environment"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        resValues = true
    }

    defaultConfig {
        // Keep the existing staging base identity; production overrides it below.
        applicationId = "com.field.field"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (uploadSigning.values.all { !it.isNullOrBlank() }) {
            create("productionUpload") {
                storeFile = file(uploadSigning.getValue("ANDROID_UPLOAD_KEYSTORE_PATH")!!)
                storeType = "PKCS12"
                storePassword = uploadSigning.getValue("ANDROID_UPLOAD_STORE_PASSWORD")
                keyAlias = uploadSigning.getValue("ANDROID_UPLOAD_KEY_ALIAS")
                keyPassword = uploadSigning.getValue("ANDROID_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    productFlavors {
        create("staging") {
            dimension = "environment"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            resValue("string", "app_name", "Fieldrush Staging")
            manifestPlaceholders["authRedirectScheme"] = "com.alialtaraif.field.staging"
            signingConfig = signingConfigs.getByName("debug")
        }
        create("production") {
            dimension = "environment"
            applicationId = "gg.fieldrush.app"
            resValue("string", "app_name", "Fieldrush")
            manifestPlaceholders["authRedirectScheme"] = "com.alialtaraif.field"
            signingConfig = signingConfigs.findByName("productionUpload")
        }
    }

    buildTypes {
        release {
            // Flavor signing applies: staging debug key, production upload key
            // or unsigned compilation. Store artifacts must pass signature checks.
            signingConfig = null
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
