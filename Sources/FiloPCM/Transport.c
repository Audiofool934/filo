#include "FiloPCM.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stddef.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio metrics require lock-free 64-bit atomics");

OSStatus filo_select_tap_input(AudioObjectID device, AudioDeviceIOProcID proc, uint32_t streamCount) {
    if (!streamCount) return kAudioHardwareIllegalOperationError;
    size_t bytes = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + streamCount * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, bytes);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc; usage->mNumberStreams = streamCount;
    usage->mStreamIsOn[streamCount - 1] = 1;
    AudioObjectPropertyAddress address = { kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)bytes, usage);
    free(usage);
    return status;
}

struct FiloTransport {
    bool emit, relay;
    uint32_t bits;
    uint32_t inputSkip, inputCount;
    uint64_t position, capacity, captured;
    float *capture;
    _Atomic uint64_t callbacks, frames, nonzero, invalid, publishedCaptured;
    _Atomic uint32_t inputBuffers, inputFirstChannels, inputLastChannels, inputLastBytes;
};

static bool layout(const AudioBufferList *list, uint32_t *frames) {
    if (!list || !frames) return false;
    if (list->mNumberBuffers == 1) {
        const AudioBuffer *b = &list->mBuffers[0];
        if (b->mNumberChannels != 2 || !b->mData || b->mDataByteSize % 8) return false;
        *frames = b->mDataByteSize / 8;
        return *frames > 0;
    }
    if (list->mNumberBuffers == 2) {
        for (unsigned i = 0; i < 2; ++i) {
            const AudioBuffer *b = &list->mBuffers[i];
            if (b->mNumberChannels != 1 || !b->mData || b->mDataByteSize % 4) return false;
        }
        if (list->mBuffers[0].mDataByteSize != list->mBuffers[1].mDataByteSize) return false;
        *frames = list->mBuffers[0].mDataByteSize / 4;
        return *frames > 0;
    }
    return false;
}

static void silence(AudioBufferList *list) {
    if (!list) return;
    for (uint32_t i = 0; i < list->mNumberBuffers; ++i)
        if (list->mBuffers[i].mData) memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
}

static float read_sample(const AudioBufferList *list, uint32_t f, uint32_t c) {
    if (list->mNumberBuffers == 1) return ((const float *)list->mBuffers[0].mData)[f * 2 + c];
    return ((const float *)list->mBuffers[c].mData)[f];
}

static void write_sample(AudioBufferList *list, uint32_t f, uint32_t c, float value) {
    if (list->mNumberBuffers == 1) ((float *)list->mBuffers[0].mData)[f * 2 + c] = value;
    else ((float *)list->mBuffers[c].mData)[f] = value;
}

bool filo_copy(const AudioBufferList *input, AudioBufferList *output) {
    uint32_t inFrames = 0, outFrames = 0;
    if (!layout(input, &inFrames) || !layout(output, &outFrames) || inFrames != outFrames) {
        silence(output);
        return false;
    }
    if (input->mNumberBuffers == output->mNumberBuffers) {
        for (uint32_t i = 0; i < input->mNumberBuffers; ++i)
            memcpy(output->mBuffers[i].mData, input->mBuffers[i].mData, input->mBuffers[i].mDataByteSize);
    } else {
        for (uint32_t f = 0; f < inFrames; ++f)
            for (uint32_t c = 0; c < 2; ++c) write_sample(output, f, c, read_sample(input, f, c));
    }
    return true;
}

float filo_test_sample(uint64_t frame, uint32_t channel, uint32_t bits) {
    // Deterministic distinct channels, roughly -60 dBFS peak. No audible full-scale test noise.
    uint32_t x = (uint32_t)frame ^ ((uint32_t)(frame >> 32) * 0x85ebca6bU) ^ (channel ? 0xc2b2ae35U : 0x27d4eb2fU);
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    int32_t value = (int32_t)(x & (bits == 16 ? 63U : 16383U)) - (bits == 16 ? 32 : 8192);
    return (float)value / (bits == 16 ? 32768.0f : 8388608.0f);
}

FiloTransport *filo_transport_create(bool emit, bool relay, uint32_t bits, uint64_t capacity) {
    if (bits != 16 && bits != 24) return NULL;
    if (capacity > SIZE_MAX / (2 * sizeof(float))) return NULL;
    FiloTransport *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->emit = emit; s->relay = relay; s->bits = bits; s->capacity = capacity;
    s->inputCount = 1;
    if (capacity) {
        s->capture = calloc((size_t)capacity * 2, sizeof(float));
        if (!s->capture) { free(s); return NULL; }
    }
    return s;
}
void filo_transport_set_input_offset(FiloTransport *s, uint32_t skip, uint32_t count) {
    s->inputSkip = skip; s->inputCount = count;
}

