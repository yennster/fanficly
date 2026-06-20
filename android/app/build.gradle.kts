plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android {
    namespace = "io.github.yennster.fanficly"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.yennster.fanficly"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.5.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables { useSupportLibrary = true }
    }

    // App-store builds are signed from a keystore configured out-of-band (see
    // docs/ANDROID_PUBLISHING.md). The block reads from gradle.properties /
    // environment so the keystore secrets never live in the repo.
    signingConfigs {
        create("release") {
            val storeFilePath = (project.findProperty("FANFICLY_STORE_FILE") as String?)
                ?: System.getenv("FANFICLY_STORE_FILE")
            if (storeFilePath != null) {
                storeFile = file(storeFilePath)
                storePassword = (project.findProperty("FANFICLY_STORE_PASSWORD") as String?)
                    ?: System.getenv("FANFICLY_STORE_PASSWORD")
                keyAlias = (project.findProperty("FANFICLY_KEY_ALIAS") as String?)
                    ?: System.getenv("FANFICLY_KEY_ALIAS")
                keyPassword = (project.findProperty("FANFICLY_KEY_PASSWORD") as String?)
                    ?: System.getenv("FANFICLY_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Only attach the signing config when a keystore was actually
            // provided, so a plain `assembleRelease` still works for CI smoke builds.
            if ((project.findProperty("FANFICLY_STORE_FILE") as String?) != null ||
                System.getenv("FANFICLY_STORE_FILE") != null
            ) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        debug {
            applicationIdSuffix = ".debug"
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging {
        resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    implementation(libs.androidx.material.icons.extended)
    implementation(libs.androidx.navigation.compose)
    debugImplementation(libs.androidx.ui.tooling)

    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.security.crypto)

    implementation(libs.okhttp)
    implementation(libs.jsoup)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(libs.androidx.junit)
}
