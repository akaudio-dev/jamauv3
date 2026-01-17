//
//  OggDecoder.h
//  jamauv3Extension
//
//  C wrapper for stb_vorbis OGG decoding functionality.
//  This provides a clean C interface that can be used from Swift.
//

#ifndef OggDecoder_h
#define OggDecoder_h

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to the OGG decoder
typedef struct OggDecoderContext OggDecoderContext;

// Error codes
typedef enum {
    OGG_DECODER_SUCCESS = 0,
    OGG_DECODER_ERROR_INVALID_FILE = -1,
    OGG_DECODER_ERROR_OUT_OF_MEMORY = -2,
    OGG_DECODER_ERROR_INVALID_PARAMETER = -3,
    OGG_DECODER_ERROR_DECODE_FAILED = -4
} OggDecoderError;

// Audio format information
typedef struct {
    int sampleRate;
    int channels;
    int64_t totalSamples;
} OggAudioInfo;

// Decode an entire OGG file from memory to interleaved float samples
// Returns the number of samples decoded (per channel), or negative error code
// Output buffer is allocated by this function and must be freed with ogg_decoder_free_buffer
int32_t ogg_decoder_decode_memory(
    const uint8_t* data,
    size_t dataLength,
    float** outputBuffer,
    OggAudioInfo* audioInfo
);

// Decode an entire OGG file from disk to interleaved float samples
// Returns the number of samples decoded (per channel), or negative error code
// Output buffer is allocated by this function and must be freed with ogg_decoder_free_buffer
int32_t ogg_decoder_decode_file(
    const char* filePath,
    float** outputBuffer,
    OggAudioInfo* audioInfo
);

// Decode to interleaved 16-bit samples (useful for some audio APIs)
int32_t ogg_decoder_decode_memory_short(
    const uint8_t* data,
    size_t dataLength,
    int16_t** outputBuffer,
    OggAudioInfo* audioInfo
);

int32_t ogg_decoder_decode_file_short(
    const char* filePath,
    int16_t** outputBuffer,
    OggAudioInfo* audioInfo
);

// Free a buffer allocated by the decode functions
void ogg_decoder_free_buffer(void* buffer);

// Get audio info without decoding the entire file
int ogg_decoder_get_info_memory(
    const uint8_t* data,
    size_t dataLength,
    OggAudioInfo* audioInfo
);

int ogg_decoder_get_info_file(
    const char* filePath,
    OggAudioInfo* audioInfo
);

// Streaming decoder interface for large files or real-time use

// Open a streaming decoder from memory
OggDecoderContext* ogg_decoder_open_memory(
    const uint8_t* data,
    size_t dataLength,
    OggDecoderError* error
);

// Open a streaming decoder from file
OggDecoderContext* ogg_decoder_open_file(
    const char* filePath,
    OggDecoderError* error
);

// Get info from an open decoder
int ogg_decoder_stream_get_info(
    OggDecoderContext* context,
    OggAudioInfo* audioInfo
);

// Read samples from the stream (returns number of samples read, 0 at end of file)
// Output is interleaved float samples
int32_t ogg_decoder_stream_read_float(
    OggDecoderContext* context,
    float* outputBuffer,
    int32_t maxSamples
);

// Read samples as 16-bit integers
int32_t ogg_decoder_stream_read_short(
    OggDecoderContext* context,
    int16_t* outputBuffer,
    int32_t maxSamples
);

// Seek to a specific sample position
int ogg_decoder_stream_seek(
    OggDecoderContext* context,
    int64_t samplePosition
);

// Get current sample position
int64_t ogg_decoder_stream_tell(OggDecoderContext* context);

// Close the streaming decoder
void ogg_decoder_close(OggDecoderContext* context);

#ifdef __cplusplus
}
#endif

#endif /* OggDecoder_h */
