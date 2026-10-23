#include "AudioSilence.h"
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct SillSilenceContext {
    uint32_t expectedInput, expectedOutput;
    atomic_uint_fast64_t revision, callbacks, lastTick, zeroedBytes;
    atomic_uint inputChannels, outputChannels;
    atomic_bool fault;
};
SillSilenceContext *SillSilenceCreate(uint32_t input, uint32_t output) {
    SillSilenceContext *context = calloc(1, sizeof(*context));
    if (!context) return NULL;
    context->expectedInput = input;
    context->expectedOutput = output;
    atomic_init(&context->revision, 0); atomic_init(&context->callbacks, 0);
    atomic_init(&context->lastTick, 0); atomic_init(&context->zeroedBytes, 0);
    atomic_init(&context->inputChannels, 0); atomic_init(&context->outputChannels, 0);
    atomic_init(&context->fault, false);
    if (!atomic_is_lock_free(&context->revision) || !atomic_is_lock_free(&context->fault) || !atomic_is_lock_free(&context->inputChannels)) { free(context); return NULL; }
    return context;
}
void SillSilenceDestroy(SillSilenceContext *context) { free(context); }
bool SillSilenceInspect(SillSilenceContext *context, SillSilenceReadback *result) {
    if (!context || !result) return false;
    for (int attempt = 0; attempt < 3; ++attempt) {
        uint64_t before = atomic_load(&context->revision);
        if (before & 1) continue;
        result->callbacks = atomic_load(&context->callbacks);
        result->lastTick = atomic_load(&context->lastTick);
        result->zeroedBytes = atomic_load(&context->zeroedBytes);
        result->inputChannels = atomic_load(&context->inputChannels);
        result->outputChannels = atomic_load(&context->outputChannels);
        result->fault = atomic_load(&context->fault);
        if (before == atomic_load(&context->revision)) return true;
    }
    return false;
}
OSStatus SillSilenceIOProc(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *opaque) {
    SillSilenceContext *context = opaque;
    if (!context) return kAudioHardwareIllegalOperationError;
    uint32_t inputs = 0, outputs = 0;
    uint64_t bytes = 0;
    bool fault = false;
    atomic_fetch_add(&context->revision, 1);
    if (input && input->mNumberBuffers <= 128) {
        for (uint32_t index = 0; index < input->mNumberBuffers; ++index)
            inputs += input->mBuffers[index].mNumberChannels;
    }
    if (output && output->mNumberBuffers <= 128) {
        for (uint32_t index = 0; index < output->mNumberBuffers; ++index) {
            AudioBuffer *buffer = &output->mBuffers[index];
            outputs += buffer->mNumberChannels;
            if (!buffer->mData || !buffer->mDataByteSize) { fault = true; continue; }
            memset(buffer->mData, 0, buffer->mDataByteSize);
            bytes += buffer->mDataByteSize;
        }
    }
    fault |= inputs != context->expectedInput || outputs != context->expectedOutput;
    fault |= context->expectedOutput > 0 && bytes == 0;
    atomic_store(&context->inputChannels, inputs); atomic_store(&context->outputChannels, outputs);
    atomic_store(&context->zeroedBytes, bytes); atomic_store(&context->lastTick, mach_continuous_time());
    atomic_fetch_add(&context->callbacks, 1);
    if (fault) atomic_store(&context->fault, true);
    atomic_fetch_add(&context->revision, 1);
    return fault ? kAudioHardwareIllegalOperationError : noErr;
}
