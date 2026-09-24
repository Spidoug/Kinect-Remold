# Native IP Camera Runtime

`Kinect360RemoldCameraIp.exe` is an optional Windows user-mode service. It is a read-only consumer of the RGB publication produced by the physical camera bridge; it does not open the Kinect USB device and cannot switch RGB/IR/depth modes.

## Data path

```text
Xbox NUI Camera (02AE)
        |
        v
Microsoft winusb.sys
        |
        v
Kinect360RemoldCameraBridge.exe
        |
        +--> Global\Kinect360RemoldFrame-<device-id> (NV12 RGB)
                 |                         |
                 |                         +--> Media Foundation virtual camera [same device-id]
                 |
                 +--> Kinect360RemoldCameraIp.exe
                          |
                          +--> /                 HTML viewer
                          +--> /stream.mjpg      MJPEG stream
                          +--> /snapshot.jpg     JPEG snapshot
                          +--> /status.json      runtime status
```

The IP service can be pinned to one stable `deviceId` from the capability manifest and opens only that Kinect's read-only shared frame mapping. The control panel pins the selected/Ready Kinect when the feature is enabled, so reconnecting does not silently switch the network stream to another sensor. It never claims `\\.\pipe\Kinect360RemoldScanner-<device-id>` and never opens a second physical USB session.

## Secure default

Installation leaves the IP camera **disabled** and bound to `127.0.0.1`. Installation does not expose a TCP port to the LAN. Enabling LAN mode is an explicit administrator action.

The deployment defaults in `build/Product.psd1` are:

- disabled;
- loopback bind `127.0.0.1`;
- TCP port `8088`;
- eight encoded frames per second;
- JPEG quality 78;
- at most four concurrent clients.

When LAN mode is explicitly enabled, the service binds `0.0.0.0`, rejects non-private/non-link-local IPv4 peers in the application itself, and the installer/control panel creates a Windows Firewall rule only for the **Private** profile and `LocalSubnet`.

## Authentication and secrets

All content routes require HTTP Basic authentication. A strong random password is generated with Windows CNG (`BCryptGenRandom`). The password is never compiled into the runtime and normal `status` output never prints it.

Secret configuration is stored at:

```text
%ProgramData%\Kinect Xbox 360 Remold\camera-ip.ini
```

Its ACL grants full access to LocalSystem and Administrators and read access to LocalService, because the IP-camera service runs as `NT AUTHORITY\LocalService` rather than LocalSystem.

A separate non-secret status file is stored at:

```text
%ProgramData%\Kinect Xbox 360 Remold\camera-ip-public.ini
```

It contains only enabled/bind/port/user/status information and may be read by ordinary local users. Credentials are shown only through the explicit administrator command in the Kinect control panel. Password rotation is also administrator-only.


## HTTP hardening

The built-in server intentionally has a small read-only surface. It accepts only `GET`, exact known routes, HTTP/1.0 or HTTP/1.1, and bounded request headers. HTTP/1.1 requires `Host`; transfer encoding and GET request bodies are rejected. Client receive/send timeouts and a configured concurrent-client limit prevent idle connections from holding resources indefinitely.

Authentication comparison is constant-time. Repeated failed authentication attempts from one source are temporarily rate-limited. Responses include `nosniff`, no-referrer, same-origin resource, frame-deny and restrictive permissions headers; the HTML viewer also receives a restrictive Content Security Policy.

The service process runs as LocalService with no need to access the physical camera. The shared RGB mapping grants LocalService read-only access; the separate frame consumer lease is writable so an authenticated viewer counts as an active frame consumer, like a Linux ScannerPort subscription.

## Transport boundary

HTTP Basic authentication is **not encryption**. A Basic credential and video stream can be observed by an attacker who can intercept the HTTP connection. Therefore direct exposure to the public internet is unsupported. For access outside a trusted private network, use a VPN or a TLS reverse proxy and keep the Remold service on loopback/private LAN only.

## RGB / IR hardware limitation

The Kinect 1414 has one physical video engine on endpoint `0x81`; RGB and raw IR are mutually exclusive. The IP runtime consumes RGB only when the selected Kinect publishes it. SynKinect Studio Surveillance may temporarily own the RGB/IR day/night switch; when Surveillance releases IR it returns the hardware to RGB so Scanner, Interactivity, virtual-camera and IP-camera RGB consumers can resume normally.