void filo_transport_destroy(FiloTransport *s) { if (s) { free(s->capture); free(s); } }
FiloMetrics filo_transport_metrics(const FiloTransport *s) {
    FiloMetrics result = {0};
    if (!s) return result;
    result.callbacks = atomic_load_explicit(&s->callbacks, memory_order_relaxed);
    result.frames = atomic_load_explicit(&s->frames, memory_order_relaxed);
    result.nonzeroSamples = atomic_load_explicit(&s->nonzero, memory_order_relaxed);
    result.invalidBuffers = atomic_load_explicit(&s->invalid, memory_order_relaxed);
    result.capturedFrames = atomic_load_explicit(&s->publishedCaptured, memory_order_relaxed);
    result.inputBuffers = atomic_load_explicit(&s->inputBuffers, memory_order_relaxed);
    result.inputFirstChannels = atomic_load_explicit(&s->inputFirstChannels, memory_order_relaxed);
    result.inputLastChannels = atomic_load_explicit(&s->inputLastChannels, memory_order_relaxed);
    result.inputLastBytes = atomic_load_explicit(&s->inputLastBytes, memory_order_relaxed);
    return result;
}
const float *filo_transport_capture(const FiloTransport *s) { return s ? s->capture : NULL; }

OSStatus filo_io(AudioObjectID device, const AudioTimeStamp *now,
                 const AudioBufferList *input, const AudioTimeStamp *inputTime,
                 AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    FiloTransport *s = context;
    uint32_t frames = 0;
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    if (s->emit) {
        if (!layout(output, &frames)) {
            silence(output); atomic_fetch_add_explicit(&s->invalid, 1, memory_order_relaxed); return noErr;
        }
        for (uint32_t f = 0; f < frames; ++f)
            for (uint32_t c = 0; c < 2; ++c) write_sample(output, f, c, filo_test_sample(s->position + f, c, s->bits));
        s->position += frames;
    } else {
        atomic_store_explicit(&s->inputBuffers, input->mNumberBuffers, memory_order_relaxed);
        if (input->mNumberBuffers) {
            atomic_store_explicit(&s->inputFirstChannels, input->mBuffers[0].mNumberChannels, memory_order_relaxed);
            atomic_store_explicit(&s->inputLastChannels, input->mBuffers[input->mNumberBuffers - 1].mNumberChannels, memory_order_relaxed);
            atomic_store_explicit(&s->inputLastBytes, input->mBuffers[input->mNumberBuffers - 1].mDataByteSize, memory_order_relaxed);
        }
        // An aggregate exposes physical inputs before appended tap inputs.
        // The control path validates the stream list and records the tap's buffer span.
        struct { UInt32 count; AudioBuffer buffers[2]; } selected = {0};
        if (s->inputCount < 1 || s->inputCount > 2 || input->mNumberBuffers != s->inputSkip + s->inputCount) {
            silence(output); atomic_fetch_add_explicit(&s->invalid, 1, memory_order_relaxed); return noErr;
        }
        selected.count = s->inputCount;
        for (uint32_t i = 0; i < s->inputCount; ++i) selected.buffers[i] = input->mBuffers[s->inputSkip + i];
        input = (const AudioBufferList *)&selected;
        if (!layout(input, &frames) || (s->relay && !filo_copy(input, output))) {
            silence(output); atomic_fetch_add_explicit(&s->invalid, 1, memory_order_relaxed); return noErr;
        }
        if (!s->relay) silence(output);
        uint64_t nonzero = 0;
        for (uint32_t f = 0; f < frames; ++f) {
            for (uint32_t c = 0; c < 2; ++c) {
                float value = read_sample(input, f, c);
                nonzero += value != 0;
                if (s->captured < s->capacity) s->capture[s->captured * 2 + c] = value;
            }
            if (s->captured < s->capacity) ++s->captured;
        }
        atomic_fetch_add_explicit(&s->nonzero, nonzero, memory_order_relaxed);
        atomic_store_explicit(&s->publishedCaptured, s->captured, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&s->frames, frames, memory_order_relaxed);
    return noErr;
}
