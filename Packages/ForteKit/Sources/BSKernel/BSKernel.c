#include "BSKernel.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define BS_CHUNK 512              // Frames per IOProc inner block (scratch size).
#define BS_SUBBLOCK 32            // EQ coefficient smoothing granularity.
#define BS_LOOKAHEAD_SECONDS 0.0015
#define BS_RELEASE_SECONDS 0.120
#define BS_GAIN_SMOOTH_SECONDS 0.020
#define BS_EQ_SMOOTH_SECONDS 0.030
#define BS_EQ_Q 1.1
#define BS_BASS_HZ 100.0
#define BS_TREBLE_HZ 10000.0
#define BS_SOUND_THRESHOLD 3.2e-5f    // -90 dBFS

const float BSEQBandFrequencies[BS_EQ_BAND_COUNT] = {32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};

typedef enum { BSFilterPeak, BSFilterLowShelf, BSFilterHighShelf } BSFilterType;

typedef struct {
    double b0, b1, b2, a1, a2;
} BSBiquad;

struct BSKernel {
    double sampleRate;

    // Parameters: written from any thread, read by the render thread.
    _Atomic float boostDB;
    _Atomic float eqGainDB[BS_EQ_FILTER_COUNT];
    _Atomic bool eqEnabled;
    _Atomic float balance;
    _Atomic float width;
    _Atomic float ceilingDB;
    _Atomic float outputGain;
    _Atomic uint32_t sourceCount;
    uint32_t sourceStream[BS_MAX_SOURCES];     // Written before IO starts.
    _Atomic float sourceGainTarget[BS_MAX_SOURCES];

    // Meters: max-accumulated by the render thread, read-and-reset by the UI.
    _Atomic float inputPeak[2];
    _Atomic float outputPeak[2];
    _Atomic float gainReductionDB;
    _Atomic float sourcePeak[BS_MAX_SOURCES];
    _Atomic uint64_t renderCount;
    _Atomic uint64_t lastSoundTime;   // mach_absolute_time of the last non-silent input

    // Render-thread state.
    float sourceGain[BS_MAX_SOURCES];
    float eqCurrentDB[BS_EQ_FILTER_COUNT];
    BSBiquad eq[BS_EQ_FILTER_COUNT];
    double eqState[2][BS_EQ_FILTER_COUNT][2];
    float gain, balanceL, balanceR, widthCurrent, outGain;
    float gainSmoothing, eqSmoothing;

    // Look-ahead limiter. Window N = lookahead + 1, audio delayed by `lookahead` frames.
    uint32_t lookahead;
    uint32_t window;
    float *delay[2];
    uint32_t delayPos;
    float *minValue;              // Monotonic deque for the sliding-window minimum of required gain.
    uint32_t *minIndex;
    uint32_t minMask, minHead, minTail;
    uint32_t sampleIndex;
    float releaseEnv, releaseCoef;
    float *box;                   // Moving average over the window smooths the gain envelope.
    double boxSum;
    uint32_t boxPos;

    float scratch[4][BS_CHUNK];
};

// MARK: - Filters

