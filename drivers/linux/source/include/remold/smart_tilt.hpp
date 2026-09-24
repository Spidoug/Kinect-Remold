#pragma once

// Smart Tilt control law and digital framing shared by the Windows virtual
// camera and the Linux V4L2 virtual camera. This file is mirrored byte-for-byte as
//   drivers/linux/source/include/remold/smart_tilt.hpp
//   drivers/windows/source/components/camera/shared/Kinect360RemoldSmartTilt.h
// and depends only on the C++ standard library.
//
// Inputs are the per-frame motion sample published by the camera service (the
// only periodic status owner), an optional face observation and the live user
// settings. The controller never polls the broker; its only output is an
// absolute Tilt command that the caller forwards to the broker. Digital
// framing (pan, zoom, vertical crop) follows the same face target and hides
// the coarse mechanical movement of the motor.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>

namespace remold::smart_tilt {

struct Policy {
    int tiltMinDegrees = -27;
    int tiltMaxDegrees = 27;
    int startupTiltDegrees = 6;
    int faceVerticalDeadZonePixels = 10;
    double faceErrorFilterAlpha = 0.35;
    double accelFilterAlpha = 0.30;
    double accelCorrectionFilterAlpha = 0.30;
    int minCommandDeltaDegrees = 1;
    int motorSettleToleranceDegrees = 1;
    uint64_t motorSettleMs = 140;
    uint64_t commandPeriodMs = 90;
    uint64_t noFaceRelaxMs = 2000;
    uint64_t noFaceCenterMs = 8000;
    double accelCountsPerG = 819.0;
    double accelGravityMinimumG = 0.65;
    double accelGravityMaximumG = 1.35;
};

struct Settings {
    bool autoFraming = true;
    int trackingSpeed = 90;           // 1..100
    bool stabilization = true;
    int stabilizationStrength = 60;   // 1..100
    bool autoCenter = true;
    int manualTiltDegrees = 6;        // target while autoFraming is off
};

struct Motion {
    bool accelValid = false;
    bool tiltValid = false;
    int32_t accelX = 0;
    int32_t accelY = 0;
    int32_t accelZ = 0;
    int32_t tiltTenths = 0;
    uint64_t tickMs = 0;              // time the sample was measured
};

struct Face {
    bool valid = false;
    int centerY = 0;
    int frameHeight = 480;
};

struct Step {
    bool command = false;
    int commandDegrees = 0;
    bool measuredTiltValid = false;
    int measuredTiltDegrees = 0;
    bool faceErrorValid = false;
    int controlledDy = 0;             // filtered vertical face error, pixels
    int stabilizationCorrectionTenths = 0;
    bool faceLost = false;            // no face for Policy::noFaceRelaxMs
};

class Controller {
public:
    explicit Controller(const Policy& policy) : m_policy(policy) { Reset(0); }

    const Policy& GetPolicy() const noexcept { return m_policy; }

    // Called when the camera consumer becomes active or inactive. Motor state
    // is re-learned from the next motion sample; nothing is commanded here.
    void Reset(uint64_t nowMs) noexcept {
        m_lastFaceMs = nowMs;
        m_lastCommandMs = 0;
        m_lastCommand = kNone;
        m_measuredTilt = kNone;
        m_faceTarget = static_cast<double>(m_policy.startupTiltDegrees);
        m_faceTargetReady = false;
        m_faceErrorReady = false;
        m_filteredFaceDy = 0.0;
        m_filteredAccelCorrection = 0.0;
        m_lastMotionTickMs = 0;
        m_motionValid = false;
        m_accelReady = false;
        m_accelSign = 0;
        m_accelSignScore = 0.0;
        m_previousAccelSample = false;
        m_pendingAutoCenter = false;
    }

