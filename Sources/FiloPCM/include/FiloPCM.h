#ifndef FILO_PCM_H
#define FILO_PCM_H
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct FiloTransport FiloTransport;
typedef struct {
    uint64_t callbacks;
    uint64_t frames;
    uint64_t nonzeroSamples;
    uint64_t invalidBuffers;
    uint64_t capturedFrames;
    uint32_t inputBuffers, inputFirstChannels, inputLastChannels, inputLastBytes;
} FiloMetrics;

// Float32 stereo only. Any unsupported layout is rejected, never downmixed.
bool filo_copy(const AudioBufferList * _Nullable input, AudioBufferList * _Nullable output);
float filo_test_sample(uint64_t frame, uint32_t channel, uint32_t bits);
FiloTransport * _Nullable filo_transport_create(bool emit, bool relay, uint32_t bits, uint64_t captureCapacity);
void filo_transport_set_input_offset(FiloTransport * _Nonnull state, uint32_t skip, uint32_t count);
void filo_transport_destroy(FiloTransport * _Nullable state);
FiloMetrics filo_transport_metrics(const FiloTransport * _Nullable state);
// Read captured data only after AudioDeviceStop + AudioDeviceDestroyIOProcID.
const float * _Nullable filo_transport_capture(const FiloTransport * _Nullable state);
OSStatus filo_io(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                 const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                 AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
