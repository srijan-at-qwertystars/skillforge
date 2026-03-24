// gradle-coroutines.kts — Gradle build configuration for Kotlin Coroutines projects
//
// Usage: Copy relevant sections into your build.gradle.kts
//
// Includes dependencies for:
//   - kotlinx-coroutines-core
//   - kotlinx-coroutines-android
//   - kotlinx-coroutines-test
//   - kotlinx-coroutines-play-services
//   - kotlinx-coroutines-reactive / rx3 / jdk9
//   - Ktor (client + server)
//   - Room, Retrofit, WorkManager
//   - Turbine (Flow testing)

plugins {
    kotlin("jvm") version "2.0.21"
    // For Android:
    // id("com.android.application") version "8.7.0"
    // kotlin("android") version "2.0.21"
    kotlin("plugin.serialization") version "2.0.21"
}

val coroutinesVersion = "1.9.0"
val ktorVersion = "3.0.1"
val roomVersion = "2.6.1"
val lifecycleVersion = "2.8.7"
val workVersion = "2.10.0"

repositories {
    mavenCentral()
    google()
}

dependencies {
    // ══════════════════════════════════════════
    // Core Coroutines
    // ══════════════════════════════════════════
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:$coroutinesVersion")

    // Android coroutines support (Dispatchers.Main)
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:$coroutinesVersion")

    // ══════════════════════════════════════════
    // Testing
    // ══════════════════════════════════════════
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:$coroutinesVersion")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-debug:$coroutinesVersion")
    testImplementation("app.cash.turbine:turbine:1.2.0")
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.3")
    testImplementation("kotlin-test")

    // ══════════════════════════════════════════
    // Reactive Interop
    // ══════════════════════════════════════════
    // RxJava 3 bridge
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-rx3:$coroutinesVersion")

    // Reactive Streams bridge
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-reactive:$coroutinesVersion")

    // JDK 9+ Flow bridge
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-jdk9:$coroutinesVersion")

    // Java 8 CompletableFuture integration
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-jdk8:$coroutinesVersion")

    // Google Play Services (Tasks API)
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:$coroutinesVersion")

    // SLF4J MDC context propagation
    // implementation("org.jetbrains.kotlinx:kotlinx-coroutines-slf4j:$coroutinesVersion")

    // ══════════════════════════════════════════
    // Ktor (Server)
    // ══════════════════════════════════════════
    // implementation("io.ktor:ktor-server-core:$ktorVersion")
    // implementation("io.ktor:ktor-server-netty:$ktorVersion")
    // implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    // implementation("io.ktor:ktor-server-websockets:$ktorVersion")
    // implementation("io.ktor:ktor-server-status-pages:$ktorVersion")
    // implementation("io.ktor:ktor-serialization-kotlinx-json:$ktorVersion")
    // testImplementation("io.ktor:ktor-server-test-host:$ktorVersion")

    // ══════════════════════════════════════════
    // Ktor (Client)
    // ══════════════════════════════════════════
    // implementation("io.ktor:ktor-client-core:$ktorVersion")
    // implementation("io.ktor:ktor-client-cio:$ktorVersion")           // CIO engine
    // implementation("io.ktor:ktor-client-okhttp:$ktorVersion")        // OkHttp engine (Android)
    // implementation("io.ktor:ktor-client-content-negotiation:$ktorVersion")
    // implementation("io.ktor:ktor-client-logging:$ktorVersion")
    // testImplementation("io.ktor:ktor-client-mock:$ktorVersion")

    // ══════════════════════════════════════════
    // Android Lifecycle + ViewModel
    // ══════════════════════════════════════════
    // implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:$lifecycleVersion")
    // implementation("androidx.lifecycle:lifecycle-runtime-ktx:$lifecycleVersion")
    // implementation("androidx.lifecycle:lifecycle-runtime-compose:$lifecycleVersion")  // collectAsStateWithLifecycle
    // implementation("androidx.lifecycle:lifecycle-livedata-ktx:$lifecycleVersion")

    // ══════════════════════════════════════════
    // Room Database
    // ══════════════════════════════════════════
    // implementation("androidx.room:room-runtime:$roomVersion")
    // implementation("androidx.room:room-ktx:$roomVersion")  // suspend + Flow support
    // ksp("androidx.room:room-compiler:$roomVersion")
    // testImplementation("androidx.room:room-testing:$roomVersion")

    // ══════════════════════════════════════════
    // Retrofit
    // ══════════════════════════════════════════
    // implementation("com.squareup.retrofit2:retrofit:2.11.0")
    // implementation("com.squareup.retrofit2:converter-kotlinx-serialization:2.11.0")

    // ══════════════════════════════════════════
    // WorkManager
    // ══════════════════════════════════════════
    // implementation("androidx.work:work-runtime-ktx:$workVersion")  // CoroutineWorker
    // testImplementation("androidx.work:work-testing:$workVersion")

    // ══════════════════════════════════════════
    // Serialization
    // ══════════════════════════════════════════
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
}

tasks.test {
    useJUnitPlatform()
    // Enable coroutine debug mode in tests
    jvmArgs("-Dkotlinx.coroutines.debug")
}

kotlin {
    jvmToolchain(21)
}
