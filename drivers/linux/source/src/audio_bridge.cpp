#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <functional>
#include <iomanip>
#include <fstream>
#include <memory>
#include <mutex>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include <grp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <alsa/asoundlib.h>
#include <libusb-1.0/libusb.h>

#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"
#include "Kinect360RemoldAudioFirmware.generated.h"

using namespace remold;

namespace {
std::atomic<bool> run{true};
void stoph(int){run=false;}

constexpr uint16_t VID=0x045e;
constexpr uint16_t BOOT_PID=0x02ad;
constexpr uint16_t UAC_RUNTIME_PIDS[]={0x02bb,0x02c3};
constexpr uint32_t CMDMAG=0x06022009u, STATMAG=0x0A6FE000u;
constexpr uint32_t LOAD=0x00080000u, ENTRY=0x00080030u;
constexpr uint8_t BULK_IN=0x81, BULK_OUT=0x01;
constexpr uint32_t PAGE_BYTES=16u*1024u, CHUNK_BYTES=512u;
constexpr int BOOT_TIMEOUT_MS=10000;
constexpr int POST_FIRMWARE_DELAY_MS=1500;
constexpr int AUDIO_RETRY_MS=500;

#pragma pack(push,1)
struct BootCommand{uint32_t magic,tag,bytes,command,address,unknown;};
struct BootStatus{uint32_t magic,tag,status;};
#pragma pack(pop)
static_assert(sizeof(BootCommand)==24);
static_assert(sizeof(BootStatus)==12);

struct Diag{
  std::atomic<uint64_t> usbOpen{0},bootSessions{0},runtimeSessions{0},fwUploads{0},fwFailures{0},alsaReads{0},published{0},clients{0};
  std::atomic<int> captureVolumeBasisPoints{10000};std::atomic<bool> captureMuted{false};
  std::mutex m;std::string stage="starting",detail="",captureBackend="software",capturePcm="";int last=0;
  void audio_state(int volume,bool muted,std::string backend,std::string pcm=""){{std::lock_guard<std::mutex>g(m);captureVolumeBasisPoints=volume;captureMuted=muted;captureBackend=std::move(backend);if(!pcm.empty())capturePcm=std::move(pcm);}write();}
  void set(std::string s,int e=0,std::string d=""){{std::lock_guard<std::mutex>g(m);stage=std::move(s);last=e;detail=std::move(d);}write();}
  void write(){
    std::string s,d,backend,pcm;int e;{std::lock_guard<std::mutex>g(m);s=stage;d=detail;e=last;backend=captureBackend;pcm=capturePcm;}
    std::filesystem::create_directories(kRuntimeDir);
    std::ostringstream o;
    o<<"version=1\nheartbeat_ms="<<unixio::monotonic_ms()
     <<"\naudio_transport_model=kinect-uac-alsa"
     <<"\nboot_usb_pid=02ad\nruntime_usb_pid=02bb/02c3"
     <<"\nboot_transport=libusb-1.0-bulk-ep01-ep81"
     <<"\nruntime_transport=snd-usb-audio-alsa"
     <<"\ncapture_share_policy=dsnoop-preferred-plughw-hw-fallback"
     <<"\naudio_control_socket="<<kAudioControlSocket
     <<"\ncapture_volume_basis_points="<<captureVolumeBasisPoints.load()
     <<"\ncapture_muted="<<(captureMuted.load()?1:0)
     <<"\ncapture_volume_backend="<<backend
     <<"\ncapture_pcm="<<pcm
     <<"\ncapture_sample_rate=16000\ncapture_channels=4\ncapture_bits=32"
     <<"\nfirmware_kind=Microsoft-Kinect-Runtime-1.8-UACFirmware"
     <<"\nfirmware_version="<<gRemoldAudioFirmwareVersion
     <<"\nfirmware_sha256="<<gRemoldAudioFirmwareSha256
     <<"\nfirmware_bytes="<<gRemoldAudioFirmwareSize
     <<"\nfirmware_load_address=0x00080000\nfirmware_entry_address=0x00080030"
     <<"\nstage="<<s<<"\ndetail="<<d<<"\nlast_error="<<e
     <<"\nusb_open_attempts="<<usbOpen.load()<<"\nboot_sessions="<<bootSessions.load()
     <<"\nfirmware_uploads="<<fwUploads.load()<<"\nfirmware_failures="<<fwFailures.load()
     <<"\nruntime_sessions="<<runtimeSessions.load()<<"\nalsa_reads="<<alsaReads.load()
     <<"\npublished_frames="<<published.load()<<"\npipe_clients="<<clients.load()<<"\n";
    std::string tmp=std::string(kAudioStatus)+".tmp";{std::ofstream f(tmp);f<<o.str();}
    std::error_code ec;std::filesystem::rename(tmp,kAudioStatus,ec);if(ec){std::filesystem::remove(kAudioStatus,ec);std::filesystem::rename(tmp,kAudioStatus,ec);}
  }
}diag;

std::vector<std::string> sensor_id_aliases(const std::string& id){
  std::vector<std::string> out;if(id.empty())return out;out.push_back(id);
  if(id.rfind("usb-",0)!=0)return out;
  const auto dash=id.find('-',4);if(dash==std::string::npos||dash+1>=id.size())return out;
  std::string path=id.substr(dash+1);
  for(int depth=0;depth<2;depth++){const auto dot=path.rfind('.');if(dot==std::string::npos)break;path.resize(dot);out.push_back(id.substr(0,dash+1)+path);}
  return out;
}

std::string resolve_sensor_id(const std::string& requested,const std::set<std::string>& active){
  if(active.empty())return {};
  if(requested.empty())return *active.begin();
  if(active.find(requested)!=active.end())return requested;
  const auto requestedAliases=sensor_id_aliases(requested);
  std::string match;std::size_t bestScore=0;bool ambiguous=false;
  for(const auto&candidate:active){
    const auto candidateAliases=sensor_id_aliases(candidate);std::size_t score=0;
    for(const auto&a:requestedAliases){if(std::find(candidateAliases.begin(),candidateAliases.end(),a)!=candidateAliases.end())score=std::max(score,a.size());}
    if(score==0)continue;
    if(score>bestScore){bestScore=score;match=candidate;ambiguous=false;}
    else if(score==bestScore&&candidate!=match)ambiguous=true;
  }
  if(bestScore>0&&!ambiguous)return match;
  return active.size()==1?*active.begin():std::string{};
}

class AudioRouter{
public:
  explicit AudioRouter(const char*p):path_(p){}~AudioRouter(){stop();}
  bool start(){s_=unixio::server_socket(path_,0666);if(s_<0)return false;t_=std::thread([this]{accept_loop();});return true;}
  void stop(){stopping_=true;if(s_>=0){::shutdown(s_,SHUT_RDWR);::close(s_);s_=-1;}if(t_.joinable())t_.join();std::lock_guard<std::mutex>g(m_);for(auto&c:clients_)::close(c.fd);clients_.clear();::unlink(path_.c_str());}
  void set_active_ids(const std::vector<std::string>& ids){std::lock_guard<std::mutex>g(m_);active_.clear();active_.insert(ids.begin(),ids.end());}
  void publish(const std::string&id,const int32_t*p,uint64_t frame,uint32_t channelMask=0xF){
    audio::FrameHeader h{};h.channelMask=channelMask;h.frameNumber=frame;h.tickMs=unixio::monotonic_ms();
    std::lock_guard<std::mutex>g(m_);
    for(auto it=clients_.begin();it!=clients_.end();){
      if(it->id!=id){++it;continue;}
      if(!unixio::write_all(it->fd,&h,sizeof(h))||!unixio::write_all(it->fd,p,audio::kPayloadBytes)){::close(it->fd);it=clients_.erase(it);diag.clients.fetch_sub(1);}else ++it;
    }
  }
private:
  struct Client{int fd=-1;std::string id;};
  std::string path_;int s_=-1;std::thread t_;std::atomic<bool>stopping_{false};std::mutex m_;std::vector<Client>clients_;std::set<std::string>active_;
  void accept_loop(){while(!stopping_&&run){int c=::accept4(s_,nullptr,nullptr,SOCK_CLOEXEC);if(c<0){if(errno==EINTR)continue;if(stopping_)break;continue;}audio::Request q{};audio::Reply r{};if(!unixio::read_exact(c,&q,sizeof(q))||q.magic!=audio::kMagic||q.version!=audio::kVersion||q.command!=audio::Command::SubscribeMicrophones){::close(c);continue;}std::string target(q.deviceId,strnlen(q.deviceId,sizeof(q.deviceId)));{std::lock_guard<std::mutex>g(m_);target=resolve_sensor_id(target,active_);if(target.empty())r.result=-ENODEV;}if(!unixio::write_all(c,&r,sizeof(r))||r.result<0){::close(c);continue;}std::lock_guard<std::mutex>g(m_);clients_.push_back(Client{c,target});diag.clients.fetch_add(1);}}
};

struct UsbBoot{
  libusb_device_handle*h=nullptr;int iface=-1,alt=0;std::string identityKey;
  ~UsbBoot(){if(h){if(iface>=0)libusb_release_interface(h,iface);libusb_close(h);}}
};

std::string usb_identity_key(libusb_device*dev){
  if(!dev)return {};
  std::array<uint8_t,8> ports{};
  const int count=libusb_get_port_numbers(dev,ports.data(),static_cast<int>(ports.size()));
  if(count<=0)return {};
  std::ostringstream out;out<<static_cast<unsigned>(libusb_get_bus_number(dev))<<":";
  for(int i=0;i<count;i++){if(i)out<<'.';out<<static_cast<unsigned>(ports[static_cast<size_t>(i)]);}
  return out.str();
}

std::set<std::string> enumerate_audio_family_keys(libusb_context*ctx){
  std::set<std::string> keys;libusb_device**list=nullptr;const ssize_t count=libusb_get_device_list(ctx,&list);
  if(count<0)return keys;
  for(ssize_t i=0;i<count;i++){
    libusb_device_descriptor dd{};if(libusb_get_device_descriptor(list[i],&dd)!=0||dd.idVendor!=VID)continue;
    const bool family=dd.idProduct==BOOT_PID||std::any_of(std::begin(UAC_RUNTIME_PIDS),std::end(UAC_RUNTIME_PIDS),[&](uint16_t p){return p==dd.idProduct;});
    if(!family)continue;
    auto key=usb_identity_key(list[i]);
    if(!key.empty())keys.insert(std::move(key));
  }
  libusb_free_device_list(list,1);return keys;
}

std::unique_ptr<UsbBoot> open_boot(libusb_context*ctx,const std::set<std::string>&suppressedKeys={}){
  libusb_device**list=nullptr;const ssize_t count=libusb_get_device_list(ctx,&list);if(count<0)return {};
  std::unique_ptr<UsbBoot> result;
  for(ssize_t i=0;i<count&&!result;i++){
    libusb_device_descriptor dd{};if(libusb_get_device_descriptor(list[i],&dd)!=0||dd.idVendor!=VID||dd.idProduct!=BOOT_PID)continue;
    const std::string identityKey=usb_identity_key(list[i]);
    if(!identityKey.empty()&&suppressedKeys.find(identityKey)!=suppressedKeys.end())continue;
    libusb_config_descriptor*cfg=nullptr;if(libusb_get_active_config_descriptor(list[i],&cfg)!=0&&libusb_get_config_descriptor(list[i],0,&cfg)!=0)continue;
    int iface=-1,altSetting=0;
    // Only the dedicated 02AD boot identity may receive UACFirmware.
    // Do not upload into a post-firmware runtime interface.
    if(cfg->bNumInterfaces==1){
      for(int ai=0;ai<cfg->interface[0].num_altsetting&&iface<0;ai++){
        const auto&alt=cfg->interface[0].altsetting[ai];bool in=false,out=false;
        for(uint8_t e=0;e<alt.bNumEndpoints;e++){
          const auto&ep=alt.endpoint[e];if((ep.bmAttributes&LIBUSB_TRANSFER_TYPE_MASK)!=LIBUSB_TRANSFER_TYPE_BULK)continue;
          if(ep.bEndpointAddress==BULK_IN)in=true;
          if(ep.bEndpointAddress==BULK_OUT)out=true;
        }
        if(in&&out){iface=alt.bInterfaceNumber;altSetting=alt.bAlternateSetting;}
      }
    }
    libusb_free_config_descriptor(cfg);if(iface<0)continue;
    diag.usbOpen.fetch_add(1);libusb_device_handle*h=nullptr;if(libusb_open(list[i],&h)!=0||!h)continue;
    libusb_set_auto_detach_kernel_driver(h,1);
    if(libusb_claim_interface(h,iface)!=0){libusb_close(h);continue;}
    if(altSetting&&libusb_set_interface_alt_setting(h,iface,altSetting)!=0){libusb_release_interface(h,iface);libusb_close(h);continue;}
    result=std::make_unique<UsbBoot>();result->h=h;result->iface=iface;result->alt=altSetting;result->identityKey=identityKey;
  }
  libusb_free_device_list(list,1);return result;
}

bool bulk_write(UsbBoot&s,const void*p,int n){int x=0;return libusb_bulk_transfer(s.h,BULK_OUT,(unsigned char*)const_cast<void*>(p),n,&x,BOOT_TIMEOUT_MS)==0&&x==n;}
bool bulk_read_exact(UsbBoot&s,void*p,int n){int x=0;return libusb_bulk_transfer(s.h,BULK_IN,(unsigned char*)p,n,&x,BOOT_TIMEOUT_MS)==0&&x==n;}
bool bulk_read_any(UsbBoot&s,void*p,int capacity){int x=0;return libusb_bulk_transfer(s.h,BULK_IN,(unsigned char*)p,capacity,&x,BOOT_TIMEOUT_MS)==0&&x>0;}
bool status(UsbBoot&s,uint32_t tag){BootStatus st{};return bulk_read_exact(s,&st,sizeof(st))&&st.magic==STATMAG&&st.tag==tag&&st.status==0;}

bool upload_uac_firmware(UsbBoot&s){
  if(gRemoldAudioFirmwareSize==0)return false;
  uint32_t tag=1;
  BootCommand probe{CMDMAG,tag,0x60,0,0x15,0};
  std::array<uint8_t,512>version{};
  // Same Windows interface: the loader sends one non-empty version packet before
  // the 12-byte status reply; its exact payload length is not used as a gate.
  if(!bulk_write(s,&probe,sizeof(probe))||!bulk_read_any(s,version.data(),static_cast<int>(version.size()))||!status(s,tag))return false;
  ++tag;
  uint32_t address=LOAD;size_t sent=0;
  while(sent<gRemoldAudioFirmwareSize&&run){
    const uint32_t page=static_cast<uint32_t>(std::min<size_t>(PAGE_BYTES,gRemoldAudioFirmwareSize-sent));
    BootCommand command{CMDMAG,tag,page,3,address,0};if(!bulk_write(s,&command,sizeof(command)))return false;
    uint32_t pageSent=0;
    while(pageSent<page){
      const uint32_t chunk=std::min<uint32_t>(CHUNK_BYTES,page-pageSent);
      if(!bulk_write(s,gRemoldAudioFirmware+sent+pageSent,static_cast<int>(chunk)))return false;
      pageSent+=chunk;
    }
    if(!status(s,tag))return false;
    sent+=page;address+=page;++tag;
  }
  if(!run)return false;
  BootCommand launch{CMDMAG,tag,0,4,ENTRY,0};if(!bulk_write(s,&launch,sizeof(launch)))return false;
  // A successful launch may return status or immediately re-enumerate the USB device.
  BootStatus st{};int transferred=0;
  const int rc=libusb_bulk_transfer(s.h,BULK_IN,reinterpret_cast<unsigned char*>(&st),sizeof(st),&transferred,BOOT_TIMEOUT_MS);
  if(rc==LIBUSB_ERROR_NO_DEVICE||rc==LIBUSB_ERROR_IO||rc==LIBUSB_ERROR_PIPE)return true;
  return rc==0&&transferred==static_cast<int>(sizeof(st))&&st.magic==STATMAG&&st.tag==tag&&st.status==0;
}

struct SoundUsbIdentity{std::string sensorId,functionKey;};

SoundUsbIdentity sound_usb_identity(const std::filesystem::path&p){
  std::error_code ec;auto cur=std::filesystem::canonical(p,ec);if(ec)return {};
  for(int i=0;i<12&&!cur.empty();i++,cur=cur.parent_path()){
    std::ifstream v(cur/"idVendor"),d(cur/"idProduct");std::string vs,ds;
    if(!(v>>vs&&d>>ds))continue;
    if(vs!="045e")return {};
    bool family=(ds=="02ad");for(uint16_t pid:UAC_RUNTIME_PIDS){char b[5];std::snprintf(b,sizeof(b),"%04x",pid);if(ds==b){family=true;break;}}
    if(!family)return {};
    std::ifstream bf(cur/"busnum"),pf(cur/"devpath");unsigned bus=0;std::string devpath;
    if(!(bf>>bus)||!(pf>>devpath)||devpath.empty())return {};
    std::ostringstream function;function<<bus<<":"<<devpath;
    std::string sensorPath=devpath;const auto dot=sensorPath.rfind('.');if(dot!=std::string::npos)sensorPath.resize(dot);
    std::ostringstream sensor;sensor<<"usb-"<<std::setfill('0')<<std::setw(3)<<bus<<'-'<<sensorPath;
    return {sensor.str(),function.str()};
  }
  return {};
}

std::string sensor_id_from_sound_path(const std::filesystem::path&p){return sound_usb_identity(p).sensorId;}

std::set<std::string> active_alsa_function_keys(){
  std::set<std::string> keys;std::error_code ec;std::filesystem::directory_iterator it("/sys/class/sound",ec),end;if(ec)return keys;
  for(;it!=end;it.increment(ec)){
    if(ec){ec.clear();continue;}const auto name=it->path().filename().string();if(name.rfind("card",0)!=0)continue;
    const auto identity=sound_usb_identity(it->path()/"device");if(!identity.functionKey.empty())keys.insert(identity.functionKey);
  }
  return keys;
}

struct PcmEndpoint{
  std::string id,card,functionKey;int device=-1;std::vector<std::string> candidates;
  bool valid()const{return !id.empty()&&!card.empty()&&device>=0;}
};

std::string lower_ascii(std::string value){for(char&c:value)c=static_cast<char>(std::tolower(static_cast<unsigned char>(c)));return value;}
int mixer_score(const char* raw){
  const std::string n=lower_ascii(raw?raw:"");int score=0;
  if(n.find("mic")!=std::string::npos)score+=50;
  if(n.find("capture")!=std::string::npos)score+=40;
  if(n.find("input")!=std::string::npos)score+=25;
  if(n.find("pcm")!=std::string::npos)score+=10;
  if(n.find("master")!=std::string::npos)score+=5;
  return score;
}

struct MixerSnapshot{bool volume=false,mute=false;int volumeBp=10000;bool muted=false;};
MixerSnapshot mixer_access(const std::string&card,int setVolumeBp,bool writeVolume,int setMute,bool writeMute){
  MixerSnapshot out{};snd_mixer_t*mixer=nullptr;
  if(snd_mixer_open(&mixer,0)<0)return out;
  const std::string hw="hw:"+card;
  if(snd_mixer_attach(mixer,hw.c_str())<0||snd_mixer_selem_register(mixer,nullptr,nullptr)<0||snd_mixer_load(mixer)<0){snd_mixer_close(mixer);return out;}
  snd_mixer_elem_t*best=nullptr;int bestScore=-1;
  for(auto*e=snd_mixer_first_elem(mixer);e;e=snd_mixer_elem_next(e)){
    if(!snd_mixer_selem_is_active(e))continue;
    const bool hasV=snd_mixer_selem_has_capture_volume(e);const bool hasS=snd_mixer_selem_has_capture_switch(e);
    if(!hasV&&!hasS)continue;
    int score=mixer_score(snd_mixer_selem_get_name(e));if(hasV)score+=8;if(hasS)score+=4;
    if(score>bestScore){best=e;bestScore=score;}
  }
  if(best){
    if(snd_mixer_selem_has_capture_volume(best)){
      out.volume=true;long lo=0,hi=0;snd_mixer_selem_get_capture_volume_range(best,&lo,&hi);
      if(writeVolume&&hi>lo){const long raw=lo+static_cast<long>((hi-lo)*(std::clamp(setVolumeBp,0,10000)/10000.0));(void)snd_mixer_selem_set_capture_volume_all(best,raw);}
      long total=0;int count=0;
      for(int c=0;c<=SND_MIXER_SCHN_LAST;c++){auto ch=static_cast<snd_mixer_selem_channel_id_t>(c);if(!snd_mixer_selem_has_capture_channel(best,ch))continue;long raw=0;if(snd_mixer_selem_get_capture_volume(best,ch,&raw)==0){total+=raw;count++;}}
      if(count&&hi>lo)out.volumeBp=std::clamp(static_cast<int>(std::lround(((total/static_cast<double>(count))-lo)*10000.0/(hi-lo))),0,10000);
    }
    if(snd_mixer_selem_has_capture_switch(best)){
      out.mute=true;if(writeMute)(void)snd_mixer_selem_set_capture_switch_all(best,setMute?0:1);
      int enabled=1,seen=0;
      for(int c=0;c<=SND_MIXER_SCHN_LAST;c++){auto ch=static_cast<snd_mixer_selem_channel_id_t>(c);if(!snd_mixer_selem_has_capture_channel(best,ch))continue;int sw=1;if(snd_mixer_selem_get_capture_switch(best,ch,&sw)==0){enabled&=sw;seen++;}}
      if(seen)out.muted=!enabled;
    }
  }
  snd_mixer_close(mixer);return out;
}

class CaptureVolumeController{
public:
  void set_card(const std::string&card){
    {std::lock_guard<std::mutex>g(mu_);card_=card;}
    refresh(true);
  }
  int set_volume(int bp){volume_.store(std::clamp(bp,0,10000));refresh(false,true,false);return 0;}
  int set_mute(bool value){muted_.store(value);refresh(false,false,true);return 0;}
  audio::ControlReply state(){refresh(false);audio::ControlReply r{};r.volumeBasisPoints=volume_.load();r.muted=muted_.load()?1u:0u;r.backend=(hardwareVolume_.load()||hardwareMute_.load())?audio::VolumeBackend::AlsaMixer:audio::VolumeBackend::Software;return r;}
  void process(int32_t*data,std::size_t samples){
    if(!data||samples==0)return;
    if(muted_.load()&&!hardwareMute_.load()){std::fill(data,data+samples,0);return;}
    if(hardwareVolume_.load())return;
    const int bp=volume_.load();if(bp==10000)return;const double gain=bp/10000.0;
    for(std::size_t i=0;i<samples;i++){const double v=static_cast<double>(data[i])*gain;data[i]=static_cast<int32_t>(std::clamp(v,static_cast<double>(INT32_MIN),static_cast<double>(INT32_MAX)));}
  }
private:
  std::mutex mu_;std::string card_;std::atomic<int>volume_{10000};std::atomic<bool>muted_{false},hardwareVolume_{false},hardwareMute_{false};
  std::string card(){std::lock_guard<std::mutex>g(mu_);return card_;}
  void refresh(bool adoptHardware=false,bool writeVolume=false,bool writeMute=false){
    const std::string c=card();if(c.empty()){hardwareVolume_=false;hardwareMute_=false;diag.audio_state(volume_,muted_,"software");return;}
    const auto snap=mixer_access(c,volume_.load(),writeVolume,muted_.load()?1:0,writeMute);
    hardwareVolume_=snap.volume;hardwareMute_=snap.mute;
    if((adoptHardware||writeVolume)&&snap.volume)volume_=snap.volumeBp;
    if((adoptHardware||writeMute)&&snap.mute)muted_=snap.muted;
    diag.audio_state(volume_,muted_,(snap.volume||snap.mute)?"alsa-mixer":"software");
  }
};

class AudioControlServer{
public:
  AudioControlServer(std::mutex&mu,std::map<std::string,std::shared_ptr<CaptureVolumeController>>&controllers):mu_(mu),controllers_(controllers){}
  ~AudioControlServer(){stop();}
  bool start(){server_=unixio::server_socket(kAudioControlSocket,0666);if(server_<0)return false;thread_=std::thread([this]{loop();});return true;}
  void stop(){stopping_=true;if(server_>=0){::shutdown(server_,SHUT_RDWR);::close(server_);server_=-1;}if(thread_.joinable())thread_.join();::unlink(kAudioControlSocket);}
private:
  std::mutex&mu_;std::map<std::string,std::shared_ptr<CaptureVolumeController>>&controllers_;int server_=-1;std::atomic<bool>stopping_{false};std::thread thread_;
  std::shared_ptr<CaptureVolumeController> resolve(const char*raw,std::size_t cap){std::string requested(raw,strnlen(raw,cap));std::lock_guard<std::mutex>g(mu_);std::set<std::string>active;for(const auto&item:controllers_)active.insert(item.first);const std::string id=resolve_sensor_id(requested,active);if(id.empty())return {};auto it=controllers_.find(id);return it==controllers_.end()?std::shared_ptr<CaptureVolumeController>{}:it->second;}
  void serve(int fd){audio::ControlRequest q{};if(!unixio::read_exact(fd,&q,sizeof(q))||q.magic!=audio::kControlMagic||q.version!=audio::kVersion){::close(fd);return;}audio::ControlReply r{};auto controller=resolve(q.deviceId,sizeof(q.deviceId));if(!controller)r.result=-ENODEV;else switch(q.command){case audio::ControlCommand::GetState:break;case audio::ControlCommand::SetVolume:r.result=controller->set_volume(q.value);break;case audio::ControlCommand::SetMute:r.result=controller->set_mute(q.value!=0);break;default:r.result=-EINVAL;break;}if(r.result==0&&controller)r=controller->state();(void)unixio::write_all(fd,&r,sizeof(r));::close(fd);}
  void loop(){while(!stopping_&&run){int fd=::accept4(server_,nullptr,nullptr,SOCK_CLOEXEC);if(fd<0){if(errno==EINTR)continue;if(stopping_||!run)break;continue;}unixio::set_io_timeout(fd,3000);std::thread([this,fd]{serve(fd);}).detach();}}
};

std::vector<PcmEndpoint> find_pcms(){
  std::vector<PcmEndpoint> out;std::error_code ec;std::filesystem::directory_iterator it("/sys/class/sound",ec),end;if(ec)return out;
  for(;it!=end;it.increment(ec)){
    if(ec){ec.clear();continue;}const auto&e=*it;auto n=e.path().filename().string();if(n.rfind("card",0)!=0)continue;
    std::string num=n.substr(4);if(num.empty()||!std::all_of(num.begin(),num.end(),[](unsigned char c){return c>='0'&&c<='9';}))continue;
    const auto identity=sound_usb_identity(e.path()/"device");if(identity.sensorId.empty())continue;
    for(int dev=0;dev<16;dev++){
      const auto pcm=std::filesystem::path("/sys/class/sound")/("pcmC"+num+"D"+std::to_string(dev)+"c");
      if(std::filesystem::exists(pcm,ec)){PcmEndpoint ep;ep.id=identity.sensorId;ep.card=num;ep.functionKey=identity.functionKey;ep.device=dev;ep.candidates={"dsnoop:CARD="+num+",DEV="+std::to_string(dev),"plughw:"+num+","+std::to_string(dev),"hw:"+num+","+std::to_string(dev)};out.push_back(std::move(ep));break;}ec.clear();
    }
  }
  std::sort(out.begin(),out.end(),[](const PcmEndpoint&a,const PcmEndpoint&b){return a.id<b.id;});
  out.erase(std::unique(out.begin(),out.end(),[](const PcmEndpoint&a,const PcmEndpoint&b){return a.id==b.id;}),out.end());
  return out;
}

int capture_alsa_candidate(const std::string&name,const std::string&deviceId,AudioRouter&a,CaptureVolumeController&volume,const std::atomic<bool>&localRun){
  snd_pcm_t*pcm=nullptr;int rc=snd_pcm_open(&pcm,name.c_str(),SND_PCM_STREAM_CAPTURE,SND_PCM_NONBLOCK);if(rc<0)return rc;
  snd_pcm_hw_params_t*hw;snd_pcm_hw_params_alloca(&hw);
  if((rc=snd_pcm_hw_params_any(pcm,hw))<0||(rc=snd_pcm_hw_params_set_access(pcm,hw,SND_PCM_ACCESS_RW_INTERLEAVED))<0||(rc=snd_pcm_hw_params_set_format(pcm,hw,SND_PCM_FORMAT_S32_LE))<0){snd_pcm_close(pcm);return rc;}
  unsigned rate=16000;int dir=0;if((rc=snd_pcm_hw_params_set_rate_near(pcm,hw,&rate,&dir))<0||rate!=16000){snd_pcm_close(pcm);return rc<0?rc:-EINVAL;}
  if((rc=snd_pcm_hw_params_set_channels(pcm,hw,4))<0){snd_pcm_close(pcm);return rc;}
  snd_pcm_uframes_t period=256;if((rc=snd_pcm_hw_params_set_period_size_near(pcm,hw,&period,&dir))<0||(rc=snd_pcm_hw_params(pcm,hw))<0||(rc=snd_pcm_prepare(pcm))<0||(rc=snd_pcm_start(pcm))<0){snd_pcm_close(pcm);return rc;}
  diag.runtimeSessions.fetch_add(1);diag.set("uac-alsa-capturing",0,name);diag.audio_state(volume.state().volumeBasisPoints,volume.state().muted!=0,volume.state().backend==audio::VolumeBackend::AlsaMixer?"alsa-mixer":"software",name);
  std::vector<int32_t>buf(audio::kChannels*audio::kSamples);uint64_t frame=0;int idleWindows=0;unsigned filled=0;
  while(run&&localRun.load()){
    int ready=snd_pcm_wait(pcm,250);if(ready==0){if(++idleWindows>=12){rc=-ETIMEDOUT;break;}continue;}if(ready<0){rc=ready;break;}
    snd_pcm_sframes_t n=snd_pcm_readi(pcm,buf.data()+static_cast<std::size_t>(filled)*audio::kChannels,audio::kSamples-filled);
    if(n==-EAGAIN)continue;
    if(n==-EPIPE||n==-ESTRPIPE){if(n==-ESTRPIPE){while((rc=snd_pcm_resume(pcm))==-EAGAIN&&run&&localRun.load())std::this_thread::sleep_for(std::chrono::milliseconds(25));}if(n==-EPIPE||rc<0)rc=snd_pcm_prepare(pcm);if(rc>=0)rc=snd_pcm_start(pcm);if(rc<0)break;filled=0;idleWindows=0;continue;}
    if(n<0){rc=static_cast<int>(n);break;}if(n==0)continue;
    idleWindows=0;diag.alsaReads.fetch_add(1);filled+=static_cast<unsigned>(n);
    if(filled==audio::kSamples){volume.process(buf.data(),buf.size());a.publish(deviceId,buf.data(),++frame,0xF);diag.published.fetch_add(1);filled=0;if((frame%30)==0)diag.write();}
  }
  snd_pcm_drop(pcm);snd_pcm_close(pcm);return rc;
}

int capture_alsa(const PcmEndpoint&endpoint,AudioRouter&a,CaptureVolumeController&volume,const std::atomic<bool>&localRun){
  int last=-ENODEV;
  for(const auto&candidate:endpoint.candidates){last=capture_alsa_candidate(candidate,endpoint.id,a,volume,localRun);if(!run||!localRun.load())return last;if(last==-EBUSY||last==-ENOENT||last==-EINVAL||last==-ENODEV)continue;return last;}
  return last;
}
}