static void bs_design(BSBiquad *bq, BSFilterType type, double fs, double f0, double gainDB, double q) {
    if (f0 > fs * 0.45) f0 = fs * 0.45;
    const double A = pow(10.0, gainDB / 40.0);
    const double w0 = 2.0 * M_PI * f0 / fs;
    const double cw = cos(w0), sw = sin(w0);
    double b0, b1, b2, a0, a1, a2;

    switch (type) {
    case BSFilterPeak: {
        const double alpha = sw / (2.0 * q);
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cw;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cw;
        a2 = 1.0 - alpha / A;
        break;
    }
    case BSFilterLowShelf: {
        const double sa = 2.0 * sqrt(A) * (sw / 2.0 * M_SQRT2); // shelf slope S = 1
        b0 = A * ((A + 1.0) - (A - 1.0) * cw + sa);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
        b2 = A * ((A + 1.0) - (A - 1.0) * cw - sa);
        a0 = (A + 1.0) + (A - 1.0) * cw + sa;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
        a2 = (A + 1.0) + (A - 1.0) * cw - sa;
        break;
    }
    case BSFilterHighShelf:
    default: {
        const double sa = 2.0 * sqrt(A) * (sw / 2.0 * M_SQRT2);
        b0 = A * ((A + 1.0) + (A - 1.0) * cw + sa);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
        b2 = A * ((A + 1.0) + (A - 1.0) * cw - sa);
        a0 = (A + 1.0) - (A - 1.0) * cw + sa;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw);
        a2 = (A + 1.0) - (A - 1.0) * cw - sa;
        break;
    }
    }

    bq->b0 = b0 / a0;
    bq->b1 = b1 / a0;
    bq->b2 = b2 / a0;
    bq->a1 = a1 / a0;
    bq->a2 = a2 / a0;
}

static void bs_design_filter(BSBiquad *bq, int filter, double fs, double gainDB) {
    switch (filter) {
    case BS_EQ_BASS: bs_design(bq, BSFilterLowShelf, fs, BS_BASS_HZ, gainDB, 0); return;
    case BS_EQ_TREBLE: bs_design(bq, BSFilterHighShelf, fs, BS_TREBLE_HZ, gainDB, 0); return;
    case 0: bs_design(bq, BSFilterLowShelf, fs, BSEQBandFrequencies[0], gainDB, 0); return;
    case BS_EQ_BAND_COUNT - 1: bs_design(bq, BSFilterHighShelf, fs, BSEQBandFrequencies[filter], gainDB, 0); return;
    default: bs_design(bq, BSFilterPeak, fs, BSEQBandFrequencies[filter], gainDB, BS_EQ_Q); return;
    }
}

static double bs_magnitude_db(const BSBiquad *bq, double w) {
    const double c1 = cos(w), s1 = sin(w), c2 = cos(2.0 * w), s2 = sin(2.0 * w);
    const double nr = bq->b0 + bq->b1 * c1 + bq->b2 * c2;
    const double ni = -(bq->b1 * s1 + bq->b2 * s2);
    const double dr = 1.0 + bq->a1 * c1 + bq->a2 * c2;
    const double di = -(bq->a1 * s1 + bq->a2 * s2);
    return 10.0 * log10((nr * nr + ni * ni) / (dr * dr + di * di));
}

void BSEQComputeResponse(const float *gainsDB, double sampleRate,
                         const float *frequencies, float *outDB, uint32_t count) {
    BSBiquad filters[BS_EQ_FILTER_COUNT];
    for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) bs_design_filter(&filters[f], f, sampleRate, gainsDB[f]);
    for (uint32_t i = 0; i < count; i++) {
        const double w = 2.0 * M_PI * fmin(frequencies[i], sampleRate * 0.4999) / sampleRate;
        double sum = 0.0;
        for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) {
            if (gainsDB[f] != 0.0f) sum += bs_magnitude_db(&filters[f], w);
        }
        outDB[i] = (float)sum;
    }
}

// MARK: - Lifecycle

static inline float bs_db_to_lin(float db) { return powf(10.0f, db / 20.0f); }

