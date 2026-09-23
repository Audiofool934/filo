#ifndef FILO_FINITE_REFERENCE_H
#define FILO_FINITE_REFERENCE_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct FiniteReference FiniteReference;
typedef struct {
    uint64_t callbacks, outputFrames, emittedFrames, firstFixtureOutputFrame;
    uint64_t timestampMissing, timestampDiscontinuities;
    bool started, completed, fault;
} FiniteReferenceMetrics;

FiniteReference * _Nullable finite_reference_create(const float * _Nonnull samples, uint64_t frames);
void finite_reference_destroy(FiniteReference * _Nullable state);
bool finite_reference_go(FiniteReference * _Nonnull state);
FiniteReferenceMetrics finite_reference_metrics(const FiniteReference * _Nonnull state);
OSStatus finite_reference_io(AudioDeviceID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
