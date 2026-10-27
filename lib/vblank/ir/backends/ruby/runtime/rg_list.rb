# A game's list (`list :trail, capacity: 64`): a row of numbers it pushes onto, drops from either
# end and reads by position. Pools are built out of these too, a list per field.
#
# The items sit in an array as long as the list's capacity, used as a ring: dropping the oldest
# item moves where the front is rather than moving every item along, which is also how the
# console keeps a list it shifts. A narrow list (`width: :byte` or `:half`) keeps each number the
# way the console's narrow stores do, so 200 in a byte reads back as -56.
#
# What the interpreter refuses — pushing onto a full list, dropping from an empty one, reading
# past the last item — stops the game with the interpreter's words, through rg_fault. A run that
# carried on past one of those would be answering a different question.

class RgList
  attr_reader :items, :capacity, :width, :name
  attr_accessor :front, :length

  # +width+ is the bytes a slot takes, 1, 2 or 4; +name+ is the game's name for the list.
  def initialize(capacity, width, name)
    @items = Array.new(capacity < 1 ? 1 : capacity, 0)
    @capacity = capacity
    @width = width
    @name = name
    @front = 0
    @length = 0
  end
end

def rg_list_fit(list, value)
  return rg_to_byte(value) if list.width == 1
  return rg_to_half(value) if list.width == 2

  value
end

# Where item +index+ sits in the ring.
def rg_list_slot(list, index) = (list.front + index) % list.capacity

def rg_list_check_index(list, index)
  return if index >= 0 && index < list.length

  rg_fault("index #{index} is out of range: list :#{list.name} is empty") if list.length == 0
  rg_fault("index #{index} is out of range for list :#{list.name} (valid indexes are 0..#{list.length - 1})")
end

# A list declared where the program reaches it starts again, empty.
def rg_list_empty(list)
  list.front = 0
  list.length = 0
end

# ...or, declared full of a value (`full_of:`), starts again holding its capacity of it.
def rg_list_full(list, value)
  list.front = 0
  list.length = list.capacity
  list.items.fill(rg_list_fit(list, value), 0, list.capacity)
end

def rg_list_length(list) = list.length

def rg_list_push(list, value)
  if list.length >= list.capacity
    rg_fault("list :#{list.name} is full (capacity #{list.capacity}): drop an item first, or give it a larger capacity")
  end
  list.items[rg_list_slot(list, list.length)] = rg_list_fit(list, value)
  list.length += 1
end

# Drops the oldest item (+front+ not nought) or the newest.
def rg_list_drop(list, front)
  rg_fault("list :#{list.name} is empty: there is nothing to #{front != 0 ? 'shift' : 'pop'}") if list.length == 0
  list.front = rg_list_slot(list, 1) if front != 0
  list.length -= 1
end

def rg_list_get(list, index)
  rg_list_check_index(list, index)
  list.items[rg_list_slot(list, index)]
end

def rg_list_set(list, index, value)
  rg_list_check_index(list, index)
  list.items[rg_list_slot(list, index)] = rg_list_fit(list, value)
end

# Every item from +from+ for +count+ items set to +value+; both ends are checked before anything
# is written, as the interpreter checks them.
def rg_list_fill(list, from, count, value)
  return if count <= 0

  rg_list_check_index(list, from)
  rg_list_check_index(list, rg_add(from, count - 1))
  fitted = rg_list_fit(list, value)
  count.times { |i| list.items[rg_list_slot(list, from + i)] = fitted }
end

# The list made to hold exactly +count+ entries of a table, from entry +at+ on, held so the whole
# run is inside the table. The program says how the table is kept (a byte, a half or a word,
# signed or not) because a C table is read at that width; every table here is an Array of the
# whole numbers it holds already, so that is not needed.
def rg_list_copy(list, table, _kept, table_length, at, count)
  rg_fault("a copy of #{count} entries does not fit list :#{list.name} (capacity #{list.capacity})") if count > list.capacity
  rg_fault("a copy of #{count} entries is longer than its table (#{table_length} entries)") if count > table_length
  start = rg_clamp(at, 0, table_length - count)
  list.front = 0
  list.length = count
  count.times { |i| list.items[i] = rg_list_fit(list, table[start + i]) }
end
