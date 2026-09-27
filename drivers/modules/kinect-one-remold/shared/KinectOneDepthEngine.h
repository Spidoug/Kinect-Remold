#pragma once

#include "KinectOneNativeUsb.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace KinectOneDepthEngine {

constexpr int Width = 512;
constexpr int Height = 424;
constexpr int Pixels = Width * Height;
constexpr int RawSubBytes = Width * Height * 11 / 8;
constexpr float Pi = 3.14159265358979323846f;

#pragma pack(push, 1)
struct DepthCameraCalibration {
    float fx = 0, fy = 0, reserved0 = 0, cx = 0, cy = 0;
    float k1 = 0, k2 = 0, p1 = 0, p2 = 0, k3 = 0;
    float reserved[13]{};
};
#pragma pack(pop)
static_assert(sizeof(DepthCameraCalibration) == 23 * sizeof(float));

struct Parameters {
    float amplitudeScale = 0.6666667f;
    std::array<float, 3> frequencyScale{1.322581f, 1.0f, 1.612903f};
    std::array<float, 3> phaseShift{0.0f, 2.094395f, 4.18879f};
    float irOutputScale = 16.0f;
    float individualAmplitudeThreshold = 3.0f;
    float totalAmplitudeThreshold = 10.0f;
    float confidenceSlope = -0.5330578f;
    float confidenceOffset = 0.7694894f;
    float minConfidence = 0.3490659f;
    float maxConfidence = 0.6108653f;
    float phaseOffset = 0.0f;
    float unambiguousDistanceMm = 2083.333f;
    float minimumDepthMm = 400.0f;
    float maximumDepthMm = 6000.0f;
};

class Decoder {
public:
    bool configure(const std::vector<std::uint8_t>& depthParameters,
                   const std::vector<std::uint8_t>& p0Response) {
        if (depthParameters.size() < sizeof(DepthCameraCalibration)) return false;
        DepthCameraCalibration calibration{};
        std::memcpy(&calibration, depthParameters.data(), sizeof(calibration));
        if (!std::isfinite(calibration.fx) || !std::isfinite(calibration.fy) ||
            calibration.fx <= 1 || calibration.fy <= 1) return false;
        calibration_ = calibration;
        if (!loadPhaseTables(p0Response)) return false;
        buildGeometryTables();
        buildMeasurementLut();
        rawDepth_.assign(Pixels, 0.0f);
        filtered_.assign(Pixels, 0.0f);
        rawIr_.assign(Pixels, 0.0f);
        ready_ = true;
        return true;
    }

    bool ready() const { return ready_; }
    const DepthCameraCalibration& calibration() const { return calibration_; }

