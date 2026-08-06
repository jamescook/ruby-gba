# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Reference
        # The interpreter's model of a `list`: a bounded, ordered collection the
        # program pushes onto, drops from either end, and reads back by index. It's
        # the headless stand-in for what a console keeps in memory as a ring buffer
        # — here a plain Ruby array is enough, because only the *observable*
        # behavior (what you can push, drop, and read back, and when it's full) has
        # to match, not how the storage is laid out.
        #
        # `capacity` is the ceiling — the rounded value from the IR, so this agrees
        # with the console on exactly when a push overflows. The interpreter checks
        # bounds (full / empty / index in range) before calling in and turns a
        # violation into a friendly error, so these methods trust their caller.
        class ListValue
          attr_reader :capacity

          def initialize(capacity)
            @capacity = capacity
            @items = []
          end

          # How many items are in the list right now.
          def length
            @items.length
          end

          def empty?
            @items.empty?
          end

          # True once the list holds all it can — the next push would overflow.
          def full?
            @items.length >= @capacity
          end

          # A valid index is any slot currently holding an item (0..length-1).
          def index?(index)
            index >= 0 && index < @items.length
          end

          # Append a value at the end (caller ensures there's room).
          def push(value)
            @items.push(value)
          end

          # The value at an index (caller ensures the index is in range).
          def get(index)
            @items[index]
          end

          # Overwrite the value at an index (caller ensures the index is in range).
          def set(index, value)
            @items[index] = value
          end

          # Remove and return the oldest item (the front). Caller ensures the list
          # isn't empty.
          def shift
            @items.shift
          end

          # Remove and return the newest item (the back). Caller ensures the list
          # isn't empty.
          def pop
            @items.pop
          end
        end
      end
    end
  end
end
