#include <windows.h>
#include <setupapi.h>
#include <winusb.h>

#include "KinectOneRemoldProtocol.h"
#include "KinectOneNativeUsb.h"
#include "KinectOneDepthEngine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <deque>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {
using namespace KinectOneRemoldProtocol;
using Clock=std::chrono::steady_clock;

constexpr GUID kDeviceInterfaceGuid={0x5f7bce30,0xee54,0x4b88,{0x8a,0x58,0xa3,0xf6,0xc0,0xc9,0x48,0xb1}};
constexpr wchar_t kServiceName[]=L"KinectOneRemold";
constexpr wchar_t kSdkPipe[]=L"\\\\.\\pipe\\KinectOneRemoldSdk";
constexpr char kSdkPipeProtocol[]="\\\\.\\pipe\\KinectOneRemoldSdk";
constexpr char kModuleId[]="kinect-one-remold";
constexpr char kGeneration[]="xbox-one";
constexpr char kReadyCapabilities[]="color,depth,infrared,body-tracking,native-full-hd-color,native-metric-depth,native-jpeg-color,native-winusb,usb3,packet-core";
constexpr char kTransportCapabilities[]="native-winusb,usb3,packet-core";

std::atomic<bool> g_running{true};
std::mutex g_activeMutex;
std::unordered_set<std::string> g_activeDevices;
std::atomic<int> g_clientThreads{0};
bool deviceActive(const std::string& id){std::lock_guard<std::mutex> lock(g_activeMutex);return g_activeDevices.find(id)!=g_activeDevices.end();}
bool activateDevice(const std::string& id){std::lock_guard<std::mutex> lock(g_activeMutex);return g_activeDevices.insert(id).second;}
void deactivateDevice(const std::string& id){std::lock_guard<std::mutex> lock(g_activeMutex);g_activeDevices.erase(id);}
struct ActiveDeviceLease{std::string id;bool held=false;explicit ActiveDeviceLease(std::string value):id(std::move(value)),held(activateDevice(id)){}~ActiveDeviceLease(){if(held)deactivateDevice(id);}};
SERVICE_STATUS_HANDLE g_serviceHandle=nullptr;SERVICE_STATUS g_serviceStatus{};
std::uint64_t tickMs(){return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count();}
std::string sanitizeId(std::string v){for(char& ch:v){auto c=static_cast<unsigned char>(ch);if(!std::isalnum(c)&&ch!='-'&&ch!='_'&&ch!='.')ch='_';}return v.empty()?"kinect-one":v;}
std::string trim(std::string v){while(!v.empty()&&std::isspace(static_cast<unsigned char>(v.back())))v.pop_back();auto f=std::find_if_not(v.begin(),v.end(),[](unsigned char c){return std::isspace(c);});v.erase(v.begin(),f);return v;}
std::wstring firstLocationPath(HDEVINFO set,SP_DEVINFO_DATA& dev){
    DWORD type=0,needed=0;(void)SetupDiGetDeviceRegistryPropertyW(set,&dev,SPDRP_LOCATION_PATHS,&type,nullptr,0,&needed);
    if(needed<sizeof(wchar_t))return {};
    std::vector<std::uint8_t> storage(needed+sizeof(wchar_t),0);
    if(!SetupDiGetDeviceRegistryPropertyW(set,&dev,SPDRP_LOCATION_PATHS,&type,storage.data(),needed,nullptr))return {};
    if(type!=REG_MULTI_SZ&&type!=REG_SZ)return {};
    const auto* value=reinterpret_cast<const wchar_t*>(storage.data());return value&&*value?std::wstring(value):std::wstring{};
}
std::string stableDeviceId(const std::wstring& path,const std::wstring& location={}){
    // The SetupAPI interface path can be recreated when the PnP devnode is
    // rebound. Prefer the physical USB location path so the Studio keeps the
    // same Kinect identity across repair/re-enumeration; use the interface path
    // only when Windows does not expose a location.
    std::wstring key=location.empty()?path:location;
    std::transform(key.begin(),key.end(),key.begin(),[](wchar_t c){return static_cast<wchar_t>(std::towlower(c));});
    std::uint64_t hash=1469598103934665603ull;
    for(wchar_t wc:key){std::uint32_t value=static_cast<std::uint32_t>(wc);for(int b=0;b<4;++b){hash^=static_cast<std::uint8_t>((value>>(b*8))&0xffu);hash*=1099511628211ull;}}
    std::ostringstream out;out<<"kinect-one-"<<std::hex<<hash;return sanitizeId(out.str());
}

