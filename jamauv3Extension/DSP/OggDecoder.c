//
//  OggDecoder.c
//  jamauv3Extension
//
//  C wrapper implementation for stb_vorbis OGG decoding.
//

#include "OggDecoder.h"
#include <stdlib.h>
#include <string.h>

// Include stb_vorbis implementation
// Note: stb_vorbis is stored as .h to prevent Xcode from compiling it separately
#define STB_VORBIS_NO_PUSHDATA_API  // We only need the pulldata API
#include "stb_vorbis.h"

// Opaque context wraps stb_vorbis
struct OggDecoderContext {
    stb_vorbis* vorbis;
    int channels;
    int sampleRate;
};

// MARK: - Full Decode Functions

int32_t ogg_decoder_decode_memory(
    const uint8_t* data,
    size_t dataLength,
    float** outputBuffer,
    OggAudioInfo* audioInfo
) {
    if (!data || !outputBuffer || !audioInfo) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    int channels = 0;
    int sampleRate = 0;
    short* decodedShort = NULL;

    int samples = stb_vorbis_decode_memory(
        data,
        (int)dataLength,
        &channels,
        &sampleRate,
        &decodedShort
    );

    if (samples < 0 || !decodedShort) {
        return OGG_DECODER_ERROR_DECODE_FAILED;
    }

    audioInfo->channels = channels;
    audioInfo->sampleRate = sampleRate;
    audioInfo->totalSamples = samples;

    // Convert to float
    size_t totalSamples = (size_t)samples * (size_t)channels;
    float* floatBuffer = (float*)malloc(totalSamples * sizeof(float));
    if (!floatBuffer) {
        free(decodedShort);
        return OGG_DECODER_ERROR_OUT_OF_MEMORY;
    }

    for (size_t i = 0; i < totalSamples; i++) {
        floatBuffer[i] = decodedShort[i] / 32768.0f;
    }

    free(decodedShort);
    *outputBuffer = floatBuffer;

    return samples;
}

int32_t ogg_decoder_decode_file(
    const char* filePath,
    float** outputBuffer,
    OggAudioInfo* audioInfo
) {
    if (!filePath || !outputBuffer || !audioInfo) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    int channels = 0;
    int sampleRate = 0;
    short* decodedShort = NULL;

    int samples = stb_vorbis_decode_filename(
        filePath,
        &channels,
        &sampleRate,
        &decodedShort
    );

    if (samples < 0 || !decodedShort) {
        return OGG_DECODER_ERROR_DECODE_FAILED;
    }

    audioInfo->channels = channels;
    audioInfo->sampleRate = sampleRate;
    audioInfo->totalSamples = samples;

    // Convert to float
    size_t totalSamples = (size_t)samples * (size_t)channels;
    float* floatBuffer = (float*)malloc(totalSamples * sizeof(float));
    if (!floatBuffer) {
        free(decodedShort);
        return OGG_DECODER_ERROR_OUT_OF_MEMORY;
    }

    for (size_t i = 0; i < totalSamples; i++) {
        floatBuffer[i] = decodedShort[i] / 32768.0f;
    }

    free(decodedShort);
    *outputBuffer = floatBuffer;

    return samples;
}

int32_t ogg_decoder_decode_memory_short(
    const uint8_t* data,
    size_t dataLength,
    int16_t** outputBuffer,
    OggAudioInfo* audioInfo
) {
    if (!data || !outputBuffer || !audioInfo) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    int channels = 0;
    int sampleRate = 0;
    short* decoded = NULL;

    int samples = stb_vorbis_decode_memory(
        data,
        (int)dataLength,
        &channels,
        &sampleRate,
        &decoded
    );

    if (samples < 0 || !decoded) {
        return OGG_DECODER_ERROR_DECODE_FAILED;
    }

    audioInfo->channels = channels;
    audioInfo->sampleRate = sampleRate;
    audioInfo->totalSamples = samples;
    *outputBuffer = decoded;

    return samples;
}

int32_t ogg_decoder_decode_file_short(
    const char* filePath,
    int16_t** outputBuffer,
    OggAudioInfo* audioInfo
) {
    if (!filePath || !outputBuffer || !audioInfo) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    int channels = 0;
    int sampleRate = 0;
    short* decoded = NULL;

    int samples = stb_vorbis_decode_filename(
        filePath,
        &channels,
        &sampleRate,
        &decoded
    );

    if (samples < 0 || !decoded) {
        return OGG_DECODER_ERROR_DECODE_FAILED;
    }

    audioInfo->channels = channels;
    audioInfo->sampleRate = sampleRate;
    audioInfo->totalSamples = samples;
    *outputBuffer = decoded;

    return samples;
}

void ogg_decoder_free_buffer(void* buffer) {
    free(buffer);
}

// MARK: - Info Functions

