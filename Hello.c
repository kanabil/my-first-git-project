#include <jni.h>
#include <stdio.h>
#include "Hello.h"

JNIEXPORT void JNICALL Java_Hello_sayHello(JNIEnv *env, jobject thisObj)
{
    printf("Hello World with may odifications!\n");
    return;
}
