#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <vector>

namespace KinectOneNativeUsb {

constexpr std::uint16_t VendorId = 0x045e;
// Supported Kinect v2 sensor product IDs.
constexpr std::array<std::uint16_t, 2> SensorProductIds{0x02c4, 0x02d8};
constexpr std::uint8_t ControlInterface = 0;
constexpr std::uint8_t DepthInterface = 1;
constexpr std::uint8_t CommandOut = 0x02;
constexpr std::uint8_t CommandIn = 0x81;
constexpr std::uint8_t ColorIn = 0x83;
constexpr std::uint8_t DepthIn = 0x84;
constexpr std::uint32_t CommandMagic = 0x06022009u;
constexpr std::uint32_t CompletionMagic = 0x0A6FE000u;
constexpr std::size_t CompletionBytes = 16;
constexpr std::size_t DepthWidth = 512;
constexpr std::size_t DepthHeight = 424;
constexpr std::size_t DepthSubImageBytes = DepthWidth * DepthHeight * 11 / 8;
constexpr std::size_t DepthSubImagesPerFrame = 10;


inline bool supportedProduct(std::uint16_t product) {
    return std::find(SensorProductIds.begin(), SensorProductIds.end(), product) != SensorProductIds.end();
}

#pragma pack(push, 1)
struct CommandHeader {
    std::uint32_t magic;
    std::uint32_t sequence;
    std::uint32_t maxResponseBytes;
    std::uint32_t command;
    std::uint32_t reserved;
};

struct Completion {
    std::uint32_t magic;
    std::uint32_t sequence;
    std::uint32_t status;
    std::uint32_t reserved;
};

struct DepthSubpacketFooter {
    std::uint32_t magic0;
    std::uint32_t magic1;
    std::uint32_t timestamp;
    std::uint32_t sequence;
    std::uint32_t subsequence;
    std::uint32_t length;
    std::uint32_t fields[32];
};
#pragma pack(pop)

static_assert(sizeof(CommandHeader) == 20);
static_assert(sizeof(Completion) == CompletionBytes);
static_assert(sizeof(DepthSubpacketFooter) == 152);

struct CommandSpec {
    std::uint32_t command = 0;
    std::uint32_t maxResponseBytes = 0;
    std::vector<std::uint32_t> parameters;
};

inline std::vector<std::uint8_t> encodeCommand(std::uint32_t sequence, const CommandSpec& spec) {
    std::vector<std::uint8_t> bytes(sizeof(CommandHeader) + spec.parameters.size() * sizeof(std::uint32_t));
    CommandHeader header{CommandMagic, sequence, spec.maxResponseBytes, spec.command, 0};
    std::memcpy(bytes.data(), &header, sizeof(header));
    if (!spec.parameters.empty()) {
        std::memcpy(bytes.data() + sizeof(header), spec.parameters.data(), spec.parameters.size() * sizeof(std::uint32_t));
    }
    return bytes;
}

inline bool validCompletion(const std::uint8_t* bytes, std::size_t size, std::uint32_t sequence) {
    if (!bytes || size != sizeof(Completion)) return false;
    Completion completion{};
    std::memcpy(&completion, bytes, sizeof(completion));
    return completion.magic == CompletionMagic && completion.sequence == sequence;
}

namespace command {
inline CommandSpec firmwareVersions() { return {0x02, 0x200, {}}; }
inline CommandSpec hardwareInfo() { return {0x14, 0x5c, {}}; }
inline CommandSpec serialNumber() { return {0x22, 0x80, {0x01}}; }
inline CommandSpec depthParameters() { return {0x22, 0x1c0000, {0x03}}; }
inline CommandSpec colorParameters() { return {0x22, 0x1c0000, {0x04}}; }
inline CommandSpec p0Tables() { return {0x22, 0x1c0000, {0x02}}; }
inline CommandSpec initStreams() { return {0x09, 0, {}}; }
inline CommandSpec streaming(bool enabled) { return {0x2b, 0, {enabled ? 1u : 0u}}; }
inline CommandSpec mode(bool enabled, std::uint32_t timing = 0) { return {0x4b, 0, {enabled ? 1u : 0u, timing, 0, 0}}; }
inline CommandSpec status() { return {0x16, 4, {0x090000}}; }
inline CommandSpec stop() { return {0x0a, 0, {}}; }
}  // namespace command

class JpegAssembler {
public:
    void push(const std::uint8_t* data, std::size_t size) {
        if (!data || size == 0) return;
        buffer_.insert(buffer_.end(), data, data + size);
        parse();
    }

    bool pop(std::vector<std::uint8_t>& frame) {
        if (ready_.empty()) return false;
        frame = std::move(ready_.front());
        ready_.pop_front();
        return true;
    }

    bool push(const std::uint8_t* data, std::size_t size, std::vector<std::uint8_t>& frame) {
        push(data, size);
        return pop(frame);
    }