static inline float bs_clamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static uint32_t bs_next_pow2(uint32_t v) {
    uint32_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

static void bs_reset_limiter(BSKernel *k) {
    memset(k->delay[0], 0, sizeof(float) * k->lookahead);
    memset(k->delay[1], 0, sizeof(float) * k->lookahead);
    k->delayPos = 0;
    k->minHead = k->minTail = 0;
    k->sampleIndex = 0;
    k->releaseEnv = 1.0f;
    for (uint32_t i = 0; i < k->window; i++) k->box[i] = 1.0f;
    k->boxSum = (double)k->window;
    k->boxPos = 0;
}

BSKernel *BSKernelCreate(double sampleRate) {
    if (!(sampleRate >= 8000.0 && sampleRate <= 768000.0)) sampleRate = 48000.0;

    BSKernel *k = calloc(1, sizeof(BSKernel));
    if (!k) return NULL;
    k->sampleRate = sampleRate;

    atomic_init(&k->boostDB, 0.0f);
    for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) atomic_init(&k->eqGainDB[f], 0.0f);
    atomic_init(&k->eqEnabled, true);
    atomic_init(&k->balance, 0.0f);
    atomic_init(&k->width, 1.0f);
    atomic_init(&k->ceilingDB, -1.0f);
    atomic_init(&k->outputGain, 1.0f);
    atomic_init(&k->sourceCount, 1);
    for (int s = 0; s < BS_MAX_SOURCES; s++) {
        k->sourceStream[s] = (uint32_t)s;
        atomic_init(&k->sourceGainTarget[s], 1.0f);
        atomic_init(&k->sourcePeak[s], 0.0f);
        k->sourceGain[s] = 1.0f;
    }
    for (int c = 0; c < 2; c++) {
        atomic_init(&k->inputPeak[c], 0.0f);
        atomic_init(&k->outputPeak[c], 0.0f);
    }
    atomic_init(&k->gainReductionDB, 0.0f);
    atomic_init(&k->renderCount, 0);
    atomic_init(&k->lastSoundTime, mach_absolute_time());

    for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) bs_design_filter(&k->eq[f], f, sampleRate, 0.0);
    k->gain = 1.0f;
    k->balanceL = k->balanceR = 1.0f;
    k->widthCurrent = 1.0f;
    k->outGain = 1.0f;
    k->gainSmoothing = 1.0f - expf(-1.0f / (float)(BS_GAIN_SMOOTH_SECONDS * sampleRate));
    k->eqSmoothing = 1.0f - expf(-(float)BS_SUBBLOCK / (float)(BS_EQ_SMOOTH_SECONDS * sampleRate));

    k->lookahead = (uint32_t)lround(BS_LOOKAHEAD_SECONDS * sampleRate);
    if (k->lookahead < 4) k->lookahead = 4;
    k->window = k->lookahead + 1;
    const uint32_t dequeCapacity = bs_next_pow2(k->window + 1);
    k->minMask = dequeCapacity - 1;
    k->delay[0] = calloc(k->lookahead, sizeof(float));
    k->delay[1] = calloc(k->lookahead, sizeof(float));
    k->minValue = calloc(dequeCapacity, sizeof(float));
    k->minIndex = calloc(dequeCapacity, sizeof(uint32_t));
    k->box = calloc(k->window, sizeof(float));
    k->releaseCoef = 1.0f - expf(-1.0f / (float)(BS_RELEASE_SECONDS * sampleRate));

    if (!k->delay[0] || !k->delay[1] || !k->minValue || !k->minIndex || !k->box) {
        BSKernelDestroy(k);
        return NULL;
    }
    bs_reset_limiter(k);
    return k;
}

void BSKernelDestroy(BSKernel *k) {
    if (!k) return;
    free(k->delay[0]);
    free(k->delay[1]);
    free(k->minValue);
    free(k->minIndex);
    free(k->box);
    free(k);
}

double BSKernelGetSampleRate(const BSKernel *k) { return k->sampleRate; }

uint32_t BSKernelGetLatencyFrames(const BSKernel *k) { return k->lookahead; }

// MARK: - Parameters

void BSKernelSetBoost(BSKernel *k, float db) {
    atomic_store_explicit(&k->boostDB, bs_clamp(db, -60.0f, 30.0f), memory_order_relaxed);
}

void BSKernelSetEQEnabled(BSKernel *k, bool enabled) {
    atomic_store_explicit(&k->eqEnabled, enabled, memory_order_relaxed);
}

