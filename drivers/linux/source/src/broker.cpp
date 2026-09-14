#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <signal.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <array>
#include <iomanip>
#include <sstream>
#include <string>
#include <grp.h>
#include <libusb-1.0/libusb.h>
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;
namespace {
std::atomic<bool> run{true};
std::mutex usb_mu;
libusb_context* usb_ctx=nullptr;
libusb_device_handle* motor=nullptr;
enum class MotorKind { None, Classic1414, Audio1473 };
MotorKind motor_kind=MotorKind::None;
uint32_t motor_tag=0;
bool motor_primed=false;
unsigned char motor_in=0;
unsigned char motor_out=0;
int motor_alt=0;
std::string motor_device_id;
constexpr uint16_t VID=0x045e;
constexpr uint16_t MOTOR_1414_PID=0x02b0;
constexpr uint16_t AUDIO_RUNTIME_PIDS[]={0x02bb,0x02c3};
constexpr unsigned char ALT_OUT_PREFERRED=0x01;
constexpr unsigned char ALT_IN_PREFERRED=0x81;
constexpr uint32_t ALT_MAGIC=0x06022009u;
constexpr uint32_t ALT_REPLY_MAGIC=0x0a6fe000u;
constexpr uint32_t ALT_STATUS=0x8032u;
constexpr uint32_t ALT_TILT=0x803bu;
constexpr uint32_t ALT_LED=0x10u;
constexpr unsigned CONTROL_IO_TIMEOUT_MS=5000;
constexpr int TILT_MIN=-27;
constexpr int TILT_MAX=27;
constexpr int TILT_TOLERANCE_TENTHS=15;
#pragma pack(push,1)
struct AltCommand{uint32_t magic,tag,arg1,cmd,arg2;};
struct AltReply{uint32_t magic,tag,status;};
#pragma pack(pop)
static_assert(sizeof(AltCommand)==20);
static_assert(sizeof(AltReply)==12);

void stop_handler(int){run=false;}


void close_motor(){
  if(motor){
    if(motor_kind==MotorKind::Audio1473)libusb_release_interface(motor,0);
    libusb_close(motor);motor=nullptr;
  }
  motor_kind=MotorKind::None;motor_tag=0;motor_primed=false;motor_in=0;motor_out=0;motor_alt=0;motor_device_id.clear();
}

bool discover_1473_control_pipes(){
  if(!motor||motor_kind!=MotorKind::Audio1473)return true;
  libusb_device* dev=libusb_get_device(motor);
  libusb_config_descriptor* config=nullptr;
  int rc=libusb_get_active_config_descriptor(dev,&config);
  if(rc!=0||!config)return false;
  bool found=false;
  unsigned char selected_in=0,selected_out=0;
  int selected_alt=0;
  if(config->bNumInterfaces==0){libusb_free_config_descriptor(config);return false;}
  for(uint8_t i=0;i<config->bNumInterfaces&&!found;i++){
    const auto& iface=config->interface[i];
    for(int a=0;a<iface.num_altsetting&&!found;a++){
      const auto& alt=iface.altsetting[a];
      if(alt.bInterfaceNumber!=0)continue;
      unsigned char in=0,out=0;
      for(uint8_t e=0;e<alt.bNumEndpoints;e++){
        const auto& ep=alt.endpoint[e];
        if((ep.bmAttributes&LIBUSB_TRANSFER_TYPE_MASK)!=LIBUSB_TRANSFER_TYPE_BULK)continue;
        if(ep.bEndpointAddress&LIBUSB_ENDPOINT_IN){
          if(!in||ep.bEndpointAddress==ALT_IN_PREFERRED)in=ep.bEndpointAddress;
        }else{
          if(!out||ep.bEndpointAddress==ALT_OUT_PREFERRED)out=ep.bEndpointAddress;
        }
      }
      if(in&&out){selected_in=in;selected_out=out;selected_alt=alt.bAlternateSetting;found=true;}
    }
  }
  libusb_free_config_descriptor(config);
  if(!found)return false;
  // libusb/USB starts at alternate setting 0. Match Windows: avoid a redundant
  // SET_INTERFACE for the normal MI_00 layout, because some 1473 controllers
  // reject the unnecessary request.
  if(selected_alt!=0){
    rc=libusb_set_interface_alt_setting(motor,0,selected_alt);
    if(rc!=0)return false;
  }
  motor_in=selected_in;motor_out=selected_out;motor_alt=selected_alt;
  return true;
}

std::string sensor_id(libusb_device* dev){
  if(!dev)return {};
  std::array<uint8_t,8> ports{};
  const int n=libusb_get_port_numbers(dev,ports.data(),static_cast<int>(ports.size()));
  if(n<=0)return {};
  std::ostringstream id;
  id<<"usb-"<<std::setfill('0')<<std::setw(3)<<static_cast<unsigned>(libusb_get_bus_number(dev))<<'-';
  const int sensor_ports=n>1?n-1:n;
  for(int i=0;i<sensor_ports;i++){if(i)id<<'.';id<<static_cast<unsigned>(ports[static_cast<std::size_t>(i)]);}
  return id.str();
}

bool open_control_device(const std::string& target){
  libusb_device** list=nullptr;
  const ssize_t count=libusb_get_device_list(usb_ctx,&list);
  if(count<0)return false;
  libusb_device_handle* selected=nullptr;
  MotorKind selected_kind=MotorKind::None;
  std::string selected_id;
  for(ssize_t i=0;i<count&&!selected;i++){
    libusb_device_descriptor d{};
    if(libusb_get_device_descriptor(list[i],&d)!=0||d.idVendor!=VID)continue;
    MotorKind kind=MotorKind::None;
    if(d.idProduct==MOTOR_1414_PID)kind=MotorKind::Classic1414;
    else for(const auto pid:AUDIO_RUNTIME_PIDS)if(d.idProduct==pid){kind=MotorKind::Audio1473;break;}
    if(kind==MotorKind::None)continue;
    const std::string id=sensor_id(list[i]);
    if(!target.empty()&&id!=target)continue;
    if(libusb_open(list[i],&selected)!=0)continue;
    selected_kind=kind;selected_id=id;
  }
  libusb_free_device_list(list,1);
  if(!selected)return false;
  motor=selected;motor_kind=selected_kind;motor_device_id=selected_id;motor_tag=0;
  if(motor_kind==MotorKind::Classic1414){motor_primed=true;return true;}
  libusb_set_auto_detach_kernel_driver(motor,1);
  if(libusb_claim_interface(motor,0)!=0){close_motor();return false;}
  motor_primed=false;
  if(!discover_1473_control_pipes()){close_motor();return false;}
  return true;
}

bool ensure_motor(const std::string& target){
  if(motor&& (target.empty()||motor_device_id==target))return true;
  if(motor)close_motor();
  return open_control_device(target);
}

int alt_ack(uint32_t expected){
  AltReply a{};int done=0;
  int n=libusb_bulk_transfer(motor,motor_in,reinterpret_cast<unsigned char*>(&a),sizeof(a),&done,CONTROL_IO_TIMEOUT_MS);
  if(n!=0)return n;
  if(done!=static_cast<int>(sizeof(a))||a.magic!=ALT_REPLY_MAGIC||a.status!=0)return -EIO;
  // The 1473 tag is a sequencing hint. A valid magic+status ACK remains valid
  // after re-enumeration even if firmware reports the preceding tag.
  (void)expected;
  return 0;
}

int alt_command_raw(uint32_t cmd,int32_t arg2){
  const uint32_t tag=motor_tag++;
  AltCommand q{ALT_MAGIC,tag,0,cmd,static_cast<uint32_t>(arg2)};int done=0;
  int n=libusb_bulk_transfer(motor,motor_out,reinterpret_cast<unsigned char*>(&q),sizeof(q),&done,CONTROL_IO_TIMEOUT_MS);
  if(n!=0)return n;
  if(done!=static_cast<int>(sizeof(q)))return -EIO;
  return alt_ack(tag);
}

int prepare_1473(){
  if(motor_kind!=MotorKind::Audio1473||motor_primed)return 0;
  if((!motor_in||!motor_out)&&!discover_1473_control_pipes())return -ENODEV;
  // Same one-shot semantic keep-alive as Windows. A fresh MI_00 handle starts at tag 0.
  motor_tag=0;
  const int n=alt_command_raw(ALT_LED,3);
  if(n==0)motor_primed=true;
  return n;
}
int prepare_1414(){return 0;}
void recover_1414(){}
void recover_1473(){
  if(!motor||motor_kind!=MotorKind::Audio1473)return;
  // Error-only endpoint-local recovery: never reset the whole 02BB/02C3
  // composite because snd-usb-audio may be streaming on another interface.
  if(motor_in)(void)libusb_clear_halt(motor,motor_in);
  if(motor_out)(void)libusb_clear_halt(motor,motor_out);
}

int status_1414(control::Reply& r){
  unsigned char b[10]{};
  int n=libusb_control_transfer(motor,0xC0,0x32,0,0,b,sizeof(b),1000);
  if(n!=10)return n<0?n:-EIO;
  r.accelX=static_cast<int16_t>((b[2]<<8)|b[3]);
  r.accelY=static_cast<int16_t>((b[4]<<8)|b[5]);
  r.accelZ=static_cast<int16_t>((b[6]<<8)|b[7]);
  r.tiltTenths=static_cast<int8_t>(b[8])*5;
  r.state=b[9];
  return 0;
}

int status_1473(control::Reply& r){
  const uint32_t tag=motor_tag++;
  AltCommand q{ALT_MAGIC,tag,0x68,ALT_STATUS,0};unsigned char buf[256]{};int done=0;
  int n=libusb_bulk_transfer(motor,motor_out,reinterpret_cast<unsigned char*>(&q),16,&done,CONTROL_IO_TIMEOUT_MS);
  if(n!=0||done!=16)return n!=0?n:-EIO;
  n=libusb_bulk_transfer(motor,motor_in,buf,sizeof(buf),&done,CONTROL_IO_TIMEOUT_MS);
  if(n!=0||done!=0x68)return n!=0?n:-EIO;
  int32_t v[4]{};std::memcpy(v,buf+16,sizeof(v));
  r.accelX=static_cast<int16_t>(v[0]);r.accelY=static_cast<int16_t>(v[1]);r.accelZ=static_cast<int16_t>(v[2]);
  r.tiltTenths=v[3]*10;r.state=0;
  return alt_ack(tag);
}

int issue_tilt_1414(int deg){
  const int16_t half=static_cast<int16_t>(deg*2);
  const int n=libusb_control_transfer(motor,0x40,0x31,static_cast<uint16_t>(half),0,nullptr,0,1000);
  return n<0?n:0;
}
int issue_tilt_1473(int deg){return alt_command_raw(ALT_TILT,deg);}
int set_led_1414(int mode){const int n=libusb_control_transfer(motor,0x40,0x06,static_cast<uint16_t>(mode),0,nullptr,0,1000);return n<0?n:0;}
int set_led_1473(int mode){
  int alt=3;if(mode==0)alt=1;else if(mode==4)alt=2;else if(mode==2)alt=4;else if(mode==1||mode==3)alt=3;
  if((!motor_in||!motor_out)&&!discover_1473_control_pipes())return -ENODEV;
  const int n=alt_command_raw(ALT_LED,alt);if(n==0)motor_primed=true;return n;
}

struct ControlOps{
  int(*prepare)();
  int(*status)(control::Reply&);
  int(*issue_tilt)(int);
  int(*set_led)(int);
  void(*recover)();
};
const ControlOps* ops_for(MotorKind kind){
  static const ControlOps k1414{prepare_1414,status_1414,issue_tilt_1414,set_led_1414,recover_1414};
  static const ControlOps k1473{prepare_1473,status_1473,issue_tilt_1473,set_led_1473,recover_1473};
  if(kind==MotorKind::Classic1414)return &k1414;
  if(kind==MotorKind::Audio1473)return &k1473;
  return nullptr;
}

int read_status_locked(control::Reply& r){
  const ControlOps* ops=ops_for(motor_kind);if(!ops)return -ENODEV;
  const int n=ops->status(r);if(n==0)r.transport=control::Transport::PhysicalMotor;return n;
}

int wait_tilt_locked(int deg,control::Reply& r){
  std::this_thread::sleep_for(std::chrono::milliseconds(120));
  const int target=deg*10;
  bool got=false;int first=0,last=0;bool first_valid=false;int last_error=-ETIMEDOUT;
  for(int i=0;i<40;i++){
    control::Reply latest{};
    const int n=read_status_locked(latest);
    if(n==0){
      got=true;r=latest;last=latest.tiltTenths;
      if(!first_valid){first=last;first_valid=true;}
      if(std::abs(last-target)<=TILT_TOLERANCE_TENTHS)return 0;
    }else if(n!=-ETIMEDOUT){last_error=n;return n;}
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  if(!got)return last_error;
  return first_valid&&std::abs(last-first)>=5?-ETIMEDOUT:-EIO;
}

template<class F>
int with_fresh_handle_retry(const std::string& target,F&& operation,control::Reply& r){
  int last=-ENODEV;
  for(int attempt=0;attempt<2;attempt++){
    if(!ensure_motor(target)){last=-ENODEV;}else{
      r={};
      const ControlOps* ops=ops_for(motor_kind);
      if(!ops){last=-ENODEV;}else{
        last=operation(*ops,r);
        if(last==0)return 0;
        if(ops->recover)ops->recover();
      }
    }
    close_motor();
    if(attempt==0)std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return last;
}

int32_t prepare_camera(const std::string& target,control::Reply& r){
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry(target,[](const ControlOps& ops,control::Reply& out){
    const int n=ops.prepare();if(n==0)out.transport=control::Transport::PhysicalMotor;return n;
  },r);
}

int32_t usb_status(const std::string& target,control::Reply& r){
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry(target,[](const ControlOps& ops,control::Reply& out){
    int n=ops.prepare();if(n!=0)return n;
    n=ops.status(out);if(n==0)out.transport=control::Transport::PhysicalMotor;return n;
  },r);
}

int32_t set_tilt(const std::string& target,int deg,control::Reply& r){
  deg=std::clamp(deg,TILT_MIN,TILT_MAX);
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry(target,[&](const ControlOps& ops,control::Reply& out){
    int n=ops.prepare();if(n!=0)return n;
    n=ops.issue_tilt(deg);if(n!=0)return n;
    n=wait_tilt_locked(deg,out);if(n==0)out.transport=control::Transport::PhysicalMotor;return n;
  },r);
}

int32_t set_led(const std::string& target,int mode,control::Reply& r){
  if(!(mode==0||mode==1||mode==2||mode==3||mode==4||mode==6))return -EINVAL;
  std::lock_guard<std::mutex> g(usb_mu);
  return with_fresh_handle_retry(target,[&](const ControlOps& ops,control::Reply& out){
    const int n=ops.set_led(mode);if(n==0)out.transport=control::Transport::PhysicalMotor;return n;
  },r);
}

void client(int fd){
  control::Request q{};control::Reply r{};
  if(!unixio::read_exact(fd,&q,sizeof(q))||q.magic!=control::kMagic||q.version!=control::kVersion){::close(fd);return;}
  const std::string target(q.deviceId,strnlen(q.deviceId,sizeof(q.deviceId)));
  switch(q.command){
    case control::Command::Ping:r.result=0;break;
    case control::Command::Status:r.result=usb_status(target,r);break;
    case control::Command::Tilt:r.result=set_tilt(target,q.value,r);break;
    case control::Command::Led:r.result=set_led(target,q.value,r);break;
    case control::Command::PrepareCamera:r.result=prepare_camera(target,r);break;
    default:r.result=-EINVAL;break;
  }
  unixio::write_all(fd,&r,sizeof(r));::close(fd);
}
}
int main(){
  struct sigaction action{};
  action.sa_handler=stop_handler;
  sigemptyset(&action.sa_mask);
  action.sa_flags=0;
  sigaction(SIGINT,&action,nullptr);sigaction(SIGTERM,&action,nullptr);std::signal(SIGPIPE,SIG_IGN);
  if(libusb_init(&usb_ctx)!=0)return 2;
  int s=unixio::server_socket(kControlSocket,0660);
  if(s<0){std::perror("control socket");libusb_exit(usb_ctx);return 3;}
  if(auto* gr=getgrnam("video")){
    if(::chown(kControlSocket,0,gr->gr_gid)!=0 && errno!=ENOENT && errno!=EPERM){}
  }
  while(run){int c=::accept4(s,nullptr,nullptr,SOCK_CLOEXEC);if(c<0){if(errno==EINTR)continue;if(!run)break;unixio::retry_sleep();continue;}std::thread(client,c).detach();}
  ::close(s);::unlink(kControlSocket);{std::lock_guard<std::mutex> g(usb_mu);close_motor();}libusb_exit(usb_ctx);return 0;
}
