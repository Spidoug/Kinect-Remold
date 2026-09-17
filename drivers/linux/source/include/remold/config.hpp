#pragma once

#include <algorithm>
#include <cctype>
#include <fstream>
#include <map>
#include <string>

#include "protocol.hpp"

namespace remold {

class Config {
 public:
  explicit Config(const std::string& path = kConfigPath) { load(path); }

  std::string get(const std::string& key, const std::string& fallback = "") const {
    const auto it = values_.find(key);
    return it == values_.end() ? fallback : it->second;
  }

  int get_int(const std::string& key, int fallback) const {
    const std::string value = get(key);
    if (value.empty()) return fallback;

    try {
      std::size_t parsed = 0;
      const int result = std::stoi(value, &parsed, 10);
      return parsed == value.size() ? result : fallback;
    } catch (...) {
      return fallback;
    }
  }

  bool get_bool(const std::string& key, bool fallback) const {
    std::string value = get(key);
    if (value.empty()) return fallback;

    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
      return static_cast<char>(std::tolower(c));
    });

    if (value == "1" || value == "true" || value == "yes" || value == "on") return true;
    if (value == "0" || value == "false" || value == "no" || value == "off") return false;
    return fallback;
  }

 private:
  std::map<std::string, std::string> values_;

  static std::string trim(std::string value) {
    const auto not_space = [](unsigned char c) { return !std::isspace(c); };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), not_space));
    value.erase(std::find_if(value.rbegin(), value.rend(), not_space).base(), value.end());
    return value;
  }

  void load(const std::string& path) {
    std::ifstream input(path);
    std::string line;
    while (std::getline(input, line)) {
      line = trim(line);
      if (line.empty() || line[0] == '#') continue;

      const auto separator = line.find('=');
      if (separator == std::string::npos) continue;

      const std::string key = trim(line.substr(0, separator));
      if (key.empty()) continue;
      values_[key] = trim(line.substr(separator + 1));
    }
  }
};

}  // namespace remold
