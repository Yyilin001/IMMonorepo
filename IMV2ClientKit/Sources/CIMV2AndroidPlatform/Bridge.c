#include "CIMV2AndroidPlatform.h"
#include <stdlib.h>
#include <string.h>
#ifdef __ANDROID__
#include <jni.h>
#include <pthread.h>
static JavaVM *vm;
static jobject host;
static jmethodID perform;
static pthread_mutex_t install_lock = PTHREAD_MUTEX_INITIALIZER;
JNIEXPORT jboolean JNICALL Java_com_xmtx_im_swiftplatform_AndroidRuntimePlatform_nativeInstall(JNIEnv *env, jobject self) {
    pthread_mutex_lock(&install_lock);
    jboolean success = JNI_FALSE;
    if (!host) {
        jclass cls = (*env)->GetObjectClass(env, self);
        jmethodID method = (*env)->GetMethodID(env, cls, "perform", "(IJLjava/lang/String;[BI)[B");
        (*env)->DeleteLocalRef(env, cls);
        if (method && (*env)->GetJavaVM(env, &vm) == JNI_OK) {
            host = (*env)->NewGlobalRef(env, self);
            perform = method;
            success = host != NULL;
        }
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
    pthread_mutex_unlock(&install_lock);
    return success;
}
#endif
IMV2AndroidResult im_v2_android_call(int32_t operation, int64_t handle, const char *name, const uint8_t *bytes, size_t count, int32_t value) {
    IMV2AndroidResult result = {2, NULL, 0};
#ifdef __ANDROID__
    pthread_mutex_lock(&install_lock);
    JavaVM *machine = vm; jobject instance = host; jmethodID method = perform;
    pthread_mutex_unlock(&install_lock);
    if (!machine || !instance || count > 2097152) return result;
    JNIEnv *env = NULL;
    int attached = 0;
    jint state = (*machine)->GetEnv(machine, (void **)&env, JNI_VERSION_1_6);
    if (state == JNI_EDETACHED) {
        if ((*machine)->AttachCurrentThread(machine, &env, NULL) != JNI_OK) return result;
        attached = 1;
    } else if (state != JNI_OK) return result;
    if ((*env)->PushLocalFrame(env, 8) != JNI_OK) goto done;
    jstring key = name ? (*env)->NewStringUTF(env, name) : NULL;
    jbyteArray input = (*env)->NewByteArray(env, (jsize)count);
    if (input && count) (*env)->SetByteArrayRegion(env, input, 0, (jsize)count, (const jbyte *)bytes);
    if ((*env)->ExceptionCheck(env)) goto pop;
    jbyteArray output = (*env)->CallObjectMethod(env, instance, method, operation, (jlong)handle, key, input, value);
    if ((*env)->ExceptionCheck(env) || !output) goto pop;
    jsize length = (*env)->GetArrayLength(env, output);
    if (length < 4 || length > 2162696) goto pop;
    uint8_t header[4];
    (*env)->GetByteArrayRegion(env, output, 0, 4, (jbyte *)header);
    result.status = (int32_t)(((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3]);
    if (length > 4) {
        result.bytes = malloc((size_t)length - 4);
        if (!result.bytes) { result.status = 2; goto pop; }
        result.count = (size_t)length - 4;
        (*env)->GetByteArrayRegion(env, output, 4, length - 4, (jbyte *)result.bytes);
    }
pop:
    (*env)->PopLocalFrame(env, NULL);
done:
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        free(result.bytes); result = (IMV2AndroidResult){2, NULL, 0};
    }
    if (attached) (*machine)->DetachCurrentThread(machine);
#endif
    return result;
}
void im_v2_android_free(IMV2AndroidResult result) { free(result.bytes); }
