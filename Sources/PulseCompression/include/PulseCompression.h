#ifndef PULSE_COMPRESSION_H
#define PULSE_COMPRESSION_H
#include <stddef.h>
#include <stdint.h>
#include "PulseCrash.h"
// Caller owns the returned allocation and releases it with pulse_free.
uint8_t *pulse_gzip(const uint8_t *input, size_t count, size_t *output_count);
uint8_t *pulse_gunzip(const uint8_t *input, size_t count, size_t *output_count);
void pulse_free(void *buffer);
#endif
