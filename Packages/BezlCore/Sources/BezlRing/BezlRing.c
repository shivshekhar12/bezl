#include "BezlRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct BezlRing {
    float *buffer;
    size_t mask;            // capacity - 1 (capacity is a power of two)
    _Atomic size_t head;    // total samples written (producer-owned)
    _Atomic size_t tail;    // total samples read (consumer-owned)
};

static size_t next_pow2(size_t v) {
    size_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

BezlRing *bezl_ring_create(size_t capacity) {
    if (capacity < 2) capacity = 2;
    size_t cap = next_pow2(capacity);
    BezlRing *ring = calloc(1, sizeof(BezlRing));
    if (!ring) return NULL;
    ring->buffer = calloc(cap, sizeof(float));
    if (!ring->buffer) { free(ring); return NULL; }
    ring->mask = cap - 1;
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    return ring;
}

void bezl_ring_destroy(BezlRing *ring) {
    if (!ring) return;
    free(ring->buffer);
    free(ring);
}

size_t bezl_ring_write(BezlRing *ring, const float *samples, size_t count) {
    size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    size_t capacity = ring->mask + 1;
    size_t free_space = capacity - (head - tail);
    if (count > free_space) count = free_space;
    for (size_t i = 0; i < count; i++) {
        ring->buffer[(head + i) & ring->mask] = samples[i];
    }
    atomic_store_explicit(&ring->head, head + count, memory_order_release);
    return count;
}

size_t bezl_ring_read(BezlRing *ring, float *out, size_t count) {
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t avail = head - tail;
    if (count > avail) count = avail;
    for (size_t i = 0; i < count; i++) {
        out[i] = ring->buffer[(tail + i) & ring->mask];
    }
    atomic_store_explicit(&ring->tail, tail + count, memory_order_release);
    return count;
}

size_t bezl_ring_available(BezlRing *ring) {
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    return head - tail;
}

void bezl_ring_clear(BezlRing *ring) {
    size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    atomic_store_explicit(&ring->tail, head, memory_order_release);
}