void firmware_loop(libusb_context*ctx){
  std::set<std::string> launchedKeys;
  std::map<std::string,unsigned> absentPasses;
  constexpr unsigned kDisconnectPasses=6; // ~3 seconds at AUDIO_RETRY_MS.
  while(run){
    const auto familyPresent=enumerate_audio_family_keys(ctx);
    for(auto it=launchedKeys.begin();it!=launchedKeys.end();){
      if(familyPresent.find(*it)!=familyPresent.end()){absentPasses[*it]=0;++it;continue;}
      unsigned&passes=absentPasses[*it];
      if(++passes>=kDisconnectPasses){absentPasses.erase(*it);it=launchedKeys.erase(it);}else ++it;
    }
    std::set<std::string> suppressedKeys=launchedKeys;
    const auto activePcmKeys=active_alsa_function_keys();
    suppressedKeys.insert(activePcmKeys.begin(),activePcmKeys.end());
    auto boot=open_boot(ctx,suppressedKeys);
    if(boot){
      const std::string key=boot->identityKey;
      diag.bootSessions.fetch_add(1);
      diag.set("uac-firmware-uploading",0,"uploading Microsoft Kinect Runtime v1.8 UACFirmware 01.02.709.00 through 02AD libusb bulk endpoints");
      const bool ok=upload_uac_firmware(*boot);boot.reset();
      if(ok){
        diag.fwUploads.fetch_add(1);
        if(!key.empty()){launchedKeys.insert(key);absentPasses[key]=0;}
        diag.set("uac-firmware-launched",0,"waiting for 045E:02BB/02C3 Kinect USB Audio re-enumeration; this boot epoch will not be reflashed");
        unixio::retry_sleep(POST_FIRMWARE_DELAY_MS);
      }else{
        diag.fwFailures.fetch_add(1);diag.set("uac-firmware-error",EIO,"UACFirmware upload/bootloader handshake failed");unixio::retry_sleep(AUDIO_RETRY_MS);
      }
      continue;
    }
    unixio::retry_sleep(AUDIO_RETRY_MS);
  }
}

