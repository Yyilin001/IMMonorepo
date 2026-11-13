# AndroidX Test references these compile-time Error Prone annotations. They are
# not runtime APIs. Keep suppression limited to the instrumentation APK.
-dontwarn com.google.errorprone.annotations.CanIgnoreReturnValue
-dontwarn com.google.errorprone.annotations.MustBeClosed
-keep class com.xmtx.im.swiftprobe.SwiftProbeTests { *; }
