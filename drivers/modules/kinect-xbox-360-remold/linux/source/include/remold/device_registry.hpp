#pragma once
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include "remold/protocol.hpp"

namespace remold::devices {
struct Device {
  std::string id;
  std::string label;
  std::string state;
  std::string control;
  std::string camera;
  std::string audio;
  std::string audio_control;
  std::string virtual_camera;
  std::string sdk;

  bool camera_ready() const { return state == "Ready" && !camera.empty(); }
};

inline std::vector<Device> read_manifest() {
  std::vector<Device> out;
  std::ifstream in(kDeviceManifest);
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream row(line);
    Device d;
    if (!std::getline(row, d.id, '\t')) continue;
    if (!std::getline(row, d.label, '\t')) continue;
    if (!std::getline(row, d.state, '\t')) continue;
    std::getline(row, d.control, '\t');
    std::getline(row, d.camera, '\t');
    std::getline(row, d.audio, '\t');
    std::getline(row, d.audio_control, '\t');
    std::getline(row, d.virtual_camera, '\t');
    std::getline(row, d.sdk);
    if (!d.id.empty()) out.push_back(std::move(d));
  }
  return out;
}

inline const Device* find(const std::vector<Device>& devices, const std::string& id) {
  for (const auto& d : devices) if (d.id == id) return &d;
  return nullptr;
}
}
