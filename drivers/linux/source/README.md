# Linux native source

CMake source for the Kinect Xbox 360 Remold Linux runtime.

The normal repository build entry point is `bash Kinect-Xbox-360-Remold.sh`. `scripts/build.sh` keeps CMake intermediates outside this source directory and publishes only to the root `binaries/linux/{drivers,sdk}` tree.

Hardware services use libusb, ALSA, OpenCV and v4l2loopback. `REMOLD_BUILD_HARDWARE=OFF` is available for host-independent compilation of the control client and SDK service.
