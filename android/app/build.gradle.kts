import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.hilt)
    alias(libs.plugins.ksp)
    alias(libs.plugins.google.services)
    alias(libs.plugins.sentry)
}

val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.clipulse.android"
    compileSdk = 35

    signingConfigs {
        create("release") {
            storeFile = file("cli-pulse-upload.jks")
            storePassword = localProps.getProperty("STORE_PASSWORD", System.getenv("STORE_PASSWORD") ?: "")
            keyAlias = localProps.getProperty("KEY_ALIAS", "cli-pulse-upload")
            keyPassword = localProps.getProperty("KEY_PASSWORD", System.getenv("KEY_PASSWORD") ?: "")
        }
    }

    defaultConfig {
        applicationId = "com.clipulse.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 55
        versionName = "1.38.1"

        buildConfigField("String", "SUPABASE_URL",
            "\"${localProps.getProperty("SUPABASE_URL", "https://gkjwsxotmwrgqsvfijzs.supabase.co")}\"")
        buildConfigField("String", "SUPABASE_ANON_KEY",
            "\"${localProps.getProperty("SUPABASE_ANON_KEY", System.getenv("SUPABASE_ANON_KEY") ?: "")}\"")
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID",
            "\"${localProps.getProperty("GOOGLE_WEB_CLIENT_ID", System.getenv("GOOGLE_WEB_CLIENT_ID") ?: "")}\"")
        buildConfigField("String", "SENTRY_DSN",
            "\"${localProps.getProperty("SENTRY_DSN", System.getenv("SENTRY_DSN") ?: "")}\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            // The upload keystore (cli-pulse-upload.jks) is gitignored, so CI
            // doesn't have it. Fall back to debug signing when it's absent so
            // CI still validates the release build (compile + R8/minify) and
            // the job goes green on the real signal (unit tests + release
            // compile). Local + release pipelines have the keystore present
            // and sign with the real upload key. Never distribute a CI artifact.
            signingConfig = if (file("cli-pulse-upload.jks").exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    // Room schema export for migration testing
    ksp {
        arg("room.schemaLocation", "$projectDir/schemas")
    }

    testOptions {
        unitTests.all {
            it.jvmArgs("-Xmx1g")
        }
    }
}

// Sentry Gradle plugin — auto-uploads ProGuard/R8 mapping files for release
// builds and writes a debug-meta resource so the SDK matches events to the
// right release. Without this, R8-minified release crashes show as
// `a.b.c.d(:42)` in Sentry instead of real class/method names.
//
// Auth token is read from the SENTRY_AUTH_TOKEN env var. Source it from
// ~/Library/Application Support/CLI-Pulse-Secrets/sentry-cli-auth-token-2026-04-29.txt
// before running `./gradlew assembleRelease`. If the env var is unset the
// plugin skips the upload (release artifact still builds).
sentry {
    org.set("jason-yeyuhe")
    projectName.set("android")

    // Gate the upload on whether SENTRY_AUTH_TOKEN is present at configure
    // time. False ⇒ the upload task is wired but immediately skipped, so
    // building offline / on a fresh checkout never fails.
    val hasSentryToken = !System.getenv("SENTRY_AUTH_TOKEN").isNullOrEmpty()
    autoUploadProguardMapping.set(hasSentryToken)
    includeProguardMapping.set(true)

    // Don't ship source code — only mapping. Stack traces with original
    // class/method names are sufficient and we keep source local.
    includeSourceContext.set(false)

    // Skip telemetry pings to Sentry's plugin-usage endpoint.
    telemetry.set(false)

    // Don't auto-instrument okhttp/sqlite/etc — the SDK is already configured
    // explicitly in SentryInit.kt with privacy-conservative defaults
    // (sendDefaultPii=false, tracesSampleRate=0). Avoid any side effects from
    // build-time bytecode injection that could change runtime behavior.
    tracingInstrumentation {
        enabled.set(false)
    }
}

dependencies {
    // Compose
    val composeBom = platform(libs.compose.bom)
    implementation(composeBom)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    // v1.21 E2: NavigationSuiteScaffold auto-switches between NavigationBar
    // (phone, compact width) and NavigationRail / Drawer (tablet, foldable,
    // expanded width) based on window size class.
    implementation(libs.compose.material3.adaptive.nav.suite)
    implementation(libs.compose.material.icons)
    debugImplementation(libs.compose.ui.tooling)

    // Navigation
    implementation(libs.navigation.compose)

    // Lifecycle
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)

    // Activity
    implementation(libs.activity.compose)

    // Core
    implementation(libs.core.ktx)

    // v1.22 S5 — Glance app-widget (Swarm at-a-glance)
    implementation(libs.glance.appwidget)

    // Hilt
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)

    // Networking
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging)
    implementation(libs.moshi)
    implementation(libs.moshi.kotlin)
    ksp(libs.moshi.codegen)

    // Auth
    implementation(libs.credentials)
    implementation(libs.credentials.play)
    implementation(libs.google.id)

    // Storage
    implementation(libs.datastore.preferences)
    implementation(libs.security.crypto)

    // Billing
    implementation(libs.billing.ktx)

    // Background
    implementation(libs.work.runtime)
    implementation(libs.hilt.work)
    ksp(libs.hilt.work.compiler)

    // Coroutines
    implementation(libs.coroutines.android)

    // Firebase
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)

    // Room
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)

    // Image loading
    implementation(libs.coil.compose)

    // Crash reporting
    implementation(libs.sentry.android.core)

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("io.mockk:mockk:1.13.13")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("app.cash.turbine:turbine:1.2.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    // Android's `android.jar` ships `org.json` as throw-only stubs for unit
    // tests; without a real impl, `optJSONArray`/`optJSONObject` etc. raise
    // `RuntimeException: Method ... not mocked`. The Maven artifact below
    // provides the real implementation on the test classpath so collectors
    // that parse JSON (Claude, Codex, Gemini, …) are exercisable in plain
    // JVM unit tests without pulling in Robolectric.
    testImplementation("org.json:json:20240303")
}
