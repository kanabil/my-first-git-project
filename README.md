Simple HelloWorld in C with Java [![Build Status](https://travis-ci.org/charlycoste/jni-example.svg?branch=master)](https://travis-ci.org/charlycoste/jni-example)
================================

This sample is for Ubuntu/Debian environment

Why this project ?
------------------

This is just a "Hello world" sample to explain how someone could compile a library written in C language and use it
in a Java program without having to rewrite the whole library itself in Java.

How to test ?
-------------

You would probably have the `make` command installed on your system, the `gcc` compiler, and the `javac` command provided
by the Java SDK.
If you don't have these tools installed on your environment, you may install it the easy way :

On debian, as root :

    # aptitude install make gcc openjdk-7-jdk

On Ubuntu, using sudo :

    $ sudo apt-get install make gcc openjdk-7-jdk
    
Microsoft Windows® or Apple MacOS® are supposed to be much more easier than GNU/Linux so you may find yourself how to do
the same on these systems.

To test it, just clone the repo, then type `make` as a simple user :

    $ git clone https://github.com/charlycoste/jni-example.git
    $ cd jni-example
    $ make test

If you don't want to use the `make` command and do everything yourself, you can do each step of compilation yourself :

    $ javac Hello.java
    $ gcc -fPIC -I/usr/lib/jvm/java-7-openjdk-amd64/include -I/usr/lib/jvm/java-7-openjdk-amd64/include/linux -shared -o libhello.so Hello.c
    $ java -Djava.library.path=. Hello
