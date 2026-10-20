#include "FilterCancellation.h"
#include <stdatomic.h>
#include <stdlib.h>

struct FilterCancellationContext { atomic_bool canceled; };
static _Thread_local FilterCancellationContext *current_context;

FilterCancellationContext *filter_cancellation_create(void) {
    FilterCancellationContext *context = malloc(sizeof(*context));
    if (context) atomic_init(&context->canceled, false);
    return context;
}
void filter_cancellation_destroy(FilterCancellationContext *context) { free(context); }
void filter_cancellation_cancel(FilterCancellationContext *context) {
    if (context) atomic_store_explicit(&context->canceled, true, memory_order_relaxed);
}
FilterCancellationContext *filter_cancellation_enter(FilterCancellationContext *context) {
    FilterCancellationContext *previous = current_context;
    current_context = context;
    return previous;
}
bool filter_cancellation_requested(void) {
    return current_context && atomic_load_explicit(&current_context->canceled, memory_order_relaxed);
}
