.PHONY: all android linux clean

all: linux android

android:
	sh ./native/build-android.sh

linux:
	sh ./native/build-linux.sh

clean:
	rm -rf build libs native/vendor native/bridge/target
