import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningFile = providers.gradleProperty("imFlutterSigningFile").orNull?.let { rootProject.file(it) }
    ?: File(System.getProperty("user.home"), ".android/im-flutter-release/signing.properties")

android {
    namespace = "dev.local.local_im"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xmtx.im.flutterexample"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 31
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Replace Flutter's default multi-ABI filters for both APK and AAB.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    signingConfigs {
        if (releaseSigningFile.isFile) {
            val settings = Properties().apply { releaseSigningFile.inputStream().use { load(it) } }
            create("release") {
                storeFile = releaseSigningFile.resolveSibling(settings.getProperty("storeFile"))
                storePassword = settings.getProperty("storePassword")
                keyAlias = settings.getProperty("keyAlias")
                keyPassword = settings.getProperty("keyPassword")
            }
        }
    }

    buildTypes.getByName("release").signingConfig = signingConfigs.findByName("release")
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        // Compress the Flutter and Swift native libraries in the downloadable APK.
        variant.packaging.jniLibs.useLegacyPackaging.set(true)
        variant.packaging.jniLibs.useLegacyPackagingFromBundle.set(true)
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

// Test runner supplies a disposable localhost CA only to an isolated debug APK.
providers.environmentVariable("IM_FLUTTER_TEST_OVERLAY").orNull?.let { overlay ->
    val debug = extensions.getByType<com.android.build.gradle.BaseExtension>().sourceSets.getByName("debug")
    debug.manifest.srcFile(file("$overlay/AndroidManifest.xml"))
    debug.res.srcDir(file("$overlay/res"))
    android.buildTypes.getByName("debug").applicationIdSuffix = ".verification"
}
