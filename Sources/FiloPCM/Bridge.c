#include "FiloBridge.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_LONG_LOCK_FREE == 2,
               "The bridge requires lock-free 64-bit atomics");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2,
               "The bridge requires lock-free status atomics");

typedef struct {
    bool floating, planar, highAligned;
    uint32_t bits, bytes, buffers, channelsPerBuffer, bytesPerFrame;
} BridgeFormat;

typedef struct {
    bool sampleEstablished, hostEstablished;
    double expectedSampleTime, previousExpectedSampleTime;
    uint64_t lastHostTime;
} BridgeTimeline;

struct FiloBridge {
    FiloBridgeConfig config;
    BridgeFormat input, output;
    float *ring, *capture;
    uint8_t *rawCapture;
    BridgeTimeline inputTimeline, outputTimeline; // Each timeline has exactly one IOProc writer.
    _Atomic uint64_t writeIndex;
    char producerSeparation[64];
    _Atomic uint64_t readIndex;
    char consumerSeparation[64];
    _Atomic uint64_t inputCallbacks, outputCallbacks, startupSilenceFrames;
    _Atomic uint64_t underflows, overflows, invalidBuffers, representationFailures;
    _Atomic uint64_t renderedCaptureFrames;
    _Atomic uint64_t initialQueuedFrames;
    _Atomic uint64_t inputTimestampMissing, outputTimestampMissing;
    _Atomic uint64_t inputTimestampDiscontinuities, outputTimestampDiscontinuities;
    _Atomic uint32_t fault;
    _Atomic bool started;
    uint64_t captureCount; // Consumer-owned until both IOProcs have stopped.
};

