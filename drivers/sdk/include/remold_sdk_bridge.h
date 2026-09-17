#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define REMOLD_SDK_BRIDGE_VERSION 1u
#define REMOLD_ENDPOINT_BYTES 108u

/* Clean-room host API for applications and emulator adapters. This is not the
   proprietary Microsoft Kinect10.dll ABI. Wire values are little-endian. */
enum RemoldSdkInitFlags {
    REMOLD_SDK_USE_COLOR    = 1u << 0,
    REMOLD_SDK_USE_DEPTH    = 1u << 1,
    REMOLD_SDK_USE_SKELETON = 1u << 2,
    REMOLD_SDK_USE_AUDIO    = 1u << 3,
    REMOLD_SDK_USE_INFRARED = 1u << 4
};

enum RemoldSdkCapabilities {
    REMOLD_CAP_COLOR          = 1u << 0,
    REMOLD_CAP_INFRARED       = 1u << 1,
    REMOLD_CAP_DEPTH          = 1u << 2,
    REMOLD_CAP_AUDIO_4MIC     = 1u << 3,
    REMOLD_CAP_TILT_LED_ACCEL = 1u << 4,
    REMOLD_CAP_NUI20          = 1u << 5,
    REMOLD_CAP_RAW_FRAMES     = 1u << 6,
    REMOLD_CAP_SKELETON       = 1u << 7,
    REMOLD_CAP_AUDIO_CONTROL  = 1u << 8,
    REMOLD_CAP_SDK_BRIDGE     = 1u << 9
};

typedef struct RemoldSdkState {
    uint32_t sensor_count;
    uint32_t connected;
    uint32_t capabilities;
    int32_t elevation_degrees;
    int32_t accel_x;
    int32_t accel_y;
    int32_t accel_z;
    uint32_t initialized_flags;
    char camera_endpoint[REMOLD_ENDPOINT_BYTES];
    char audio_endpoint[REMOLD_ENDPOINT_BYTES];
    char audio_control_endpoint[REMOLD_ENDPOINT_BYTES];
    char skeleton_endpoint[REMOLD_ENDPOINT_BYTES];
} RemoldSdkState;

typedef struct RemoldAudioState {
    int32_t volume_basis_points; /* 0..10000 */
    uint32_t muted;
    uint32_t capabilities;
    uint32_t backend;            /* 1=software, 2=ALSA mixer, 3=Windows endpoint */
} RemoldAudioState;

/* All functions return 0 on success. Non-zero values are the native bridge
   result (negative errno on Linux or HRESULT-compatible value on Windows), or
   a client-side negative error when the transport itself cannot be reached. */
/* Selection is thread-local so independent application threads can address
   different physical Kinect sensors through the same process. */
int32_t remold_sdk_select_sensor(uint32_t index);
int32_t remold_sdk_select_device(const char* device_id);
int32_t remold_sdk_sensor_count(uint32_t* count);
int32_t remold_sdk_status(RemoldSdkState* state);
int32_t remold_sdk_runtime_info(RemoldSdkState* state);
int32_t remold_sdk_initialize(uint32_t flags, RemoldSdkState* state);
int32_t remold_sdk_shutdown(RemoldSdkState* state);
int32_t remold_sdk_get_elevation(int32_t* degrees);
int32_t remold_sdk_set_elevation(int32_t degrees, RemoldSdkState* state);
int32_t remold_sdk_get_accelerometer(int32_t* x, int32_t* y, int32_t* z);

int32_t remold_audio_get_state(RemoldAudioState* state);
int32_t remold_audio_set_volume(int32_t volume_basis_points, RemoldAudioState* state);
int32_t remold_audio_set_mute(uint32_t muted, RemoldAudioState* state);

/* Human-readable transport/validation diagnostic for the calling thread. */
const char* remold_sdk_last_error(void);

#ifdef __cplusplus
}
#endif
