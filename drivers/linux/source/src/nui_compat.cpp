#include <algorithm>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <map>
#include <poll.h>
#include <thread>
#include <vector>
#include <grp.h>
#include <sys/socket.h>
#include <unistd.h>
#include "remold/device_registry.hpp"
#include "remold/protocol.hpp"
#include "remold/unix_socket.hpp"

using namespace remold;
namespace {
std::atomic<bool> run{true};
void stop_handler(int){run=false;}

void copy_path(char* dst,std::size_t cap,const std::string& value){
  if(cap==0)return;
  std::memset(dst,0,cap);
  const std::size_t n=std::min(cap-1,value.size());
  if(n)std::memcpy(dst,value.data(),n);
}
void set_video_group(const char* path){
  if(auto* gr=getgrnam("video")){
    if(::chown(path,0,gr->gr_gid)!=0 && errno!=ENOENT && errno!=EPERM){}
  }
}

void discovery_client(int fd){
  nui::Request q{};
  nui::Reply r{};
  if(!unixio::read_exact(fd,&q,sizeof(q))||q.magic!=nui::kMagic||q.version!=nui::kVersion||q.command!=nui::Command::RuntimeInfo){
    ::close(fd);return;
  }
  const std::string camera=devices::primary_camera_endpoint();
  if(camera.empty())r.result=-ENODEV;
  copy_path(r.cameraEndpoint,sizeof(r.cameraEndpoint),camera);
  copy_path(r.audioEndpoint,sizeof(r.audioEndpoint),kAudioSocket);
  copy_path(r.controlEndpoint,sizeof(r.controlEndpoint),kControlSocket);
  copy_path(r.skeletonEndpoint,sizeof(r.skeletonEndpoint),nui::kSkeletonSocket);
  copy_path(r.audioControlEndpoint,sizeof(r.audioControlEndpoint),kAudioControlSocket);
  copy_path(r.sdkEndpoint,sizeof(r.sdkEndpoint),sdk::kSocket);
  (void)unixio::write_all(fd,&r,sizeof(r));
  ::close(fd);
}

bool broker_request(control::Command command,int32_t value,const std::string& deviceId,control::Reply& reply){
  int fd=unixio::connect_socket(kControlSocket);if(fd<0)return false;
  control::Request request{};request.command=command;request.value=value;
  const std::size_t n=std::min(deviceId.size(),sizeof(request.deviceId)-1);if(n)std::memcpy(request.deviceId,deviceId.data(),n);
  const bool ok=unixio::write_all(fd,&request,sizeof(request))&&unixio::read_exact(fd,&reply,sizeof(reply));
  ::close(fd);return ok&&reply.magic==control::kMagic&&reply.version==control::kVersion;
}

void sdk_client(int fd){
  sdk::Request q{};sdk::Reply r{};
  if(!unixio::read_exact(fd,&q,sizeof(q))||q.magic!=sdk::kMagic||q.version!=sdk::kVersion){::close(fd);return;}
  const auto sensors=devices::read_manifest();
  const std::string requested(q.deviceId,strnlen(q.deviceId,sizeof(q.deviceId)));
  const auto* sensor=devices::select(sensors,requested,q.sensorIndex);
  r.sensorCount=static_cast<uint32_t>(sensors.size());
  r.status=sensor?1u:0u;
  r.capabilities=nui::CapabilityColor|nui::CapabilityInfrared|nui::CapabilityDepth|nui::CapabilityAudio4Mic|nui::CapabilityTiltLedAccel|nui::CapabilityNui20JointModel|nui::CapabilitySkeletonStream|nui::CapabilityAudioControl|nui::CapabilitySdkBridge;
  if(sensor)copy_path(r.cameraEndpoint,sizeof(r.cameraEndpoint),sensor->camera);
  copy_path(r.audioEndpoint,sizeof(r.audioEndpoint),kAudioSocket);
  copy_path(r.audioControlEndpoint,sizeof(r.audioControlEndpoint),kAudioControlSocket);
  copy_path(r.skeletonEndpoint,sizeof(r.skeletonEndpoint),nui::kSkeletonSocket);
  control::Reply state{};
  const std::string id=sensor?sensor->id:std::string{};
  switch(q.command){
    case sdk::Command::SensorCount: break;
    case sdk::Command::Status:
    case sdk::Command::RuntimeInfo:
      if(!sensor)r.result=-ENODEV;
      else if(broker_request(control::Command::Status,0,id,state)){
        r.result=state.result;r.elevationDegrees=state.tiltTenths/10;r.accelX=state.accelX;r.accelY=state.accelY;r.accelZ=state.accelZ;
      }else r.result=-ENODEV;
      break;
    case sdk::Command::Initialize:
      if(!sensor)r.result=-ENODEV;else r.initializedFlags=q.flags;
      break;
    case sdk::Command::Shutdown:r.initializedFlags=0;break;
    case sdk::Command::GetElevation:
    case sdk::Command::GetAccelerometer:
      if(!sensor||!broker_request(control::Command::Status,0,id,state))r.result=-ENODEV;
      else{r.result=state.result;r.elevationDegrees=state.tiltTenths/10;r.accelX=state.accelX;r.accelY=state.accelY;r.accelZ=state.accelZ;}
      break;
    case sdk::Command::SetElevation:
      if(q.value<-27||q.value>27)r.result=-EINVAL;
      else if(!sensor||!broker_request(control::Command::Tilt,q.value,id,state))r.result=-ENODEV;
      else{r.result=state.result;r.elevationDegrees=state.tiltTenths/10;r.accelX=state.accelX;r.accelY=state.accelY;r.accelZ=state.accelZ;}
      break;
    default:r.result=-EINVAL;break;
  }
  (void)unixio::write_all(fd,&r,sizeof(r));::close(fd);
}

class SdkServer{
public:
  ~SdkServer(){stop();}
  bool start(){server_=unixio::server_socket(sdk::kSocket,0660);if(server_<0)return false;set_video_group(sdk::kSocket);thread_=std::thread([this]{loop();});return true;}
  void stop(){stopping_=true;if(server_>=0){::shutdown(server_,SHUT_RDWR);::close(server_);server_=-1;}if(thread_.joinable())thread_.join();::unlink(sdk::kSocket);}
private:
  int server_=-1;std::atomic<bool> stopping_{false};std::thread thread_;
  void loop(){while(!stopping_&&run){pollfd pfd{server_,POLLIN,0};int pr=::poll(&pfd,1,250);if(pr<0){if(errno==EINTR)continue;break;}if(pr==0||!(pfd.revents&POLLIN))continue;int fd=::accept4(server_,nullptr,nullptr,SOCK_CLOEXEC);if(fd<0){if(errno==EINTR)continue;if(stopping_)break;continue;}std::thread(sdk_client,fd).detach();}}
};

class SkeletonRelay{
public:
  ~SkeletonRelay(){stop();}
  bool start(){
    server_=unixio::server_socket(nui::kSkeletonSocket,0660);
    if(server_<0)return false;
    set_video_group(nui::kSkeletonSocket);
    acceptThread_=std::thread([this]{accept_loop();});
    return true;
  }
  void stop(){
    if(stopping_.exchange(true))return;
    if(server_>=0){::shutdown(server_,SHUT_RDWR);::close(server_);server_=-1;}
    {
      std::lock_guard<std::mutex> g(mu_);
      for(auto& item:publishers_)::shutdown(item.second,SHUT_RDWR);
      for(auto& sub:subscribers_)::shutdown(sub.fd,SHUT_RDWR);
    }
    if(acceptThread_.joinable())acceptThread_.join();
    for(auto& thread:publishThreads_)if(thread.joinable())thread.join();
    {
      std::lock_guard<std::mutex> g(mu_);
      for(auto& item:publishers_)::close(item.second);
      publishers_.clear();
      for(auto& sub:subscribers_)::close(sub.fd);
      subscribers_.clear();
    }
    ::unlink(nui::kSkeletonSocket);
  }
private:
  struct Subscriber{int fd=-1;std::string id;};
  int server_=-1;
  std::atomic<bool> stopping_{false};
  std::mutex mu_;
  std::vector<Subscriber> subscribers_;
  std::map<std::string,int> publishers_;
  std::thread acceptThread_;
  std::vector<std::thread> publishThreads_;