struct DeviceInfo{std::wstring path;std::string id,label,state;};

class WinUsbSession{
public:
    explicit WinUsbSession(const DeviceInfo& info):info_(info){}
    ~WinUsbSession(){close();}
    bool open(std::string& error){
        file_=CreateFileW(info_.path.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OVERLAPPED,nullptr);
        if(file_==INVALID_HANDLE_VALUE){error="open";return false;}if(!WinUsb_Initialize(file_,&control_)||!control_){error="winusb-init";return false;}if(!WinUsb_GetAssociatedInterface(control_,0,&depth_)||!depth_){error="depth-interface";return false;}
        ULONG colorTimeout=4,pipeTimeout=5000;WinUsb_SetPipePolicy(control_,KinectOneNativeUsb::CommandIn,PIPE_TRANSFER_TIMEOUT,sizeof(pipeTimeout),&pipeTimeout);WinUsb_SetPipePolicy(control_,KinectOneNativeUsb::CommandOut,PIPE_TRANSFER_TIMEOUT,sizeof(pipeTimeout),&pipeTimeout);WinUsb_SetPipePolicy(control_,KinectOneNativeUsb::ColorIn,PIPE_TRANSFER_TIMEOUT,sizeof(colorTimeout),&colorTimeout);
        if(!WinUsb_SetCurrentAlternateSetting(depth_,0)){error="depth-alt-zero";return false;}
        if(!controlNoData(0x00,0x31,40,0)){error="iso-delay";return false;}
        // Windows normally manages U1/U2 itself. Ask the device explicitly, but
        // do not reject controllers whose WinUSB stack owns these power policies.
        (void)controlNoData(0x00,0x03,48,0);(void)controlNoData(0x00,0x03,49,0);
        if(!setVideoFunction(false)){error="video-function-suspend";return false;}
        return true;
    }
    bool command(const KinectOneNativeUsb::CommandSpec& spec,std::vector<std::uint8_t>& response){
        const std::uint32_t seq=sequence_++;auto req=KinectOneNativeUsb::encodeCommand(seq,spec);ULONG sent=0;if(!WinUsb_WritePipe(control_,KinectOneNativeUsb::CommandOut,req.data(),static_cast<ULONG>(req.size()),&sent,nullptr)||sent!=req.size())return false;
        response.clear();if(spec.maxResponseBytes){response.resize(spec.maxResponseBytes);ULONG got=0;if(!WinUsb_ReadPipe(control_,KinectOneNativeUsb::CommandIn,response.data(),static_cast<ULONG>(response.size()),&got,nullptr))return false;response.resize(got);}
        std::array<std::uint8_t,KinectOneNativeUsb::CompletionBytes> completion{};ULONG got=0;if(!WinUsb_ReadPipe(control_,KinectOneNativeUsb::CommandIn,completion.data(),static_cast<ULONG>(completion.size()),&got,nullptr)||got!=completion.size())return false;return KinectOneNativeUsb::validCompletion(completion.data(),got,seq);
    }
    bool command(const KinectOneNativeUsb::CommandSpec& spec){std::vector<std::uint8_t> ignored;return command(spec,ignored);}
    bool probe(){if(!setVideoFunction(true))return false;std::vector<std::uint8_t> response;bool ok=command(KinectOneNativeUsb::command::hardwareInfo(),response);(void)setVideoFunction(false);return ok;}
    bool initialize(std::string& error){
        if(!setVideoFunction(true)){error="video-function-enable";return false;}
        std::vector<std::uint8_t> depthParams,p0,colorParams,status,probe;if(!command(KinectOneNativeUsb::command::firmwareVersions(),probe)||!command(KinectOneNativeUsb::command::hardwareInfo(),probe)||!command(KinectOneNativeUsb::command::serialNumber(),probe)){error="identity-query";return false;}if(!command(KinectOneNativeUsb::command::depthParameters(),depthParams)){error="depth-calibration";return false;}if(!command(KinectOneNativeUsb::command::p0Tables(),p0)){error="phase-calibration";return false;}if(!command(KinectOneNativeUsb::command::colorParameters(),colorParams)||colorParams.size()<64){error="color-calibration";return false;}if(!decoder_.configure(depthParams,p0)){error="calibration-decode";return false;}
        if(!command(KinectOneNativeUsb::command::mode(true,0x00640064u))||!command(KinectOneNativeUsb::command::mode(false))){error="mode-init";return false;}bool sensorReady=false;for(int i=0;i<50;++i){if(!command(KinectOneNativeUsb::command::status(),status)){error="status-query";return false;}std::uint32_t v=0;if(status.size()>=4)memcpy(&v,status.data(),4);if(v&1u){sensorReady=true;break;}Sleep(100);}if(!sensorReady){error="sensor-not-ready";return false;}if(!command(KinectOneNativeUsb::command::initStreams())){error="stream-init";return false;}if(!WinUsb_SetCurrentAlternateSetting(depth_,1)){error="depth-alt-setting";return false;}if(!command(KinectOneNativeUsb::command::status(),status)){error="post-alt-status";return false;}if(!command(KinectOneNativeUsb::command::streaming(true))){error="stream-enable";return false;}streaming_=true;return startIso(error);
    }
    bool run(HANDLE client,std::uint32_t mask){
        depthMask_=mask;depthThread_=std::thread([this]{depthLoop();});std::uint64_t frame=0;std::vector<std::uint8_t> chunk(1024*1024),jpeg;
        while(g_running&&!failed_){drainDepth(client,mask,frame);if(!((mask&StreamRgb)||(mask&StreamRgbHighQuality))){Sleep(1);continue;}ULONG got=0;BOOL ok=WinUsb_ReadPipe(control_,KinectOneNativeUsb::ColorIn,chunk.data(),static_cast<ULONG>(chunk.size()),&got,nullptr);if(ok&&got>0){jpegAssembler_.push(chunk.data(),got);while(jpegAssembler_.pop(jpeg)){StreamMode mode=(mask&StreamRgbHighQuality)?StreamMode::RgbHighQuality:StreamMode::Rgb;if(!sendFrame(client,mode,1920,1080,PixelFormat::Jpeg,jpeg.data(),jpeg.size(),++frame)){failed_=true;break;}}}else if(!ok){DWORD e=GetLastError();if(e!=ERROR_SEM_TIMEOUT&&e!=ERROR_IO_PENDING&&e!=ERROR_OPERATION_ABORTED){failed_=true;break;}}Sleep(1);}
        isoRunning_=false;if(depthThread_.joinable())depthThread_.join();return !failed_;
    }
    const KinectOneDepthEngine::DepthCameraCalibration& depthCalibration() const { return decoder_.calibration(); }

