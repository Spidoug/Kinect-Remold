#pragma once
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include "remold/protocol.hpp"

namespace remold::devices {
struct Endpoint { std::string id; std::string label; std::string camera; };

inline std::vector<Endpoint> read_manifest() {
  std::vector<Endpoint> out;
  std::ifstream in(kDeviceManifest);
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream row(line);
    Endpoint e;
    if (!std::getline(row, e.id, '\t')) continue;
    if (!std::getline(row, e.label, '\t')) continue;
    if (!std::getline(row, e.camera, '\t')) continue;
    if (!e.id.empty() && !e.camera.empty()) out.push_back(std::move(e));
  }
  return out;
}

inline const Endpoint* select(const std::vector<Endpoint>& endpoints,const std::string& id,uint32_t index) {
  if(!id.empty())for(const auto& e:endpoints)if(e.id==id)return &e;
  if(index<endpoints.size())return &endpoints[index];
  return nullptr;
}
inline std::string primary_camera_endpoint() {
  const auto endpoints = read_manifest();
  return endpoints.empty() ? std::string{} : endpoints.front().camera;
}
}
