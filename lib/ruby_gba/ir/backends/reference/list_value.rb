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

          # +width+ says how big one slot is. A `:word` list holds whole 32-bit numbers and is
          # what almost everything is; a narrower one holds less, and holding less is the point
          # of asking for it — a quarter or a half of the memory. A narrow slot can always go
          # below nothing (see Build.element_range for why there is no choice about that), and
          # what it does with a number too big for it is the interesting part: it does what the
          # console does, keeping the low bits and dropping the rest. See #fit.
          def initialize(capacity, width: :word)
            @capacity = capacity
            @low, @high = Build.element_range(width)
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
            @items.push(fit(value))
          end

          # The value at an index (caller ensures the index is in range).
          def get(index)
            @items[index]
          end

          # Overwrite the value at an index (caller ensures the index is in range).
          def set(index, value)
            @items[index] = fit(value)
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

          private

          # WHAT A SLOT REALLY HOLDS once a number has been put in it. A word-wide slot holds
          # the number; a narrower one keeps the low bits that fit and drops the rest, which is
          # what the console's byte and halfword stores do and so is what this has to do to
          # agree with it. The value comes back the way the console's sign-extending load reads
          # it, so 200 in a byte slot is -56 on both backends rather than 200 here and -56
          # there — the two agreeing about what was dropped is the whole of the contract.
          def fit(value)
            span = @high - @low + 1
            return value if span > 0xFFFF_FFFF

            @low + ((value - @low) % span)
          end
        end
      end
    end
  end
end