    void close(){
        isoRunning_=false;if(depthThread_.joinable())depthThread_.join();if(isoBuffer_){WinUsb_UnregisterIsochBuffer(isoBuffer_);isoBuffer_=nullptr;}if(isoMemory_){VirtualFree(isoMemory_,0,MEM_RELEASE);isoMemory_=nullptr;}
        if(control_&&streaming_){
            (void)WinUsb_SetCurrentAlternateSetting(depth_,0);
            (void)command(KinectOneNativeUsb::command::mode(true,0x00640064u));
            (void)command(KinectOneNativeUsb::command::mode(false));
            (void)command(KinectOneNativeUsb::command::stop());
            (void)command(KinectOneNativeUsb::command::streaming(false));
            (void)command(KinectOneNativeUsb::command::mode(true));
            (void)command(KinectOneNativeUsb::command::mode(false));
            (void)command(KinectOneNativeUsb::command::mode(true));
            (void)command(KinectOneNativeUsb::command::mode(false));
            streaming_=false;
        }
        if(control_)(void)setVideoFunction(false);
        if(depth_){WinUsb_Free(depth_);depth_=nullptr;}
        if(control_){WinUsb_Free(control_);control_=nullptr;}
        if(file_!=INVALID_HANDLE_VALUE){CloseHandle(file_);file_=INVALID_HANDLE_VALUE;}
    }
private:
    bool controlNoData(UCHAR requestType,UCHAR request,USHORT value,USHORT index){WINUSB_SETUP_PACKET packet{};packet.RequestType=requestType;packet.Request=request;packet.Value=value;packet.Index=index;packet.Length=0;ULONG transferred=0;return WinUsb_ControlTransfer(control_,packet,nullptr,0,&transferred,nullptr)!=FALSE;}
    bool setVideoFunction(bool enabled){const USHORT options=enabled?0u:3u;return controlNoData(0x01,0x03,0,static_cast<USHORT>((options<<8)|KinectOneNativeUsb::ControlInterface));}
    bool startIso(std::string& error){
        WINUSB_PIPE_INFORMATION_EX pipe{};bool found=false;
        for(UCHAR i=0;i<16;++i){if(WinUsb_QueryPipeEx(depth_,1,i,&pipe)&&pipe.PipeId==KinectOneNativeUsb::DepthIn){found=true;break;}}
        if(!found||pipe.MaximumBytesPerInterval<0x8400){error="iso-bandwidth";return false;}
        isoPacketBytes_=pipe.MaximumBytesPerInterval;isoPackets_=8;isoBatchBytes_=isoPacketBytes_*isoPackets_;isoBytes_=isoBatchBytes_*IsoQueueDepth;
        isoMemory_=static_cast<PUCHAR>(VirtualAlloc(nullptr,isoBytes_,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE));if(!isoMemory_){error="iso-memory";return false;}
        if(!WinUsb_RegisterIsochBuffer(depth_,KinectOneNativeUsb::DepthIn,isoMemory_,isoBytes_,&isoBuffer_)){error="iso-register";return false;}
        isoRunning_=true;return true;
    }
    void depthLoop(){
        struct Slot{OVERLAPPED ov{};std::vector<USBD_ISO_PACKET_DESCRIPTOR> packets;ULONG offset=0;};
        std::array<Slot,IsoQueueDepth> slots;
        std::array<HANDLE,IsoQueueDepth> events{};
        for(ULONG i=0;i<IsoQueueDepth;++i){slots[i].offset=i*isoBatchBytes_;slots[i].packets.resize(isoPackets_);slots[i].ov.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);events[i]=slots[i].ov.hEvent;if(!events[i]){failed_=true;isoRunning_=false;break;}}
        bool continuing=false;
        auto submit=[&](Slot& slot)->bool{
            memset(slot.packets.data(),0,slot.packets.size()*sizeof(slot.packets[0]));ResetEvent(slot.ov.hEvent);
            BOOL ok=WinUsb_ReadIsochPipeAsap(isoBuffer_,slot.offset,isoBatchBytes_,continuing?TRUE:FALSE,isoPackets_,slot.packets.data(),&slot.ov);
            if(!ok&&GetLastError()!=ERROR_IO_PENDING)return false;
            continuing=true;
            return true;
        };
        if(isoRunning_){for(auto& slot:slots)if(!submit(slot)){failed_=true;isoRunning_=false;break;}}
        while(isoRunning_&&g_running&&!failed_){
            DWORD wait=WaitForMultipleObjects(IsoQueueDepth,events.data(),FALSE,1000);
            if(wait==WAIT_TIMEOUT) continue;
            if(wait>=WAIT_OBJECT_0+IsoQueueDepth){failed_=true;break;}
            const ULONG index=wait-WAIT_OBJECT_0;Slot& slot=slots[index];DWORD transferred=0;
            if(!GetOverlappedResult(file_,&slot.ov,&transferred,FALSE)){DWORD e=GetLastError();if(e==ERROR_OPERATION_ABORTED&&!isoRunning_)break;failed_=true;break;}
            for(ULONG i=0;i<isoPackets_;++i){const auto& d=slot.packets[i];if(d.Status!=0||d.Offset+d.Length>isoBatchBytes_)continue;std::vector<std::uint8_t> raw;std::uint32_t ts=0;
                const std::uint8_t* data=d.Length?isoMemory_+slot.offset+d.Offset:nullptr;
                if(depthAssembler_.pushIsoPacket(data,d.Length,raw,ts)){std::lock_guard<std::mutex> lock(queueMutex_);depthQueue_.push_back({std::move(raw),ts});if(depthQueue_.size()>3)depthQueue_.pop_front();}}
            memset(&slot.ov.Internal,0,sizeof(slot.ov.Internal));memset(&slot.ov.InternalHigh,0,sizeof(slot.ov.InternalHigh));
            if(!submit(slot)){failed_=true;break;}
        }
        CancelIoEx(file_,nullptr);
        for(auto& slot:slots){if(slot.ov.hEvent){WaitForSingleObject(slot.ov.hEvent,100);CloseHandle(slot.ov.hEvent);slot.ov.hEvent=nullptr;}}
    }
    void drainDepth(HANDLE client,std::uint32_t mask,std::uint64_t& frame){std::deque<std::pair<std::vector<std::uint8_t>,std::uint32_t>> q;{std::lock_guard<std::mutex> lock(queueMutex_);q.swap(depthQueue_);}for(auto& item:q){std::vector<std::uint16_t> depth,ir;bool needIr=(mask&StreamInfrared)!=0;if(!decoder_.decode(item.first,depth,needIr?&ir:nullptr))continue;if((mask&StreamDepth)&&!sendFrame(client,StreamMode::Depth,512,424,PixelFormat::DepthMm16,reinterpret_cast<std::uint8_t*>(depth.data()),depth.size()*2,++frame)){failed_=true;return;}if(needIr&&!sendFrame(client,StreamMode::Infrared,512,424,PixelFormat::InfraredU16,reinterpret_cast<std::uint8_t*>(ir.data()),ir.size()*2,++frame)){failed_=true;return;}}}
    bool writeAll(HANDLE pipe,const void* data,std::size_t bytes){const auto* p=static_cast<const std::uint8_t*>(data);while(bytes){DWORD part=static_cast<DWORD>(std::min<std::size_t>(bytes,16u*1024u*1024u)),written=0;if(!WriteFile(pipe,p,part,&written,nullptr)||written==0)return false;p+=written;bytes-=written;}return true;}
    bool sendFrame(HANDLE pipe,StreamMode mode,std::uint32_t w,std::uint32_t h,PixelFormat format,const std::uint8_t* data,std::size_t bytes,std::uint64_t frameNo){FrameHeader hdr{};hdr.mode=mode;hdr.width=w;hdr.height=h;hdr.pixelFormat=format;hdr.payloadBytes=static_cast<std::uint32_t>(bytes);hdr.frameNumber=frameNo;hdr.tickMs=tickMs();return writeAll(pipe,&hdr,sizeof(hdr))&&writeAll(pipe,data,bytes);}

    DeviceInfo info_{};HANDLE file_=INVALID_HANDLE_VALUE;WINUSB_INTERFACE_HANDLE control_=nullptr,depth_=nullptr;std::uint32_t sequence_=1;bool streaming_=false;KinectOneDepthEngine::Decoder decoder_{};KinectOneNativeUsb::JpegAssembler jpegAssembler_{};KinectOneNativeUsb::DepthFrameAssembler depthAssembler_{};
    static constexpr ULONG IsoQueueDepth=4;WINUSB_ISOCH_BUFFER_HANDLE isoBuffer_=nullptr;PUCHAR isoMemory_=nullptr;ULONG isoPacketBytes_=0,isoPackets_=0,isoBatchBytes_=0,isoBytes_=0;std::atomic<bool> isoRunning_{false},failed_{false};std::uint32_t depthMask_=0;std::thread depthThread_;std::mutex queueMutex_;std::deque<std::pair<std::vector<std::uint8_t>,std::uint32_t>> depthQueue_;
};