int ogg_decoder_get_info_memory(
    const uint8_t* data,
    size_t dataLength,
    OggAudioInfo* audioInfo
) {
    if (!data || !audioInfo) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    int error = 0;
    stb_vorbis* vorbis = stb_vorbis_open_memory(data, (int)dataLength, &error, NULL);
    if (!vorbis) {
        return OGG_DECODER_ERROR_INVALID_FILE;
    }

    stb_vorbis_info info = stb_vorbis_get_info(vorbis);
    audioInfo->channels = info.channels;
    audioInfo->sampleRate = info.sample_rate;
    audioInfo->totalSamples = stb_vorbis_stream_length_in_samples(vorbis);

    stb_vorbis_close(vorbis);
    return OGG_DECODER_SUCCESS;
}

int ogg_decoder_get_info_file(
    const char* filePath,
    OggAudioInfo* audioInfo
) {
    if (!filePath || !audioInfo) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    int error = 0;
    stb_vorbis* vorbis = stb_vorbis_open_filename(filePath, &error, NULL);
    if (!vorbis) {
        return OGG_DECODER_ERROR_INVALID_FILE;
    }

    stb_vorbis_info info = stb_vorbis_get_info(vorbis);
    audioInfo->channels = info.channels;
    audioInfo->sampleRate = info.sample_rate;
    audioInfo->totalSamples = stb_vorbis_stream_length_in_samples(vorbis);

    stb_vorbis_close(vorbis);
    return OGG_DECODER_SUCCESS;
}

// MARK: - Streaming Functions

OggDecoderContext* ogg_decoder_open_memory(
    const uint8_t* data,
    size_t dataLength,
    OggDecoderError* error
) {
    if (!data) {
        if (error) *error = OGG_DECODER_ERROR_INVALID_PARAMETER;
        return NULL;
    }

    OggDecoderContext* context = (OggDecoderContext*)malloc(sizeof(OggDecoderContext));
    if (!context) {
        if (error) *error = OGG_DECODER_ERROR_OUT_OF_MEMORY;
        return NULL;
    }

    int vorbisError = 0;
    context->vorbis = stb_vorbis_open_memory(data, (int)dataLength, &vorbisError, NULL);
    if (!context->vorbis) {
        free(context);
        if (error) *error = OGG_DECODER_ERROR_INVALID_FILE;
        return NULL;
    }

    stb_vorbis_info info = stb_vorbis_get_info(context->vorbis);
    context->channels = info.channels;
    context->sampleRate = info.sample_rate;

    if (error) *error = OGG_DECODER_SUCCESS;
    return context;
}

OggDecoderContext* ogg_decoder_open_file(
    const char* filePath,
    OggDecoderError* error
) {
    if (!filePath) {
        if (error) *error = OGG_DECODER_ERROR_INVALID_PARAMETER;
        return NULL;
    }

    OggDecoderContext* context = (OggDecoderContext*)malloc(sizeof(OggDecoderContext));
    if (!context) {
        if (error) *error = OGG_DECODER_ERROR_OUT_OF_MEMORY;
        return NULL;
    }

    int vorbisError = 0;
    context->vorbis = stb_vorbis_open_filename(filePath, &vorbisError, NULL);
    if (!context->vorbis) {
        free(context);
        if (error) *error = OGG_DECODER_ERROR_INVALID_FILE;
        return NULL;
    }

    stb_vorbis_info info = stb_vorbis_get_info(context->vorbis);
    context->channels = info.channels;
    context->sampleRate = info.sample_rate;

    if (error) *error = OGG_DECODER_SUCCESS;
    return context;
}

int ogg_decoder_stream_get_info(
    OggDecoderContext* context,
    OggAudioInfo* audioInfo
) {
    if (!context || !audioInfo) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    audioInfo->channels = context->channels;
    audioInfo->sampleRate = context->sampleRate;
    audioInfo->totalSamples = stb_vorbis_stream_length_in_samples(context->vorbis);

    return OGG_DECODER_SUCCESS;
}

int32_t ogg_decoder_stream_read_float(
    OggDecoderContext* context,
    float* outputBuffer,
    int32_t maxSamples
) {
    if (!context || !outputBuffer) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    return stb_vorbis_get_samples_float_interleaved(
        context->vorbis,
        context->channels,
        outputBuffer,
        maxSamples * context->channels
    );
}

int32_t ogg_decoder_stream_read_short(
    OggDecoderContext* context,
    int16_t* outputBuffer,
    int32_t maxSamples
) {
    if (!context || !outputBuffer) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    return stb_vorbis_get_samples_short_interleaved(
        context->vorbis,
        context->channels,
        outputBuffer,
        maxSamples * context->channels
    );
}

int ogg_decoder_stream_seek(
    OggDecoderContext* context,
    int64_t samplePosition
) {
    if (!context) {
        return OGG_DECODER_ERROR_INVALID_PARAMETER;
    }

    if (stb_vorbis_seek(context->vorbis, (unsigned int)samplePosition)) {
        return OGG_DECODER_SUCCESS;
    }
    return OGG_DECODER_ERROR_DECODE_FAILED;
}

int64_t ogg_decoder_stream_tell(OggDecoderContext* context) {
    if (!context) {
        return -1;
    }
    return stb_vorbis_get_sample_offset(context->vorbis);
}

void ogg_decoder_close(OggDecoderContext* context) {
    if (context) {
        if (context->vorbis) {
            stb_vorbis_close(context->vorbis);
        }
        free(context);
    }
}
