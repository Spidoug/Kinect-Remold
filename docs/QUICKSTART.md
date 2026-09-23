# Quick start

## Windows

1. Extract the source ZIP to a normal writable directory.
2. Run `Kinect-Xbox-360-Remold.cmd` from an ordinary Command Prompt.
3. Run `binaries\windows\drivers\KINECT.cmd` and choose **Install / Reinstall**.
4. Launch `binaries\windows\applications\SynKinectStudio\SynKinectStudio.vbs`. It starts the Studio without a console window; the `.cmd` entry point immediately hands off to the same hidden launcher.

The build creates one virtual camera and one Remold audio/audio-control endpoint per detected Kinect identity. Hot-plugged Kinects are reconciled by the resident runtime.

## Linux

1. Extract the source ZIP.
2. Run `bash Kinect-Xbox-360-Remold.sh`.
3. Run `sudo binaries/linux/drivers/INSTALL.sh`.
4. Launch `binaries/linux/applications/SynKinectStudio/SynKinectStudio.desktop` from the desktop environment, or run `SynKinectStudio.sh`. The launcher detaches the Studio from the terminal so only the application window remains.

Linux installation is performed only by the generated scripts. The current build does not create or install native package-manager packages.

## Device lifecycle

The Studio discovers devices from the capability manifest. A Kinect remains represented while it is `Booting` or `Reconnecting`; controls are enabled only when their required endpoint reports ready.
