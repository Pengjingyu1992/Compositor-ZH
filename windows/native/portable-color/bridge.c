#include <stdbool.h>
#include <stdlib.h>

// Native cancellation uses a thread-local flag. Here the worker is terminated
// by its owner, so the module has no OS imports or shared cancellation memory.
bool filter_cancellation_requested(void) { return false; }

static int allocation_failed;
void color_reset_failure(void) { allocation_failed = 0; }
int color_allocation_failed(void) { return allocation_failed; }
void *__real_malloc(size_t size);
void *__real_calloc(size_t count, size_t size);
void *__real_realloc(void *pointer, size_t size);
void *__wrap_malloc(size_t size) {
    void *result = __real_malloc(size);
    if (!result && size) allocation_failed = 1;
    return result;
}
void *__wrap_calloc(size_t count, size_t size) {
    void *result = __real_calloc(count, size);
    if (!result && count && size) allocation_failed = 1;
    return result;
}
void *__wrap_realloc(void *pointer, size_t size) {
    void *result = __real_realloc(pointer, size);
    if (!result && size) allocation_failed = 1;
    return result;
}
void *color_allocate(size_t size) { return __wrap_malloc(size); }