void BSKernelSetEQBandGain(BSKernel *k, int filter, float db) {
    if (filter < 0 || filter >= BS_EQ_FILTER_COUNT) return;
    atomic_store_explicit(&k->eqGainDB[filter], bs_clamp(db, -24.0f, 24.0f), memory_order_relaxed);
}

void BSKernelSetBalance(BSKernel *k, float balance) {
    atomic_store_explicit(&k->balance, bs_clamp(balance, -1.0f, 1.0f), memory_order_relaxed);
}

void BSKernelSetStereoWidth(BSKernel *k, float width) {
    atomic_store_explicit(&k->width, bs_clamp(width, 0.0f, 2.0f), memory_order_relaxed);
}

void BSKernelSetLimiterCeiling(BSKernel *k, float db) {
    atomic_store_explicit(&k->ceilingDB, bs_clamp(db, -24.0f, 0.0f), memory_order_relaxed);
}

void BSKernelSetOutputGain(BSKernel *k, float linear) {
    atomic_store_explicit(&k->outputGain, bs_clamp(linear, 0.0f, 1.0f), memory_order_relaxed);
}

void BSKernelSetSources(BSKernel *k, const uint32_t *streamIndices, uint32_t count) {
    if (count > BS_MAX_SOURCES) count = BS_MAX_SOURCES;
    for (uint32_t s = 0; s < count; s++) {
        k->sourceStream[s] = streamIndices[s];
        // Start at the target so a muted app doesn't blip at full volume while its gain glides down.
        k->sourceGain[s] = atomic_load_explicit(&k->sourceGainTarget[s], memory_order_relaxed);
    }
    atomic_store_explicit(&k->sourceCount, count, memory_order_release);
}

void BSKernelSetSourceGain(BSKernel *k, uint32_t source, float linear) {
    if (source >= BS_MAX_SOURCES) return;
    atomic_store_explicit(&k->sourceGainTarget[source], bs_clamp(linear, 0.0f, 4.0f), memory_order_relaxed);
}

float BSKernelReadSourcePeak(BSKernel *k, uint32_t source) {
    if (source >= BS_MAX_SOURCES) return 0.0f;
    return atomic_exchange_explicit(&k->sourcePeak[source], 0.0f, memory_order_relaxed);
}

double BSKernelSecondsSinceSound(const BSKernel *k) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    const uint64_t last = atomic_load_explicit(&k->lastSoundTime, memory_order_relaxed);
    const uint64_t now = mach_absolute_time();
    return now > last ? (double)(now - last) * timebase.numer / timebase.denom / 1e9 : 0.0;
}

static inline void bs_store_max(_Atomic float *slot, float value) {
    float current = atomic_load_explicit(slot, memory_order_relaxed);
    while (value > current &&
           !atomic_compare_exchange_weak_explicit(slot, &current, value, memory_order_relaxed, memory_order_relaxed)) {
    }
}

void BSKernelReadMeters(BSKernel *k, BSMeters *out) {
    for (int c = 0; c < 2; c++) {
        out->inputPeak[c] = atomic_exchange_explicit(&k->inputPeak[c], 0.0f, memory_order_relaxed);
        out->outputPeak[c] = atomic_exchange_explicit(&k->outputPeak[c], 0.0f, memory_order_relaxed);
    }
    out->gainReduction = atomic_exchange_explicit(&k->gainReductionDB, 0.0f, memory_order_relaxed);
    out->renderCount = atomic_load_explicit(&k->renderCount, memory_order_relaxed);
}

// MARK: - Render

static void bs_sanitize_state(BSKernel *k) {
    for (int c = 0; c < 2; c++) {
        for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) {
            for (int s = 0; s < 2; s++) {
                const double v = k->eqState[c][f][s];
                if (!isfinite(v)) {
                    memset(k->eqState, 0, sizeof(k->eqState));
                    return;
                }
                if (fabs(v) < 1e-20) k->eqState[c][f][s] = 0.0; // flush denormals
            }
        }
    }
}

