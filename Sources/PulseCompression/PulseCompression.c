#include "PulseCompression.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <zlib.h>

// Platform zlib, no vendored implementation. Fixed gzip mtime makes output deterministic.
uint8_t *pulse_gzip(const uint8_t *input, size_t count, size_t *output_count) {
    if (!output_count || count > 1048576 || (!input && count)) return NULL;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) return NULL;
    size_t capacity = (size_t)deflateBound(&stream, (uLong)count);
    uint8_t *output = malloc(capacity);
    if (!output) { deflateEnd(&stream); return NULL; }
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)count;
    stream.next_out = output;
    stream.avail_out = (uInt)capacity;
    int result = deflate(&stream, Z_FINISH);
    *output_count = (size_t)stream.total_out;
    deflateEnd(&stream);
    if (result != Z_STREAM_END) { free(output); return NULL; }
    return output;
}

// Bounded decoder used to validate restored gzip and in round-trip tests.
uint8_t *pulse_gunzip(const uint8_t *input, size_t count, size_t *output_count) {
    if (!output_count || count > 1114112 || (!input && count)) return NULL;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, 15 + 16) != Z_OK) return NULL;
    const size_t capacity = 1048577;
    uint8_t *output = malloc(capacity);
    if (!output) { inflateEnd(&stream); return NULL; }
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)count;
    stream.next_out = output;
    stream.avail_out = (uInt)capacity;
    int result = inflate(&stream, Z_FINISH);
    *output_count = (size_t)stream.total_out;
    int valid = result == Z_STREAM_END && stream.avail_in == 0 && stream.total_out <= 1048576;
    inflateEnd(&stream);
    if (!valid) { free(output); return NULL; }
    return output;
}
void pulse_free(void *buffer) { free(buffer); }
