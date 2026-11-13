-keep class com.xmtx.im.swiftprobe.NativeProbe { *; }
# The probe API is invoked by the separate instrumentation APK.
-keep class com.xmtx.im.swiftprobe.SwiftProbe { *; }
# Instrumentation shares these libraries with the tested APK. R8 cannot infer
# all entry points from the separately packaged runner; preserve this test ABI.
-keep class kotlin.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class com.xmtx.im.swiftprobe.R$raw { *; }
