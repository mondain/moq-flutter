plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.moqapp.moq_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.moqapp.moq_flutter"
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

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }
}

// Rust FFI library build configuration
val rustProjectDir = projectDir.resolve("../../native/moq_quic")

// Task to build Rust library for all Android ABIs
val buildRustLibs = tasks.register("buildRustLibs") {
    doLast {
        if (!rustProjectDir.exists()) {
            println("Rust project directory not found: $rustProjectDir")
            return@doLast
        }

        val cargoExe = if (System.getProperty("os.name").toLowerCase().contains("windows")) {
            "cargo.exe"
        } else {
            "cargo"
        }

        // Check if cargo is available
        val process = ProcessBuilder(cargoExe, "--version")
            .redirectErrorStream(true)
            .start()

        if (process.waitFor() != 0) {
            println("Cargo not found. Skipping Rust library build.")
            return@doLast
        }

        println("Building Rust library for Android...")

        // Android ABIs to build for
        val androidAbis = listOf(
            "aarch64-linux-android" to "arm64-v8a",
            "armv7-linux-androideabi" to "armeabi-v7a",
            "x86_64-linux-android" to "x86_64",
            "i686-linux-android" to "x86"
        )

        // Determine build profile
        val profile = if (name.contains("debug")) "dev" else "release"
        val buildFlag = if (name.contains("debug")) "" else "--release"

        androidAbis.forEach { (rustTarget, _) ->
            println("Installing Rust target: $rustTarget")
            exec {
                commandLine("rustup", "target", "add", rustTarget)
                isIgnoreExitValue = true
            }

            println("Building for $rustTarget...")
            exec {
                workingDir(rustProjectDir)
                commandLine(cargoExe, "build", "--lib", "--target", rustTarget, buildFlag)
                environment("CARGO_TERM_COLOR" to "always")
            }
        }

        println("Rust library build completed")
    }
}

// Task to copy built Rust libraries to jniLibs
tasks.register<Copy>("copyRustLibs") {
    dependsOn(buildRustLibs)

    val jniLibsDir = projectDir.resolve("src/main/jniLibs")
    val profile = if (name.contains("debug")) "debug" else "release"

    val androidAbis = mapOf(
        "aarch64-linux-android" to "arm64-v8a",
        "armv7-linux-androideabi" to "armeabi-v7a",
        "x86_64-linux-android" to "x86_64",
        "i686-linux-android" to "x86"
    )

    androidAbis.forEach { (rustTarget, androidAbi) ->
        from(rustProjectDir.resolve("target/$rustTarget/$profile")) {
            include("*.so")
            into(androidAbi)
        }
    }

    into(jniLibsDir)
}

// Hook Rust build into Flutter build
afterEvaluate {
    tasks.named("assembleDebug").configure {
        dependsOn(buildRustLibs)
        finalizedBy("copyRustLibs")
    }

    tasks.named("assembleRelease").configure {
        dependsOn(buildRustLibs)
        finalizedBy("copyRustLibs")
    }
}

flutter {
    source = "../.."
}