class AudioNode{
public:
  AudioNode(PcmEndpoint endpoint,AudioRouter&router,std::shared_ptr<CaptureVolumeController>volume):endpoint_(std::move(endpoint)),router_(router),volume_(std::move(volume)){}
  ~AudioNode(){stop();}
  void start(){thread_=std::thread([this]{loop();});}
  void stop(){active_=false;if(thread_.joinable())thread_.join();}
  const PcmEndpoint& endpoint()const{return endpoint_;}
private:
  PcmEndpoint endpoint_;AudioRouter&router_;std::shared_ptr<CaptureVolumeController>volume_;std::atomic<bool>active_{true};std::thread thread_;
  void loop(){while(run&&active_.load()){volume_->set_card(endpoint_.card);const int n=capture_alsa(endpoint_,router_,*volume_,active_);if(n<0&&run&&active_.load())diag.set("uac-runtime-error",-n,"sensor="+endpoint_.id+",card="+endpoint_.card+",device="+std::to_string(endpoint_.device));if(run&&active_.load())unixio::retry_sleep(AUDIO_RETRY_MS);}}
};

void capture_manager(AudioRouter&router,std::mutex&controllerMu,std::map<std::string,std::shared_ptr<CaptureVolumeController>>&controllers){
  std::map<std::string,std::unique_ptr<AudioNode>> nodes;diag.set("uac-searching");
  while(run){
    const auto endpoints=find_pcms();std::set<std::string>present;std::vector<std::string>ids;
    for(const auto&ep:endpoints){present.insert(ep.id);ids.push_back(ep.id);auto it=nodes.find(ep.id);const bool changed=it!=nodes.end()&&(it->second->endpoint().card!=ep.card||it->second->endpoint().device!=ep.device);if(changed){it->second->stop();nodes.erase(it);std::lock_guard<std::mutex>g(controllerMu);controllers.erase(ep.id);}if(nodes.find(ep.id)==nodes.end()){auto volume=std::make_shared<CaptureVolumeController>();{std::lock_guard<std::mutex>g(controllerMu);controllers[ep.id]=volume;}auto node=std::make_unique<AudioNode>(ep,router,volume);node->start();nodes.emplace(ep.id,std::move(node));}}
    for(auto it=nodes.begin();it!=nodes.end();){if(present.find(it->first)!=present.end()){++it;continue;}it->second->stop();{std::lock_guard<std::mutex>g(controllerMu);controllers.erase(it->first);}it=nodes.erase(it);}
    router.set_active_ids(ids);
    if(endpoints.empty())diag.set("uac-endpoint-not-found",ENODEV,"no active Kinect USB Audio capture endpoint is available; waiting for firmware/runtime enumeration");
    for(int i=0;i<5&&run;i++)unixio::retry_sleep(100);
  }
  router.set_active_ids({});
  for(auto&item:nodes)item.second->stop();
  nodes.clear();
  std::lock_guard<std::mutex>g(controllerMu);controllers.clear();
}

int main(){
  std::signal(SIGINT,stoph);std::signal(SIGTERM,stoph);std::signal(SIGPIPE,SIG_IGN);
  AudioRouter monitor(kAudioSocket);if(!monitor.start())return 2;
  std::mutex controllerMu;std::map<std::string,std::shared_ptr<CaptureVolumeController>>controllers;
  AudioControlServer audioControl(controllerMu,controllers);if(!audioControl.start())return 3;
  libusb_context*ctx=nullptr;if(libusb_init(&ctx)!=0)return 4;
  std::thread firmware(firmware_loop,ctx);
  std::thread capture(capture_manager,std::ref(monitor),std::ref(controllerMu),std::ref(controllers));
  while(run)std::this_thread::sleep_for(std::chrono::milliseconds(200));
  if(capture.joinable())capture.join();
  if(firmware.joinable())firmware.join();
  audioControl.stop();libusb_exit(ctx);return 0;
}
