#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <setupapi.h>
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cwchar>
#include <cwctype>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

#include "Kinect360RemoldHardwareProfile.h"

namespace Kinect360RemoldIdentity {
// Use inline literal property keys rather than the SDK's externally linked
// DEVPKEY objects. This keeps every component on the same Windows-defined
// identity contract without creating a linker dependency on devpkey symbols.
inline constexpr DEVPROPKEY kDeviceParentKey = {
    {0x4340a6c5,0x93fa,0x4706,{0x97,0x2c,0x7b,0x64,0x80,0x08,0xa5,0xa7}}, 8};
inline constexpr DEVPROPKEY kDeviceContainerIdKey = {
    {0x8c7ed206,0x3f8a,0x4827,{0xb3,0xab,0xae,0x9e,0x1f,0xae,0xfc,0x6c}}, 2};

inline std::wstring FirstLocationPath(HDEVINFO info, SP_DEVINFO_DATA& dev) {
    DWORD type = 0, needed = 0;
    (void)SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_LOCATION_PATHS, &type, nullptr, 0, &needed);
    if (needed < sizeof(wchar_t)) return {};
    std::vector<BYTE> buffer(needed + sizeof(wchar_t), 0);
    if (!SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_LOCATION_PATHS, &type, buffer.data(), needed, nullptr)) return {};
    if (type != REG_MULTI_SZ && type != REG_SZ) return {};
    const auto* value = reinterpret_cast<const wchar_t*>(buffer.data());
    return value && value[0] ? std::wstring(value) : std::wstring{};
}

inline std::wstring PhysicalParentLocation(std::wstring path) {
    if (path.empty()) return path;
    std::transform(path.begin(), path.end(), path.begin(), [](wchar_t c){ return static_cast<wchar_t>(towlower(c)); });
    // Composite runtime interfaces may append USBMI(...). Strip those tails first.
    const auto mi = path.rfind(L"#usbmi(");
    if (mi != std::wstring::npos) path.erase(mi);
    // Camera/audio/control are siblings behind the Kinect internal hub. The last
    // USB(...) element identifies the sibling, while its parent identifies the
    // physical Kinect and remains stable across 02AD -> 02BB/02C3 re-enumeration.
    const auto usb = path.rfind(L"#usb(");
    if (usb != std::wstring::npos) path.erase(usb);
    return path;
}

inline uint64_t Hash(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c){ return static_cast<wchar_t>(towlower(c)); });
    uint64_t h = 1469598103934665603ull;
    for (wchar_t c : value) {
        h ^= static_cast<uint16_t>(c & 0xffff); h *= 1099511628211ull;
        h ^= static_cast<uint16_t>((static_cast<uint32_t>(c) >> 16) & 0xffff); h *= 1099511628211ull;
    }
    return h;
}

inline std::string DeviceIdFromLocation(const std::wstring& location) {
    const auto physical = PhysicalParentLocation(location);
    if (physical.empty()) return {};
    std::ostringstream out;
    out << "usb-" << std::hex << std::setfill('0') << std::setw(16) << Hash(physical);
    return out.str();
}

inline std::string DeviceId(HDEVINFO info, SP_DEVINFO_DATA& dev) {
    return DeviceIdFromLocation(FirstLocationPath(info, dev));
}

// Reads PID_xxxx and REV_xxxx from the device's USB hardware IDs. PnP builds
// them from idProduct/bcdDevice, so the model can be resolved without opening
// the WinUSB handle that CameraBridge owns exclusively.
inline Kinect360RemoldHardware::Model ModelFromHardwareIds(HDEVINFO info, SP_DEVINFO_DATA& dev) {
    DWORD type = 0, needed = 0;
    (void)SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_HARDWAREID, &type, nullptr, 0, &needed);
    if (needed < sizeof(wchar_t)) return Kinect360RemoldHardware::Model::Unknown;
    std::vector<BYTE> buffer(needed + 2 * sizeof(wchar_t), 0);
    if (!SetupDiGetDeviceRegistryPropertyW(info, &dev, SPDRP_HARDWAREID, &type, buffer.data(), needed, nullptr) ||
        type != REG_MULTI_SZ) return Kinect360RemoldHardware::Model::Unknown;
    auto hexField = [](const std::wstring& id, const wchar_t* key, uint16_t& value) {
        const auto at = id.find(key);
        if (at == std::wstring::npos || id.size() < at + 8) return false;
        const std::wstring digits = id.substr(at + 4, 4);
        if (digits.find_first_not_of(L"0123456789abcdefABCDEF") != std::wstring::npos) return false;
        value = static_cast<uint16_t>(std::wcstoul(digits.c_str(), nullptr, 16));
        return true;
    };
    for (const auto* entry = reinterpret_cast<const wchar_t*>(buffer.data()); *entry; entry += wcslen(entry) + 1) {
        std::wstring id(entry);
        std::transform(id.begin(), id.end(), id.begin(), [](wchar_t c){ return static_cast<wchar_t>(towupper(c)); });
        uint16_t productId = 0, revision = 0;
        if (hexField(id, L"PID_", productId) && hexField(id, L"REV_", revision))
            return Kinect360RemoldHardware::ModelFromCamera(productId, revision);
    }
    return Kinect360RemoldHardware::Model::Unknown;
}

// Resolves the Xbox 360 model of one physical Kinect from its 02AE camera,
// exactly like the Linux broker. Unknown means the camera is not enumerated.
inline Kinect360RemoldHardware::Model CameraModel(const std::string& deviceId) {
    auto model = Kinect360RemoldHardware::Model::Unknown;
    HDEVINFO set = SetupDiGetClassDevsW(&Kinect360RemoldHardware::kCameraTransportGuid, nullptr, nullptr,
                                        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE_VALUE) return model;
    for (DWORD index = 0; model == Kinect360RemoldHardware::Model::Unknown; ++index) {
        SP_DEVINFO_DATA dev{};
        dev.cbSize = sizeof(dev);
        if (!SetupDiEnumDeviceInfo(set, index, &dev)) break;
        if (!deviceId.empty() && DeviceId(set, dev) != deviceId) continue;
        model = ModelFromHardwareIds(set, dev);
    }
    SetupDiDestroyDeviceInfoList(set);
    return model;
}
} // namespace Kinect360RemoldIdentity