    void reset() { buffer_.clear(); ready_.clear(); }

private:
    void parse() {
        static constexpr std::uint8_t Soi0 = 0xff, Soi1 = 0xd8, Eoi0 = 0xff, Eoi1 = 0xd9;
        constexpr std::size_t MaxFrameBytes = 16u * 1024u * 1024u;
        for (;;) {
            std::size_t begin = 0;
            while (begin + 1 < buffer_.size() && !(buffer_[begin] == Soi0 && buffer_[begin + 1] == Soi1)) ++begin;
            if (begin + 1 >= buffer_.size()) {
                if (!buffer_.empty()) {
                    const bool keepMarkerPrefix = buffer_.back() == Soi0;
                    const std::uint8_t last = buffer_.back();
                    buffer_.clear();
                    if (keepMarkerPrefix) buffer_.push_back(last);
                }
                return;
            }
            if (begin) buffer_.erase(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(begin));
            if (buffer_.size() > MaxFrameBytes) { buffer_.erase(buffer_.begin(), buffer_.begin() + 2); continue; }
            std::size_t end = 2;
            while (end + 1 < buffer_.size() && !(buffer_[end] == Eoi0 && buffer_[end + 1] == Eoi1)) ++end;
            if (end + 1 >= buffer_.size()) return;
            end += 2;
            ready_.emplace_back(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(end));
            buffer_.erase(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(end));
            while (ready_.size() > 3) ready_.pop_front();
        }
    }

    std::vector<std::uint8_t> buffer_;
    std::deque<std::vector<std::uint8_t>> ready_;
};

class DepthFrameAssembler {
public:
    DepthFrameAssembler() : frame_(DepthSubImageBytes * DepthSubImagesPerFrame) {}

    bool pushIsoPacket(const std::uint8_t* data, std::size_t size, std::vector<std::uint8_t>& frame, std::uint32_t& timestamp) {
        if (size == 0) {
            stream_.clear();
            return false;
        }
        if (!data) return false;
        stream_.insert(stream_.end(), data, data + size);
        bool completed = false;
        while (stream_.size() >= RecordBytes) {
            std::size_t offset = recordOffset();
            if (offset == NoOffset) {
                if (stream_.size() > RecordBytes - 1u) {
                    const std::size_t drop = stream_.size() - (RecordBytes - 1u);
                    stream_.erase(stream_.begin(), stream_.begin() + static_cast<std::ptrdiff_t>(drop));
                    resyncDrops_ += drop;
                }
                break;
            }
            if (offset) {
                stream_.erase(stream_.begin(), stream_.begin() + static_cast<std::ptrdiff_t>(offset));
                resyncDrops_ += offset;
            }
            if (stream_.size() < RecordBytes) break;
            if (!consumeRecord(stream_.data(), frame, timestamp, completed)) {
                stream_.erase(stream_.begin());
                ++resyncDrops_;
                continue;
            }
            stream_.erase(stream_.begin(), stream_.begin() + static_cast<std::ptrdiff_t>(RecordBytes));
            resyncDrops_ = 0;
            if (completed) return true;
        }
        constexpr std::size_t MaxBuffered = RecordBytes * 3u;
        if (stream_.size() > MaxBuffered) reset();
        return false;
    }

    void reset() { stream_.clear(); mask_ = 0; haveSequence_ = false; resyncDrops_ = 0; }

private:
    static constexpr std::size_t RecordBytes = DepthSubImageBytes + sizeof(DepthSubpacketFooter);
    static constexpr std::size_t NoOffset = static_cast<std::size_t>(-1);

    std::size_t recordOffset() const {
        if (stream_.size() < RecordBytes) return NoOffset;
        const std::size_t maxOffset = stream_.size() - RecordBytes;
        for (std::size_t offset = 0; offset <= maxOffset; ++offset) {
            DepthSubpacketFooter footer{};
            std::memcpy(&footer, stream_.data() + offset + DepthSubImageBytes, sizeof(footer));
            if (footer.length == DepthSubImageBytes && footer.subsequence < DepthSubImagesPerFrame) return offset;
        }
        return NoOffset;
    }

    bool consumeRecord(const std::uint8_t* record, std::vector<std::uint8_t>& frame,
                       std::uint32_t& timestamp, bool& completed) {
        completed = false;
        DepthSubpacketFooter footer{};
        std::memcpy(&footer, record + DepthSubImageBytes, sizeof(footer));
        if (footer.length != DepthSubImageBytes || footer.subsequence >= DepthSubImagesPerFrame) return false;
        if (haveSequence_ && footer.sequence != sequence_) mask_ = 0;
        sequence_ = footer.sequence;
        haveSequence_ = true;
        std::memcpy(frame_.data() + footer.subsequence * DepthSubImageBytes, record, DepthSubImageBytes);
        mask_ |= (1u << footer.subsequence);
        timestamp_ = footer.timestamp;
        const std::uint32_t full = (1u << DepthSubImagesPerFrame) - 1u;
        if (mask_ != full) return true;
        frame = frame_;
        timestamp = timestamp_;
        mask_ = 0;
        completed = true;
        return true;
    }

    std::vector<std::uint8_t> frame_;
    std::vector<std::uint8_t> stream_;
    std::uint32_t mask_ = 0;
    std::uint32_t sequence_ = 0;
    std::uint32_t timestamp_ = 0;
    std::size_t resyncDrops_ = 0;
    bool haveSequence_ = false;
};

}  // namespace KinectOneNativeUsb