    Step Update(uint64_t nowMs, const Motion& motion, const Face& face, const Settings& settings) noexcept {
        Step out{};
        const int speed = std::clamp(settings.trackingSpeed, 1, 100);
        ConsumeMotion(motion, settings);
        m_pendingAutoCenter = false;
        if (m_measuredTilt != kNone) {
            out.measuredTiltValid = true;
            out.measuredTiltDegrees = m_measuredTilt;
        }

        if (!settings.autoFraming) {
            m_faceTargetReady = false;
            m_faceErrorReady = false;
            ClearAccelCorrection();
            LearnMountBias();
            const int target = ClampTilt(settings.manualTiltDegrees);
            if (CanCommand(nowMs) &&
                (m_lastCommand == kNone || std::abs(target - m_lastCommand) >= m_policy.minCommandDeltaDegrees)) {
                out.command = true;
                out.commandDegrees = target;
            }
            return out;
        }

        if (face.valid && face.frameHeight > 1) {
            m_lastFaceMs = nowMs;
            const double dy = static_cast<double>(face.centerY) - static_cast<double>(face.frameHeight) / 2.0;
            if (!m_faceErrorReady) {
                m_filteredFaceDy = dy;
                m_faceErrorReady = true;
            } else {
                m_filteredFaceDy += (dy - m_filteredFaceDy) * m_policy.faceErrorFilterAlpha;
            }
            const int controlledDy = static_cast<int>(std::lround(m_filteredFaceDy));
            out.faceErrorValid = true;
            out.controlledDy = controlledDy;

            const double accelCorrection = UpdateAccelCorrection(settings);
            out.stabilizationCorrectionTenths = static_cast<int>(std::lround(accelCorrection * 10.0));

            const bool faceNeedsTilt = std::abs(controlledDy) > m_policy.faceVerticalDeadZonePixels;
            const bool accelNeedsTilt = std::abs(accelCorrection) >= 0.50;
            if ((faceNeedsTilt || accelNeedsTilt) && CanCommand(nowMs)) {
                const int currentTilt = m_measuredTilt;
                if (!m_faceTargetReady) {
                    m_faceTarget = static_cast<double>(currentTilt);
                    m_faceTargetReady = true;
                }
                if (faceNeedsTilt) {
                    // Re-anchor on the measured physical angle so the same face
                    // error is never integrated while the motor is travelling.
                    const double halfHeight = static_cast<double>(face.frameHeight) / 2.0;
                    const double authority = 5.0 + (static_cast<double>(speed) / 100.0) * 15.0;
                    double correction = (static_cast<double>(controlledDy) / halfHeight) * authority;
                    if (std::abs(correction) < 1.0) correction = controlledDy > 0 ? 1.0 : -1.0;
                    m_faceTarget = std::clamp(static_cast<double>(currentTilt) - correction,
                                              static_cast<double>(m_policy.tiltMinDegrees),
                                              static_cast<double>(m_policy.tiltMaxDegrees));
                }
                const int wanted = ClampTilt(static_cast<int>(std::lround(m_faceTarget + accelCorrection)));
                const int prior = m_lastCommand == kNone ? currentTilt : m_lastCommand;
                const double motorAlpha = 0.55 + (static_cast<double>(speed) / 100.0) * 0.40;
                const int maxStep = 3 + (speed * 9) / 100;
                const int step = std::clamp(static_cast<int>(std::lround((wanted - prior) * motorAlpha)), -maxStep, maxStep);
                int smooth = ClampTilt(prior + step);
                if (smooth == prior && wanted != prior) smooth += wanted > prior ? 1 : -1;
                if (m_lastCommand == kNone || std::abs(smooth - m_lastCommand) >= m_policy.minCommandDeltaDegrees) {
                    out.command = true;
                    out.commandDegrees = smooth;
                }
            }
            return out;
        }

        m_faceErrorReady = false;
        if (nowMs - m_lastFaceMs < m_policy.noFaceRelaxMs) return out;
        out.faceLost = true;

        ClearAccelCorrection();
        LearnMountBias();
        if (settings.autoCenter && nowMs - m_lastFaceMs >= m_policy.noFaceCenterMs && CanCommand(nowMs) &&
            std::abs(m_measuredTilt - m_policy.startupTiltDegrees) >= m_policy.minCommandDeltaDegrees) {
            out.command = true;
            out.commandDegrees = m_policy.startupTiltDegrees;
            m_pendingAutoCenter = true;
        }
        return out;
    }

