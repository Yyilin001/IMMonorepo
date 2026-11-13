#include "ProbeJNI.h"
#include <jni.h>
#include <string.h>

JNIEXPORT jlong JNICALL Java_com_xmtx_im_swiftprobe_NativeProbe_start(JNIEnv *env, jobject self, jbyteArray input) {
    if (!input) return 0;
    jsize count = (*env)->GetArrayLength(env, input);
    jbyte *bytes = (*env)->GetByteArrayElements(env, input, NULL);
    if (!bytes) return 0;
    int64_t result = im_probe_start((const uint8_t *)bytes, count);
    (*env)->ReleaseByteArrayElements(env, input, bytes, JNI_ABORT);
    return result;
}
JNIEXPORT jbyteArray JNICALL Java_com_xmtx_im_swiftprobe_NativeProbe_poll(JNIEnv *env, jobject self, jlong handle) {
    char *value = im_probe_poll(handle);
    if (!value) return NULL;
    size_t count = strlen(value);
    jbyteArray result = (*env)->NewByteArray(env, (jsize)count);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)count, (const jbyte *)value);
    im_probe_free(value);
    return result;
}
JNIEXPORT void JNICALL Java_com_xmtx_im_swiftprobe_NativeProbe_cancel(JNIEnv *env, jobject self, jlong handle) { im_probe_cancel(handle); }
JNIEXPORT jint JNICALL Java_com_xmtx_im_swiftprobe_NativeProbe_release(JNIEnv *env, jobject self, jlong handle) { return im_probe_release(handle); }
JNIEXPORT jint JNICALL Java_com_xmtx_im_swiftprobe_NativeProbe_active(JNIEnv *env, jobject self) { return im_probe_active(); }
