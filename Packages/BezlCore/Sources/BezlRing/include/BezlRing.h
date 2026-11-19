#ifndef BEZL_RING_H
#define BEZL_RING_H

#include <stddef.h>

/// Single-producer / single-consumer lock-free ring buffer of floats.
/// The producer (real-time audio thread) calls only `bezl_ring_write`.
/// The consumer (analysis queue) calls only `bezl_ring_read` / `bezl_ring_available`.
/// No allocation, locking or syscalls happen in either call.
typedef struct BezlRing BezlRing;

/// Capacity is rounded up to a power of two. Returns NULL on allocation failure.
BezlRing *_Nullable bezl_ring_create(size_t capacity);
void bezl_ring_destroy(BezlRing *_Nullable ring);

/// Writes up to `count` samples; when the ring is full the oldest samples are NOT
/// overwritten — excess input is dropped. Returns the number written.
size_t bezl_ring_write(BezlRing *_Nonnull ring, const float *_Nonnull samples, size_t count);

/// Reads up to `count` samples into `out`. Returns the number read.
size_t bezl_ring_read(BezlRing *_Nonnull ring, float *_Nonnull out, size_t count);

size_t bezl_ring_available(BezlRing *_Nonnull ring);

/// Drops everything currently buffered (consumer side only).
void bezl_ring_clear(BezlRing *_Nonnull ring);

#endif
