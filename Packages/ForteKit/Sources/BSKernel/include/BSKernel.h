#ifndef BSKERNEL_H
#define BSKERNEL_H

#include <stdbool.h>
#include <stdint.h>
#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

CF_ASSUME_NONNULL_BEGIN

#define BS_EQ_BAND_COUNT 10   ///< Graphic EQ bands (filters 0..9).
#define BS_EQ_BASS 10         ///< Bass tone control: low shelf at 100 Hz.
#define BS_EQ_TREBLE 11       ///< Treble tone control: high shelf at 10 kHz.
#define BS_EQ_FILTER_COUNT 12
#define BS_MAX_SOURCES 16     ///< Separately gained inputs (the global tap plus one per mixed app).

/// Real-time stereo processor:
/// sources (per-app gain) -> EQ + tone -> boost -> stereo width -> balance -> look-ahead limiter -> output volume.
/// Setters are lock-free and may be called from any thread while audio is rendering.
typedef struct BSKernel BSKernel;

typedef struct BSMeters {
    float inputPeak[2];    ///< Linear peak per channel of the mixed input since the previous read.
    float outputPeak[2];   ///< Linear peak per channel since the previous read.
    float gainReduction;   ///< Deepest limiter gain reduction since the previous read, in dB (>= 0).
    uint64_t renderCount;  ///< Total IO cycles rendered.
} BSMeters;

/// Centre frequencies (Hz) of the graphic bands. Band 0 is a low shelf, band 9 a high shelf, the rest peaking.
extern const float BSEQBandFrequencies[BS_EQ_BAND_COUNT];

BSKernel *_Nullable BSKernelCreate(double sampleRate);
void BSKernelDestroy(BSKernel *_Nullable kernel);

double BSKernelGetSampleRate(const BSKernel *kernel);
/// Delay introduced by the limiter's look-ahead.
uint32_t BSKernelGetLatencyFrames(const BSKernel *kernel);

void BSKernelSetBoost(BSKernel *kernel, float decibels);
void BSKernelSetEQEnabled(BSKernel *kernel, bool enabled);
/// `filter` is a graphic band (0..9), BS_EQ_BASS or BS_EQ_TREBLE.
void BSKernelSetEQBandGain(BSKernel *kernel, int filter, float decibels);
/// -1 (left only) ... 0 (centre) ... +1 (right only).
void BSKernelSetBalance(BSKernel *kernel, float balance);
/// 0 = mono, 1 = unchanged, 2 = double side level.
void BSKernelSetStereoWidth(BSKernel *kernel, float width);
/// Output ceiling in dBFS. Default -1.
void BSKernelSetLimiterCeiling(BSKernel *kernel, float decibels);
/// Software volume applied after the limiter (0...1), for devices without a hardware volume control.
void BSKernelSetOutputGain(BSKernel *kernel, float linear);

/// Input layout: source i is read from input buffer `streamIndices[i]` (mono buffers feed both channels).
/// Defaults to one source at buffer 0. Call before audio starts.
void BSKernelSetSources(BSKernel *kernel, const uint32_t *streamIndices, uint32_t count);
/// Linear gain for one source (0 mutes). Default 1.
void BSKernelSetSourceGain(BSKernel *kernel, uint32_t source, float linear);
/// Pre-gain linear peak of one source since the previous read (shows activity even when muted).
float BSKernelReadSourcePeak(BSKernel *kernel, uint32_t source);

/// Copies meter values and resets the peak-hold fields. Call from a non-real-time thread.
void BSKernelReadMeters(BSKernel *kernel, BSMeters *outMeters);

/// Planar stereo render of an already-mixed input. In-place is allowed. Real-time safe.
void BSKernelProcess(BSKernel *kernel, const float *inL, const float *inR, float *outL, float *outR, uint32_t frameCount);

/// AudioDeviceIOProc; pass the kernel as client data. Mixes the configured input sources, processes them and
/// writes the result to the first two output channels (or folds to mono on a one-channel device).
OSStatus BSKernelIOProc(AudioObjectID device,
                        const AudioTimeStamp *now,
                        const AudioBufferList *inputData,
                        const AudioTimeStamp *inputTime,
                        AudioBufferList *outputData,
                        const AudioTimeStamp *outputTime,
                        void *_Nullable clientData);

/// Disables the device's input streams before `firstEnabledStream` for `ioProc`, so the aggregate's output
/// sub-device never opens its microphone (which would also force Bluetooth headsets into call quality).
OSStatus BSDeviceSetInputStreamUsage(AudioObjectID device, AudioDeviceIOProcID ioProc, uint32_t firstEnabledStream);

/// Summed magnitude response in dB of all BS_EQ_FILTER_COUNT filters at each frequency, for drawing the curve.
void BSEQComputeResponse(const float *gainsDB, double sampleRate,
                         const float *frequencies, float *outDB, uint32_t count);

CF_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif
