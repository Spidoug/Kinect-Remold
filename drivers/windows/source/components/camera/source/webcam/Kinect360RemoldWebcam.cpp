#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfvirtualcamera.h>
#include <setupapi.h>
#include <cstdio>
#include <cwctype>
#include <set>
#include <string>
#include <vector>
#include "../../shared/Kinect360RemoldVirtualCameraIdentity.h"
#include "../../shared/Kinect360RemoldScannerPort.h"

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mfsensorgroup.lib")
#pragma comment(lib, "setupapi.lib")

namespace {
constexpr wchar_t kClsidString[] = L"{D0C8E936-5A2B-4C0D-936F-281501A73691}";
constexpr wchar_t kFriendlyPrefix[] = L"Kinect Xbox 360 Camera [";
constexpr wchar_t kCameraRegistry[] = L"SOFTWARE\\Kinect360Remold\\VirtualCameras";
const GUID kVcamKind = {0xc7f7c57b,0xdf30,0x41d0,{0xaf,0xfc,0x15,0x20,0x1c,0xdf,0x92,0x0d}};

void PrintHr(const wchar_t* what, HRESULT hr) {
    std::fwprintf(stderr, L"%ls failed: 0x%08X\n", what, static_cast<unsigned>(hr));
}

bool ValidDeviceId(const std::wstring& id) {
    if (id.empty() || id.size() > 96) return false;
    for (wchar_t c : id) {
        if (!(iswalnum(c) || c == L'-' || c == L'_' || c == L'.')) return false;
    }
    return true;
}

std::wstring FriendlyName(const std::wstring& id) {
    return std::wstring(kFriendlyPrefix) + id + L"]";
}

bool ParseFriendlyName(const std::wstring& name, std::wstring& id) {
    const std::wstring prefix = kFriendlyPrefix;
    if (name.size() <= prefix.size() + 1 || name.compare(0, prefix.size(), prefix) != 0) return false;
    const size_t close = name.find(L']', prefix.size());
    if (close == std::wstring::npos || close == prefix.size()) return false;
    id = name.substr(prefix.size(), close - prefix.size());
    return ValidDeviceId(id);
}

HRESULT SetRegString(HKEY root, const std::wstring& subkey, const wchar_t* name, const std::wstring& value) {
    HKEY key = nullptr;
    LONG rc = RegCreateKeyExW(root, subkey.c_str(), 0, nullptr, 0,
                              KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &key, nullptr);
    if (rc != ERROR_SUCCESS) return HRESULT_FROM_WIN32(rc);
    const BYTE* bytes = reinterpret_cast<const BYTE*>(value.c_str());
    const DWORD cb = static_cast<DWORD>((value.size()+1) * sizeof(wchar_t));
    rc = RegSetValueExW(key, name, 0, REG_SZ, bytes, cb);
    RegCloseKey(key);
    return HRESULT_FROM_WIN32(rc);
}

HRESULT RegisterComServer(const std::wstring& dllPath) {
    const std::wstring base = std::wstring(L"SOFTWARE\\Classes\\CLSID\\") + kClsidString;
    HRESULT hr = SetRegString(HKEY_LOCAL_MACHINE, base, nullptr, L"Kinect Xbox 360 Camera Source");
    if (FAILED(hr)) return hr;
    hr = SetRegString(HKEY_LOCAL_MACHINE, base + L"\\InprocServer32", nullptr, dllPath);
    if (FAILED(hr)) return hr;
    return SetRegString(HKEY_LOCAL_MACHINE, base + L"\\InprocServer32", L"ThreadingModel", L"Both");
}

HRESULT UnregisterComServer() {
    const std::wstring base = std::wstring(L"SOFTWARE\\Classes\\CLSID\\") + kClsidString;
    LONG rc = RegDeleteTreeW(HKEY_LOCAL_MACHINE, base.c_str());
    if (rc == ERROR_FILE_NOT_FOUND) return S_OK;
    return HRESULT_FROM_WIN32(rc);
}

HRESULT RememberCamera(const std::wstring& id, const std::wstring& dllPath) {
    return SetRegString(HKEY_LOCAL_MACHINE, kCameraRegistry, id.c_str(), dllPath);
}

void ForgetCamera(const std::wstring& id) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kCameraRegistry, 0, KEY_SET_VALUE | KEY_WOW64_64KEY, &key) == ERROR_SUCCESS) {
        (void)RegDeleteValueW(key, id.c_str());
        RegCloseKey(key);
    }
}