void BSKernelProcess(BSKernel *k, const float *inL, const float *inR, float *outL, float *outR, uint32_t frames) {
    float targetEQ[BS_EQ_FILTER_COUNT];
    const bool eqOn = atomic_load_explicit(&k->eqEnabled, memory_order_relaxed);
    for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) {
        targetEQ[f] = eqOn ? atomic_load_explicit(&k->eqGainDB[f], memory_order_relaxed) : 0.0f;
    }
    const float targetGain = bs_db_to_lin(atomic_load_explicit(&k->boostDB, memory_order_relaxed));
    const float balance = atomic_load_explicit(&k->balance, memory_order_relaxed);
    const float targetBalL = balance > 0.0f ? 1.0f - balance : 1.0f;
    const float targetBalR = balance < 0.0f ? 1.0f + balance : 1.0f;
    const float targetWidth = atomic_load_explicit(&k->width, memory_order_relaxed);
    const float targetOut = atomic_load_explicit(&k->outputGain, memory_order_relaxed);
    const float ceiling = bs_db_to_lin(atomic_load_explicit(&k->ceilingDB, memory_order_relaxed));

    const float sm = k->gainSmoothing;
    const uint32_t N = k->window;
    const uint32_t D = k->lookahead;
    const double invN = 1.0 / (double)N;
    float inPeakL = 0, inPeakR = 0, outPeakL = 0, outPeakR = 0, minGain = 1.0f;

    for (uint32_t start = 0; start < frames; start += BS_SUBBLOCK) {
        const uint32_t n = frames - start < BS_SUBBLOCK ? frames - start : BS_SUBBLOCK;

        for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) {
            const float current = k->eqCurrentDB[f], target = targetEQ[f];
            if (current == target) continue;
            float next = current + (target - current) * k->eqSmoothing;
            if (fabsf(target - next) < 0.01f) next = target;
            k->eqCurrentDB[f] = next;
            bs_design_filter(&k->eq[f], f, k->sampleRate, next);
        }

        for (uint32_t i = start; i < start + n; i++) {
            float xl = inL[i], xr = inR[i];
            if (!isfinite(xl)) xl = 0.0f;
            if (!isfinite(xr)) xr = 0.0f;
            const float al = fabsf(xl), ar = fabsf(xr);
            if (al > inPeakL) inPeakL = al;
            if (ar > inPeakR) inPeakR = ar;

            // EQ: cascaded transposed direct form II biquads, double precision for stable low shelves.
            double l = xl, r = xr;
            for (int f = 0; f < BS_EQ_FILTER_COUNT; f++) {
                const BSBiquad *q = &k->eq[f];
                double *sl = k->eqState[0][f];
                double *sr = k->eqState[1][f];
                const double yl = q->b0 * l + sl[0];
                sl[0] = q->b1 * l - q->a1 * yl + sl[1];
                sl[1] = q->b2 * l - q->a2 * yl;
                const double yr = q->b0 * r + sr[0];
                sr[0] = q->b1 * r - q->a1 * yr + sr[1];
                sr[1] = q->b2 * r - q->a2 * yr;
                l = yl;
                r = yr;
            }

            k->gain += (targetGain - k->gain) * sm;
            k->widthCurrent += (targetWidth - k->widthCurrent) * sm;
            k->balanceL += (targetBalL - k->balanceL) * sm;
            k->balanceR += (targetBalR - k->balanceR) * sm;
            k->outGain += (targetOut - k->outGain) * sm;

            l *= k->gain;
            r *= k->gain;
            const double mid = 0.5 * (l + r);
            const double side = 0.5 * (l - r) * k->widthCurrent;
            float sL = (float)((mid + side) * k->balanceL);
            float sR = (float)((mid - side) * k->balanceR);

            // Limiter gain computer: the gain needed to keep this frame under the ceiling.
            const float peak = fmaxf(fabsf(sL), fabsf(sR));
            const float required = peak > ceiling ? ceiling / peak : 1.0f;

            // Sliding minimum over the last N frames (monotonic deque, amortised O(1)).
            const uint32_t idx = k->sampleIndex++;
            while (k->minHead != k->minTail && k->minValue[(k->minTail - 1) & k->minMask] >= required) k->minTail--;
            k->minValue[k->minTail & k->minMask] = required;
            k->minIndex[k->minTail & k->minMask] = idx;
            k->minTail++;
            while (idx - k->minIndex[k->minHead & k->minMask] >= N) k->minHead++;
            const float held = k->minValue[k->minHead & k->minMask];

            // Instant attack, exponential release, then an N-frame moving average. Because every value in the
            // averaging window is <= the gain each peak needs, the gain reaches it exactly when the delayed
            // peak leaves the delay line.
            k->releaseEnv = held < k->releaseEnv ? held : k->releaseEnv + (held - k->releaseEnv) * k->releaseCoef;
            k->boxSum += (double)k->releaseEnv - (double)k->box[k->boxPos];
            k->box[k->boxPos] = k->releaseEnv;
            if (++k->boxPos == N) k->boxPos = 0;
            float g = (float)(k->boxSum * invN);
            if (g > 1.0f) g = 1.0f;
            if (g < minGain) minGain = g;

            const float dl = k->delay[0][k->delayPos];
            const float dr = k->delay[1][k->delayPos];
            k->delay[0][k->delayPos] = sL;
            k->delay[1][k->delayPos] = sR;
            if (++k->delayPos == D) k->delayPos = 0;

            float ol = bs_clamp(dl * g, -ceiling, ceiling) * k->outGain;
            float orr = bs_clamp(dr * g, -ceiling, ceiling) * k->outGain;
            outL[i] = ol;
            outR[i] = orr;
            ol = fabsf(ol);
            orr = fabsf(orr);
            if (ol > outPeakL) outPeakL = ol;
            if (orr > outPeakR) outPeakR = orr;
        }
    }

    bs_sanitize_state(k);

    bs_store_max(&k->inputPeak[0], inPeakL);
    bs_store_max(&k->inputPeak[1], inPeakR);
    bs_store_max(&k->outputPeak[0], outPeakL);
    bs_store_max(&k->outputPeak[1], outPeakR);
    bs_store_max(&k->gainReductionDB, minGain < 1.0f ? -20.0f * log10f(fmaxf(minGain, 1e-6f)) : 0.0f);
}

