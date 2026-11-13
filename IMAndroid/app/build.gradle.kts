import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

plugins { id("com.android.application"); kotlin("android"); kotlin("plugin.serialization"); id("org.jetbrains.kotlin.plugin.compose") }

// Opt-in isolated-backend trust. No certificate or configuration is added to a normal Debug or Release build.
val fixtureCa = providers.gradleProperty("imDebugTestCaFile").orNull
val fixtureResources = layout.buildDirectory.dir("generated/isolatedBackendTrust/res")
val generateFixtureTrust = fixtureCa?.let { path ->
    tasks.register("generateIsolatedBackendTrust") {
        val certificate = file(path)
        inputs.file(certificate); inputs.dir("src/debug/res"); outputs.dir(fixtureResources)
        doLast {
            val pem = certificate.readText()
            require(pem.length <= 65536 && !pem.contains("PRIVATE KEY"))
            val parsed = CertificateFactory.getInstance("X.509")
                .generateCertificates(pem.byteInputStream())
            require(parsed.isNotEmpty() && parsed.all { (it as X509Certificate).basicConstraints >= 0 })
            val root = fixtureResources.get().asFile
            root.deleteRecursively();root.resolve("raw").mkdirs();root.resolve("xml").mkdirs()
            project.copy { from("src/debug/res"); into(root) }
            root.resolve("raw/isolated_backend_ca.pem").writeText(pem)
            root.resolve("xml/debug_network_security.xml").writeText("""
                <network-security-config>
                    <base-config cleartextTrafficPermitted="false"><trust-anchors><certificates src="system" /></trust-anchors></base-config>
                    <debug-overrides><trust-anchors><certificates src="user" /><certificates src="@raw/isolated_backend_ca" /></trust-anchors></debug-overrides>
                </network-security-config>
            """.trimIndent())
        }
    }
}
android {
    namespace = "com.xmtx.im"
    compileSdk = 36
    if (fixtureCa != null) sourceSets.getByName("debug").res.setSrcDirs(listOf(fixtureResources))
    defaultConfig {
        ndk { abiFilters += "arm64-v8a" }
        applicationId = "com.xmtx.im.android"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true; buildConfig = true }
    buildTypes {
        if (providers.gradleProperty("imSharedSDKVerification").orNull == "true") getByName("debug") { applicationIdSuffix = ".sharedverification" }
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        // Smaller distribution packages; Android extracts the native libraries on install.
        variant.packaging.jniLibs.useLegacyPackaging.set(true)
        variant.packaging.jniLibs.useLegacyPackagingFromBundle.set(true)
    }
}
if (generateFixtureTrust != null) tasks.configureEach { if (name == "preDebugBuild") dependsOn(generateFixtureTrust) }
kotlin { jvmToolchain(17) }
dependencies {
    testImplementation("junit:junit:4.13.2")
    implementation(project(":sharedsdk"))
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation(platform("androidx.compose:compose-bom:2025.12.00"))
    implementation("androidx.activity:activity-compose:1.12.1")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("androidx.navigation3:navigation3-runtime:1.0.0")
    implementation("androidx.navigation3:navigation3-ui:1.0.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.12.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("com.squareup.okhttp3:okhttp:4.12.0")
    androidTestImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
}
