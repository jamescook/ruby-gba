# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class Reference
        # A GAME'S OWN STATE, READ BACK BY THE NAMES THE GAME GAVE IT: a list, one field of a
        # pool, or all of it at once. The interpreter answers these, and so does a game run as C
        # (Native::HeadlessRun), from the same code — so the two answer the same question the
        # same way, in the same words when the name is wrong.
        #
        # Whoever includes this says what it holds: #list_items, a list's items oldest first by
        # its name (nil for a list it has none of); #list_names, every list's name, the
        # framework's own among them; and #variables_now, every variable by name.
        module ReadingBack
          # Read a list: everything in it now, oldest first, under the name the game declared.
          # An Array, so a test asks for an item, the length, or the whole thing as it likes.
          def list(name)
            list_items(name) or raise ArgumentError, no_such_message("list", name, declared_lists)
          end

          # Read one field of a pool: an entry per slot, the value where an instance is live and
          # nil where the slot is free, so a test can ask about the one it spawned first.
          #
          # A pool keeps each field as a list of its own, beside a column saying which slots are
          # live. Those are named after the pool, and nothing a game writes should have to know
          # how — so this is asked by pool and field, the two names the game used.
          def pool(name, field)
            live = list_items(pool_live_list(name)) or raise ArgumentError, no_such_message("pool", name, pools)
            values = list_items(Messages::MadeNames.make(:pool_field, pool: name, field: field))
            raise ArgumentError, no_such_message("field", field, pool_fields(name), of: " in pool :#{name}") if values.nil?

            values.zip(live).map { |value, up| value if up.to_i.nonzero? }
          end

          # Everything the game declared, as it stands now: each variable's value, each list
          # read the way #list reads it, and each pool field the way #pool reads it —
          #
          #   { vars: { hearts: 3 }, lists: { trail: [3, 3] }, pools: { guard: { x: [nil, 10] } } }
          #
          # Plain Hashes, so two of them compare with == and a test that compares two moments
          # compares the whole game, including whatever it declares after the test is written.
          # What the framework keeps for itself is named with two underscores and left out: it
          # is how the game is run, not what the game is.
          def game_state
            { vars: variables_now.reject { |name, _| framework_own?(name) },
              lists: declared_lists.to_h { |name| [name, list(name)] },
              pools: pools.to_h { |name| [name, pool_fields(name).to_h { |field| [field, pool(name, field)] }] } }
          end

          private

          # A pool's field is a list, and so is what the pool keeps for itself beside its fields:
          # which slots are live, which are free, the order they were spawned in. The two are
          # spelled apart (see Messages::MadeNames), so a list's name says which it is, and of
          # which pool.

          # The list saying which slots of +pool+ are live.
          def pool_live_list(pool) = Messages::MadeNames.make(:pool_part, pool: pool, part: :active)

          # The lists the game declared itself; the framework's own are named with two
          # underscores in front.
          def declared_lists = list_names.reject { |name| framework_own?(name) }

          def framework_own?(name) = name.start_with?("__")

          def pools
            list_names.filter_map do |key|
              kind, parts = Messages::MadeNames.read(key)
              parts[:pool].to_sym if kind == :pool_part && parts[:part] == "active"
            end
          end

          # The fields of +pool+.
          def pool_fields(pool)
            list_names.filter_map do |key|
              kind, parts = Messages::MadeNames.read(key)
              parts[:field].to_sym if kind == :pool_field && parts[:pool] == pool.to_s
            end
          end

          def no_such_message(what, name, there, of: "")
            listed = there.empty? ? "There are none." : "There #{there.size == 1 ? 'is' : 'are'} #{there.map { |n| ":#{n}" }.join(', ')}."
            "There is no #{what} :#{name}#{of}. #{listed}"
          end
        end
      end
    end
  end
end
