#pragma once

#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "remold/protocol.hpp"

namespace remold::devices {

struct Endpoint {
  std::string id;
  std::string label;
  std::string camera;
};

inline void trim_trailing_cr(std::string& value) {
  if (!value.empty() && value.back() == '\r') value.pop_back();
}

inline std::vector<Endpoint> read_manifest() {
  std::vector<Endpoint> endpoints;
  std::ifstream input(kDeviceManifest);
  std::string line;

  while (std::getline(input, line)) {
    trim_trailing_cr(line);
    if (line.empty() || line[0] == '#') continue;

    std::istringstream row(line);
    Endpoint endpoint;
    if (!std::getline(row, endpoint.id, '\t')) continue;
    if (!std::getline(row, endpoint.label, '\t')) continue;
    if (!std::getline(row, endpoint.camera, '\t')) continue;

    trim_trailing_cr(endpoint.camera);
    if (!endpoint.id.empty() && !endpoint.camera.empty()) {
      endpoints.push_back(std::move(endpoint));
    }
  }

  return endpoints;
}

inline const Endpoint* select(const std::vector<Endpoint>& endpoints,
                              const std::string& id,
                              uint32_t index) {
  if (!id.empty()) {
    for (const auto& endpoint : endpoints) {
      if (endpoint.id == id) return &endpoint;
    }
    return nullptr;
  }

  return index < endpoints.size() ? &endpoints[index] : nullptr;
}

inline std::string primary_camera_endpoint() {
  const auto endpoints = read_manifest();
  return endpoints.empty() ? std::string{} : endpoints.front().camera;
}

}  // namespace remold::devices
