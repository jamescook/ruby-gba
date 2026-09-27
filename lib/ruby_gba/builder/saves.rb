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
                         :start_value, :list_made, :save_var)

      include SaveRecords
      include SavePlaces
      include SaveJobs
      include SaveHalf

      def initialize(port)
        @port = port
        @save_data = {}      # record name → its SaveRecords::Layout, in declaration order
        @save_data_kept = {} # a kept variable or list → the record that keeps it
        @save_table = nil    # the table of places' own layout, made with the first record
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
    end

    # The verb: `save_data`. Everything behind it is the Saves object this Builder holds.
    module SaveData
      # Declare a record of the game's state, kept in save memory in +copies+ numbered copies.
      # The block names what it keeps, with `keep`. Returns a handle: `files[n]` is one copy,
      # and a copy saves, loads, erases and says whether it is good. See Saves.
      def save_data(name, copies: 1, when_busy: :wait, &block)
        saves.declare(name, copies: copies, when_busy: when_busy, &block)
      end

      private

      def saves
        @saves ||= Saves.new(Saves::Port.new(
          handle: self, record: method(:record), repeat: method(:repeat), at_boot: method(:at_boot),
          ensure_var: method(:ensure_var), declare_func: method(:declare_func),
          run_each_pass: ->(name) { @per_pass_routines << name },
          start_value: ->(name) { @boot_inits.find { |node| node.kind == :set && node.var == name }&.value },
          list_made: ->(name) { @program.walk.find { |node| node.kind == :list_new && node.name == name } },
          save_var: method(:persisted?),
        ))
      end
    end
  end
end