    bool decode(const std::vector<std::uint8_t>& raw,
                std::vector<std::uint16_t>& depthMm,
                std::vector<std::uint16_t>* infrared = nullptr) const {
        if (!ready_ || raw.size() < static_cast<std::size_t>(RawSubBytes) * 9u) return false;
        std::fill(rawDepth_.begin(), rawDepth_.end(), 0.0f);
        if (infrared) std::fill(rawIr_.begin(), rawIr_.end(), 0.0f);
        auto& rawDepth = rawDepth_;
        auto& rawIr = rawIr_;

        for (int y = 0; y < Height; ++y) {
            for (int x = 0; x < Width; ++x) {
                const int pixel = y * Width + x;
                if (zTable_[pixel] <= 0.0f || x == 0 || x == Width - 1) continue;
                FrequencyMeasurement f[3]{};
                bool valid = true;
                for (int freq = 0; freq < 3; ++freq) {
                    std::array<std::int32_t, 3> sample{};
                    for (int phase = 0; phase < 3; ++phase) {
                        sample[phase] = measurement(raw.data(), freq * 3 + phase, x, y);
                        if (sample[phase] == 32767) valid = false;
                    }
                    if (!valid) break;
                    f[freq] = correlate(pixel, freq, sample);
                }
                if (!valid) { if (infrared) rawIr[pixel] = 65535.0f; continue; }

                const float irAverage=(f[0].amplitude+f[1].amplitude+f[2].amplitude)/3.0f*parameters_.irOutputScale;
                if (infrared) rawIr[pixel]=std::clamp(irAverage,0.0f,65535.0f);
                float phase = unwrap(f[0], f[1], f[2]);
                if (!(phase > 0.0f) || !std::isfinite(phase)) continue;
                phase += parameters_.phaseOffset;
                const float linear = zTable_[pixel] * phase;
                const float maxDistance = phase * parameters_.unambiguousDistanceMm * 2.0f;
                if (!(linear > 0.0f) || !(maxDistance > 0.0f)) continue;
                const float correction=(xTable_[pixel]*90.0f)/(maxDistance*maxDistance*8192.0f);
                const float denominator=1.0f-linear*correction;
                if (std::fabs(denominator)<1e-6f) continue;
                const float depth=linear/denominator;
                if (std::isfinite(depth)&&depth>=parameters_.minimumDepthMm&&depth<=parameters_.maximumDepthMm) rawDepth[pixel]=depth;
            }
        }

        // Native edge-aware cleanup: reject isolated ToF returns and use a
        // range-gated 3x3 robust mean inside continuous surfaces.  The gate is
        // deliberately depth-relative so thin foreground structures survive.
        filtered_ = rawDepth;
        auto& filtered = filtered_;
        for(int y=1;y<Height-1;++y)for(int x=1;x<Width-1;++x){
            const int i=y*Width+x;const float center=rawDepth[i];if(center<=0)continue;
            const float gate=std::max(24.0f,center*0.018f);float sum=center,weight=1.0f;int support=1;float minD=center,maxD=center;
            for(int dy=-1;dy<=1;++dy)for(int dx=-1;dx<=1;++dx){if(dx==0&&dy==0)continue;const float d=rawDepth[(y+dy)*Width+x+dx];if(d<=0)continue;minD=std::min(minD,d);maxD=std::max(maxD,d);const float delta=std::fabs(d-center);if(delta<=gate){const float w=1.0f/(1.0f+delta/std::max(1.0f,gate*.35f));sum+=d*w;weight+=w;support++;}}
            if(support<3||(maxD-minD>std::max(110.0f,center*.055f)&&support<6))filtered[i]=0;else filtered[i]=sum/weight;
        }

        depthMm.assign(Pixels,0);if(infrared)infrared->assign(Pixels,0);
        for(int y=0;y<Height;++y){const int oy=Height-1-y;for(int x=0;x<Width;++x){const int src=y*Width+x,dst=oy*Width+x;const float d=filtered[src];if(d>0)depthMm[dst]=static_cast<std::uint16_t>(std::clamp(std::lround(d),0l,65535l));if(infrared)(*infrared)[dst]=static_cast<std::uint16_t>(std::clamp(std::lround(rawIr[src]),0l,65535l));}}
        return true;
    }

private:
    struct FrequencyMeasurement { float phase = 0, amplitude = 0; };

    bool loadPhaseTables(const std::vector<std::uint8_t>& response) {
        constexpr std::size_t tableBytes = Pixels * sizeof(std::uint16_t);
        constexpr std::size_t first = 32 + 2;
        constexpr std::size_t second = first + tableBytes + 4;
        constexpr std::size_t third = second + tableBytes + 4;
        if (response.size() < third + tableBytes) return false;
        for (int table = 0; table < 3; ++table) {
            const std::size_t offset = table == 0 ? first : table == 1 ? second : third;
            for (int y = 0; y < Height; ++y) {
                const int sourceY = Height - 1 - y;
                for (int x = 0; x < Width; ++x) {
                    std::uint16_t value = 0;
                    const std::size_t p = offset + (sourceY * Width + x) * sizeof(std::uint16_t);
                    std::memcpy(&value, response.data() + p, sizeof(value));
                    p0_[table][y * Width + x] = value;
                }
            }
        }
        for (int table = 0; table < 3; ++table) {
            trig_[table].resize(static_cast<std::size_t>(Pixels) * 6u);
            for (int i = 0; i < Pixels; ++i) {
                const float base = -static_cast<float>(p0_[table][i]) * 0.000031f * Pi;
                for (int k = 0; k < 3; ++k) {
                    const float a = base + parameters_.phaseShift[k];
                    trig_[table][i * 6 + k] = std::cos(a);
                    trig_[table][i * 6 + 3 + k] = std::sin(-a);
                }
            }
        }
        return true;
    }

