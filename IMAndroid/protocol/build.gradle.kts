plugins { `java-library`; id("com.google.protobuf") }
java { toolchain { languageVersion.set(JavaLanguageVersion.of(17)) } }
sourceSets.main { proto { srcDir("../../Protocol") ; include("im_realtime/v2/*.proto") } }
dependencies { api("com.google.protobuf:protobuf-javalite:4.33.0") }
protobuf {
    protoc { artifact = "com.google.protobuf:protoc:4.33.0" }
    generateProtoTasks { all().configureEach { builtins { named("java") { option("lite") } } } }
}
