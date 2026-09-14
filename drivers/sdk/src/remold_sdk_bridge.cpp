#include "remold_sdk_bridge.h"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace {
constexpr uint32_t kSdkMagic = 0x4B534D52u;      // RMSK
constexpr uint32_t kSdkVersion = 1u;
constexpr uint32_t kAudioControlMagic = 0x434D4D52u; // RMMC
constexpr uint32_t kAudioVersion = 1u;

enum class SdkCommand : uint32_t {
    SensorCount=1, Status=2, Initialize=3, Shutdown=4,
    GetElevation=5, SetElevation=6, GetAccelerometer=7, RuntimeInfo=8
};
enum class AudioCommand : uint32_t { GetState=1, SetVolume=2, SetMute=3 };

#pragma pack(push,1)
struct SdkRequest {
    uint32_t magic=kSdkMagic, version=kSdkVersion;
    SdkCommand command=SdkCommand::Status;
    int32_t value=0;
    uint32_t flags=0;
    uint32_t sensorIndex=0;
    char deviceId[64]{};
};
struct SdkReply {
    uint32_t magic=kSdkMagic, version=kSdkVersion;
    int32_t result=0;
    uint32_t sensorCount=0,status=0,capabilities=0;
    int32_t elevationDegrees=0,accelX=0,accelY=0,accelZ=0;
    uint32_t initializedFlags=0;
    char cameraEndpoint[108]{},audioEndpoint[108]{},audioControlEndpoint[108]{},skeletonEndpoint[108]{};
};
struct AudioRequest {
    uint32_t magic=kAudioControlMagic,version=kAudioVersion;
    AudioCommand command=AudioCommand::GetState;
    int32_t value=0;
    char deviceId[64]{};
};
struct AudioReply {
    uint32_t magic=kAudioControlMagic,version=kAudioVersion;
    int32_t result=0,volumeBasisPoints=10000;
    uint32_t muted=0,capabilities=0,backend=1,reserved=0;
};
#pragma pack(pop)
static_assert(sizeof(SdkRequest)==88,"SDK request ABI");
static_assert(sizeof(SdkReply)==476,"SDK reply ABI");
static_assert(sizeof(AudioRequest)==80,"audio control request ABI");
static_assert(sizeof(AudioReply)==32,"audio control reply ABI");

thread_local std::string gLastError;
thread_local uint32_t gSensorIndex=0;
thread_local std::string gDeviceId;
void fail(const std::string& text){gLastError=text;}
void clear_error(){gLastError.clear();}
void copy_device_id(char (&dst)[64],const std::string& id){
    std::memset(dst,0,sizeof(dst));
    const size_t n=std::min(id.size(),sizeof(dst)-1);
    if(n)std::memcpy(dst,id.data(),n);
}