std::string probeState(const std::wstring& path,const std::string& id){if(deviceActive(id))return "Ready";DeviceInfo d;d.path=path;WinUsbSession s(d);std::string error;if(!s.open(error))return "Unavailable";return s.probe()?"Ready":"Unavailable";}
std::vector<DeviceInfo> enumerateDevices(){
    std::vector<DeviceInfo> devices;HDEVINFO set=SetupDiGetClassDevsW(&kDeviceInterfaceGuid,nullptr,nullptr,DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);if(set==INVALID_HANDLE_VALUE)return devices;
    for(DWORD index=0;;++index){SP_DEVICE_INTERFACE_DATA iface{};iface.cbSize=sizeof(iface);if(!SetupDiEnumDeviceInterfaces(set,nullptr,&kDeviceInterfaceGuid,index,&iface)){if(GetLastError()==ERROR_NO_MORE_ITEMS)break;continue;}DWORD required=0;SetupDiGetDeviceInterfaceDetailW(set,&iface,nullptr,0,&required,nullptr);if(required<sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W))continue;std::vector<std::uint8_t> storage(required);auto* detail=reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(storage.data());detail->cbSize=sizeof(*detail);SP_DEVINFO_DATA dev{};dev.cbSize=sizeof(dev);if(!SetupDiGetDeviceInterfaceDetailW(set,&iface,detail,required,nullptr,&dev))continue;DeviceInfo info;info.path=detail->DevicePath;info.id=stableDeviceId(info.path,firstLocationPath(set,dev));info.label="Kinect One / v2 "+info.id;info.state=probeState(info.path,info.id);devices.push_back(std::move(info));}
    SetupDiDestroyDeviceInfoList(set);return devices;
}
const DeviceInfo* findDevice(const std::vector<DeviceInfo>& devices,const std::string& id){auto it=std::find_if(devices.begin(),devices.end(),[&](const DeviceInfo& d){return d.id==id;});return it==devices.end()?nullptr:&*it;}
std::string discoveryRow(const DeviceInfo& d){bool ready=d.state=="Ready";std::ostringstream out;out<<d.id<<'\t'<<d.label<<'\t'<<d.state<<'\t'<<"\t"<<(ready?kSdkPipeProtocol:"")<<'\t'<<"\t\t\t"<<kSdkPipeProtocol<<'\t'<<kModuleId<<'\t'<<kGeneration<<'\t'<<(ready?kReadyCapabilities:kTransportCapabilities)<<'\t'<<"1920\t1080\t512\t424\t512\t424\t30\t30";return out.str();}
std::string dispatchText(std::string command){command=trim(std::move(command));auto devices=enumerateDevices();if(command=="LIST"){std::string r;for(const auto& d:devices)r+=discoveryRow(d)+"\n";return r;}if(command.rfind("GET ",0)==0){auto* d=findDevice(devices,trim(command.substr(4)));return d?discoveryRow(*d)+"\n":"ERR NOT_FOUND\n";}if(command.rfind("CONTROL\t",0)==0){std::istringstream in(command);std::string verb,id,action;std::getline(in,verb,'\t');std::getline(in,id,'\t');std::getline(in,action);auto* d=findDevice(devices,trim(id));if(!d)return "ERR NOT_FOUND\n";action=trim(action);if(action=="Status")return "OK "+d->state+"\n";if(action=="OpenCamera"||action=="OneColor"||action=="OneDepth"||action=="OneInfrared")return d->state=="Ready"?"OK Ready\n":"ERR NOT_READY\n";if(action=="OneBodyTracking")return "OK StudioBody3D\n";return "ERR UNSUPPORTED_ACTION\n";}return "ERR BAD_COMMAND\n";}
struct ParsedRequest{Request request{};std::string deviceId;bool valid=false;};
ParsedRequest parseRequest(const char* data,DWORD size){ParsedRequest out;if(size!=sizeof(Request)&&size!=sizeof(RequestV2))return out;memcpy(&out.request,data,sizeof(Request));if(out.request.magic!=kMagic||out.request.version!=kVersion)return out;if(size==sizeof(RequestV2)){RequestV2 v{};memcpy(&v,data,sizeof(v));std::size_t n=0;while(n<sizeof(v.deviceId)&&v.deviceId[n])++n;out.deviceId.assign(v.deviceId,n);}out.valid=true;return out;}
void writeReply(HANDLE pipe,const Reply& r){DWORD written=0;WriteFile(pipe,&r,sizeof(r),&written,nullptr);}

