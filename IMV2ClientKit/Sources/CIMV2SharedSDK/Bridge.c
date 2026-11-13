#include "CIMV2SharedSDK.h"
#ifdef __ANDROID__
#include <jni.h>
#include <string.h>
static jlong input(JNIEnv *env, jbyteArray bytes, jlong client, int create) {
    if (!bytes) return 0;
    jsize count = (*env)->GetArrayLength(env, bytes);
    if (count <= 0 || count > 1048576) return 0;
    jbyte *data = (*env)->GetByteArrayElements(env, bytes, NULL);
    if (!data) return 0;
    int64_t id = create ? im_shared_create((uint8_t *)data, count) : im_shared_submit(client, (uint8_t *)data, count);
    (*env)->ReleaseByteArrayElements(env, bytes, data, JNI_ABORT);
    return id;
}
JNIEXPORT jlong JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_create(JNIEnv *env, jobject self, jbyteArray bytes) { return input(env, bytes, 0, 1); }
JNIEXPORT jlong JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_submit(JNIEnv *env, jobject self, jlong client, jbyteArray bytes) { return input(env, bytes, client, 0); }
JNIEXPORT jbyteArray JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_poll(JNIEnv *env, jobject self, jlong id) {
    char *value = im_shared_poll(id);
    if (!value) return NULL;
    size_t length = strlen(value);
    jbyteArray result = (*env)->NewByteArray(env, (jsize)length);
    if (result) (*env)->SetByteArrayRegion(env, result, 0, (jsize)length, (jbyte *)value);
    im_shared_free(value);
    return result;
}
JNIEXPORT void JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_cancel(JNIEnv *env, jobject self, jlong id) { im_shared_cancel(id); }
JNIEXPORT jint JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_release(JNIEnv *env, jobject self, jlong id) { return im_shared_release(id); }
JNIEXPORT jint JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_releaseClient(JNIEnv *env, jobject self, jlong id) { return im_shared_release_client(id); }
JNIEXPORT jint JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_active(JNIEnv *env, jobject self) { return im_shared_active(); }
JNIEXPORT jint JNICALL Java_com_xmtx_im_sharedsdk_NativeSharedSDK_clients(JNIEnv *env, jobject self) { return im_shared_clients(); }
#endif