std::set<std::wstring> RegistryCameraIds() {
    std::set<std::wstring> ids;
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kCameraRegistry, 0, KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key) != ERROR_SUCCESS) return ids;
    DWORD index = 0;
    for (;;) {
        wchar_t name[256]{};
        DWORD chars = static_cast<DWORD>(std::size(name));
        const LONG rc = RegEnumValueW(key, index++, name, &chars, nullptr, nullptr, nullptr, nullptr);
        if (rc == ERROR_NO_MORE_ITEMS) break;
        if (rc == ERROR_SUCCESS && ValidDeviceId(std::wstring(name, chars))) ids.emplace(name, chars);
    }
    RegCloseKey(key);
    return ids;
}

HRESULT FindPnPCamera(const std::wstring& friendlyName, std::wstring& instanceId) {
    instanceId.clear();
    HDEVINFO set = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    HRESULT result = S_FALSE;
    for (DWORD index = 0;; ++index) {
        SP_DEVINFO_DATA data{}; data.cbSize = sizeof(data);
        if (!SetupDiEnumDeviceInfo(set, index, &data)) {
            const DWORD error = GetLastError();
            if (error != ERROR_NO_MORE_ITEMS && result == S_FALSE) result = HRESULT_FROM_WIN32(error);
            break;
        }
        wchar_t name[512]{}; DWORD type = 0, bytes = 0;
        bool haveName = SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_FRIENDLYNAME, &type,
            reinterpret_cast<PBYTE>(name), sizeof(name), &bytes) != FALSE;
        if (!haveName) haveName = SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_DEVICEDESC, &type,
            reinterpret_cast<PBYTE>(name), sizeof(name), &bytes) != FALSE;
        if (!haveName || _wcsnicmp(name, friendlyName.c_str(), friendlyName.size()) != 0) continue;
        wchar_t instance[1024]{};
        if (!SetupDiGetDeviceInstanceIdW(set, &data, instance, ARRAYSIZE(instance), nullptr)) continue;
        std::wstring upper = instance;
        for (auto& ch : upper) ch = static_cast<wchar_t>(towupper(ch));
        if (upper.rfind(L"SWD\\VCAMDEVAPI\\", 0) != 0) continue;
        instanceId = instance; result = S_OK; break;
    }
    SetupDiDestroyDeviceInfoList(set);
    return result;
}

HRESULT FindEnumeratedCamera(const std::wstring& friendlyName, std::wstring& symbolicLink) {
    symbolicLink.clear();
    IMFAttributes* attributes = nullptr;
    HRESULT hr = MFCreateAttributes(&attributes, 1);
    if (FAILED(hr)) return hr;
    hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    if (FAILED(hr)) { attributes->Release(); return hr; }
    IMFActivate** devices = nullptr; UINT32 count = 0;
    hr = MFEnumDeviceSources(attributes, &devices, &count);
    attributes->Release();
    if (FAILED(hr)) return hr;
    bool found = false;
    for (UINT32 index = 0; index < count; ++index) {
        IMFActivate* activate = devices[index];
        if (!activate) continue;
        LPWSTR friendly = nullptr; UINT32 friendlyChars = 0;
        const HRESULT nameHr = activate->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &friendly, &friendlyChars);
        const bool match = SUCCEEDED(nameHr) && friendly &&
            _wcsnicmp(friendly, friendlyName.c_str(), friendlyName.size()) == 0;
        if (friendly) CoTaskMemFree(friendly);
        if (match) {
            LPWSTR link = nullptr; UINT32 linkChars = 0;
            if (SUCCEEDED(activate->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link, &linkChars)) && link)
                symbolicLink.assign(link, linkChars);
            if (link) CoTaskMemFree(link);
            found = true;
        }
    }
    for (UINT32 index = 0; index < count; ++index) if (devices[index]) devices[index]->Release();
    CoTaskMemFree(devices);
    return found ? S_OK : S_FALSE;
}

std::set<std::wstring> EnumeratedCameraIds() {
    std::set<std::wstring> ids;
    IMFAttributes* attributes = nullptr;
    if (FAILED(MFCreateAttributes(&attributes, 1))) return ids;
    if (FAILED(attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID))) {
        attributes->Release(); return ids;
    }
    IMFActivate** devices = nullptr; UINT32 count = 0;
    if (FAILED(MFEnumDeviceSources(attributes, &devices, &count))) { attributes->Release(); return ids; }
    attributes->Release();
    for (UINT32 i=0;i<count;++i) {
        LPWSTR raw=nullptr; UINT32 chars=0;
        if (devices[i] && SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,&raw,&chars)) && raw) {
            std::wstring id;
            if (ParseFriendlyName(std::wstring(raw,chars), id)) ids.insert(id);
        }
        if (raw) CoTaskMemFree(raw);
        if (devices[i]) devices[i]->Release();
    }
    CoTaskMemFree(devices);
    return ids;
}

