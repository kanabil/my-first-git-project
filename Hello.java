public class Hello {

    static {
        System.loadLibrary("hello"); // => libhello.so
    }

    private native void sayHello();

    public static void main(String[] args) {

        new Hello().sayHello();

    }
}
