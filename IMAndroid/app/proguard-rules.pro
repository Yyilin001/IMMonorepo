# Protobuf Lite looks up generated message fields when building its runtime schema.
# Match the upstream v33.0 java/lite/proguard.pgcfg rule; unused classes may still be removed.
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}
