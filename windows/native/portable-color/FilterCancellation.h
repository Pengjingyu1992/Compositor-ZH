#ifndef FILTER_CANCELLATION_H
#define FILTER_CANCELLATION_H
#include <stdbool.h>

typedef struct FilterCancellationContext FilterCancellationContext;
FilterCancellationContext *filter_cancellation_create(void);
void filter_cancellation_destroy(FilterCancellationContext *context);
void filter_cancellation_cancel(FilterCancellationContext *context);
FilterCancellationContext *filter_cancellation_enter(FilterCancellationContext *context);
bool filter_cancellation_requested(void);
#endif