    // The broker accepted the command returned by the last Update().
    void CommandAccepted(int degrees, uint64_t nowMs) noexcept {
        m_lastCommand = degrees;
        m_lastCommandMs = nowMs;
        if (m_pendingAutoCenter) {
            m_faceTarget = static_cast<double>(degrees);
            m_faceTargetReady = true;
        }
        m_pendingAutoCenter = false;
    }

private:
    static constexpr int kNone = 999;

    Policy m_policy;
    uint64_t m_lastFaceMs = 0;
    uint64_t m_lastCommandMs = 0;
    int m_lastCommand = kNone;
    int m_measuredTilt = kNone;
    double m_faceTarget = 0.0;
    bool m_faceTargetReady = false;
    bool m_faceErrorReady = false;
    double m_filteredFaceDy = 0.0;
    double m_filteredAccelCorrection = 0.0;
    uint64_t m_lastMotionTickMs = 0;
    bool m_motionValid = false;
    bool m_accelReady = false;
    double m_filteredAccelPitch = 0.0;
    double m_accelMountBias = 0.0;
    int m_accelSign = 0;
    double m_accelSignScore = 0.0;
    bool m_previousAccelSample = false;
    double m_previousAccelPitch = 0.0;
    int m_previousAccelTilt = 0;
    bool m_pendingAutoCenter = false;

    int ClampTilt(int degrees) const noexcept {
        return std::clamp(degrees, m_policy.tiltMinDegrees, m_policy.tiltMaxDegrees);
    }

    // Commands require a valid measured angle, an elapsed command period and
    // a motor that is not still settling onto the previous command.
    bool CanCommand(uint64_t nowMs) const noexcept {
        if (!m_motionValid || m_measuredTilt == kNone) return false;
        if (m_lastCommand != kNone && nowMs - m_lastCommandMs < m_policy.commandPeriodMs) return false;
        const bool settling = m_lastCommand != kNone &&
            std::abs(m_measuredTilt - m_lastCommand) > m_policy.motorSettleToleranceDegrees &&
            nowMs - m_lastCommandMs < m_policy.motorSettleMs;
        return !settling;
    }

    bool AccelPitchDegrees(const Motion& motion, double& pitch) const noexcept {
        // Gravity-only pitch: reject samples whose magnitude shows strong
        // linear acceleration so compensation never chases a bump.
        const double x = static_cast<double>(motion.accelX);
        const double y = static_cast<double>(motion.accelY);
        const double z = static_cast<double>(motion.accelZ);
        const double magnitude = std::sqrt(x * x + y * y + z * z);
        if (magnitude < m_policy.accelCountsPerG * m_policy.accelGravityMinimumG ||
            magnitude > m_policy.accelCountsPerG * m_policy.accelGravityMaximumG) return false;
        pitch = std::asin(std::clamp(z / magnitude, -1.0, 1.0)) * (180.0 / 3.14159265358979323846);
        return std::isfinite(pitch);
    }

    void ConsumeMotion(const Motion& motion, const Settings& settings) noexcept {
        // A missing sample (stale, or the motor is travelling) only blocks
        // commands; filtered pitch and learned polarity carry across the gap
        // because the samples around a travel are the ones that teach the sign.
        m_motionValid = motion.tiltValid;
        if (!motion.tiltValid || motion.tickMs == m_lastMotionTickMs) return;
        m_lastMotionTickMs = motion.tickMs;

        const int reported = ClampTilt(static_cast<int>(std::lround(static_cast<double>(motion.tiltTenths) / 10.0)));
        m_measuredTilt = reported;
        if (settings.autoFraming && !m_faceTargetReady) {
            // Warm-start from the measured angle: activating the camera never
            // jerks the motor towards a stored target.
            m_faceTarget = static_cast<double>(reported);
            m_faceTargetReady = true;
            m_lastCommand = reported;
        }

        double pitch = 0.0;
        if (!motion.accelValid || !AccelPitchDegrees(motion, pitch)) return;
        if (!m_accelReady) {
            m_filteredAccelPitch = pitch;
            m_accelReady = true;
        } else {
            m_filteredAccelPitch += (pitch - m_filteredAccelPitch) * m_policy.accelFilterAlpha;
        }

        // Learn motor-to-accelerometer polarity from real movement so no
        // hardware model or mounting orientation depends on a guessed sign.
        if (m_previousAccelSample) {
            const double tiltDelta = static_cast<double>(reported - m_previousAccelTilt);
            const double pitchDelta = m_filteredAccelPitch - m_previousAccelPitch;
            if (std::abs(tiltDelta) >= 0.75) {
                const double ratio = pitchDelta / tiltDelta;
                if (std::abs(ratio) >= 0.20 && std::abs(ratio) <= 2.50) {
                    m_accelSignScore = std::clamp(m_accelSignScore + (ratio > 0.0 ? 1.0 : -1.0), -4.0, 4.0);
                    const int learned = m_accelSignScore >= 2.0 ? 1 : (m_accelSignScore <= -2.0 ? -1 : 0);
                    if (learned != 0 && learned != m_accelSign) {
                        m_accelSign = learned;
                        m_accelMountBias = m_filteredAccelPitch - static_cast<double>(m_accelSign * reported);
                    }
                }
            }
        }
        m_previousAccelPitch = m_filteredAccelPitch;
        m_previousAccelTilt = reported;
        m_previousAccelSample = true;
    }

