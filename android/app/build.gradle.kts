plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.moqapp.moq_flutter"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

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
                // Use ring crypto backend for Android (aws-lc-rs has cross-compilation issues)
                commandLine(cargoExe, "build", "--lib", "--target", rustTarget, "--no-default-features", "--features", "ring", buildFlag)

                // Set up environment for NDK toolchain
                val ndkRoot = System.getenv("ANDROID_NDK_ROOT")
                    ?: "${System.getenv("ANDROID_HOME") ?: "/home/mondain/Android/Sdk"}/ndk/27.0.12077973"
                val toolchainBin = "$ndkRoot/toolchains/llvm/prebuilt/linux-x86_64/bin"
                val currentPath = System.getenv("PATH") ?: ""

                environment(
                    "CARGO_TERM_COLOR" to "always",
                    "ANDROID_NDK_ROOT" to ndkRoot,
                    "PATH" to "$toolchainBin:$currentPath",
                    // Set explicit CC for the target
                    "CC_aarch64-linux-android" to "$toolchainBin/aarch64-linux-android21-clang",
                    "CC_armv7-linux-androideabi" to "$toolchainBin/armv7a-linux-androideabi21-clang",
                    "CC_x86_64-linux-android" to "$toolchainBin/x86_64-linux-android21-clang",
                    "CC_i686-linux-android" to "$toolchainBin/i686-linux-android21-clang",
                    "AR_aarch64-linux-android" to "$toolchainBin/llvm-ar",
                    "AR_armv7-linux-androideabi" to "$toolchainBin/llvm-ar",
                    "AR_x86_64-linux-android" to "$toolchainBin/llvm-ar",
                    "AR_i686-linux-android" to "$toolchainBin/llvm-ar"
                )
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