OSStatus BSKernelIOProc(AudioObjectID device,
                        const AudioTimeStamp *now,
                        const AudioBufferList *inputData,
                        const AudioTimeStamp *inputTime,
                        AudioBufferList *outputData,
                        const AudioTimeStamp *outputTime,
                        void *clientData) {
    (void)device;
    (void)now;
    (void)inputTime;
    (void)outputTime;
    BSKernel *k = (BSKernel *)clientData;
    if (!k || !outputData) return noErr;

    // Output: silence every buffer, then target the first two channels. The HAL hands IOProcs Float32.
    float *outPtr[2] = {NULL, NULL};
    uint32_t outStride[2] = {0, 0};
    uint32_t outChannels = 0;
    uint32_t frames = UINT32_MAX;
    for (UInt32 b = 0; b < outputData->mNumberBuffers; b++) {
        AudioBuffer *buf = &outputData->mBuffers[b];
        if (!buf->mData || buf->mNumberChannels == 0) continue;
        memset(buf->mData, 0, buf->mDataByteSize);
        const uint32_t bufFrames = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
        for (UInt32 c = 0; c < buf->mNumberChannels && outChannels < 2; c++) {
            outPtr[outChannels] = (float *)buf->mData + c;
            outStride[outChannels] = buf->mNumberChannels;
            outChannels++;
            if (bufFrames < frames) frames = bufFrames;
        }
    }
    if (outChannels == 0 || frames == UINT32_MAX) return noErr;

    // Inputs: each source is one buffer (one tap stream). Mono buffers feed both channels.
    const float *srcL[BS_MAX_SOURCES], *srcR[BS_MAX_SOURCES];
    uint32_t srcStride[BS_MAX_SOURCES], srcFrames[BS_MAX_SOURCES];
    float srcPeak[BS_MAX_SOURCES];
    const uint32_t sources = atomic_load_explicit(&k->sourceCount, memory_order_acquire);
    for (uint32_t s = 0; s < sources; s++) {
        srcL[s] = srcR[s] = NULL;
        srcFrames[s] = 0;
        srcStride[s] = 1;
        srcPeak[s] = 0.0f;
        const uint32_t b = k->sourceStream[s];
        if (!inputData || b >= inputData->mNumberBuffers) continue;
        const AudioBuffer *buf = &inputData->mBuffers[b];
        if (!buf->mData || buf->mNumberChannels == 0) continue;
        srcL[s] = (const float *)buf->mData;
        srcR[s] = buf->mNumberChannels > 1 ? srcL[s] + 1 : srcL[s];
        srcStride[s] = buf->mNumberChannels;
        srcFrames[s] = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
    }

    atomic_fetch_add_explicit(&k->renderCount, 1, memory_order_relaxed);

    const float sm = k->gainSmoothing;
    float *L = k->scratch[0], *R = k->scratch[1], *OL = k->scratch[2], *OR = k->scratch[3];
    for (uint32_t done = 0; done < frames;) {
        const uint32_t n = frames - done < BS_CHUNK ? frames - done : BS_CHUNK;
        memset(L, 0, sizeof(float) * n);
        memset(R, 0, sizeof(float) * n);
        for (uint32_t s = 0; s < sources; s++) {
            const float target = atomic_load_explicit(&k->sourceGainTarget[s], memory_order_relaxed);
            float g = k->sourceGain[s], peak = srcPeak[s];
            const uint32_t stride = srcStride[s];
            for (uint32_t i = 0; i < n; i++) {
                g += (target - g) * sm;
                const uint32_t f = done + i;
                if (!srcL[s] || f >= srcFrames[s]) continue;
                const float l = srcL[s][f * stride], r = srcR[s][f * stride];
                const float a = fmaxf(fabsf(l), fabsf(r));
                if (a > peak) peak = a;
                L[i] += g * l;
                R[i] += g * r;
            }
            k->sourceGain[s] = g;
            srcPeak[s] = peak;
        }
        BSKernelProcess(k, L, R, OL, OR, n);
        if (outChannels >= 2) {
            for (uint32_t i = 0; i < n; i++) {
                outPtr[0][(done + i) * outStride[0]] = OL[i];
                outPtr[1][(done + i) * outStride[1]] = OR[i];
            }
        } else {
            for (uint32_t i = 0; i < n; i++) outPtr[0][(done + i) * outStride[0]] = 0.5f * (OL[i] + OR[i]);
        }
        done += n;
    }
    float loudest = 0.0f;
    for (uint32_t s = 0; s < sources; s++) {
        bs_store_max(&k->sourcePeak[s], srcPeak[s]);
        if (srcPeak[s] > loudest) loudest = srcPeak[s];
    }
    if (loudest > BS_SOUND_THRESHOLD) atomic_store_explicit(&k->lastSoundTime, mach_absolute_time(), memory_order_relaxed);
    return noErr;
}

OSStatus BSDeviceSetInputStreamUsage(AudioObjectID device, AudioDeviceIOProcID ioProc, uint32_t firstEnabledStream) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    if (status != noErr) return status;
    if (size < sizeof(AudioHardwareIOProcStreamUsage)) size = sizeof(AudioHardwareIOProcStreamUsage);

    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)ioProc;
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, usage);
    if (status == noErr) {
        for (UInt32 i = 0; i < usage->mNumberStreams; i++) usage->mStreamIsOn[i] = i >= firstEnabledStream;
        status = AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
    }
    free(usage);
    return status;
}
