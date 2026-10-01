# frozen_string_literal: true

module RubyGBA
  class Builder
    # EVERY `save_data` RECORD A GAME DECLARES, and the machinery behind them: the routines each
    # record is built into (SaveRecords), the table saying where each lives (SavePlaces), the
    # queue that writes saves a piece a pass (SaveJobs), and the order a half is written in
    # (SaveHalf). One object the Builder holds, rather than four add-ons sharing its insides.
    #
    # It builds program the way the Builder does — recording statements, declaring routines,
    # adding to what runs at power-on — and it asks the Builder for exactly those things
    # through a Port, which is the whole of what it knows about the Builder. The game's save
    # handles (DSL::SaveData) talk to it directly, so none of what they need sits among the
    # verbs a game writes.
    class Saves
      # WHAT THE SAVES ASK OF THE BUILDER, and nothing more: build a statement, a loop, a
      # routine, something run at power-on or once a pass, a variable; and three questions
      # about what the game declared. +handle+ is the Builder itself, for the numbers and
      # conditions (DSL::Value, DSL::Condition) the saves hand back to a game — those build
      # program through it.
      Port = Data.define(:handle, :record, :repeat, :at_boot, :ensure_var, :declare_func, :run_each_pass,
                         :start_value, :list_made, :save_var, :pool_refill)

      include SaveRecords
      include SavePlaces
      include SaveJobs
      include SaveHalf

      def initialize(port)
        @port = port
        @save_data = {}          # record name → its SaveRecords::Layout, in declaration order
        @save_data_keeping = {}  # record name → what it keeps so far, in the order kept
        @save_data_kept = {}     # a kept variable or list → the record that keeps it
        @save_data_peeks = {}    # a peek's stand-in → the SaveRecords::PeekSite it stands for
        @save_data_settled = false # true once the records are laid out, and nothing more can be kept
        @save_table = nil        # the table of places' own layout, made when the records are laid out
      end

      def records? = @save_data.any?

      # Which record keeps each thing, by the name the game declared it with: a variable, a
      # list, a pool kept whole, and :random_numbers for the stream. A pool kept a field at a
      # time is not here, because a load of it leaves which slots are live as they were.
      def keepers
        @save_data_keeping.each_with_object({}) do |(record, things), keepers|
          things.each do |thing|
            name = case thing
                   when SaveRecords::Kept then random_numbers?(thing.name) ? :random_numbers : thing.name
                   when DSL::Pool then thing.name
                   end
            keepers[name] = record if name
          end
        end
      end

      private

      def handle = @port.handle
      def record(node) = @port.record.call(node)
      def repeat(...) = @port.repeat.call(...)
      def at_boot(node) = @port.at_boot.call(node)
      def ensure_var(name) = @port.ensure_var.call(name)
      def declare_func(name, &body) = @port.declare_func.call(name, &body)
      def run_each_pass(name) = @port.run_each_pass.call(name)

      # What the game declared +name+ with, as a value node, or nil.
      def start_value(name) = @port.start_value.call(name)

      # The node that made the list +name+.
      def list_made(name) = @port.list_made.call(name)

      # Whether +name+ is a `save_var`, which saves itself.
      def save_var?(name) = @port.save_var.call(name)

      # Statements that put +pool+ back as power-on leaves it.
      def pool_refill(pool) = @port.pool_refill.call(pool)
    end

    # The verb: `save_data`. Everything behind it is the Saves object this Builder holds.
    module SaveData
      # Declare a record of the game's state, kept in save memory in +copies+ numbered copies.
      # The block, if given, names what it keeps with `keep`, and the handle's `keep` adds more
      # later. Returns a handle: `files[n]` is one copy, and a copy saves, loads, erases and
      # says whether it is good. See Saves.
      def save_data(name, copies: 1, when_busy: :wait, &block)
        saves.declare(name, copies: copies, when_busy: when_busy, &block)
      end

      # Refuse to build unless the records keep, between them, all of the game's own state:
      # every variable, list and pool it declared, and the random numbers if it rolls any.
      # +except+ names what a load must leave alone — which screen the game is on, say.
      #
      # It is for a game that saves in the middle of play. Such a save is only right while it
      # keeps everything the play depends on, and a thing added to the game later and never
      # added to a record breaks it silently: the load puts back everything else, and the
      # player finds the one thing wrong. Checked here, at the end of the build, it is a
      # friendly error the day the thing is added.
      #
      # A name that starts with _ is scratch and never needed, a `save_var` saves itself, and
      # what the framework keeps for itself (named with two underscores) is its own business.
      # A pool counts only when it is kept whole, since one field on its own leaves which
      # slots are live behind.
      def saves_keep_everything(except: [])
        if @saves_keep_everything
          raise ArgumentError, "saves_keep_everything is written two times. Write it one time, " \
                               "with every name to leave out in its except:."
        end
        left_out = Array(except)
        unless left_out.all?(Symbol)
          raise ArgumentError, "saves_keep_everything takes names in except:, like `except: [:mode, :cursor]`. " \
                               "It was given #{except.inspect}."
        end

        @saves_keep_everything = left_out
        nil
      end

      private

      # The check behind saves_keep_everything, run once every routine the game wrote is built
      # (the last place a `keep` or a declaration can come from) and before the records are
      # laid out.
      def check_saves_keep_everything!
        left_out = @saves_keep_everything or return
        unless @saves&.records?
          raise ArgumentError, "saves_keep_everything checks what the save_data records keep, but this game " \
                               "declares no save_data record. To fix this, declare one with save_data, or " \
                               "remove saves_keep_everything."
        end

        state = declared_state
        keepers = @saves.keepers
        left_out.each { |name| check_left_out!(name, state, keepers) }
        missing = state.keys - keepers.keys - left_out
        return if missing.empty?

        things = missing.map { |name| state.fetch(name) }
        things = things.one? ? things.first : "#{things[0..-2].join(', ')} or #{things.last}"
        raise ArgumentError, "saves_keep_everything: no save_data record keeps #{things}. If the game needs " \
                             "one of these after a load, keep it in a record. If it does not, add its name " \
                             "to except:."
      end

      def check_left_out!(name, state, keepers)
        if (record = keepers[name])
          raise ArgumentError, "saves_keep_everything leaves out :#{name}, but save_data :#{record} keeps it. " \
                               "To fix this, remove :#{name} from except:."
        end
        return if state.key?(name)

        scratch = name.start_with?("_") ? " A name that starts with _ is scratch, and is never needed." : ""
        raise ArgumentError, "saves_keep_everything leaves out :#{name}, but the game declares no variable, " \
                             "list or pool with that name.#{scratch} To fix this, remove :#{name} from except:."
      end

      # The game's own state, each name with the words that say what it is.
      def declared_state
        state = {}
        @variables.each_key { |name| state[name] = "the variable :#{name}" unless scratch?(name) || persisted?(name) }
        @program.walk do |node|
          state[node.name] = "the list :#{node.name}" if node.kind == :list_new && !scratch?(node.name)
        end
        declared_pools.each { |pool| state[pool.name] = "the pool :#{pool.name}" unless scratch?(pool.name) }
        state[:random_numbers] = "the random numbers (:random_numbers)" if @prng_used
        state
      end

      def scratch?(name) = name.start_with?("_")

      # Lay the records out, now that every routine the game wrote is built (see
      # SaveRecords#settle_save_data). Nothing to do for a game with no records.
      def settle_save_data = @saves&.settle_save_data

      # Put each peek's reading where the game wrote it, once the whole program is built.
      def resolve_save_data_peeks = @saves&.resolve_save_data_peeks(@program)

      def saves
        @saves ||= Saves.new(Saves::Port.new(
          handle: self, record: method(:record), repeat: method(:repeat), at_boot: method(:at_boot),
          ensure_var: method(:ensure_var), declare_func: method(:declare_func),
          run_each_pass: ->(name) { @per_pass_routines << name },
          start_value: ->(name) { @boot_inits.find { |node| node.kind == :set && node.var == name }&.value },
          # A list made where it is written is in the program; one the framework makes for
          # itself at power-on — a pool's columns — is still waiting among the power-on lines.
          list_made: lambda do |name|
            made = ->(node) { node.kind == :list_new && node.name == name }
            @program.walk.find(&made) || @boot_inits.flat_map { |node| node.walk.to_a }.find(&made)
          end,
          save_var: method(:persisted?),
          pool_refill: method(:pool_refill_nodes),
        ))
      end
    end
  end
end