static bool parse_format(const AudioStreamBasicDescription *f, BridgeFormat *out) {
    if (!f || !out || f->mFormatID != kAudioFormatLinearPCM ||
        !isfinite(f->mSampleRate) || f->mSampleRate <= 0 ||
        f->mChannelsPerFrame != 2 || f->mFramesPerPacket != 1 ||
        f->mBytesPerPacket != f->mBytesPerFrame) return false;
    const uint32_t allowed = kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger |
        kAudioFormatFlagIsPacked | kAudioFormatFlagIsAlignedHigh |
        kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsNonMixable;
    if (f->mFormatFlags & ~allowed) return false;
    BridgeFormat p = {0};
    p.floating = (f->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    p.planar = (f->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    p.highAligned = (f->mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0;
    p.bits = f->mBitsPerChannel;
    p.buffers = p.planar ? 2 : 1;
    p.channelsPerBuffer = p.planar ? 1 : 2;
    p.bytesPerFrame = f->mBytesPerFrame;
    if (!p.bytesPerFrame || p.bytesPerFrame % p.channelsPerBuffer) return false;
    p.bytes = p.bytesPerFrame / p.channelsPerBuffer;
    if (p.bytes < 2 || p.bytes > 4) return false;
    bool packed = (f->mFormatFlags & kAudioFormatFlagIsPacked) != 0;
    bool signedInteger = (f->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    if (p.floating) {
        if (signedInteger || p.bits != 32 || p.bytes != 4 || p.highAligned) return false;
    } else {
        if (!signedInteger || (p.bits != 16 && p.bits != 24 && p.bits != 32)) return false;
        if (p.bytes * 8 == p.bits) {
            // CoreAudio implies packed storage when valid bits occupy the whole word.
            if (p.highAligned) return false;
        } else if (!(p.bits == 24 && p.bytes == 4 && !packed)) return false;
    }
    *out = p;
    return true;
}

static void silence(AudioBufferList *list) {
    if (!list) return;
    for (uint32_t i = 0; i < list->mNumberBuffers; ++i)
        if (list->mBuffers[i].mData)
            memset(list->mBuffers[i].mData, 0, list->mBuffers[i].mDataByteSize);
}

static bool validate_layout(const AudioBufferList *list, const BridgeFormat *format,
                            uint32_t offset, uint32_t *frames) {
    if (!list || !frames || offset > UINT32_MAX - format->buffers ||
        list->mNumberBuffers != offset + format->buffers) return false;
    uint32_t length = 0;
    for (uint32_t i = 0; i < format->buffers; ++i) {
        const AudioBuffer *b = &list->mBuffers[offset + i];
        if (!b->mData || b->mNumberChannels != format->channelsPerBuffer ||
            b->mDataByteSize == 0 || b->mDataByteSize % format->bytesPerFrame) return false;
        uint32_t n = b->mDataByteSize / format->bytesPerFrame;
        if (i && n != length) return false;
        length = n;
    }
    *frames = length;
    return true;
}

static const uint8_t *sample_address(const AudioBufferList *list, const BridgeFormat *format,
                                     uint32_t offset, uint32_t frame, uint32_t channel) {
    uint32_t buffer = offset + (format->planar ? channel : 0);
    size_t within = (size_t)frame * format->bytesPerFrame +
                    (format->planar ? 0 : channel * format->bytes);
    return (const uint8_t *)list->mBuffers[buffer].mData + within;
}

static float read_float(const AudioBufferList *list, const BridgeFormat *format,
                        uint32_t offset, uint32_t frame, uint32_t channel) {
    float result;
    memcpy(&result, sample_address(list, format, offset, frame, channel), sizeof(result));
    return result;
}

static bool exact_integer(float value, uint32_t bits, int64_t *word) {
    if (!isfinite(value)) return false;
    const double scale = bits == 16 ? 32768.0 : bits == 24 ? 8388608.0 : 2147483648.0;
    double scaled = (double)value * scale;
    if (scaled < -scale || scaled >= scale || trunc(scaled) != scaled) return false;
    *word = (int64_t)scaled;
    return true;
}

static bool representable(const FiloBridge *s, float value) {
    int64_t ignored;
    if (!isfinite(value)) return false;
    if (s->config.sourceBits && !exact_integer(value, s->config.sourceBits, &ignored)) return false;
    return s->output.floating || exact_integer(value, s->output.bits, &ignored);
}

static void latch_fault(FiloBridge *s, FiloBridgeFault fault) {
    uint32_t expected = FiloBridgeFaultNone;
    atomic_compare_exchange_strong_explicit(&s->fault, &expected, (uint32_t)fault,
                                           memory_order_release, memory_order_relaxed);
}

static void check_timestamp(FiloBridge *s, BridgeTimeline *timeline,
                            const AudioTimeStamp *timestamp, uint32_t frames,
                            _Atomic uint64_t *missingCount, _Atomic uint64_t *discontinuityCount) {
    if (atomic_load_explicit(&s->fault, memory_order_acquire)) return;
    // Beyond 2^52 frames, a Float64 cannot preserve the required sub-frame evidence reliably.
    bool sampleValid = timestamp && (timestamp->mFlags & kAudioTimeStampSampleTimeValid) &&
        isfinite(timestamp->mSampleTime) && fabs(timestamp->mSampleTime) <= 4503599627370496.0;
    bool hostValid = timestamp && (timestamp->mFlags & kAudioTimeStampHostTimeValid);
    bool missing = !sampleValid || !hostValid;
    bool discontinuity = false;
    if (sampleValid) {
        if (timeline->sampleEstablished) {
            // Keep the first timestamp as the anchor, so a permitted fractional deviation
            // cannot accumulate into unnoticed whole-frame loss over repeated callbacks.
            if (fabs(timestamp->mSampleTime - timeline->expectedSampleTime) > 0.5 ||
                fabs(timestamp->mSampleTime - timeline->previousExpectedSampleTime) > 0.5)
                discontinuity = true;
        } else {
            timeline->sampleEstablished = true;
            timeline->expectedSampleTime = timestamp->mSampleTime;
        }
        timeline->previousExpectedSampleTime = timestamp->mSampleTime;
    }
    // Count every validated callback even when its timestamp is missing.
    // A subsequent valid timestamp can still expose a jump across that evidence gap.
    if (timeline->sampleEstablished) {
        timeline->expectedSampleTime += frames;
        timeline->previousExpectedSampleTime += frames;
        if (fabs(timeline->expectedSampleTime) > 4503599627370496.0) {
            timeline->sampleEstablished = false;
            missing = true;
        }
    }
    if (hostValid) {
        if (timeline->hostEstablished && timestamp->mHostTime < timeline->lastHostTime)
            discontinuity = true;
        timeline->lastHostTime = timestamp->mHostTime;
        timeline->hostEstablished = true;
    }
    if (missing) atomic_fetch_add_explicit(missingCount, 1, memory_order_relaxed);
    if (discontinuity) {
        atomic_fetch_add_explicit(discontinuityCount, 1, memory_order_relaxed);
        latch_fault(s, FiloBridgeFaultTimestamp);
    }
}

static void touch_storage(void *storage, size_t bytes) {
    // calloc can reserve zero pages lazily. Touch them on the control thread so
    // the initial real-time writes do not incur all of those first-touch faults.
    volatile uint8_t *p = storage;
    for (size_t offset = 0; offset < bytes;) {
        p[offset] = 0;
        if (bytes - offset <= 4096) break;
        offset += 4096;
    }
    if (bytes) p[bytes - 1] = 0;
}

FiloBridge *filo_bridge_create(const FiloBridgeConfig *config) {
    if (!config || config->capacityFrames < 2 ||
        (config->capacityFrames & (config->capacityFrames - 1)) ||
        config->capacityFrames > UINT64_MAX / 2 ||
        !config->primeFrames || config->primeFrames > config->capacityFrames ||
        config->capacityFrames > SIZE_MAX / (2 * sizeof(float)) ||
        config->renderCaptureFrames > SIZE_MAX / (2 * sizeof(float)) ||
        (config->sourceBits != 0 && config->sourceBits != 16 && config->sourceBits != 24)) return NULL;
    BridgeFormat input, output;
    if (!parse_format(&config->inputFormat, &input) || !input.floating ||
        !parse_format(&config->outputFormat, &output) ||
        config->inputFormat.mSampleRate != config->outputFormat.mSampleRate ||
        config->inputBufferCount != input.buffers ||
        config->inputBufferOffset > UINT32_MAX - input.buffers) return NULL;
    FiloBridge *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->config = *config; s->input = input; s->output = output;
    s->ring = calloc((size_t)config->capacityFrames * 2, sizeof(float));
    if (config->renderCaptureFrames) {
        s->capture = calloc((size_t)config->renderCaptureFrames * 2, sizeof(float));
        s->rawCapture = calloc((size_t)config->renderCaptureFrames * 2, output.bytes);
    }
    if (!s->ring || (config->renderCaptureFrames && (!s->capture || !s->rawCapture))) {
        filo_bridge_destroy(s); return NULL;
    }
    touch_storage(s->ring, (size_t)config->capacityFrames * 2 * sizeof(float));
    if (config->renderCaptureFrames) {
        touch_storage(s->capture, (size_t)config->renderCaptureFrames * 2 * sizeof(float));
        touch_storage(s->rawCapture, (size_t)config->renderCaptureFrames * 2 * output.bytes);
    }
    // calloc initializes atomic scalars to their zero values on supported targets.
    // Explicit initialization also makes their object lifetime clear to C tooling.
    atomic_init(&s->writeIndex, 0); atomic_init(&s->readIndex, 0);
    atomic_init(&s->inputCallbacks, 0); atomic_init(&s->outputCallbacks, 0);
    atomic_init(&s->startupSilenceFrames, 0); atomic_init(&s->underflows, 0);
    atomic_init(&s->overflows, 0); atomic_init(&s->invalidBuffers, 0);
    atomic_init(&s->representationFailures, 0); atomic_init(&s->renderedCaptureFrames, 0);
    atomic_init(&s->initialQueuedFrames, 0);
    atomic_init(&s->inputTimestampMissing, 0); atomic_init(&s->outputTimestampMissing, 0);
    atomic_init(&s->inputTimestampDiscontinuities, 0); atomic_init(&s->outputTimestampDiscontinuities, 0);
    atomic_init(&s->fault, FiloBridgeFaultNone); atomic_init(&s->started, false);
    return s;
}

void filo_bridge_destroy(FiloBridge *s) {
    if (s) { free(s->ring); free(s->capture); free(s->rawCapture); free(s); }
}

FiloBridgeMetrics filo_bridge_metrics(const FiloBridge *s) {
    FiloBridgeMetrics m = {0};
    if (!s) return m;
    // Reading consumer before producer avoids a stale producer index under normal operation.
    m.deliveredFrames = atomic_load_explicit(&s->readIndex, memory_order_acquire);
    m.capturedFrames = atomic_load_explicit(&s->writeIndex, memory_order_acquire);
    m.queuedFrames = m.capturedFrames - m.deliveredFrames;
    // This is telemetry, not a transactional snapshot: both threads may advance during reads.
    if (m.queuedFrames > s->config.capacityFrames) m.queuedFrames = s->config.capacityFrames;
    m.inputCallbacks = atomic_load_explicit(&s->inputCallbacks, memory_order_relaxed);
    m.outputCallbacks = atomic_load_explicit(&s->outputCallbacks, memory_order_relaxed);
    m.startupSilenceFrames = atomic_load_explicit(&s->startupSilenceFrames, memory_order_relaxed);
    m.underflows = atomic_load_explicit(&s->underflows, memory_order_relaxed);
    m.overflows = atomic_load_explicit(&s->overflows, memory_order_relaxed);
    m.invalidBuffers = atomic_load_explicit(&s->invalidBuffers, memory_order_relaxed);
    m.representationFailures = atomic_load_explicit(&s->representationFailures, memory_order_relaxed);
    m.renderedCaptureFrames = atomic_load_explicit(&s->renderedCaptureFrames, memory_order_acquire);
    m.inputTimestampMissing = atomic_load_explicit(&s->inputTimestampMissing, memory_order_relaxed);
    m.outputTimestampMissing = atomic_load_explicit(&s->outputTimestampMissing, memory_order_relaxed);
    m.inputTimestampDiscontinuities = atomic_load_explicit(&s->inputTimestampDiscontinuities, memory_order_relaxed);
    m.outputTimestampDiscontinuities = atomic_load_explicit(&s->outputTimestampDiscontinuities, memory_order_relaxed);
    m.fault = atomic_load_explicit(&s->fault, memory_order_acquire);
    m.started = atomic_load_explicit(&s->started, memory_order_acquire);
    m.initialQueuedFrames = atomic_load_explicit(&s->initialQueuedFrames, memory_order_relaxed);
    return m;
}

const float *filo_bridge_render_capture(const FiloBridge *s) { return s ? s->capture : NULL; }
const uint8_t *filo_bridge_render_bytes(const FiloBridge *s) { return s ? s->rawCapture : NULL; }
uint64_t filo_bridge_render_byte_count(const FiloBridge *s) {
    return s ? atomic_load_explicit(&s->renderedCaptureFrames, memory_order_acquire) * s->output.bytes * 2 : 0;
}
uint32_t filo_bridge_render_bytes_per_frame(const FiloBridge *s) { return s ? s->output.bytes * 2 : 0; }

bool filo_bridge_push(FiloBridge *s, const AudioBufferList *input) {
    if (!s) return false;
    atomic_fetch_add_explicit(&s->inputCallbacks, 1, memory_order_relaxed);
    if (atomic_load_explicit(&s->fault, memory_order_acquire)) return false;
    uint32_t frames = 0;
    if (!validate_layout(input, &s->input, s->config.inputBufferOffset, &frames)) {
        atomic_fetch_add_explicit(&s->invalidBuffers, 1, memory_order_relaxed);
        latch_fault(s, FiloBridgeFaultInputLayout); return false;
    }
    uint64_t write = atomic_load_explicit(&s->writeIndex, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&s->readIndex, memory_order_acquire);
    uint64_t queued = write - read;
    if (queued > s->config.capacityFrames || frames > s->config.capacityFrames - queued) {
        atomic_fetch_add_explicit(&s->overflows, 1, memory_order_relaxed);
        latch_fault(s, FiloBridgeFaultOverflow); return false;
    }
    // Validate the entire callback before publishing any of it.
    for (uint32_t f = 0; f < frames; ++f) {
        for (uint32_t c = 0; c < 2; ++c) {
            float value = read_float(input, &s->input, s->config.inputBufferOffset, f, c);
            if (!representable(s, value)) {
                atomic_fetch_add_explicit(&s->representationFailures, 1, memory_order_relaxed);
                latch_fault(s, FiloBridgeFaultRepresentation); return false;
            }
        }
    }
    for (uint32_t f = 0; f < frames; ++f) {
        uint64_t slot = (write + f) & (s->config.capacityFrames - 1);
        for (uint32_t c = 0; c < 2; ++c)
            s->ring[slot * 2 + c] = read_float(input, &s->input, s->config.inputBufferOffset, f, c);
    }
    atomic_store_explicit(&s->writeIndex, write + frames, memory_order_release);
    return atomic_load_explicit(&s->fault, memory_order_acquire) == FiloBridgeFaultNone;
}

static bool store_sample(AudioBufferList *output, const BridgeFormat *format,
                         uint32_t frame, uint32_t channel, float value) {
    uint8_t *p = (uint8_t *)sample_address(output, format, 0, frame, channel);
    if (format->floating) { memcpy(p, &value, sizeof(value)); return true; }
    int64_t signedWord;
    if (!exact_integer(value, format->bits, &signedWord)) return false;
    uint32_t word = (uint32_t)signedWord;
    if (format->bits < 32) word &= (UINT32_C(1) << format->bits) - 1;
    if (format->highAligned) word <<= format->bytes * 8 - format->bits;
    for (uint32_t i = 0; i < format->bytes; ++i) p[i] = (uint8_t)(word >> (8 * i));
    return true;
}

static float decoded_written_sample(const AudioBufferList *output, const BridgeFormat *format,
                                    uint32_t frame, uint32_t channel) {
    const uint8_t *p = sample_address(output, format, 0, frame, channel);
    if (format->floating) { float value; memcpy(&value, p, sizeof(value)); return value; }
    uint32_t word = 0;
    for (uint32_t i = 0; i < format->bytes; ++i) word |= (uint32_t)p[i] << (8 * i);
    if (format->highAligned) word >>= format->bytes * 8 - format->bits;
    uint64_t modulus = UINT64_C(1) << format->bits;
    uint64_t valid = (uint64_t)word & (modulus - 1);
    int64_t signedWord = (valid & (modulus >> 1)) ? (int64_t)valid - (int64_t)modulus : (int64_t)valid;
    return (float)((double)signedWord / (double)(modulus >> 1));
}

bool filo_bridge_render(FiloBridge *s, AudioBufferList *output) {
    silence(output);
    if (!s) return false;
    atomic_fetch_add_explicit(&s->outputCallbacks, 1, memory_order_relaxed);
    if (atomic_load_explicit(&s->fault, memory_order_acquire)) return false;
    uint32_t frames = 0;
    if (!validate_layout(output, &s->output, 0, &frames) || frames > s->config.capacityFrames) {
        atomic_fetch_add_explicit(&s->invalidBuffers, 1, memory_order_relaxed);
        latch_fault(s, FiloBridgeFaultOutputLayout); return false;
    }
    uint64_t read = atomic_load_explicit(&s->readIndex, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&s->writeIndex, memory_order_acquire);
    uint64_t queued = write - read;
    if (!atomic_load_explicit(&s->started, memory_order_relaxed)) {
        if (queued < s->config.primeFrames || queued < frames) {
            atomic_fetch_add_explicit(&s->startupSilenceFrames, frames, memory_order_relaxed);
            return true;
        }
        atomic_store_explicit(&s->initialQueuedFrames, queued, memory_order_relaxed);
        atomic_store_explicit(&s->started, true, memory_order_release);
    }
    if (queued < frames || queued > s->config.capacityFrames) {
        atomic_fetch_add_explicit(&s->underflows, 1, memory_order_relaxed);
        latch_fault(s, FiloBridgeFaultUnderflow); return false;
    }
    for (uint32_t f = 0; f < frames; ++f) {
        uint64_t slot = (read + f) & (s->config.capacityFrames - 1);
        for (uint32_t c = 0; c < 2; ++c) {
            if (!store_sample(output, &s->output, f, c, s->ring[slot * 2 + c])) {
                silence(output);
                atomic_fetch_add_explicit(&s->representationFailures, 1, memory_order_relaxed);
                latch_fault(s, FiloBridgeFaultRepresentation); return false;
            }
        }
    }
    // If capture failed concurrently, suppress this callback before publishing consumption.
    if (atomic_load_explicit(&s->fault, memory_order_acquire)) { silence(output); return false; }
    if (s->capture && s->captureCount < s->config.renderCaptureFrames) {
        uint64_t room = s->config.renderCaptureFrames - s->captureCount;
        uint32_t count = room < frames ? (uint32_t)room : frames;
        for (uint32_t f = 0; f < count; ++f) {
            for (uint32_t c = 0; c < 2; ++c) {
                s->capture[(s->captureCount + f) * 2 + c] = decoded_written_sample(output, &s->output, f, c);
                // Copy the actual bytes independently of the float decoder above.
                memcpy(s->rawCapture + ((s->captureCount + f) * 2 + c) * s->output.bytes,
                       sample_address(output, &s->output, 0, f, c), s->output.bytes);
            }
        }
        s->captureCount += count;
        atomic_store_explicit(&s->renderedCaptureFrames, s->captureCount, memory_order_release);
    }
    atomic_store_explicit(&s->readIndex, read + frames, memory_order_release);
    return true;
}

OSStatus filo_bridge_capture_io(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)outputTime;
    silence(output);
    FiloBridge *s = context;
    if (s) {
        uint32_t frames = 0;
        if (validate_layout(input, &s->input, s->config.inputBufferOffset, &frames))
            check_timestamp(s, &s->inputTimeline, inputTime, frames,
                            &s->inputTimestampMissing, &s->inputTimestampDiscontinuities);
        (void)filo_bridge_push(s, input);
    }
    return noErr;
}

OSStatus filo_bridge_output_io(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)input; (void)inputTime;
    FiloBridge *s = context;
    if (s) {
        uint32_t frames = 0;
        if (validate_layout(output, &s->output, 0, &frames))
            check_timestamp(s, &s->outputTimeline, outputTime, frames,
                            &s->outputTimestampMissing, &s->outputTimestampDiscontinuities);
    }
    (void)filo_bridge_render(s, output);
    return noErr;
}
