# frozen_string_literal: true

module RubyGBA
  module Diagnostics
    # EVERY LIST AND POOL THE GAME DECLARED, AND HOW TO HOLD EACH ONE FULL in a running cartridge.
    #
    # A collection is sized for the worst moment of a game: a snake's body for the whole board,
    # sixty-four bullets for the frame that needs them. Running the game measures the moment it
    # is in, which is four cells of snake and six bullets, so a game whose frame is walked item
    # by item keeps up through the whole of development and falls behind in the one session that
    # fills it. Nothing works out where that happens; the build measures it instead, with each
    # collection held at its capacity (see Profiler.survey_scenes).
    #
    # HOLDING ONE FULL is writing the numbers that say how many it holds. A list keeps its length
    # in a variable, so that is the capacity. A pool says which of its slots are live a byte each,
    # and keeps a count and a stack of the free slots beside them, so every slot is marked live,
    # the count is the capacity and the stack is empty. Its walk follows a chain through the live
    # slots in the order they were spawned, so the chain is written too, through every slot from
    # the first to the last, with no removals waiting on it. The items themselves are left as they
    # are — whatever is in memory past the ones the game put there, usually nothing, and a
    # pool's fields as declared. Every word a game can write clips what it is given rather than
    # going outside memory, so a walk over them is safe. What it is not is always the same price
    # as a walk over real items: a walk whose work depends on an item's VALUE (a test that skips
    # the item when it is nought, an item used as a loop count) measures what those values
    # cost, which can be more or less than the game would ever see.
    #
    # Only what the AUTHOR declared. The framework's own lists (a save record's buffers, a
    # canvas's pixels) are sized for exactly what they hold, and are full or empty by design.
    module FullCollections
      # One collection: +label+ is what the author wrote (`list :xs`), and +writes+ are the
      # whole words to put in memory — [address, value] — before each frame to hold it full.
      Collection = Data.define(:label, :capacity, :writes)

      # The author's collections in +record+ (a Cartridge::BuildRecord), in the order the game
      # declared them.
      def self.of(record)
        record.lists.filter_map do |name, place|
          if (pool = DSL::Pool.named_by_active_list(name))
            pool_held_full(record, pool, place)
          elsif authors?(name)
            Collection.new(label: "list #{name.inspect}", capacity: place.capacity,
                           writes: [[place.length_at, place.capacity]])
          end
        end
      end

      # Whether the author named +list+, rather than the build making it up.
      def self.authors?(list) = !list.to_s.start_with?("__") && Messages::MadeNames.read(list).nil?

      def self.pool_held_full(record, pool, active)
        count = record.var_addresses[DSL::Pool.count_var(pool)]
        free = record.lists[DSL::Pool.free_list(pool)]
        links = %i[next_list prev_list retired_list].map { |name| record.lists[DSL::Pool.public_send(name, pool)] }
        ends = %i[head_var tail_var].map { |name| record.var_addresses[DSL::Pool.public_send(name, pool)] }
        return nil unless count && free && links.all? && ends.all? # a list that only looks like a pool's column

        slots = active.capacity
        after, before, retired = links
        head, tail = ends
        none = DSL::Pool::NONE
        live = words_of(active, Array.new(slots, 1))
        chain = words_of(after, (1...slots).to_a + [none]) + words_of(before, [none] + (0...(slots - 1)).to_a)
        Collection.new(label: "pool #{pool.inspect}", capacity: slots,
                       writes: live + chain + [[count, slots], [free.length_at, 0], [retired.length_at, 0],
                                               [head, 0], [tail, slots - 1]])
      end

      # Whole-word writes that put +values+ in +list+'s slots from the first, packed as many to
      # a word as its slots are narrow. A list is padded to a whole word, so the last word's
      # spare bytes are the list's own.
      def self.words_of(list, values)
        per_word = 4 / list.bytes
        mask = (1 << (list.bytes * 8)) - 1
        values.each_slice(per_word).with_index.map do |group, word|
          packed = group.each_with_index.sum { |value, at| (value & mask) << (at * list.bytes * 8) }
          [list.base + (word * 4), packed]
        end
      end
    end
  end
end
