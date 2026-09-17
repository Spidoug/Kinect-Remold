#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace remold::rawsensor {

inline bool valid_image(const uint8_t* data, int width, int height) {
  return data != nullptr && width > 0 && height > 0;
}

inline uint8_t sample(const uint8_t* bayer, int width, int height, int x, int y) {
  x = std::clamp(x, 0, width - 1);
  y = std::clamp(y, 0, height - 1);
  const std::size_t index = static_cast<std::size_t>(y) * static_cast<std::size_t>(width) +
                            static_cast<std::size_t>(x);
  return bayer[index];
}

inline uint8_t avg2(uint8_t a, uint8_t b) {
  return static_cast<uint8_t>((static_cast<unsigned>(a) + b + 1u) / 2u);
}

inline uint8_t avg4(uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
  return static_cast<uint8_t>((static_cast<unsigned>(a) + b + c + d + 2u) / 4u);
}

inline void grbg_pixel(const uint8_t* bayer,
                       int width,
                       int height,
                       int x,
                       int y,
                       uint8_t& r,
                       uint8_t& g,
                       uint8_t& b) {
  const bool odd_y = (y & 1) != 0;
  const bool odd_x = (x & 1) != 0;
  const uint8_t center = sample(bayer, width, height, x, y);

  if (!odd_y && odd_x) {
    r = center;
    g = avg4(sample(bayer, width, height, x - 1, y),
             sample(bayer, width, height, x + 1, y),
             sample(bayer, width, height, x, y - 1),
             sample(bayer, width, height, x, y + 1));
    b = avg4(sample(bayer, width, height, x - 1, y - 1),
             sample(bayer, width, height, x + 1, y - 1),
             sample(bayer, width, height, x - 1, y + 1),
             sample(bayer, width, height, x + 1, y + 1));
  } else if (odd_y && !odd_x) {
    b = center;
    g = avg4(sample(bayer, width, height, x - 1, y),
             sample(bayer, width, height, x + 1, y),
             sample(bayer, width, height, x, y - 1),
             sample(bayer, width, height, x, y + 1));
    r = avg4(sample(bayer, width, height, x - 1, y - 1),
             sample(bayer, width, height, x + 1, y - 1),
             sample(bayer, width, height, x - 1, y + 1),
             sample(bayer, width, height, x + 1, y + 1));
  } else if (!odd_y) {
    g = center;
    r = avg2(sample(bayer, width, height, x - 1, y),
             sample(bayer, width, height, x + 1, y));
    b = avg2(sample(bayer, width, height, x, y - 1),
             sample(bayer, width, height, x, y + 1));
  } else {
    g = center;
    r = avg2(sample(bayer, width, height, x, y - 1),
             sample(bayer, width, height, x, y + 1));
    b = avg2(sample(bayer, width, height, x - 1, y),
             sample(bayer, width, height, x + 1, y));
  }
}

inline void bayer_grbg_to_rgb24(const uint8_t* bayer,
                                int width,
                                int height,
                                std::vector<uint8_t>& rgb) {
  if (!valid_image(bayer, width, height)) {
    rgb.clear();
    return;
  }

  const std::size_t pixel_count = static_cast<std::size_t>(width) *
                                  static_cast<std::size_t>(height);
  rgb.resize(pixel_count * 3u);

  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      uint8_t r = 0;
      uint8_t g = 0;
      uint8_t b = 0;
      grbg_pixel(bayer, width, height, x, y, r, g, b);

      const std::size_t pixel = static_cast<std::size_t>(y) *
                                    static_cast<std::size_t>(width) +
                                static_cast<std::size_t>(x);
      const std::size_t output = pixel * 3u;
      rgb[output] = r;
      rgb[output + 1] = g;
      rgb[output + 2] = b;
    }
  }
}

inline uint8_t clamp8(int value) {
  return static_cast<uint8_t>(std::clamp(value, 0, 255));
}

inline void rgb24_to_yuyv(const uint8_t* rgb,
                          int width,
                          int height,
                          std::vector<uint8_t>& yuyv) {
  if (!valid_image(rgb, width, height) || (width & 1) != 0) {
    yuyv.clear();
    return;
  }

  const std::size_t pixel_count = static_cast<std::size_t>(width) *
                                  static_cast<std::size_t>(height);
  yuyv.resize(pixel_count * 2u);

  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; x += 2) {
      const std::size_t first_pixel = static_cast<std::size_t>(y) *
                                          static_cast<std::size_t>(width) +
                                      static_cast<std::size_t>(x);
      const std::size_t first_rgb = first_pixel * 3u;
      const std::size_t second_rgb = first_rgb + 3u;
      const std::size_t output = first_pixel * 2u;

      const int r0 = rgb[first_rgb];
      const int g0 = rgb[first_rgb + 1];
      const int b0 = rgb[first_rgb + 2];
      const int r1 = rgb[second_rgb];
      const int g1 = rgb[second_rgb + 1];
      const int b1 = rgb[second_rgb + 2];

      const int y0 = ((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16;
      const int y1 = ((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16;
      const int r = (r0 + r1) / 2;
      const int g = (g0 + g1) / 2;
      const int b = (b0 + b1) / 2;

      yuyv[output] = clamp8(y0);
      yuyv[output + 1] = clamp8(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
      yuyv[output + 2] = clamp8(y1);
      yuyv[output + 3] = clamp8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
  }
}

}  // namespace remold::rawsensor
