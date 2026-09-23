#include "finite-reference.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2, "Lock-free atomics required");
struct FiniteReference {
    float *samples;
    uint64_t frames, position, timelineFrames, hostTime;
    double sampleAnchor;
    bool sampleEstablished, hostEstablished, began;
    _Atomic uint64_t callbacks, outputFrames, emittedFrames, firstFixtureOutputFrame;
    _Atomic uint64_t timestampMissing, timestampDiscontinuities;
    _Atomic bool go, started, completed, fault;
};

FiniteReference *finite_reference_create(const float *samples, uint64_t frames) {
    if (!samples || !frames || frames > 24000000) return NULL;
    FiniteReference *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->samples = malloc((size_t)frames * 2 * sizeof(float));
    if (!s->samples) { free(s); return NULL; }
    memcpy(s->samples, samples, (size_t)frames * 2 * sizeof(float));
    s->frames = frames;
    atomic_init(&s->callbacks, 0); atomic_init(&s->outputFrames, 0);
    atomic_init(&s->emittedFrames, 0); atomic_init(&s->firstFixtureOutputFrame, UINT64_MAX);
    atomic_init(&s->timestampMissing, 0); atomic_init(&s->timestampDiscontinuities, 0);
    atomic_init(&s->go, false); atomic_init(&s->started, false);
    atomic_init(&s->completed, false); atomic_init(&s->fault, false);
    return s;
}
void finite_reference_destroy(FiniteReference *s) { if (s) { free(s->samples); free(s); } }
bool finite_reference_go(FiniteReference *s) {
    bool expected = false;
    return !atomic_load(&s->fault) && atomic_compare_exchange_strong(&s->go, &expected, true);
}
FiniteReferenceMetrics finite_reference_metrics(const FiniteReference *s) {
    return (FiniteReferenceMetrics){
        .callbacks = atomic_load(&s->callbacks), .outputFrames = atomic_load(&s->outputFrames),
        .emittedFrames = atomic_load(&s->emittedFrames), .firstFixtureOutputFrame = atomic_load(&s->firstFixtureOutputFrame),
        .timestampMissing = atomic_load(&s->timestampMissing), .timestampDiscontinuities = atomic_load(&s->timestampDiscontinuities),
        .started = atomic_load(&s->started), .completed = atomic_load(&s->completed), .fault = atomic_load(&s->fault)
    };
}
static void timestamps(FiniteReference *s, const AudioTimeStamp *t, uint32_t frames) {
    bool missing = false, bad = false;
    if (t && (t->mFlags & kAudioTimeStampSampleTimeValid) && isfinite(t->mSampleTime)) {
        if (s->sampleEstablished) {
            if (fabs(t->mSampleTime - (s->sampleAnchor + (double)s->timelineFrames)) > 0.5) bad = true;
        } else {
            s->sampleAnchor = t->mSampleTime; s->timelineFrames = 0; s->sampleEstablished = true;
        }
    } else missing = true;
    s->timelineFrames += frames;
    if (t && (t->mFlags & kAudioTimeStampHostTimeValid)) {
        if (s->hostEstablished && t->mHostTime < s->hostTime) bad = true;
        s->hostTime = t->mHostTime; s->hostEstablished = true;
    } else missing = true;
    if (missing) atomic_fetch_add(&s->timestampMissing, 1);
    if (bad) { atomic_fetch_add(&s->timestampDiscontinuities, 1); atomic_store(&s->fault, true); }
}
OSStatus finite_reference_io(AudioDeviceID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime;
    FiniteReference *s = context;
    if (output) for (uint32_t i = 0; i < output->mNumberBuffers; i++)
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    if (!s) return noErr;
    atomic_fetch_add(&s->callbacks, 1);
    if (!output || output->mNumberBuffers != 1 || output->mBuffers[0].mNumberChannels != 2 ||
        !output->mBuffers[0].mData || !output->mBuffers[0].mDataByteSize || output->mBuffers[0].mDataByteSize % 8) {
        atomic_store(&s->fault, true); return noErr;
    }
    uint32_t frames = output->mBuffers[0].mDataByteSize / 8;
    uint64_t total = atomic_load(&s->outputFrames);
    atomic_store(&s->outputFrames, total + frames);
    if (atomic_load(&s->fault) || !atomic_load_explicit(&s->go, memory_order_acquire)) return noErr;
    if (!s->began) {
        s->began = true;
        atomic_store(&s->firstFixtureOutputFrame, total);
        atomic_store(&s->started, true);
    }
    // Clock selection may change during silent preroll; source evidence begins at GO.
    timestamps(s, outputTime, frames);
    if (atomic_load(&s->fault)) return noErr;
    uint64_t remaining = s->frames - s->position;
    uint64_t count = remaining < frames ? remaining : frames;
    if (count) memcpy(output->mBuffers[0].mData, s->samples + s->position * 2, (size_t)count * 8);
    s->position += count;
    atomic_store_explicit(&s->emittedFrames, s->position, memory_order_release);
    if (s->position == s->frames) atomic_store_explicit(&s->completed, true, memory_order_release);
    return noErr;
}