    // Low-authority gravity feed-forward: rejects base pitch disturbances
    // between face updates while FaceTracker keeps composition authority.
    double UpdateAccelCorrection(const Settings& settings) noexcept {
        double raw = 0.0;
        if (settings.stabilization && m_motionValid && m_accelReady && m_accelSign != 0) {
            const double expected = m_accelMountBias + static_cast<double>(m_accelSign * m_measuredTilt);
            const double disturbance = m_filteredAccelPitch - expected;
            if (std::abs(disturbance) > kAccelDeadbandDegrees) {
                const double strength = static_cast<double>(std::clamp(settings.stabilizationStrength, 1, 100)) / 100.0;
                raw = std::clamp(-disturbance * static_cast<double>(m_accelSign) * (0.35 + 0.65 * strength),
                                 -kAccelMaximumCorrectionDegrees, kAccelMaximumCorrectionDegrees);
            }
        }
        m_filteredAccelCorrection += (raw - m_filteredAccelCorrection) * m_policy.accelCorrectionFilterAlpha;
        if (std::abs(m_filteredAccelCorrection) < 0.05) m_filteredAccelCorrection = 0.0;
        return m_filteredAccelCorrection;
    }

    void ClearAccelCorrection() noexcept { m_filteredAccelCorrection = 0.0; }

    void LearnMountBias() noexcept {
        if (!m_motionValid || !m_accelReady || m_accelSign == 0) return;
        const double neutral = m_filteredAccelPitch - static_cast<double>(m_accelSign * m_measuredTilt);
        m_accelMountBias += (neutral - m_accelMountBias) * kAccelBaselineAlpha;
    }

