#ifndef SILL_AUDIO_SILENCE_H
#define SILL_AUDIO_SILENCE_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>
typedef struct SillSilenceContext SillSilenceContext;
typedef struct {
    uint64_t callbacks;
    uint64_t lastTick;
    uint32_t inputChannels;
    uint32_t outputChannels;
    uint64_t zeroedBytes;
    bool fault;
} SillSilenceReadback;
SillSilenceContext * _Nullable SillSilenceCreate(uint32_t inputChannels, uint32_t outputChannels);
void SillSilenceDestroy(SillSilenceContext * _Nonnull context);
bool SillSilenceInspect(SillSilenceContext * _Nonnull context, SillSilenceReadback * _Nonnull result);
OSStatus SillSilenceIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
