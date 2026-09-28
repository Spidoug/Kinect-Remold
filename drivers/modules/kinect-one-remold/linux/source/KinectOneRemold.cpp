#include <libusb-1.0/libusb.h>

#include "KinectOneRemoldProtocol.h"
#include "KinectOneNativeUsb.h"
#include "KinectOneDepthEngine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <chrono>
#include <csignal>
#include <cstring>
#include <deque>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace {
using namespace KinectOneRemoldProtocol;
using Clock = std::chrono::steady_clock;

constexpr std::uint16_t kVendorId = KinectOneNativeUsb::VendorId;
constexpr char kSocketPath[] = "/run/kinect-one-remold/sdk.sock";
constexpr char kModuleId[] = "kinect-one-remold";
constexpr char kGeneration[] = "xbox-one";
constexpr char kReadyCapabilities[] = "color,depth,infrared,body-tracking,native-full-hd-color,native-metric-depth,native-jpeg-color,native-libusb,usb3,packet-core";
constexpr char kTransportCapabilities[] = "native-libusb,usb3,packet-core";
constexpr std::uint8_t kUsbRecipientInterface = 0x01;
constexpr std::uint8_t kUsbRequestSetFeature = 0x03;

bool setVideoFunction(libusb_device_handle* handle,bool enabled){
    if(!handle)return false;
    const std::uint16_t suspendOptions=enabled?0u:3u;
    const std::uint16_t index=static_cast<std::uint16_t>((suspendOptions<<8)|KinectOneNativeUsb::ControlInterface);
    return libusb_control_transfer(handle,kUsbRecipientInterface,kUsbRequestSetFeature,0,index,nullptr,0,1000)>=0;
}

std::atomic<bool> g_running{true};
std::mutex g_activeMutex;
std::unordered_set<std::string> g_activeDevices;
std::atomic<int> g_clientThreads{0};

bool deviceActive(const std::string& id){std::lock_guard<std::mutex> lock(g_activeMutex);return g_activeDevices.find(id)!=g_activeDevices.end();}
bool activateDevice(const std::string& id){std::lock_guard<std::mutex> lock(g_activeMutex);return g_activeDevices.insert(id).second;}
void deactivateDevice(const std::string& id){std::lock_guard<std::mutex> lock(g_activeMutex);g_activeDevices.erase(id);}
struct ActiveDeviceLease{std::string id;bool held=false;explicit ActiveDeviceLease(std::string value):id(std::move(value)),held(activateDevice(id)){}~ActiveDeviceLease(){if(held)deactivateDevice(id);}};

struct DeviceInfo {
    std::string id, label, state;
    // Identity is stable across USB re-enumeration. topology is retained as a
    // second physical locator for the case where the serial descriptor cannot
    // be read during a later reopen.
    std::string topology;
};

bool supportedProduct(std::uint16_t productId) { return KinectOneNativeUsb::supportedProduct(productId); }
std::uint64_t tickMs() { return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now().time_since_epoch()).count(); }

std::string sanitizeId(std::string value) {
    for (char& ch : value) { const auto c=static_cast<unsigned char>(ch); if(!std::isalnum(c)&&ch!='-'&&ch!='_'&&ch!='.') ch='_'; }
    return value.empty()?"kinect-one":value;
}
std::string trim(std::string value) {
    while(!value.empty()&&std::isspace(static_cast<unsigned char>(value.back()))) value.pop_back();
    const auto first=std::find_if_not(value.begin(),value.end(),[](unsigned char c){return std::isspace(c);}); value.erase(value.begin(),first); return value;
}
std::string usbTopologyId(libusb_device* d){
    std::uint8_t ports[8]{}; const int count=libusb_get_port_numbers(d,ports,static_cast<int>(sizeof(ports)));
    if(count<=0)return {};
    std::string id="usb"+std::to_string(libusb_get_bus_number(d));
    for(int i=0;i<count;++i)id+="-"+std::to_string(ports[i]);
    return id;
}
std::string deviceIdentity(libusb_device* d,const libusb_device_descriptor& desc){
    libusb_device_handle* h=nullptr;
    if(libusb_open(d,&h)==LIBUSB_SUCCESS&&h){
        unsigned char b[256]{};const int n=desc.iSerialNumber?libusb_get_string_descriptor_ascii(h,desc.iSerialNumber,b,sizeof(b)):0;libusb_close(h);
        if(n>0)return std::string(reinterpret_cast<char*>(b),static_cast<std::size_t>(n));
    }
    return usbTopologyId(d);
}

bool readBulk(libusb_device_handle* h,std::uint8_t ep,std::vector<std::uint8_t>& out,int timeout){
    int transferred=0; int r=libusb_bulk_transfer(h,ep,out.data(),static_cast<int>(out.size()),&transferred,timeout);
    if(r!=LIBUSB_SUCCESS) return false;
    out.resize(static_cast<std::size_t>(transferred));
    return true;
}

class UsbSession {
public:
    UsbSession(libusb_context* context,const DeviceInfo& info):context_(context),info_(info){}
    ~UsbSession(){ close(); }

    bool open(std::string& error){
        libusb_device** list=nullptr; const ssize_t count=libusb_get_device_list(context_,&list);
        if(count<0){error="enumeration";return false;}
        for(ssize_t i=0;i<count;++i){
            libusb_device_descriptor d{}; if(libusb_get_device_descriptor(list[i],&d)!=LIBUSB_SUCCESS||d.idVendor!=kVendorId||!supportedProduct(d.idProduct)) continue;
            // USB device addresses are assigned by the host and change after a
            // reset/re-enumeration. Match the same sensor by its public stable
            // identity, with physical topology as a deterministic secondary
            // locator when its serial descriptor is temporarily unavailable.
            const std::string topology=usbTopologyId(list[i]);
            const std::string identity=deviceIdentity(list[i],d);
            const bool identityMatch=!identity.empty()&&sanitizeId(identity)==info_.id;
            const bool topologyMatch=!info_.topology.empty()&&topology==info_.topology;
            if(!identityMatch&&!topologyMatch) continue;
            if(libusb_open(list[i],&handle_)==LIBUSB_SUCCESS&&handle_) break;
        }
        libusb_free_device_list(list,1);
        if(!handle_){error="open";return false;}
        libusb_set_auto_detach_kernel_driver(handle_,1);
        int cfg=0; if(libusb_get_configuration(handle_,&cfg)==LIBUSB_SUCCESS&&cfg!=1&&libusb_set_configuration(handle_,1)!=LIBUSB_SUCCESS){error="configuration";return false;}
        if(libusb_claim_interface(handle_,KinectOneNativeUsb::ControlInterface)!=LIBUSB_SUCCESS){error="claim-control";return false;} controlClaimed_=true;
        if(libusb_claim_interface(handle_,KinectOneNativeUsb::DepthInterface)!=LIBUSB_SUCCESS){error="claim-depth";return false;} depthClaimed_=true;
        if(libusb_set_interface_alt_setting(handle_,KinectOneNativeUsb::DepthInterface,0)!=LIBUSB_SUCCESS){error="depth-alt-zero";return false;}
        // Kinect v2 requires the USB3 video function to begin suspended, with U1/U2
        // enabled, before the command channel starts the sensor.
        if(libusb_control_transfer(handle_,LIBUSB_RECIPIENT_DEVICE,LIBUSB_SET_ISOCH_DELAY,40,0,nullptr,0,1000)<0){error="iso-delay";return false;}
        if(libusb_control_transfer(handle_,LIBUSB_RECIPIENT_DEVICE,kUsbRequestSetFeature,48,0,nullptr,0,1000)<0||
           libusb_control_transfer(handle_,LIBUSB_RECIPIENT_DEVICE,kUsbRequestSetFeature,49,0,nullptr,0,1000)<0){error="usb3-power-state";return false;}
        if(!setVideoFunction(false)){error="video-function-suspend";return false;}
        return true;
    }