HRESULT OpenVirtualCamera(const std::wstring& id, IMFVirtualCamera** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!ValidDeviceId(id)) return E_INVALIDARG;
    const std::wstring friendly = FriendlyName(id);
    HRESULT hr = MFCreateVirtualCamera(MFVirtualCameraType_SoftwareCameraSource,
        MFVirtualCameraLifetime_System, MFVirtualCameraAccess_AllUsers,
        friendly.c_str(), kClsidString, nullptr, 0, out);
    if (SUCCEEDED(hr) && *out) {
        hr = (*out)->SetString(Kinect360RemoldVirtualCamera::kDeviceIdAttribute, id.c_str());
        if (FAILED(hr)) { (*out)->Release(); *out = nullptr; }
    }
    return hr;
}

HRESULT GetRegisteredLink(IMFVirtualCamera* camera, std::wstring& link) {
    link.clear();
    if (!camera) return E_POINTER;
    LPWSTR raw = nullptr; UINT32 chars = 0;
    const HRESULT hr = camera->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &raw, &chars);
    if (hr == MF_E_ATTRIBUTENOTFOUND) return S_FALSE;
    if (FAILED(hr)) return hr;
    if (raw) { link.assign(raw, chars); CoTaskMemFree(raw); }
    return S_OK;
}

