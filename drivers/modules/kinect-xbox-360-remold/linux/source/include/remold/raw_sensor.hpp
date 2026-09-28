#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>

namespace remold::rawsensor {

inline uint8_t sample(const uint8_t* bayer, int width, int height, int x, int y) {
  x = std::clamp(x, 0, width - 1);
  y = std::clamp(y, 0, height - 1);
  return bayer[static_cast<std::size_t>(y) * width + x];
}

inline uint8_t avg2(uint8_t a, uint8_t b) {
  return static_cast<uint8_t>((unsigned(a) + b + 1u) / 2u);
}

inline uint8_t avg4(uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
  return static_cast<uint8_t>((unsigned(a) + b + c + d + 2u) / 4u);
}

inline void grbg_pixel(
    const uint8_t* bayer,
    int width,
    int height,
    int x,
    int y,
    uint8_t& red,
    uint8_t& green,
    uint8_t& blue) {
  const bool oddY = (y & 1) != 0;
  const bool oddX = (x & 1) != 0;
  const uint8_t center = sample(bayer, width, height, x, y);

  if (!oddY && oddX) {
    red = center;
    green = avg4(
        sample(bayer, width, height, x - 1, y),
        sample(bayer, width, height, x + 1, y),
        sample(bayer, width, height, x, y - 1),
        sample(bayer, width, height, x, y + 1));
    blue = avg4(
        sample(bayer, width, height, x - 1, y - 1),
        sample(bayer, width, height, x + 1, y - 1),
        sample(bayer, width, height, x - 1, y + 1),
        sample(bayer, width, height, x + 1, y + 1));
  } else if (oddY && !oddX) {
    blue = center;
    green = avg4(
        sample(bayer, width, height, x - 1, y),
        sample(bayer, width, height, x + 1, y),
        sample(bayer, width, height, x, y - 1),
        sample(bayer, width, height, x, y + 1));
    red = avg4(
        sample(bayer, width, height, x - 1, y - 1),
        sample(bayer, width, height, x + 1, y - 1),
        sample(bayer, width, height, x - 1, y + 1),
        sample(bayer, width, height, x + 1, y + 1));
  } else if (!oddY) {
    green = center;
    red = avg2(
        sample(bayer, width, height, x - 1, y),
        sample(bayer, width, height, x + 1, y));
    blue = avg2(
        sample(bayer, width, height, x, y - 1),
        sample(bayer, width, height, x, y + 1));
  } else {
    green = center;
    red = avg2(
        sample(bayer, width, height, x, y - 1),
        sample(bayer, width, height, x, y + 1));
    blue = avg2(
        sample(bayer, width, height, x - 1, y),
        sample(bayer, width, height, x + 1, y));
  }
}

inline void bayer_grbg_to_rgb24(
    const uint8_t* bayer,
    int width,
    int height,
    std::vector<uint8_t>& rgb) {
  rgb.resize(static_cast<std::size_t>(width) * height * 3u);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      uint8_t red = 0;
      uint8_t green = 0;
      uint8_t blue = 0;
      grbg_pixel(bayer, width, height, x, y, red, green, blue);

      const std::size_t pixel = (static_cast<std::size_t>(y) * width + x) * 3u;
      rgb[pixel] = red;
      rgb[pixel + 1] = green;
      rgb[pixel + 2] = blue;
    }
  }
}

inline uint8_t clamp8(int value) {
  return static_cast<uint8_t>(std::clamp(value, 0, 255));
}

inline void rgb24_to_yuyv(
    const uint8_t* rgb,
    int width,
    int height,
    std::vector<uint8_t>& yuyv) {
  yuyv.resize(static_cast<std::size_t>(width) * height * 2u);

  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; x += 2) {
      const std::size_t first = (static_cast<std::size_t>(y) * width + x) * 3u;
      const std::size_t second = first + 3u;
      const std::size_t output = (static_cast<std::size_t>(y) * width + x) * 2u;

      const int r0 = rgb[first];
      const int g0 = rgb[first + 1];
      const int b0 = rgb[first + 2];
      const int r1 = rgb[second];
      const int g1 = rgb[second + 1];
      const int b1 = rgb[second + 2];

      const int y0 = ((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16;
      const int y1 = ((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16;
      const int red = (r0 + r1) / 2;
      const int green = (g0 + g1) / 2;
      const int blue = (b0 + b1) / 2;

      yuyv[output] = clamp8(y0);
      yuyv[output + 1] = clamp8(((-38 * red - 74 * green + 112 * blue + 128) >> 8) + 128);
      yuyv[output + 2] = clamp8(y1);
      yuyv[output + 3] = clamp8(((112 * red - 94 * green - 18 * blue + 128) >> 8) + 128);
    }
  }
}

// Nearest-neighbour copy of the source rectangle (cropX, cropY, cropWidth,
// cropHeight) of an RGB24 image into a targetWidth x targetHeight RGB24 image.
inline void crop_scale_rgb24(
    const uint8_t* rgb,
    int width,
    int cropX,
    int cropY,
    int cropWidth,
    int cropHeight,
    int targetWidth,
    int targetHeight,
    std::vector<uint8_t>& target) {
  target.resize(static_cast<std::size_t>(targetWidth) * targetHeight * 3u);
  for (int y = 0; y < targetHeight; ++y) {
    const int sy = cropY + static_cast<int>((static_cast<int64_t>(y) * cropHeight) / targetHeight);
    const uint8_t* row = rgb + static_cast<std::size_t>(sy) * width * 3u;
    uint8_t* out = target.data() + static_cast<std::size_t>(y) * targetWidth * 3u;
    for (int x = 0; x < targetWidth; ++x) {
      const int sx = cropX + static_cast<int>((static_cast<int64_t>(x) * cropWidth) / targetWidth);
      std::memcpy(out + static_cast<std::size_t>(x) * 3u, row + static_cast<std::size_t>(sx) * 3u, 3u);
    }
  }
}

}  // namespace remold::rawsensor