  std::string resolve_id(const char* raw,std::size_t cap){
    std::string id(raw,strnlen(raw,cap));
    if(!id.empty())return id;
    const auto sensors=devices::read_manifest();
    return sensors.empty()?std::string{}:sensors.front().id;
  }
  bool sensor_exists(const std::string& id){
    if(id.empty())return false;
    const auto sensors=devices::read_manifest();
    return std::any_of(sensors.begin(),sensors.end(),[&](const devices::Endpoint& e){return e.id==id;});
  }
  void accept_loop(){
    while(!stopping_&&run){
      pollfd pfd{server_,POLLIN,0};
      int pr=::poll(&pfd,1,250);
      if(pr<0){if(errno==EINTR)continue;break;}
      if(pr==0||!(pfd.revents&POLLIN))continue;
      int fd=::accept4(server_,nullptr,nullptr,SOCK_CLOEXEC);
      if(fd<0){if(errno==EINTR)continue;if(stopping_)break;continue;}
      nui::SkeletonHello hello{};nui::SkeletonReply reply{};
      if(!unixio::read_exact(fd,&hello,sizeof(hello))||hello.magic!=nui::kMagic||hello.version!=nui::kSkeletonVersion){::close(fd);continue;}
      const std::string id=resolve_id(hello.deviceId,sizeof(hello.deviceId));
      if(!sensor_exists(id)){reply.result=-ENODEV;(void)unixio::write_all(fd,&reply,sizeof(reply));::close(fd);continue;}
      if(hello.role==nui::SkeletonRole::Subscribe){
        if(!unixio::write_all(fd,&reply,sizeof(reply))){::close(fd);continue;}
        std::lock_guard<std::mutex> g(mu_);subscribers_.push_back(Subscriber{fd,id});continue;
      }
      if(hello.role==nui::SkeletonRole::Publish){
        bool busy=false;
        {
          std::lock_guard<std::mutex> g(mu_);
          busy=publishers_.find(id)!=publishers_.end();
          if(!busy)publishers_[id]=fd;
        }
        if(busy){reply.result=-EBUSY;(void)unixio::write_all(fd,&reply,sizeof(reply));::close(fd);continue;}
        if(!unixio::write_all(fd,&reply,sizeof(reply))){std::lock_guard<std::mutex> g(mu_);publishers_.erase(id);::close(fd);continue;}
        publishThreads_.emplace_back([this,fd,id]{publisher_loop(fd,id);});
        continue;
      }
      reply.result=-EINVAL;(void)unixio::write_all(fd,&reply,sizeof(reply));::close(fd);
    }
  }
  void publisher_loop(int fd,const std::string& id){
    nui::SkeletonFrame frame{};
    while(!stopping_&&run&&unixio::read_exact(fd,&frame,sizeof(frame))){
      if(frame.magic!=nui::kSkeletonFrameMagic||frame.version!=nui::kSkeletonVersion||frame.bodyCount>nui::kMaxSkeletons)continue;
      broadcast(id,frame);
    }
    bool closeFd=false;
    {
      std::lock_guard<std::mutex> g(mu_);
      auto it=publishers_.find(id);
      if(it!=publishers_.end()&&it->second==fd){publishers_.erase(it);closeFd=true;}
    }
    if(closeFd)::close(fd);
  }
  bool send_frame(int fd,const nui::SkeletonFrame& frame){
    const auto* data=reinterpret_cast<const std::uint8_t*>(&frame);std::size_t sent=0;
    while(sent<sizeof(frame)){
      const ssize_t n=::send(fd,data+sent,sizeof(frame)-sent,MSG_NOSIGNAL|MSG_DONTWAIT);
      if(n>0){sent+=static_cast<std::size_t>(n);continue;}
      if(n<0&&errno==EINTR)continue;
      if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){pollfd pfd{fd,POLLOUT,0};const int pr=::poll(&pfd,1,30);if(pr>0&&(pfd.revents&POLLOUT))continue;}
      return false;
    }
    return true;
  }
  void broadcast(const std::string& id,const nui::SkeletonFrame& frame){
    std::lock_guard<std::mutex> g(mu_);
    for(auto it=subscribers_.begin();it!=subscribers_.end();){
      if(it->id!=id){++it;continue;}
      if(!send_frame(it->fd,frame)){::shutdown(it->fd,SHUT_RDWR);::close(it->fd);it=subscribers_.erase(it);}else ++it;
    }
  }
};
}

int main(){
  struct sigaction action{};action.sa_handler=stop_handler;sigemptyset(&action.sa_mask);sigaction(SIGINT,&action,nullptr);sigaction(SIGTERM,&action,nullptr);std::signal(SIGPIPE,SIG_IGN);
  SkeletonRelay skeleton;
  if(!skeleton.start())return 2;
  SdkServer sdkServer;
  if(!sdkServer.start())return 3;
  const int server=unixio::server_socket(nui::kSocket,0660);
  if(server<0)return 4;
  set_video_group(nui::kSocket);
  while(run){
    pollfd pfd{server,POLLIN,0};int pr=::poll(&pfd,1,250);
    if(pr<0){if(errno==EINTR)continue;break;}if(pr==0||!(pfd.revents&POLLIN))continue;
    int client=::accept4(server,nullptr,nullptr,SOCK_CLOEXEC);if(client<0){if(errno==EINTR)continue;break;}
    discovery_client(client);
  }
  ::close(server);::unlink(nui::kSocket);sdkServer.stop();skeleton.stop();return 0;
}