    void distort(double x, double y, double& dx, double& dy) const {
        const double x2 = x * x, y2 = y * y, r2 = x2 + y2, xy = x * y;
        const double radial = 1.0 + calibration_.k1 * r2 + calibration_.k2 * r2 * r2 + calibration_.k3 * r2 * r2 * r2;
        dx = x * radial + 2.0 * calibration_.p1 * xy + calibration_.p2 * (r2 + 2.0 * x2);
        dy = y * radial + calibration_.p1 * (r2 + 2.0 * y2) + 2.0 * calibration_.p2 * xy;
    }

    bool undistort(double dx, double dy, double& x, double& y) const {
        x = dx; y = dy;
        for (int i = 0; i < 20; ++i) {
            double px = 0, py = 0;
            distort(x, y, px, py);
            const double ex = dx - px, ey = dy - py;
            x += ex; y += ey;
            if (ex * ex + ey * ey < 1e-20) return true;
            if (!std::isfinite(x) || !std::isfinite(y) || std::fabs(x) > 4 || std::fabs(y) > 4) return false;
        }
        double px = 0, py = 0; distort(x, y, px, py);
        return (dx - px) * (dx - px) + (dy - py) * (dy - py) < 1e-10;
    }

    void buildGeometryTables() {
        for (int y = 0; y < Height; ++y) {
            for (int x = 0; x < Width; ++x) {
                const int i = y * Width + x;
                const double dx = (x + 0.5 - calibration_.cx) / calibration_.fx;
                const double dy = (y + 0.5 - calibration_.cy) / calibration_.fy;
                double ux = dx, uy = dy;
                if (!undistort(dx, dy, ux, uy)) { xTable_[i] = 0; zTable_[i] = 0; continue; }
                xTable_[i] = static_cast<float>(8192.0 * ux);
                zTable_[i] = static_cast<float>(parameters_.unambiguousDistanceMm / std::sqrt(ux * ux + uy * uy + 1.0));
            }
        }
    }

    void buildMeasurementLut() {
        std::int32_t value = 0;
        for (int x = 0; x < 1024; ++x) {
            const unsigned shift = static_cast<unsigned>(x / 128 - (x >= 128 ? 1 : 0));
            const std::int32_t increment = static_cast<std::int32_t>(1u << shift);
            lut_[x] = static_cast<std::int16_t>(value);
            lut_[1024 + x] = static_cast<std::int16_t>(-value);
            value += increment;
        }
        lut_[1024] = 32767;
    }

    std::int32_t measurement(const std::uint8_t* raw, int sub, int x, int y) const {
        if (x < 1 || x > 510 || y < 0 || y >= Height) return lut_[0];
        int bit = (x >> 2) + ((x & 3) << 7);
        bit *= 11;
        const int row = y < 212 ? y + 212 : 423 - y;
        const std::uint8_t* rowData = raw + static_cast<std::size_t>(RawSubBytes) * sub + static_cast<std::size_t>(row) * 352u * 2u;
        const int word = bit >> 4;
        const int shift = bit & 15;
        std::uint16_t a = 0, b = 0;
        std::memcpy(&a, rowData + word * 2, 2);
        std::memcpy(&b, rowData + (word + 1) * 2, 2);
        const std::uint16_t packed = static_cast<std::uint16_t>((a >> shift) | (b << (16 - shift)));
        return lut_[packed & 2047u];
    }

