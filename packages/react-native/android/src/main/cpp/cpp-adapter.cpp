#include <jni.h>
#include "crumbsdk_reactnativeOnLoad.hpp"

#include <fbjni/fbjni.h>

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return facebook::jni::initialize(vm, []() {
    margelo::nitro::crumbsdk_reactnative::registerAllNatives();
  });
}