#ifdef _WIN32
using NativeHandle=HANDLE;
constexpr NativeHandle kInvalid=INVALID_HANDLE_VALUE;
void close_handle(NativeHandle h){if(h!=kInvalid)CloseHandle(h);}
NativeHandle connect_local(const wchar_t* path){
    for(int attempt=0;attempt<2;++attempt){
        HANDLE h=CreateFileW(path,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(h!=INVALID_HANDLE_VALUE)return h;
        const DWORD error=GetLastError();
        if(error!=ERROR_PIPE_BUSY||!WaitNamedPipeW(path,1500))break;
    }
    fail("named pipe unavailable: "+std::to_string(GetLastError()));
    return kInvalid;
}
bool write_exact(NativeHandle h,const void* data,size_t bytes){
    const auto* p=static_cast<const uint8_t*>(data);size_t total=0;
    while(total<bytes){DWORD n=0;const DWORD chunk=static_cast<DWORD>(std::min<size_t>(bytes-total,0x7fffffff));if(!WriteFile(h,p+total,chunk,&n,nullptr)||n==0){fail("named pipe write failed: "+std::to_string(GetLastError()));return false;}total+=n;}return true;
}
bool read_exact(NativeHandle h,void* data,size_t bytes){
    auto* p=static_cast<uint8_t*>(data);size_t total=0;
    while(total<bytes){DWORD n=0;const DWORD chunk=static_cast<DWORD>(std::min<size_t>(bytes-total,0x7fffffff));if(!ReadFile(h,p+total,chunk,&n,nullptr)||n==0){fail("named pipe read failed: "+std::to_string(GetLastError()));return false;}total+=n;}return true;
}
#else
using NativeHandle=int;
constexpr NativeHandle kInvalid=-1;
void close_handle(NativeHandle h){if(h>=0)::close(h);}
NativeHandle connect_local(const char* path){
    int fd=::socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);if(fd<0){fail("socket: "+std::string(std::strerror(errno)));return kInvalid;}
    sockaddr_un addr{};addr.sun_family=AF_UNIX;
    if(std::strlen(path)>=sizeof(addr.sun_path)){fail("unix socket path too long");::close(fd);return kInvalid;}
    const size_t pathLen=std::strlen(path);
    if(pathLen>=sizeof(addr.sun_path))return -1;
    std::memcpy(addr.sun_path,path,pathLen+1);
    if(::connect(fd,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))!=0){fail("connect: "+std::string(std::strerror(errno)));::close(fd);return kInvalid;}return fd;
}
bool write_exact(NativeHandle h,const void* data,size_t bytes){
    const auto* p=static_cast<const uint8_t*>(data);size_t total=0;
    while(total<bytes){ssize_t n=::send(h,p+total,bytes-total,MSG_NOSIGNAL);if(n<0&&errno==EINTR)continue;if(n<=0){fail("socket write: "+std::string(std::strerror(errno)));return false;}total+=static_cast<size_t>(n);}return true;
}
bool read_exact(NativeHandle h,void* data,size_t bytes){
    auto* p=static_cast<uint8_t*>(data);size_t total=0;
    while(total<bytes){ssize_t n=::recv(h,p+total,bytes-total,0);if(n<0&&errno==EINTR)continue;if(n<=0){fail(n==0?"bridge closed connection":"socket read: "+std::string(std::strerror(errno)));return false;}total+=static_cast<size_t>(n);}return true;
}
#endif

void copy_text(char* dst,size_t cap,const char* src,size_t srcCap){
    if(!dst||cap==0)return;
    std::memset(dst,0,cap);
    size_t n=0;
    while(n<srcCap&&src[n])++n;
    n=std::min(n,cap-1);
    std::memcpy(dst,src,n);
}
void decode(const SdkReply& r,RemoldSdkState* out){
    if(!out)return;
    std::memset(out,0,sizeof(*out));
    out->sensor_count=r.sensorCount;
    out->connected=r.status;
    out->capabilities=r.capabilities;
    out->elevation_degrees=r.elevationDegrees;
    out->accel_x=r.accelX;
    out->accel_y=r.accelY;
    out->accel_z=r.accelZ;
    out->initialized_flags=r.initializedFlags;
    copy_text(out->camera_endpoint,sizeof(out->camera_endpoint),r.cameraEndpoint,sizeof(r.cameraEndpoint));
    copy_text(out->audio_endpoint,sizeof(out->audio_endpoint),r.audioEndpoint,sizeof(r.audioEndpoint));
    copy_text(out->audio_control_endpoint,sizeof(out->audio_control_endpoint),r.audioControlEndpoint,sizeof(r.audioControlEndpoint));
    copy_text(out->skeleton_endpoint,sizeof(out->skeleton_endpoint),r.skeletonEndpoint,sizeof(r.skeletonEndpoint));
}

