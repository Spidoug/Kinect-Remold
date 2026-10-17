#pragma once
#include <guiddef.h>

namespace Kinect360RemoldVirtualCamera {
// Activation attribute copied by the Microsoft virtual-camera media source into
// its source attribute store. It binds one virtual camera instance to one
// physical Kinect identity for the entire source/stream lifetime.
inline constexpr GUID kDeviceIdAttribute =
{ 0x3ab4771f, 0x4b45, 0x4f67, { 0x9c, 0x20, 0xc0, 0x4d, 0x5b, 0x96, 0xf7, 0x11 } };
}
