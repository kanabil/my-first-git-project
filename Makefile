build: Hello.class libhello.so

Hello.class:
	javac Hello.java	

libhello.so:
	gcc -fPIC -I/usr/lib/jvm/java-7-openjdk-amd64/include -I/usr/lib/jvm/java-7-openjdk-amd64/include/linux -shared -o libhello.so Hello.c

test: Hello.class libhello.so
	java -Djava.library.path=. Hello

clean:
	rm libhello.so Hello.class
