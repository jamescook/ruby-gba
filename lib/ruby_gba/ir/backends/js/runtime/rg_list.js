/*
 * A game's list (`list :trail, capacity: 64`), as the native runtime's rg_list.h keeps one: the
 * items in an array as long as the capacity, used as a ring, so dropping the oldest moves where
 * the front is rather than every item. A narrow list keeps each number's low bits, so 200 in a
 * byte reads back as -56. What the interpreter refuses stops the game with the same words.
 */

function rg_list_new(capacity, width, name) {
  return { items: new Int32Array(Math.max(capacity, 1)), capacity, width, front: 0, length: 0, name };
}

function rg_list_fit(list, value) {
  if (list.width === 1) return rg_to_byte(value);
  if (list.width === 2) return rg_to_half(value);
  return value;
}

/* Where item +index+ sits in the ring. */
function rg_list_slot(list, index) { return (list.front + index) % list.capacity; }

function rg_list_check_index(list, index) {
  if (index >= 0 && index < list.length) return;
  if (list.length === 0) rg_fault(`index ${index} is out of range: list :${list.name} is empty`);
  rg_fault(`index ${index} is out of range for list :${list.name} (valid indexes are 0..${list.length - 1})`);
}

/* A list declared where the program reaches it starts again, empty. */
function rg_list_empty(list) {
  list.front = 0;
  list.length = 0;
}

/* ...or, declared full of a value (`full_of:`), starts again holding its capacity of it. */
function rg_list_full(list, value) {
  list.front = 0;
  list.length = list.capacity;
  list.items.fill(rg_list_fit(list, value), 0, list.capacity);
}

function rg_list_length(list) { return list.length; }

function rg_list_push(list, value) {
  if (list.length >= list.capacity) {
    rg_fault(`list :${list.name} is full (capacity ${list.capacity}): drop an item first, or give it a larger capacity`);
  }
  list.items[rg_list_slot(list, list.length)] = rg_list_fit(list, value);
  list.length++;
}

/* Drops the oldest item (+front+ not nought) or the newest. */
function rg_list_drop(list, front) {
  if (list.length === 0) rg_fault(`list :${list.name} is empty: there is nothing to ${front ? "shift" : "pop"}`);
  if (front) list.front = rg_list_slot(list, 1);
  list.length--;
}

function rg_list_get(list, index) {
  rg_list_check_index(list, index);
  return list.items[rg_list_slot(list, index)];
}

function rg_list_set(list, index, value) {
  rg_list_check_index(list, index);
  list.items[rg_list_slot(list, index)] = rg_list_fit(list, value);
}

/* Every item from +from+ for +count+ items set to +value+; both ends checked before anything is
 * written. */
function rg_list_fill(list, from, count, value) {
  if (count <= 0) return;
  rg_list_check_index(list, from);
  rg_list_check_index(list, rg_add(from, count - 1));
  for (let i = 0; i < count; i++) list.items[rg_list_slot(list, from + i)] = rg_list_fit(list, value);
}

/* How a table's entries are kept. Each table is a typed array of the width the game declared, so
 * reading an entry already gives the whole number, and the kind is only checked. */
const RG_TABLE_INT8 = 0, RG_TABLE_UINT8 = 1, RG_TABLE_INT16 = 2, RG_TABLE_UINT16 = 3, RG_TABLE_INT32 = 4;

/* The list made to hold exactly +count+ entries of a table, from entry +at+ on, held so the whole
 * run is inside the table. */
function rg_list_copy(list, table, kept, table_length, at, count) {
  if (count > list.capacity) rg_fault(`a copy of ${count} entries does not fit list :${list.name} (capacity ${list.capacity})`);
  if (count > table_length) rg_fault(`a copy of ${count} entries is longer than its table (${table_length} entries)`);
  const start = rg_clamp(at, 0, table_length - count);
  list.front = 0;
  list.length = count;
  for (let i = 0; i < count; i++) list.items[i] = rg_list_fit(list, table[start + i]);
}