HRESULT RegisterSource(const std::wstring& dllPath) {
    DWORD attrs = GetFileAttributesW(dllPath.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    return RegisterComServer(dllPath);
}

HRESULT Install(const std::wstring& dllPath, const std::wstring& id) {
    if (!ValidDeviceId(id)) return E_INVALIDARG;
    HRESULT hr = RegisterSource(dllPath);
    if (FAILED(hr)) return hr;
    IMFVirtualCamera* camera = nullptr;
    hr = OpenVirtualCamera(id, &camera);
    if (FAILED(hr)) return hr;
    std::wstring existingLink;
    const HRESULT stateHr = GetRegisteredLink(camera, existingLink);
    if (stateHr == S_FALSE) {
        hr = camera->SetUINT32(kVcamKind, 0);
        if (SUCCEEDED(hr)) hr = camera->Start(nullptr);
    } else if (FAILED(stateHr)) hr = stateHr;
    camera->Shutdown(); camera->Release();
    if (FAILED(hr)) return hr;
    hr = RememberCamera(id, dllPath);
    if (SUCCEEDED(hr)) std::wprintf(L"Virtual camera ready: %ls\n", FriendlyName(id).c_str());
    return hr;
}

HRESULT RemoveOne(const std::wstring& id) {
    if (!ValidDeviceId(id)) return E_INVALIDARG;
    IMFVirtualCamera* camera = nullptr;
    HRESULT hr = OpenVirtualCamera(id, &camera);
    if (FAILED(hr)) { ForgetCamera(id); return hr; }
    std::wstring link;
    const HRESULT stateHr = GetRegisteredLink(camera, link);
    if (stateHr == S_OK) {
        hr = camera->Remove();
        if (hr == MF_E_INVALIDREQUEST) { std::wstring after; if (GetRegisteredLink(camera, after) == S_FALSE) hr = S_OK; }
    } else if (stateHr == S_FALSE) hr = S_OK;
    else hr = stateHr;
    camera->Shutdown(); camera->Release();
    if (SUCCEEDED(hr)) ForgetCamera(id);
    return hr;
}

HRESULT RemoveAll() {
    auto ids = RegistryCameraIds();
    const auto enumerated = EnumeratedCameraIds();
    ids.insert(enumerated.begin(), enumerated.end());
    HRESULT firstFailure = S_OK;
    for (const auto& id : ids) {
        const HRESULT hr = RemoveOne(id);
        if (FAILED(hr) && SUCCEEDED(firstFailure)) firstFailure = hr;
    }
    (void)RegDeleteTreeW(HKEY_LOCAL_MACHINE, kCameraRegistry);
    const HRESULT unregisterHr = UnregisterComServer();
    if (FAILED(unregisterHr) && SUCCEEDED(firstFailure)) firstFailure = unregisterHr;
    return firstFailure;
}


std::wstring CameraPipeName(const std::wstring& id) {
    return std::wstring(Kinect360RemoldScannerPort::kPipePrefix) + id;
}

HRESULT ExchangeDriverSettings(const std::wstring& id, bool setValue, bool enabled, bool& current) {
    if (!ValidDeviceId(id)) return E_INVALIDARG;
    const std::wstring pipeName = CameraPipeName(id);
    HRESULT last = HRESULT_FROM_WIN32(ERROR_PIPE_NOT_CONNECTED);

    // CameraBridge can be between physical sessions while a 1473 is recovering.
    // A short bounded retry makes a UI toggle atomic from the user's point of
    // view without hiding persistent transport failures.
    for (unsigned attempt = 0; attempt < 4; ++attempt) {
        if (!WaitNamedPipeW(pipeName.c_str(), 900)) {
            const DWORD error = GetLastError();
            last = HRESULT_FROM_WIN32(error ? error : ERROR_PIPE_NOT_CONNECTED);
            if (attempt + 1u < 4u) { Sleep(100); continue; }
            return last;
        }

        HANDLE pipe = CreateFileW(pipeName.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (pipe == INVALID_HANDLE_VALUE) {
            const DWORD error = GetLastError();
            last = HRESULT_FROM_WIN32(error ? error : ERROR_PIPE_NOT_CONNECTED);
            if (attempt + 1u < 4u) { Sleep(100); continue; }
            return last;
        }

        Kinect360RemoldScannerPort::Request request{};
        request.command = setValue
            ? Kinect360RemoldScannerPort::Command::SetDriverSettings
            : Kinect360RemoldScannerPort::Command::GetDriverSettings;
        request.streamMask = enabled ? Kinect360RemoldScannerPort::DriverSettingRgbHighQuality : 0u;
        Kinect360RemoldScannerPort::Reply reply{};
        DWORD written = 0, read = 0;
        bool ok = WriteFile(pipe, &request, sizeof(request), &written, nullptr) && written == sizeof(request);
        DWORD error = ok ? ERROR_SUCCESS : GetLastError();
        if (ok) {
            ok = ReadFile(pipe, &reply, sizeof(reply), &read, nullptr) && read == sizeof(reply);
            if (!ok) error = GetLastError();
        }
        CloseHandle(pipe);

        if (!ok) {
            last = HRESULT_FROM_WIN32(error ? error : ERROR_BROKEN_PIPE);
            if (attempt + 1u < 4u) { Sleep(100); continue; }
            return last;
        }
        if (reply.magic != Kinect360RemoldScannerPort::kMagic ||
            reply.version != Kinect360RemoldScannerPort::kVersion) return HRESULT_FROM_WIN32(ERROR_INVALID_DATA);
        if (FAILED(static_cast<HRESULT>(reply.result))) return static_cast<HRESULT>(reply.result);
        current = (reply.acceptedMask & Kinect360RemoldScannerPort::DriverSettingRgbHighQuality) != 0;
        return S_OK;
    }
    return last;
}

HRESULT RgbHqStatus(const std::wstring& id) {
    bool enabled = false;
    const HRESULT hr = ExchangeDriverSettings(id, false, false, enabled);
    if (SUCCEEDED(hr)) std::wprintf(L"OK device=%ls rgb-hq=%ls\n", id.c_str(), enabled ? L"on" : L"off");
    return hr;
}

HRESULT SetRgbHq(const std::wstring& id, bool enabled) {
    bool current = false;
    const HRESULT hr = ExchangeDriverSettings(id, true, enabled, current);
    if (SUCCEEDED(hr)) {
        std::wprintf(L"OK device=%ls rgb-hq=%ls; reopen virtual-camera clients to renegotiate resolution\n",
                     id.c_str(), current ? L"on" : L"off");
    }
    return hr;
}

HRESULT ToggleRgbHq(const std::wstring& id) {
    bool current = false;
    HRESULT hr = ExchangeDriverSettings(id, false, false, current);
    if (FAILED(hr)) return hr;
    return SetRgbHq(id, !current);
}

HRESULT Status(const std::wstring& id) {
    if (!ValidDeviceId(id)) return E_INVALIDARG;
    const std::wstring friendly = FriendlyName(id);

    // Reopen the system-lifetime camera with the exact creation key. This is
    // the authoritative registration check and does not depend on the timing
    // of MFEnumDeviceSources/SetupAPI publication for a second virtual camera.
    IMFVirtualCamera* camera = nullptr;
    HRESULT hr = OpenVirtualCamera(id, &camera);
    if (SUCCEEDED(hr) && camera) {
        std::wstring registeredLink;
        const HRESULT linkHr = GetRegisteredLink(camera, registeredLink);
        camera->Shutdown();
        camera->Release();
        if (linkHr == S_OK && !registeredLink.empty()) {
            std::wprintf(L"OK camera=%ls registered-link=%ls\n", friendly.c_str(), registeredLink.c_str());
            return S_OK;
        }
        if (FAILED(linkHr)) hr = linkHr;
    }

    std::wstring link;
    if (FindEnumeratedCamera(friendly, link) == S_OK) {
        std::wprintf(L"OK camera=%ls symbolic-link=%ls\n", friendly.c_str(), link.c_str());
        return S_OK;
    }
    std::wstring pnp;
    if (FindPnPCamera(friendly, pnp) == S_OK) {
        std::wprintf(L"OK camera=%ls pnp-instance=%ls media-foundation-enumeration=deferred\n", friendly.c_str(), pnp.c_str());
        return S_OK;
    }
    std::wprintf(L"NOT_REGISTERED camera=%ls\n", friendly.c_str());
    return FAILED(hr) ? hr : HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
}

std::wstring FullPath(const wchar_t* path) {
    DWORD needed = GetFullPathNameW(path, 0, nullptr, nullptr);
    if (!needed) return path ? path : L"";
    std::vector<wchar_t> buf(needed + 1);
    DWORD got = GetFullPathNameW(path, static_cast<DWORD>(buf.size()), buf.data(), nullptr);
    return got ? std::wstring(buf.data(), got) : std::wstring(path);
}
} // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) {
        std::fwprintf(
            stderr,
            L"Usage:\n"
            L"  Kinect360RemoldWebcam register-source <media-source-dll>\n"
            L"  Kinect360RemoldWebcam install <media-source-dll> <device-id>\n"
            L"  Kinect360RemoldWebcam remove <device-id>\n"
            L"  Kinect360RemoldWebcam remove-all\n"
            L"  Kinect360RemoldWebcam status <device-id>\n"
            L"  Kinect360RemoldWebcam rgb-hq-status <device-id>\n"
            L"  Kinect360RemoldWebcam rgb-hq-on <device-id>\n"
            L"  Kinect360RemoldWebcam rgb-hq-off <device-id>\n"
            L"  Kinect360RemoldWebcam rgb-hq-toggle <device-id>\n");
        return 2;
    }
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninit = SUCCEEDED(hr);
    if (hr == RPC_E_CHANGED_MODE) hr = S_OK;
    if (FAILED(hr)) { PrintHr(L"CoInitializeEx", hr); return 3; }
    hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
    if (FAILED(hr)) { PrintHr(L"MFStartup", hr); if (uninit) CoUninitialize(); return 4; }

    if (_wcsicmp(argv[1], L"register-source") == 0 && argc == 3) hr = RegisterSource(FullPath(argv[2]));
    else if (_wcsicmp(argv[1], L"install") == 0 && argc == 4) hr = Install(FullPath(argv[2]), argv[3]);
    else if (_wcsicmp(argv[1], L"remove") == 0 && argc == 3) hr = RemoveOne(argv[2]);
    else if (_wcsicmp(argv[1], L"remove-all") == 0 && argc == 2) hr = RemoveAll();
    else if (_wcsicmp(argv[1], L"status") == 0 && argc == 3) hr = Status(argv[2]);
    else if (_wcsicmp(argv[1], L"rgb-hq-status") == 0 && argc == 3) hr = RgbHqStatus(argv[2]);
    else if (_wcsicmp(argv[1], L"rgb-hq-on") == 0 && argc == 3) hr = SetRgbHq(argv[2], true);
    else if (_wcsicmp(argv[1], L"rgb-hq-off") == 0 && argc == 3) hr = SetRgbHq(argv[2], false);
    else if (_wcsicmp(argv[1], L"rgb-hq-toggle") == 0 && argc == 3) hr = ToggleRgbHq(argv[2]);
    else hr = E_INVALIDARG;

    MFShutdown();
    if (uninit) CoUninitialize();
    if (FAILED(hr)) {
        PrintHr(L"Kinect360RemoldWebcam", hr);
        if (hr == E_ACCESSDENIED) std::fwprintf(stderr, L"Run this command elevated as Administrator.\n");
        // Preserve the HRESULT in the process exit code so CameraBridge and
        // installer diagnostics can distinguish Media Foundation, access and
        // registration failures instead of collapsing every error to code 1.
        return static_cast<int>(hr);
    }
    std::wprintf(L"PASS\n");
    return 0;
}