    FrequencyMeasurement correlate(int pixel, int freq, const std::array<std::int32_t, 3>& sample) const {
        const float* t = trig_[freq].data() + static_cast<std::size_t>(pixel) * 6u;
        float a = (t[0] * sample[0] + t[1] * sample[1] + t[2] * sample[2]) * parameters_.frequencyScale[freq];
        float b = (t[3] * sample[0] + t[4] * sample[1] + t[5] * sample[2]) * parameters_.frequencyScale[freq];
        FrequencyMeasurement m;
        m.phase = std::atan2(b, a);
        if (m.phase < 0.0f) m.phase += 2.0f * Pi;
        m.amplitude = std::sqrt(a * a + b * b) * parameters_.amplitudeScale;
        return m;
    }

    float unwrap(const FrequencyMeasurement& m0, const FrequencyMeasurement& m1, const FrequencyMeasurement& m2) const {
        const float irMin = std::min({m0.amplitude, m1.amplitude, m2.amplitude});
        const float irMax = std::max({m0.amplitude, m1.amplitude, m2.amplitude});
        const float irSum = m0.amplitude + m1.amplitude + m2.amplitude;
        if (irMin < parameters_.individualAmplitudeThreshold || irSum < parameters_.totalAmplitudeThreshold) return 0.0f;

        float t0 = m0.phase / (2.0f * Pi) * 3.0f;
        float t1 = m1.phase / (2.0f * Pi) * 15.0f;
        float t2 = m2.phase / (2.0f * Pi) * 2.0f;
        float t5 = std::floor((t1 - t0) / 3.0f + 0.5f) * 3.0f + t0;
        float d = -t2 + t5;
        const bool positive = 2.0f * d >= -2.0f * d;
        d *= positive ? 0.5f : -0.5f;
        d = (d - std::floor(d)) * (positive ? 2.0f : -2.0f);
        const bool adjust = std::fabs(d) > 0.5f && std::fabs(d) < 1.5f;
        float t6 = adjust ? t5 + 15.0f : t5;
        float t7 = adjust ? t1 + 15.0f : t1;
        float t8 = (std::floor((-t2 + t6) * 0.5f + 0.5f) * 2.0f + t2) * 0.5f;
        t6 /= 3.0f; t7 /= 15.0f;
        const float sum = t8 + t6 + t7;
        float phase = sum / 3.0f;
        if (sum < 0.0f) phase = 0.0f;

        const float a = t6 * 2.0f * Pi, b = t7 * 2.0f * Pi, c = t8 * 2.0f * Pi;
        const float q0 = b * 0.826977f - c * 0.110264f;
        const float q1 = c * 0.551318f - a * 0.826977f;
        const float q2 = a * 0.110264f - b * 0.551318f;
        const float residual = q0 * q0 + q1 * q1 + q2 * q2;
        const float amplitudeForConfidence = parameters_.confidenceSlope > 0 ? irMin : irMax;
        if (!(amplitudeForConfidence > 0.0f)) return 0.0f;
        float confidence = std::exp((std::log(amplitudeForConfidence) * parameters_.confidenceSlope * 0.301030f + parameters_.confidenceOffset) * 3.321928f);
        confidence = std::clamp(confidence, parameters_.minConfidence, parameters_.maxConfidence);
        if (residual > confidence * confidence || residual > parameters_.maxConfidence * parameters_.maxConfidence) return 0.0f;
        return phase;
    }

    Parameters parameters_{};
    DepthCameraCalibration calibration_{};
    std::array<std::array<std::uint16_t, Pixels>, 3> p0_{};
    std::array<std::vector<float>, 3> trig_{};
    std::array<float, Pixels> xTable_{};
    std::array<float, Pixels> zTable_{};
    std::array<std::int16_t, 2048> lut_{};
    mutable std::vector<float> rawDepth_{};
    mutable std::vector<float> filtered_{};
    mutable std::vector<float> rawIr_{};
    bool ready_ = false;
};

}  // namespace KinectOneDepthEngine
