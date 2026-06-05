/* malloc/calloc/realloc/free for the freestanding wasm32 build.
 *
 * A small, self-contained allocator: a single doubly-linked free list with
 * boundary-tag (header+footer) coalescing, first-fit, backed by linear-memory
 * growth via memory.grow above __heap_base. The compiler is not allocation-
 * performance-critical (it compiles a program once), so simplicity and obvious
 * correctness win over speed/fragmentation tuning. Correctness is exercised by
 * a native fuzz/stress harness and end-to-end by the differential test that
 * diffs freestanding-compiler output against the native build.
 *
 * Layout per block (all sizes 8-aligned; the low 3 bits of the stored size are
 * spare, bit 0 = in-use):
 *
 *   +------------------+ <- block start (8-aligned)
 *   | header: u32 size |  (8 bytes; size = whole block, incl header+footer)
 *   +------------------+ <- payload (8-aligned), returned to caller
 *   | payload ...      |  (>= 16 bytes; holds the free-list links when free)
 *   +------------------+
 *   | footer: u32 size |  (8 bytes; mirrors header, for backward coalescing)
 *   +------------------+
 */

#include <stddef.h>
#include <stdint.h>

#include "string.h"

#define ALIGN       8u
#define HDR         8u /* header bytes before payload (8 keeps payload 8-aligned) */
#define FTR         8u /* footer bytes after payload */
#define MIN_PAYLOAD 16 /* room for the two free-list pointers */
#define PAGE        65536u

typedef struct FreeNode {
    struct FreeNode *next, *prev;
} FreeNode;

extern char __heap_base;

static char *g_heap_start;
static char *g_brk; /* next unused address */
static char *g_end; /* end of committed linear memory */
static FreeNode *g_free;
static int g_inited;

static uintptr_t align_up(uintptr_t x, uintptr_t a) { return (x + a - 1) & ~(a - 1); }

static void ensure_init(void) {
    if (g_inited) return;
    g_inited = 1;
    uintptr_t hb = align_up((uintptr_t)&__heap_base, ALIGN);
    g_heap_start = (char *)hb;
    g_brk = (char *)hb;
    g_end = (char *)((uintptr_t)__builtin_wasm_memory_size(0) * PAGE);
    g_free = NULL;
}

/* Extend the break by n bytes, growing linear memory if needed. */
static char *heap_extend(uint32_t n) {
    if ((uintptr_t)g_brk + n > (uintptr_t)g_end) {
        uintptr_t need = (uintptr_t)g_brk + n - (uintptr_t)g_end;
        uintptr_t pages = (need + PAGE - 1) / PAGE;
        if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) return NULL;
        g_end += pages * PAGE;
    }
    char *b = g_brk;
    g_brk += n;
    return b;
}

/* --- block header/footer helpers --------------------------------------- */
static uint32_t blk_size(char *b) { return *(uint32_t *)b & ~7u; }
static int blk_used(char *b) { return *(uint32_t *)b & 1u; }
static void blk_set(char *b, uint32_t size, int used) {
    uint32_t v = size | (used ? 1u : 0u);
    *(uint32_t *)b = v;                /* header */
    *(uint32_t *)(b + size - FTR) = v; /* footer mirror */
}

/* --- free list (unordered, doubly linked) ------------------------------ */
static void fl_insert(char *b) {
    FreeNode *n = (FreeNode *)(b + HDR);
    n->prev = NULL;
    n->next = g_free;
    if (g_free) g_free->prev = n;
    g_free = n;
}
static void fl_remove(char *b) {
    FreeNode *n = (FreeNode *)(b + HDR);
    if (n->prev)
        n->prev->next = n->next;
    else
        g_free = n->next;
    if (n->next) n->next->prev = n->prev;
}

void *malloc(size_t req) {
    ensure_init();
    if (req == 0) req = 1;
    if (req > 0xfffffff0u) return NULL;
    uint32_t need = (uint32_t)align_up(req, ALIGN);
    if (need < MIN_PAYLOAD) need = MIN_PAYLOAD;
    uint32_t total = HDR + need + FTR;

    for (FreeNode *n = g_free; n; n = n->next) {
        char *b = (char *)n - HDR;
        uint32_t bs = blk_size(b);
        if (bs >= total) {
            fl_remove(b);
            uint32_t rem = bs - total;
            if (rem >= HDR + MIN_PAYLOAD + FTR) { /* split off the tail */
                blk_set(b, total, 1);
                char *r = b + total;
                blk_set(r, rem, 0);
                fl_insert(r);
            } else {
                blk_set(b, bs, 1);
            }
            return b + HDR;
        }
    }

    char *b = heap_extend(total);
    if (!b) return NULL;
    blk_set(b, total, 1);
    return b + HDR;
}

void free(void *p) {
    if (!p) return;
    char *b = (char *)p - HDR;
    uint32_t bs = blk_size(b);

    /* coalesce with the following block if it is free */
    char *next = b + bs;
    if (next < g_brk && !blk_used(next)) {
        fl_remove(next);
        bs += blk_size(next);
    }
    /* coalesce with the preceding block if it is free (read its footer) */
    if (b > g_heap_start) {
        uint32_t pfoot = *(uint32_t *)(b - FTR);
        if (!(pfoot & 1u)) {
            uint32_t ps = pfoot & ~7u;
            char *prev = b - ps;
            fl_remove(prev);
            b = prev;
            bs += ps;
        }
    }
    blk_set(b, bs, 0);
    fl_insert(b);
}

void *calloc(size_t nmemb, size_t size) {
    size_t n;
    if (__builtin_mul_overflow(nmemb, size, &n)) return NULL;
    void *p = malloc(n);
    if (p) memset(p, 0, n);
    return p;
}

void *realloc(void *p, size_t n) {
    if (!p) return malloc(n);
    if (n == 0) {
        free(p);
        return NULL;
    }
    char *b = (char *)p - HDR;
    uint32_t avail = blk_size(b) - HDR - FTR; /* current payload capacity */
    if (n <= avail) return p;
    void *q = malloc(n);
    if (!q) return NULL;
    memcpy(q, p, avail);
    free(p);
    return q;
}