    bool command(const KinectOneNativeUsb::CommandSpec& spec,std::vector<std::uint8_t>& response,int timeout=1500){
        const std::uint32_t seq=sequence_++; const auto req=KinectOneNativeUsb::encodeCommand(seq,spec); int sent=0;
        int r=libusb_bulk_transfer(handle_,KinectOneNativeUsb::CommandOut,const_cast<unsigned char*>(req.data()),static_cast<int>(req.size()),&sent,timeout);
        if(r!=LIBUSB_SUCCESS||sent!=static_cast<int>(req.size())) return false;
        response.clear();
        if(spec.maxResponseBytes){
            response.resize(spec.maxResponseBytes); if(!readBulk(handle_,KinectOneNativeUsb::CommandIn,response,timeout)) return false;
        }
        std::vector<std::uint8_t> completion(KinectOneNativeUsb::CompletionBytes);
        if(!readBulk(handle_,KinectOneNativeUsb::CommandIn,completion,timeout)) return false;
        return KinectOneNativeUsb::validCompletion(completion.data(),completion.size(),seq);
    }
    bool command(const KinectOneNativeUsb::CommandSpec& spec){std::vector<std::uint8_t> ignored;return command(spec,ignored);}

    bool initialize(std::string& error){
        if(!setVideoFunction(true)){error="video-function-enable";return false;}
        std::vector<std::uint8_t> depthParams,p0,colorParams,status,probe;
        if(!command(KinectOneNativeUsb::command::firmwareVersions(),probe)||!command(KinectOneNativeUsb::command::hardwareInfo(),probe)||!command(KinectOneNativeUsb::command::serialNumber(),probe)){error="identity-query";return false;}
        if(!command(KinectOneNativeUsb::command::depthParameters(),depthParams,4000)){error="depth-calibration";return false;}
        if(!command(KinectOneNativeUsb::command::p0Tables(),p0,5000)){error="phase-calibration";return false;}
        if(!command(KinectOneNativeUsb::command::colorParameters(),colorParams,4000)||colorParams.size()<64){error="color-calibration";return false;}
        if(!decoder_.configure(depthParams,p0)){error="calibration-decode";return false;}
        if(!command(KinectOneNativeUsb::command::mode(true,0x00640064u))||!command(KinectOneNativeUsb::command::mode(false))){error="mode-init";return false;}
        bool sensorReady=false;
        for(int i=0;i<50;++i){
            if(!command(KinectOneNativeUsb::command::status(),status)){error="status-query";return false;}
            std::uint32_t value=0; if(status.size()>=4) std::memcpy(&value,status.data(),4); if(value&1u){sensorReady=true;break;}
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if(!sensorReady){error="sensor-not-ready";return false;}
        if(!command(KinectOneNativeUsb::command::initStreams())){error="stream-init";return false;}
        if(libusb_set_interface_alt_setting(handle_,KinectOneNativeUsb::DepthInterface,1)!=LIBUSB_SUCCESS){error="depth-alt-setting";return false;}
        if(!command(KinectOneNativeUsb::command::status(),status)){error="post-alt-status";return false;}
        if(!command(KinectOneNativeUsb::command::streaming(true))){error="stream-enable";return false;}
        streaming_=true; return startIso(error);
    }

    bool run(int client,std::uint32_t mask){
        std::uint64_t frame=0; std::vector<std::uint8_t> colorChunk(1024*1024),jpeg;
        while(g_running){
            // Service isochronous completions first, then poll RGB with a tiny timeout.
            timeval tv{0,2000}; (void)libusb_handle_events_timeout_completed(context_,&tv,nullptr);
            if(isoFailed_) return false;
            drainDepth(client,mask,frame);
            if(!((mask&StreamRgb)||(mask&StreamRgbHighQuality))){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}
            int transferred=0; int r=libusb_bulk_transfer(handle_,KinectOneNativeUsb::ColorIn,colorChunk.data(),static_cast<int>(colorChunk.size()),&transferred,4);
            if(r==LIBUSB_SUCCESS&&transferred>0){
                jpegAssembler_.push(colorChunk.data(),static_cast<std::size_t>(transferred));
                while(jpegAssembler_.pop(jpeg)){
                    const StreamMode mode=(mask&StreamRgbHighQuality)?StreamMode::RgbHighQuality:StreamMode::Rgb;
                    if(!sendFrame(client,mode,1920,1080,PixelFormat::Jpeg,jpeg.data(),jpeg.size(),++frame)) return false;
                }
            } else if(r!=LIBUSB_SUCCESS&&r!=LIBUSB_ERROR_TIMEOUT&&r!=LIBUSB_ERROR_INTERRUPTED) return false;
        }
        return true;
    }

    const KinectOneDepthEngine::DepthCameraCalibration& depthCalibration() const { return decoder_.calibration(); }

    void close(){
        stopIso();
        if(handle_&&streaming_){
            (void)libusb_set_interface_alt_setting(handle_,KinectOneNativeUsb::DepthInterface,0);
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
        if(handle_&&controlClaimed_)(void)setVideoFunction(false);
        if(handle_&&depthClaimed_){libusb_release_interface(handle_,KinectOneNativeUsb::DepthInterface);depthClaimed_=false;}
        if(handle_&&controlClaimed_){libusb_release_interface(handle_,KinectOneNativeUsb::ControlInterface);controlClaimed_=false;}
        if(handle_){libusb_close(handle_);handle_=nullptr;}
    }

private:
    bool setVideoFunction(bool enabled){return ::setVideoFunction(handle_,enabled);}
    struct IsoSlot { libusb_transfer* transfer=nullptr; std::vector<std::uint8_t> buffer; UsbSession* owner=nullptr; };
    static void LIBUSB_CALL isoCallback(libusb_transfer* transfer){
        auto* slot=static_cast<IsoSlot*>(transfer->user_data); if(!slot||!slot->owner) return; UsbSession* self=slot->owner;
        if(transfer->status==LIBUSB_TRANSFER_COMPLETED){
            for(int i=0;i<transfer->num_iso_packets;++i){auto& d=transfer->iso_packet_desc[i]; if(d.status!=LIBUSB_TRANSFER_COMPLETED) continue;
                unsigned char* data=d.actual_length?libusb_get_iso_packet_buffer_simple(transfer,i):nullptr; std::vector<std::uint8_t> raw; std::uint32_t ts=0;
                if(self->depthAssembler_.pushIsoPacket(data,d.actual_length,raw,ts)){std::lock_guard<std::mutex> lock(self->queueMutex_);self->depthQueue_.push_back({std::move(raw),ts});if(self->depthQueue_.size()>3)self->depthQueue_.pop_front();}
            }
        } else if(transfer->status!=LIBUSB_TRANSFER_CANCELLED) self->isoFailed_=true;
        if(self->isoRunning_&&transfer->status!=LIBUSB_TRANSFER_CANCELLED){
            for(int i=0;i<transfer->num_iso_packets;++i) transfer->iso_packet_desc[i].length=self->isoPacketBytes_;
            if(libusb_submit_transfer(transfer)==LIBUSB_SUCCESS) return;
            self->isoFailed_=true;
        }
        --self->isoOutstanding_;
    }

    int maxIsoBytes() const {
        libusb_device* dev=libusb_get_device(handle_); libusb_config_descriptor* config=nullptr; if(libusb_get_active_config_descriptor(dev,&config)!=LIBUSB_SUCCESS||!config) return -1;
        int result=-1;
        for(int ii=0;ii<config->bNumInterfaces&&result<0;++ii){const auto& iface=config->interface[ii];for(int a=0;a<iface.num_altsetting&&result<0;++a){const auto& alt=iface.altsetting[a];if(alt.bInterfaceNumber!=KinectOneNativeUsb::DepthInterface||alt.bAlternateSetting!=1)continue;for(int e=0;e<alt.bNumEndpoints;++e){const auto& ep=alt.endpoint[e];if(ep.bEndpointAddress!=KinectOneNativeUsb::DepthIn)continue;libusb_ss_endpoint_companion_descriptor* companion=nullptr;if(libusb_get_ss_endpoint_companion_descriptor(nullptr,&ep,&companion)==LIBUSB_SUCCESS&&companion){result=companion->wBytesPerInterval;libusb_free_ss_endpoint_companion_descriptor(companion);}else result=ep.wMaxPacketSize;}}}
        libusb_free_config_descriptor(config); return result;
    }

    bool startIso(std::string& error){
        const int packet=maxIsoBytes(); if(packet<0x8400){error="iso-bandwidth";return false;} isoPacketBytes_=packet; isoRunning_=true; constexpr int packetCount=8, transferCount=8;
        iso_.resize(transferCount);
        for(auto& slot:iso_){slot.owner=this;slot.buffer.resize(static_cast<std::size_t>(packet)*packetCount);slot.transfer=libusb_alloc_transfer(packetCount);if(!slot.transfer){error="iso-allocate";stopIso();return false;}
            libusb_fill_iso_transfer(slot.transfer,handle_,KinectOneNativeUsb::DepthIn,slot.buffer.data(),static_cast<int>(slot.buffer.size()),packetCount,isoCallback,&slot,1000);
            libusb_set_iso_packet_lengths(slot.transfer,packet);
            ++isoOutstanding_;
            if(libusb_submit_transfer(slot.transfer)!=LIBUSB_SUCCESS){--isoOutstanding_;error="iso-submit";stopIso();return false;}
        }
        return true;
    }
    void stopIso(){
        if(iso_.empty()) return;
        isoRunning_=false;
        for(auto& s:iso_) if(s.transfer) (void)libusb_cancel_transfer(s.transfer);
        for(int n=0;n<100&&isoOutstanding_.load()>0;++n){timeval tv{0,10000};(void)libusb_handle_events_timeout_completed(context_,&tv,nullptr);}
        for(auto& s:iso_) if(s.transfer){libusb_free_transfer(s.transfer);s.transfer=nullptr;}
        iso_.clear();
        isoOutstanding_=0;
    }

    bool drainDepth(int client,std::uint32_t mask,std::uint64_t& frame){
        std::deque<std::pair<std::vector<std::uint8_t>,std::uint32_t>> queue; {std::lock_guard<std::mutex> lock(queueMutex_);queue.swap(depthQueue_);} if(queue.empty())return true;
        for(auto& item:queue){std::vector<std::uint16_t> depth,ir; const bool needIr=(mask&StreamInfrared)!=0; if(!decoder_.decode(item.first,depth,needIr?&ir:nullptr))continue;
            if((mask&StreamDepth)&&!sendFrame(client,StreamMode::Depth,512,424,PixelFormat::DepthMm16,reinterpret_cast<const std::uint8_t*>(depth.data()),depth.size()*2,++frame))return false;
            if(needIr&&!sendFrame(client,StreamMode::Infrared,512,424,PixelFormat::InfraredU16,reinterpret_cast<const std::uint8_t*>(ir.data()),ir.size()*2,++frame))return false;}
        return true;
    }
    bool writeAll(int fd,const void* data,std::size_t bytes){const auto* p=static_cast<const std::uint8_t*>(data);while(bytes){ssize_t n=::write(fd,p,bytes);if(n<=0)return false;p+=n;bytes-=static_cast<std::size_t>(n);}return true;}
    bool sendFrame(int client,StreamMode mode,std::uint32_t w,std::uint32_t h,PixelFormat format,const std::uint8_t* data,std::size_t bytes,std::uint64_t frameNo){
        FrameHeader header{};header.mode=mode;header.width=w;header.height=h;header.pixelFormat=format;header.payloadBytes=static_cast<std::uint32_t>(bytes);header.frameNumber=frameNo;header.tickMs=tickMs();return writeAll(client,&header,sizeof(header))&&writeAll(client,data,bytes);
    }

    libusb_context* context_=nullptr; DeviceInfo info_{}; libusb_device_handle* handle_=nullptr; bool controlClaimed_=false,depthClaimed_=false,streaming_=false;
    std::uint32_t sequence_=1; KinectOneDepthEngine::Decoder decoder_{}; KinectOneNativeUsb::JpegAssembler jpegAssembler_{}; KinectOneNativeUsb::DepthFrameAssembler depthAssembler_{};
    std::vector<IsoSlot> iso_; int isoPacketBytes_=0; std::atomic<bool> isoRunning_{false},isoFailed_{false}; std::atomic<int> isoOutstanding_{0}; std::mutex queueMutex_; std::deque<std::pair<std::vector<std::uint8_t>,std::uint32_t>> depthQueue_;
};

bool nativeProbe(libusb_device* device){
    if(libusb_get_device_speed(device)!=LIBUSB_SPEED_SUPER&&libusb_get_device_speed(device)!=LIBUSB_SPEED_SUPER_PLUS)return false;
    libusb_device_handle* h=nullptr;if(libusb_open(device,&h)!=LIBUSB_SUCCESS||!h)return false;libusb_set_auto_detach_kernel_driver(h,1);int cfg=0;if(libusb_get_configuration(h,&cfg)==LIBUSB_SUCCESS&&cfg!=1)(void)libusb_set_configuration(h,1);
    if(libusb_claim_interface(h,KinectOneNativeUsb::ControlInterface)!=LIBUSB_SUCCESS){libusb_close(h);return false;}
    static std::atomic<std::uint32_t> seq{1};const std::uint32_t s=seq++;auto request=KinectOneNativeUsb::encodeCommand(s,KinectOneNativeUsb::command::hardwareInfo());int sent=0;
    bool ok=setVideoFunction(h,true);
    if(ok)ok=libusb_bulk_transfer(h,KinectOneNativeUsb::CommandOut,request.data(),static_cast<int>(request.size()),&sent,750)==LIBUSB_SUCCESS&&sent==static_cast<int>(request.size());
    std::vector<std::uint8_t> response(0x5c),completion(KinectOneNativeUsb::CompletionBytes);if(ok)ok=readBulk(h,KinectOneNativeUsb::CommandIn,response,750);if(ok)ok=readBulk(h,KinectOneNativeUsb::CommandIn,completion,750)&&KinectOneNativeUsb::validCompletion(completion.data(),completion.size(),s);
    (void)setVideoFunction(h,false);
    libusb_release_interface(h,KinectOneNativeUsb::ControlInterface);libusb_close(h);return ok;
}

std::vector<DeviceInfo> enumerateDevices(libusb_context* context){
    std::vector<DeviceInfo> devices;libusb_device** list=nullptr;const ssize_t count=libusb_get_device_list(context,&list);if(count<0)return devices;
    for(ssize_t i=0;i<count;++i){libusb_device_descriptor d{};if(libusb_get_device_descriptor(list[i],&d)!=LIBUSB_SUCCESS||d.idVendor!=kVendorId||!supportedProduct(d.idProduct))continue;DeviceInfo info;const std::string identity=deviceIdentity(list[i],d);if(identity.empty())continue;info.id=sanitizeId(identity);info.label="Kinect One / v2 "+identity;info.topology=usbTopologyId(list[i]);
        const int speed=libusb_get_device_speed(list[i]);if(speed!=LIBUSB_SPEED_SUPER&&speed!=LIBUSB_SPEED_SUPER_PLUS)info.state="USB3Required";else if(deviceActive(info.id))info.state="Ready";else info.state=nativeProbe(list[i])?"Ready":"Unavailable";devices.push_back(std::move(info));}
    libusb_free_device_list(list,1);return devices;
}
const DeviceInfo* findDevice(const std::vector<DeviceInfo>& devices,const std::string& id){auto it=std::find_if(devices.begin(),devices.end(),[&](const DeviceInfo& d){return d.id==id;});return it==devices.end()?nullptr:&*it;}
std::string discoveryRow(const DeviceInfo& d){const bool ready=d.state=="Ready";std::ostringstream out;out<<d.id<<'\t'<<d.label<<'\t'<<d.state<<'\t'<<"\t"<<(ready?kSocketPath:"")<<'\t'<<"\t\t\t"<<kSocketPath<<'\t'<<kModuleId<<'\t'<<kGeneration<<'\t'<<(ready?kReadyCapabilities:kTransportCapabilities)<<'\t'<<"1920\t1080\t512\t424\t512\t424\t30\t30";return out.str();}

std::string dispatchText(libusb_context* context,std::string command){command=trim(std::move(command));const auto devices=enumerateDevices(context);if(command=="LIST"){std::string r;for(const auto& d:devices)r+=discoveryRow(d)+"\n";return r;}if(command.rfind("GET ",0)==0){auto* d=findDevice(devices,trim(command.substr(4)));return d?discoveryRow(*d)+"\n":"ERR NOT_FOUND\n";}if(command.rfind("CONTROL\t",0)==0){std::istringstream in(command);std::string verb,id,action;std::getline(in,verb,'\t');std::getline(in,id,'\t');std::getline(in,action);auto* d=findDevice(devices,trim(id));if(!d)return "ERR NOT_FOUND\n";action=trim(action);if(action=="Status")return "OK "+d->state+"\n";if(action=="OpenCamera"||action=="OneColor"||action=="OneDepth"||action=="OneInfrared")return d->state=="Ready"?"OK Ready\n":"ERR NOT_READY\n";if(action=="OneBodyTracking")return "OK StudioBody3D\n";return "ERR UNSUPPORTED_ACTION\n";}return "ERR BAD_COMMAND\n";}

struct ParsedRequest { Request request{}; std::string deviceId; bool valid=false; };
ParsedRequest parseRequest(const char* data,std::size_t size){ParsedRequest out;if(size!=sizeof(Request)&&size!=sizeof(RequestV2))return out;std::memcpy(&out.request,data,sizeof(Request));if(out.request.magic!=kMagic||out.request.version!=kVersion)return out;if(size==sizeof(RequestV2)){RequestV2 v{};std::memcpy(&v,data,sizeof(v));out.deviceId.assign(v.deviceId,strnlen(v.deviceId,sizeof(v.deviceId)));}out.valid=true;return out;}
bool writeAll(int fd,const void* data,std::size_t bytes){const auto* p=static_cast<const std::uint8_t*>(data);while(bytes){ssize_t n=write(fd,p,bytes);if(n<=0)return false;p+=n;bytes-=static_cast<std::size_t>(n);}return true;}

void handleClient(int client,libusb_context* context){
    // AF_UNIX/SOCK_STREAM does not preserve write boundaries. Studio uses the
    // device-scoped 80-byte request for Kinect One subscriptions, while SDK text
    // commands are newline terminated. Read the complete logical request before
    // parsing so device IDs cannot be truncated by a short stream read.
    std::array<char,4096> buffer{};std::size_t used=0,target=0;
    while(used<buffer.size()){
        const ssize_t n=read(client,buffer.data()+used,buffer.size()-used);if(n<=0)return;used+=static_cast<std::size_t>(n);
        if(std::memchr(buffer.data(),'\n',used)!=nullptr)break;
        if(target==0&&used>=sizeof(Request)){
            Request base{};std::memcpy(&base,buffer.data(),sizeof(base));
            if(base.magic==kMagic&&base.version==kVersion)target=sizeof(RequestV2);
        }
        if(target>0&&used>=target){used=target;break;}
    }
    ParsedRequest parsed=parseRequest(buffer.data(),used);if(!parsed.valid){const std::string response=dispatchText(context,std::string(buffer.data(),used));if(!response.empty())writeAll(client,response.data(),response.size());return;}
    Reply reply{};if(parsed.request.command!=Command::SubscribeStreams){reply.result=ResultUnsupported;writeAll(client,&reply,sizeof(reply));return;}
    auto devices=enumerateDevices(context);const DeviceInfo* chosen=parsed.deviceId.empty()?(devices.empty()?nullptr:&devices.front()):findDevice(devices,parsed.deviceId);if(!chosen){reply.result=ResultDeviceNotFound;writeAll(client,&reply,sizeof(reply));return;}if(chosen->state!="Ready"){reply.result=ResultDeviceBusy;writeAll(client,&reply,sizeof(reply));return;}
    const std::uint32_t supported=StreamRgb|StreamRgbHighQuality|StreamDepth|StreamInfrared;const std::uint32_t accepted=parsed.request.streamMask&supported;if(accepted!=parsed.request.streamMask||accepted==0){reply.result=ResultUnsupported;writeAll(client,&reply,sizeof(reply));return;}
    ActiveDeviceLease lease(chosen->id);if(!lease.held){reply.result=ResultDeviceBusy;writeAll(client,&reply,sizeof(reply));return;}
    UsbSession session(context,*chosen);std::string error;if(!session.open(error)||!session.initialize(error)){reply.result=ResultStreamingUnavailable;writeAll(client,&reply,sizeof(reply));return;}
    reply.result=ResultOk;reply.acceptedMask=accepted;reply.width=512;reply.height=424;reply.capabilities=CapabilityRgbDepthConcurrent|CapabilityInfrared|CapabilityNativeMetricDepth|CapabilityNativeJpegColor|CapabilityStudioBody3D;reply.maxPayloadBytes=16u*1024u*1024u;{const auto& c=session.depthCalibration();reply.depthCalibrationValid=2;reply.depthConstShift=c.fx;reply.depthEmitterDistance=c.fy;reply.depthReferenceDistance=c.cx;reply.depthReferencePixelSize=c.cy;}if(!writeAll(client,&reply,sizeof(reply)))return;(void)session.run(client,accepted);
}
void stopSignal(int){g_running=false;}
} // namespace

int main(){
    std::signal(SIGINT,stopSignal);std::signal(SIGTERM,stopSignal);libusb_context* context=nullptr;if(libusb_init(&context)!=LIBUSB_SUCCESS)return 2;std::error_code ec;std::filesystem::create_directories("/run/kinect-one-remold",ec);unlink(kSocketPath);
    const int server=socket(AF_UNIX,SOCK_STREAM,0);if(server<0){libusb_exit(context);return 3;}sockaddr_un address{};address.sun_family=AF_UNIX;std::strncpy(address.sun_path,kSocketPath,sizeof(address.sun_path)-1);if(bind(server,reinterpret_cast<sockaddr*>(&address),sizeof(address))!=0||listen(server,16)!=0){close(server);libusb_exit(context);return 4;}chmod(kSocketPath,0666);
    while(g_running){const int client=accept(server,nullptr,nullptr);if(client<0){if(!g_running)break;continue;}
        timeval receiveTimeout{2,0};(void)setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&receiveTimeout,sizeof(receiveTimeout));
        ++g_clientThreads;std::thread([client,context]{handleClient(client,context);close(client);--g_clientThreads;}).detach();
    }
    close(server);unlink(kSocketPath);for(int i=0;i<100&&g_clientThreads.load()>0;++i)std::this_thread::sleep_for(std::chrono::milliseconds(50));libusb_exit(context);return 0;
}