class Runtime{
public:void start(){g_running=true;server_=std::thread([this]{serverLoop();});}void stop(){if(!g_running.exchange(false))return;HANDLE wake=CreateFileW(kSdkPipe,GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,0,nullptr);if(wake!=INVALID_HANDLE_VALUE)CloseHandle(wake);if(server_.joinable())server_.join();}
private:void serve(HANDLE pipe){char buffer[4096]{};DWORD got=0;if(!ReadFile(pipe,buffer,sizeof(buffer),&got,nullptr)||got==0)return;auto parsed=parseRequest(buffer,got);if(!parsed.valid){auto response=dispatchText(std::string(buffer,got));DWORD written=0;if(!response.empty())WriteFile(pipe,response.data(),static_cast<DWORD>(response.size()),&written,nullptr);return;}Reply reply{};if(parsed.request.command!=Command::SubscribeStreams){reply.result=ResultUnsupported;writeReply(pipe,reply);return;}auto devices=enumerateDevices();const DeviceInfo* chosen=parsed.deviceId.empty()?(devices.empty()?nullptr:&devices.front()):findDevice(devices,parsed.deviceId);if(!chosen){reply.result=ResultDeviceNotFound;writeReply(pipe,reply);return;}if(chosen->state!="Ready"){reply.result=ResultDeviceBusy;writeReply(pipe,reply);return;}std::uint32_t supported=StreamRgb|StreamRgbHighQuality|StreamDepth|StreamInfrared,accepted=parsed.request.streamMask&supported;if(!accepted||accepted!=parsed.request.streamMask){reply.result=ResultUnsupported;writeReply(pipe,reply);return;}ActiveDeviceLease lease(chosen->id);if(!lease.held){reply.result=ResultDeviceBusy;writeReply(pipe,reply);return;}WinUsbSession session(*chosen);std::string error;if(!session.open(error)||!session.initialize(error)){reply.result=ResultStreamingUnavailable;writeReply(pipe,reply);return;}reply.result=ResultOk;reply.acceptedMask=accepted;reply.width=512;reply.height=424;reply.capabilities=CapabilityRgbDepthConcurrent|CapabilityInfrared|CapabilityNativeMetricDepth|CapabilityNativeJpegColor|CapabilityStudioBody3D;reply.maxPayloadBytes=16u*1024u*1024u;{const auto& c=session.depthCalibration();reply.depthCalibrationValid=2;reply.depthConstShift=c.fx;reply.depthEmitterDistance=c.fy;reply.depthReferenceDistance=c.cx;reply.depthReferencePixelSize=c.cy;}writeReply(pipe,reply);session.run(pipe,accepted);}
    void serverLoop(){while(g_running){HANDLE pipe=CreateNamedPipeW(kSdkPipe,PIPE_ACCESS_DUPLEX,PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,16,64*1024,4*1024,1000,nullptr);if(pipe==INVALID_HANDLE_VALUE){Sleep(250);continue;}BOOL connected=ConnectNamedPipe(pipe,nullptr);if(!connected&&GetLastError()==ERROR_PIPE_CONNECTED)connected=TRUE;if(connected&&g_running){++g_clientThreads;std::thread([this,pipe]{serve(pipe);FlushFileBuffers(pipe);DisconnectNamedPipe(pipe);CloseHandle(pipe);--g_clientThreads;}).detach();}else{DisconnectNamedPipe(pipe);CloseHandle(pipe);}}for(int i=0;i<100&&g_clientThreads.load()>0;++i)Sleep(50);}std::thread server_;
};
Runtime g_runtime;
void setServiceState(DWORD state,DWORD error=NO_ERROR){if(!g_serviceHandle)return;g_serviceStatus.dwServiceType=SERVICE_WIN32_OWN_PROCESS;g_serviceStatus.dwCurrentState=state;g_serviceStatus.dwControlsAccepted=state==SERVICE_RUNNING?SERVICE_ACCEPT_STOP|SERVICE_ACCEPT_SHUTDOWN:0;g_serviceStatus.dwWin32ExitCode=error;SetServiceStatus(g_serviceHandle,&g_serviceStatus);}
void WINAPI serviceControl(DWORD control){if(control!=SERVICE_CONTROL_STOP&&control!=SERVICE_CONTROL_SHUTDOWN)return;setServiceState(SERVICE_STOP_PENDING);g_runtime.stop();}
void WINAPI serviceMain(DWORD,wchar_t**){g_serviceHandle=RegisterServiceCtrlHandlerW(kServiceName,serviceControl);if(!g_serviceHandle)return;setServiceState(SERVICE_START_PENDING);g_runtime.start();setServiceState(SERVICE_RUNNING);while(g_running)Sleep(250);g_runtime.stop();setServiceState(SERVICE_STOPPED);}
} // namespace

int wmain(int argc,wchar_t** argv){if(argc>1&&wcscmp(argv[1],L"--console")==0){g_runtime.start();while(g_running)Sleep(250);g_runtime.stop();return 0;}SERVICE_TABLE_ENTRYW table[]={{const_cast<LPWSTR>(kServiceName),serviceMain},{nullptr,nullptr}};return StartServiceCtrlDispatcherW(table)?0:static_cast<int>(GetLastError());}