int32_t sdk_exchange(SdkCommand command,int32_t value,uint32_t flags,SdkReply& reply){
    clear_error();SdkRequest request{};request.command=command;request.value=value;request.flags=flags;request.sensorIndex=gSensorIndex;copy_device_id(request.deviceId,gDeviceId);
#ifdef _WIN32
    NativeHandle h=connect_local(L"\\\\.\\pipe\\Kinect360RemoldSdk");
#else
    NativeHandle h=connect_local("/run/kinect360-remold/sdk.sock");
#endif
    if(h==kInvalid)return -1;
    const bool ok=write_exact(h,&request,sizeof(request))&&read_exact(h,&reply,sizeof(reply));close_handle(h);if(!ok)return -2;
    if(reply.magic!=kSdkMagic||reply.version!=kSdkVersion){fail("SDK bridge ABI mismatch");return -3;}return reply.result;
}
int32_t audio_exchange(AudioCommand command,int32_t value,AudioReply& reply){
    clear_error();AudioRequest request{};request.command=command;request.value=value;copy_device_id(request.deviceId,gDeviceId);
#ifdef _WIN32
    NativeHandle h=connect_local(L"\\\\.\\pipe\\Kinect360RemoldAudioControl");
#else
    NativeHandle h=connect_local("/run/kinect360-remold/audio-control.sock");
#endif
    if(h==kInvalid)return -1;
    const bool ok=write_exact(h,&request,sizeof(request))&&read_exact(h,&reply,sizeof(reply));close_handle(h);if(!ok)return -2;
    if(reply.magic!=kAudioControlMagic||reply.version!=kAudioVersion){fail("audio-control ABI mismatch");return -3;}return reply.result;
}
void decode_audio(const AudioReply& r,RemoldAudioState* out){if(!out)return;out->volume_basis_points=r.volumeBasisPoints;out->muted=r.muted;out->capabilities=r.capabilities;out->backend=r.backend;}
}

extern "C" {
int32_t remold_sdk_select_sensor(uint32_t index){gSensorIndex=index;gDeviceId.clear();clear_error();return 0;}
int32_t remold_sdk_select_device(const char* device_id){
    if(!device_id){gDeviceId.clear();gSensorIndex=0;clear_error();return 0;}
    const size_t n=std::strlen(device_id);if(n>=64){fail("device id is too long");return -1;}
    gDeviceId.assign(device_id,n);gSensorIndex=0;clear_error();return 0;
}
int32_t remold_sdk_sensor_count(uint32_t* count){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::SensorCount,0,0,r);if(count)*count=r.sensorCount;return rc;}
int32_t remold_sdk_status(RemoldSdkState* state){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::Status,0,0,r);decode(r,state);return rc;}
int32_t remold_sdk_runtime_info(RemoldSdkState* state){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::RuntimeInfo,0,0,r);decode(r,state);return rc;}
int32_t remold_sdk_initialize(uint32_t flags,RemoldSdkState* state){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::Initialize,0,flags,r);decode(r,state);return rc;}
int32_t remold_sdk_shutdown(RemoldSdkState* state){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::Shutdown,0,0,r);decode(r,state);return rc;}
int32_t remold_sdk_get_elevation(int32_t* degrees){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::GetElevation,0,0,r);if(degrees)*degrees=r.elevationDegrees;return rc;}
int32_t remold_sdk_set_elevation(int32_t degrees,RemoldSdkState* state){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::SetElevation,degrees,0,r);decode(r,state);return rc;}
int32_t remold_sdk_get_accelerometer(int32_t* x,int32_t* y,int32_t* z){SdkReply r{};int32_t rc=sdk_exchange(SdkCommand::GetAccelerometer,0,0,r);if(x)*x=r.accelX;if(y)*y=r.accelY;if(z)*z=r.accelZ;return rc;}
int32_t remold_audio_get_state(RemoldAudioState* state){AudioReply r{};int32_t rc=audio_exchange(AudioCommand::GetState,0,r);decode_audio(r,state);return rc;}
int32_t remold_audio_set_volume(int32_t volume_basis_points,RemoldAudioState* state){AudioReply r{};int32_t rc=audio_exchange(AudioCommand::SetVolume,std::max<int32_t>(0,std::min<int32_t>(10000,volume_basis_points)),r);decode_audio(r,state);return rc;}
int32_t remold_audio_set_mute(uint32_t muted,RemoldAudioState* state){AudioReply r{};int32_t rc=audio_exchange(AudioCommand::SetMute,muted?1:0,r);decode_audio(r,state);return rc;}
const char* remold_sdk_last_error(void){return gLastError.c_str();}
}
