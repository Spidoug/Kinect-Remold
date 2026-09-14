#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"
using namespace remold;

static void usage(){std::puts("Usage: kinect360-remoldctl [--device ID] status | backend | tilt <degrees> | led <off|green|red|yellow|blink-green|blink-yellow-red> | ping | nui | sdk | audio-volume [0..100] | audio-mute <on|off>");}
static int led(const std::string&s){if(s=="off")return 0;if(s=="green")return 1;if(s=="red")return 2;if(s=="yellow")return 3;if(s=="blink-green")return 4;if(s=="blink-yellow-red")return 6;return -1;}
static bool copy_device_id(char*dst,size_t cap,const std::string&id){if(!dst||cap==0||id.size()>=cap)return false;std::memset(dst,0,cap);if(!id.empty())std::memcpy(dst,id.data(),id.size());return true;}
static int nui_info(){
  int fd=unixio::connect_socket(nui::kSocket);if(fd<0){std::perror("nui");return 3;}
  nui::Request q{};nui::Reply r{};
  if(!unixio::write_all(fd,&q,sizeof(q))||!unixio::read_exact(fd,&r,sizeof(r))){::close(fd);std::puts("NUI I/O failed");return 4;}
  ::close(fd);
  if(r.magic!=nui::kMagic||r.version!=nui::kVersion){std::puts("NUI ABI mismatch");return 5;}
  std::printf("NUI v%u result=%d joints=%u max_skeletons=%u capabilities=0x%08x\n",r.version,r.result,r.jointCount,r.maxSkeletons,r.capabilities);
  std::printf("camera=%s\naudio=%s\naudio_control=%s\ncontrol=%s\nskeleton=%s\nsdk=%s\n",r.cameraEndpoint,r.audioEndpoint,r.audioControlEndpoint,r.controlEndpoint,r.skeletonEndpoint,r.sdkEndpoint);
  return r.result<0?6:0;
}

static int audio_control(const std::string&deviceId,audio::ControlCommand command,int32_t value){
  int fd=unixio::connect_socket(kAudioControlSocket);if(fd<0){std::perror("audio-control");return 3;}
  audio::ControlRequest q{};q.command=command;q.value=value;if(!copy_device_id(q.deviceId,sizeof(q.deviceId),deviceId)){::close(fd);std::puts("Device ID is too long");return 2;}audio::ControlReply r{};
  if(!unixio::write_all(fd,&q,sizeof(q))||!unixio::read_exact(fd,&r,sizeof(r))){::close(fd);std::puts("audio control I/O failed");return 4;}::close(fd);
  if(r.magic!=audio::kControlMagic||r.version!=audio::kVersion){std::puts("audio control ABI mismatch");return 5;}
  if(r.result<0){std::printf("ERROR %d (%s)\n",r.result,std::strerror(-r.result));return 6;}
  const char* backend=r.backend==audio::VolumeBackend::AlsaMixer?"alsa-mixer":r.backend==audio::VolumeBackend::WindowsEndpoint?"windows-endpoint":"software";
  std::printf("volume=%.1f%% mute=%s backend=%s capabilities=0x%08x\n",r.volumeBasisPoints/100.0,r.muted?"on":"off",backend,r.capabilities);return 0;
}
static int sdk_info(const std::string&deviceId){
  int fd=unixio::connect_socket(sdk::kSocket);if(fd<0){std::perror("sdk");return 3;}sdk::Request q{};q.command=sdk::Command::RuntimeInfo;if(!copy_device_id(q.deviceId,sizeof(q.deviceId),deviceId)){::close(fd);std::puts("Device ID is too long");return 2;}sdk::Reply r{};
  if(!unixio::write_all(fd,&q,sizeof(q))||!unixio::read_exact(fd,&r,sizeof(r))){::close(fd);std::puts("SDK bridge I/O failed");return 4;}::close(fd);
  if(r.magic!=sdk::kMagic||r.version!=sdk::kVersion){std::puts("SDK bridge ABI mismatch");return 5;}
  std::printf("SDK bridge v%u result=%d sensors=%u status=%u capabilities=0x%08x elevation=%d accel=%d,%d,%d\n",r.version,r.result,r.sensorCount,r.status,r.capabilities,r.elevationDegrees,r.accelX,r.accelY,r.accelZ);
  std::printf("camera=%s\naudio=%s\naudio_control=%s\nskeleton=%s\n",r.cameraEndpoint,r.audioEndpoint,r.audioControlEndpoint,r.skeletonEndpoint);return r.result<0?6:0;
}

int main(int argc,char**argv){
  if(argc<2){usage();return 2;}
  int arg=1;std::string deviceId;
  if(arg+1<argc&&std::string(argv[arg])=="--device"){deviceId=argv[arg+1];arg+=2;if(deviceId.empty()||deviceId.size()>=kDeviceIdBytes){usage();return 2;}}
  if(arg>=argc){usage();return 2;}
  std::string a=argv[arg++];
  if(a=="backend"&&arg==argc){std::puts("platform=linux usb=libusb-1.0 kernel=usbfs+udev audio=02ad-libusb-boot|02bb-02c3-snd-usb-audio-alsa");return 0;}
  if(a=="nui"&&arg==argc)return nui_info();
  if(a=="sdk"&&arg==argc)return sdk_info(deviceId);
  if(a=="audio-volume"){
    if(arg==argc)return audio_control(deviceId,audio::ControlCommand::GetState,0);
    if(arg+1==argc){int p=std::atoi(argv[arg]);if(p<0||p>100){usage();return 2;}return audio_control(deviceId,audio::ControlCommand::SetVolume,p*100);}usage();return 2;
  }
  if(a=="audio-mute"&&arg+1==argc){std::string v=argv[arg];if(v!="on"&&v!="off"){usage();return 2;}return audio_control(deviceId,audio::ControlCommand::SetMute,v=="on"?1:0);}
  control::Request q{};if(!copy_device_id(q.deviceId,sizeof(q.deviceId),deviceId)){usage();return 2;}
  if(a=="ping"&&arg==argc)q.command=control::Command::Ping;
  else if(a=="status"&&arg==argc)q.command=control::Command::Status;
  else if(a=="tilt"&&arg+1==argc){q.command=control::Command::Tilt;q.value=std::atoi(argv[arg]);}
  else if(a=="led"&&arg+1==argc){int v=led(argv[arg]);if(v<0){usage();return 2;}q.command=control::Command::Led;q.value=v;}
  else{usage();return 2;}
  int fd=unixio::connect_socket(kControlSocket);if(fd<0){std::perror("broker");return 3;}
  control::Reply r{};if(!unixio::write_all(fd,&q,sizeof(q))||!unixio::read_exact(fd,&r,sizeof(r))){::close(fd);std::puts("broker I/O failed");return 4;}::close(fd);
  if(r.result<0){std::printf("ERROR %d (%s)\n",r.result,std::strerror(-r.result));return 5;}
  if(a=="status")std::printf("OK device=%s accel=%d,%d,%d tilt=%.1f state=%u\n",deviceId.empty()?"auto":deviceId.c_str(),r.accelX,r.accelY,r.accelZ,r.tiltTenths/10.0,r.state);else std::puts("OK");return 0;
}
