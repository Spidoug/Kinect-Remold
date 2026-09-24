# Native IP Camera Runtime on Linux

`kinect360-remold-camera-ip` is an optional, authenticated, read-only HTTP/MJPEG consumer of the camera bridge. It does not open the Kinect USB interface itself and does not control Tilt, LED, RGB/IR mode or firmware state.

## Secure default

`INSTALL.sh` installs the feature **disabled** with `ip.bind=127.0.0.1`. It generates a strong random password through a `0600` temporary file and atomically installs the runtime policy as `/etc/kinect360-remold/remold.conf` with mode `0640`, owner `root`, and group `kinect360-remold-ip`. The containing directory is `0750 root:kinect360-remold-ip`, so there is no first-install interval where the generated secret is world-readable.

The service runs under the dedicated unprivileged account `kinect360-remold-ip`, with `video` only as a supplementary group so it can read the selected Kinect camera socket. The systemd unit applies `NoNewPrivileges`, private temporary storage, protected system/home/kernel state, namespace restrictions, an empty capability bounding set, a restrictive umask, and only the address families needed by the service.

Normal status output never reveals `ip.password`. Showing credentials, rotating the password, enabling/disabling the service and switching network mode require administrator elevation through `KINECT.sh`.


## Device selection

`ip.device_id` pins the stream to one stable Kinect `deviceId`. When the control panel enables IP streaming and this field is still empty, it writes the selected/first Ready Kinect into the configuration before starting the service. Direct/manual configurations may explicitly leave it empty for automatic selection, but that behavior is not the normal secure control-panel path. The service connects to that Kinect's existing camera socket; it never opens a second libusb session.

## LAN mode

Loopback-only mode uses `127.0.0.1`. Explicit LAN mode uses `0.0.0.0`, but the server independently rejects source addresses outside IPv4 loopback, RFC1918 private space, link-local space and CGNAT shared-address space. This is a second boundary; it is not a replacement for a host firewall.

The built-in transport is HTTP Basic and is not encrypted. Do not expose TCP 8088 directly to the public internet. For access outside a trusted private network, use a VPN or TLS reverse proxy.

## HTTP hardening

The server accepts only `GET` to `/`, `/index.html`, `/snapshot.jpg`, `/stream.mjpg` and `/status.json`. It bounds request-header size, requires `Host` for HTTP/1.1, rejects transfer encoding and GET request bodies, applies socket I/O timeouts and limits simultaneous clients.

Authentication comparison is constant-time. Repeated failed credentials from one source are temporarily blocked. Responses carry restrictive browser-security headers and the viewer receives a restrictive Content Security Policy.

## Local IPC boundary

The IP-camera service consumes the same local camera endpoint as SynKinect Studio. Product-local UNIX sockets are available to local desktop clients immediately after installation; direct USB/V4L2 nodes remain governed by udev/logind and the standard `video`/`audio` groups. The IP service itself still runs under the dedicated `kinect360-remold-ip` account and retains its independent network/authentication boundary.

The IP-camera unit is not part of the default runtime target. Enabling it through `KINECT.sh` persists the choice with systemd (`enable --now`); disabling it removes that boot-time activation (`disable --now`).