    static constexpr double kAccelBaselineAlpha = 0.025;
    static constexpr double kAccelDeadbandDegrees = 0.35;
    static constexpr double kAccelMaximumCorrectionDegrees = 5.0;
};

constexpr int kPanLimitDegrees = 30;
constexpr int kZoomMinPermille = 1000;
constexpr int kZoomMaxPermille = 2000;
constexpr int kVerticalCropLimitPermille = 650;

struct Framing {
    int panDegrees = 0;               // -30..30
    int zoomPermille = 1000;          // 1000..2000
    int verticalCropPermille = 0;     // -1000..1000
};

struct FramingSettings {
    int deadZonePercent = 7;          // 4..35
    int digitalZoomLimitPercent = 180; // 100..200
};

// Face target in frame pixels: the common bounding box of every face (group).
struct FaceBox {
    bool valid = false;
    int centerX = 0;
    int centerY = 0;
    int width = 0;
    int height = 0;
};

struct CropRect {
    uint32_t x = 0;
    uint32_t y = 0;
    uint32_t width = 0;
    uint32_t height = 0;
};

// One framing step per face period, driven by the controller step of the same
// period. Only called while automatic framing is on.
inline Framing UpdateFraming(const Framing& current, const FaceBox& target, int frameWidth, int frameHeight,
                             const Step& step, int trackingSpeed, const FramingSettings& settings) noexcept {
    Framing next = current;
    if (frameWidth < 2 || frameHeight < 2) return next;
    const double alpha = 0.10 + (static_cast<double>(std::clamp(trackingSpeed, 1, 100)) / 100.0) * 0.45;
    auto approach = [alpha](int value, int wanted) {
        return static_cast<int>(std::lround(value + (wanted - value) * alpha));
    };
    if (target.valid) {
        const int dead = std::clamp(settings.deadZonePercent, 4, 35);
        const int dx = target.centerX - frameWidth / 2;
        const int deadX = (frameWidth * dead) / 200;
        int wantedPan = current.panDegrees;
        if (std::abs(dx) > deadX) {
            wantedPan = std::clamp((dx * kPanLimitDegrees) / (frameWidth / 2), -kPanLimitDegrees, kPanLimitDegrees);
        }
        next.panDegrees = std::clamp(approach(current.panDegrees, wantedPan), -kPanLimitDegrees, kPanLimitDegrees);

        const int limit = std::clamp(settings.digitalZoomLimitPercent, 100, 200) * 10;
        int wantedZoom = kZoomMinPermille;
        if (target.width > 0 && target.height > 0) {
            const int byWidth = static_cast<int>((static_cast<int64_t>(frameWidth) * 1000) / (target.width * 2 + 1));
            const int byHeight = static_cast<int>((static_cast<int64_t>(frameHeight) * 1000) / (target.height * 3 + 1));
            wantedZoom = std::clamp(std::min(byWidth, byHeight), kZoomMinPermille, limit);
        }
        next.zoomPermille = std::clamp(approach(current.zoomPermille, wantedZoom), kZoomMinPermille, limit);

        const int wantedVertical = std::clamp((step.controlledDy * 1200) / (frameHeight / 2),
                                              -kVerticalCropLimitPermille, kVerticalCropLimitPermille);
        next.verticalCropPermille = std::clamp(approach(current.verticalCropPermille, wantedVertical),
                                               -kVerticalCropLimitPermille, kVerticalCropLimitPermille);
    } else if (step.faceLost) {
        // Truncation towards zero guarantees the relaxation reaches the full frame.
        auto relax = [](int value) { return static_cast<int>(value * 0.88); };
        next.panDegrees = relax(current.panDegrees);
        next.zoomPermille = kZoomMinPermille + relax(current.zoomPermille - kZoomMinPermille);
        next.verticalCropPermille = relax(current.verticalCropPermille);
    }
    return next;
}

// Source rectangle of a framed image. Pan and vertical correction need crop
// margin, so they imply at least 1.1x zoom.
inline CropRect FramingCrop(const Framing& framing, uint32_t width, uint32_t height) noexcept {
    CropRect crop{0, 0, width, height};
    if (width < 2 || height < 2) return crop;
    int zoom = std::clamp(framing.zoomPermille, kZoomMinPermille, kZoomMaxPermille);
    const int pan = std::clamp(framing.panDegrees, -kPanLimitDegrees, kPanLimitDegrees);
    const int vertical = std::clamp(framing.verticalCropPermille, -1000, 1000);
    if (zoom == kZoomMinPermille && pan == 0 && vertical == 0) return crop;
    if ((pan != 0 || vertical != 0) && zoom < 1100) zoom = 1100;

    crop.width = std::clamp<uint32_t>(static_cast<uint32_t>((static_cast<uint64_t>(width) * 1000u) / static_cast<uint32_t>(zoom)) & ~1u, 2u, width);
    crop.height = std::clamp<uint32_t>(static_cast<uint32_t>((static_cast<uint64_t>(height) * 1000u) / static_cast<uint32_t>(zoom)) & ~1u, 2u, height);
    const int spareX = static_cast<int>(width - crop.width);
    const int spareY = static_cast<int>(height - crop.height);
    int x = spareX / 2;
    int y = spareY / 2;
    if (spareX > 0) x += (pan * spareX) / (2 * kPanLimitDegrees);
    if (spareY > 0) y += (vertical * spareY) / 2000;
    crop.x = static_cast<uint32_t>(std::clamp(x, 0, spareX)) & ~1u;
    crop.y = static_cast<uint32_t>(std::clamp(y, 0, spareY)) & ~1u;
    return crop;
}

} // namespace remold::smart_tilt
