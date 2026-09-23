#ifndef FILO_BRIDGE_H
#define FILO_BRIDGE_H
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stdbool.h>

// All configuration and allocation happen before either IOProc starts.
// Exactly one producer calls push/capture_io and one consumer calls render/output_io.
typedef struct FiloBridge FiloBridge;
typedef enum {
    FiloBridgeFaultNone = 0,
    FiloBridgeFaultInputLayout = 1,
    FiloBridgeFaultOutputLayout = 2,
    FiloBridgeFaultOverflow = 3,
    FiloBridgeFaultUnderflow = 4,
    FiloBridgeFaultRepresentation = 5,
    FiloBridgeFaultTimestamp = 6
} FiloBridgeFault;
typedef struct {
    uint64_t capacityFrames;       // Power of two, at least 2.
    uint64_t primeFrames;          // 1...capacity; startup silence consumes no queued frames.
    uint64_t renderCaptureFrames;  // Optional lab-only storage, decoded from actual output words.
    AudioStreamBasicDescription inputFormat;  // Stereo native little-endian Float32.
    AudioStreamBasicDescription outputFormat; // Stereo Float32 or signed LE 16/24/32-bit PCM.
    uint32_t inputBufferOffset;    // Skip disabled physical-input buffers before the tap.
    uint32_t inputBufferCount;     // 1 interleaved or 2 planar, must match inputFormat.
    uint32_t sourceBits;           // 0 = no source-depth assertion, otherwise 16 or 24.
} FiloBridgeConfig;
typedef struct {
    uint64_t inputCallbacks, outputCallbacks;
    uint64_t capturedFrames, deliveredFrames, queuedFrames;
    uint64_t initialQueuedFrames; // Queue depth immediately before first payload delivery, zero until started.
    uint64_t startupSilenceFrames, underflows, overflows;
    uint64_t invalidBuffers, representationFailures, renderedCaptureFrames;
    uint64_t inputTimestampMissing, outputTimestampMissing;
    uint64_t inputTimestampDiscontinuities, outputTimestampDiscontinuities;
    uint32_t fault;
    bool started;
} FiloBridgeMetrics;

// Returns NULL for unsupported ASBDs, unsafe allocation sizes, or allocation failure.
FiloBridge * _Nullable filo_bridge_create(const FiloBridgeConfig * _Nonnull config);
// Stop and destroy BOTH IOProcs before destruction or capture-data inspection.
void filo_bridge_destroy(FiloBridge * _Nullable state);
FiloBridgeMetrics filo_bridge_metrics(const FiloBridge * _Nullable state);
const float * _Nullable filo_bridge_render_capture(const FiloBridge * _Nullable state);
// Lab-only exact bytes copied from the final output buffers, canonical interleaved L/R order.
// Padding bytes and word representation are retained. Startup/fault silence is excluded, as in float capture.
// Stop and destroy BOTH IOProcs before reading the returned storage or comparing its bytes.
const uint8_t * _Nullable filo_bridge_render_bytes(const FiloBridge * _Nullable state);
uint64_t filo_bridge_render_byte_count(const FiloBridge * _Nullable state);
uint32_t filo_bridge_render_bytes_per_frame(const FiloBridge * _Nullable state);
// Return false after a latched fault. Render always silences all provided buffers on failure.
// Before priming, render returns true, writes silence, and preserves all queued source frames.
bool filo_bridge_push(FiloBridge * _Nonnull state, const AudioBufferList * _Nullable input);
bool filo_bridge_render(FiloBridge * _Nonnull state, AudioBufferList * _Nullable output);
// IOProc wrappers additionally check sample-time progression against callback frame counts
// (maximum 0.5-frame deviation from the first timestamp's timeline) and reject backwards host time.
// A missing/invalid timestamp increments its direction's missing-evidence count without fabricating proof.
OSStatus filo_bridge_capture_io(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
OSStatus filo_bridge_output_io(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
