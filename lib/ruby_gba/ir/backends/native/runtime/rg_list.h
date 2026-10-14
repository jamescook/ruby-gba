/*
 * A game's list (`list :trail, capacity: 64`): a row of numbers it pushes onto, drops from
 * either end and reads by position. Pools are built out of these too, a list per field.
 *
 * The items sit in an array as long as the list's capacity, used as a ring: dropping the
 * oldest item moves where the front is rather than moving every item along, which is also
 * how the console keeps a list it shifts. A narrow list (`width: :byte` or `:half`) keeps
 * each number the way the console's narrow stores do, so 200 in a byte reads back as -56.
 *
 * What the interpreter refuses — pushing onto a full list, dropping from an empty one,
 * reading past the last item — stops the program here with the same plain message, through
 * rg_fault. The interpreter is the answer key, and a run that carried on past one of those
 * would be answering a different question.
 */
#ifndef RG_LIST_H
#define RG_LIST_H

#include <stdint.h>
#include "rg_int32.h"
#include "rg_runtime.h"

typedef struct rg_list {
  int32_t *items;     /* capacity of them, used as a ring */
  int32_t capacity;
  int32_t width;      /* 1, 2 or 4 bytes a slot */
  int32_t front;      /* where the oldest item is */
  int32_t length;
  const char *name;   /* the game's name for it, for the messages */
} rg_list;

static inline int32_t rg_list_fit(const rg_list *list, int32_t value) {
  if (list->width == 1) return rg_to_byte(value);
  if (list->width == 2) return rg_to_half(value);
  return value;
}

/* Where item +index+ sits in the ring. */
static inline int32_t rg_list_slot(const rg_list *list, int32_t index) {
  return (int32_t)(((int64_t)list->front + index) % list->capacity);
}

static inline void rg_list_check_index(const rg_list *list, int32_t index) {
  if (index >= 0 && index < list->length) return;
  if (list->length == 0) rg_fault("index %d is out of range: list :%s is empty", (int)index, list->name);
  rg_fault("index %d is out of range for list :%s (valid indexes are 0..%d)", (int)index, list->name,
           (int)(list->length - 1));
}

/* A list declared where the program reaches it starts again, empty. */
static inline void rg_list_empty(rg_list *list) {
  list->front = 0;
  list->length = 0;
}

static inline int32_t rg_list_length(const rg_list *list) { return list->length; }

static inline void rg_list_push(rg_list *list, int32_t value) {
  if (list->length >= list->capacity)
    rg_fault("list :%s is full (capacity %d): drop an item first, or give it a larger capacity", list->name,
             (int)list->capacity);
  list->items[rg_list_slot(list, list->length)] = rg_list_fit(list, value);
  list->length++;
}

/* Drops the oldest item (+front+ not nought) or the newest. */
static inline void rg_list_drop(rg_list *list, int32_t front) {
  if (list->length == 0) rg_fault("list :%s is empty: there is nothing to %s", list->name, front ? "shift" : "pop");
  if (front) list->front = rg_list_slot(list, 1);
  list->length--;
}

static inline int32_t rg_list_get(const rg_list *list, int32_t index) {
  rg_list_check_index(list, index);
  return list->items[rg_list_slot(list, index)];
}

static inline void rg_list_set(rg_list *list, int32_t index, int32_t value) {
  rg_list_check_index(list, index);
  list->items[rg_list_slot(list, index)] = rg_list_fit(list, value);
}

/* Every item from +from+ for +count+ items set to +value+; both ends are checked before
 * anything is written, as the interpreter checks them. */
static inline void rg_list_fill(rg_list *list, int32_t from, int32_t count, int32_t value) {
  if (count <= 0) return;
  rg_list_check_index(list, from);
  rg_list_check_index(list, rg_add(from, count - 1));
  for (int32_t i = 0; i < count; i++) list->items[rg_list_slot(list, from + i)] = rg_list_fit(list, value);
}

/* How a table's entries are kept: a table is kept at the width the game declared it, signed or
 * not (Native::Lowering#table_type). */
enum { RG_TABLE_INT8, RG_TABLE_UINT8, RG_TABLE_INT16, RG_TABLE_UINT16, RG_TABLE_INT32 };

/* Entry +at+ of a table kept as +kept+, as a whole number. */
static inline int32_t rg_table_entry(const void *table, int32_t kept, int32_t at) {
  switch (kept) {
  case RG_TABLE_INT8: return ((const int8_t *)table)[at];
  case RG_TABLE_UINT8: return ((const uint8_t *)table)[at];
  case RG_TABLE_INT16: return ((const int16_t *)table)[at];
  case RG_TABLE_UINT16: return ((const uint16_t *)table)[at];
  default: return ((const int32_t *)table)[at];
  }
}

/* The list made to hold exactly +count+ entries of a table, from entry +at+ on, with +at+
 * held so the whole run is inside the table. The table is kept as +kept+ (RG_TABLE_INT8...). */
static inline void rg_list_copy(rg_list *list, const void *table, int32_t kept, int32_t table_length, int32_t at,
                                int32_t count) {
  /* The build refuses both of these before a cartridge exists; checked here as well, since a
   * run past either end would read or write memory that belongs to something else. */
  if (count > list->capacity)
    rg_fault("a copy of %d entries does not fit list :%s (capacity %d)", (int)count, list->name, (int)list->capacity);
  if (count > table_length)
    rg_fault("a copy of %d entries is longer than its table (%d entries)", (int)count, (int)table_length);
  int32_t start = rg_clamp(at, 0, table_length - count);
  list->front = 0;
  list->length = count;
  for (int32_t i = 0; i < count; i++) list->items[i] = rg_list_fit(list, rg_table_entry(table, kept, start + i));
}

#endif
