# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # Func bodies live after the main code. A leading endless loop guards against
        # the main flow running off its end into the first body. Each func saves the
        # return address and restores it as the program counter.
        #
        # The routines that stay in the cartridge. The ones chosen to run from the
        # console's quick memory are emitted separately, as one block (see
        # {Placement}#emit_hot_functions), because that block is copied wholesale —
        # #placement answers which, and #emit_one_function is what emits either kind.
        class Functions
          # +modes+ is the IR::Modes result GBA#resolve_modes builds each #lower — not
          # known at construction, so it's set afterward with #modes= rather than
          # passed in here. +scene_preamble+ is Drawing's own #emit_scene_preamble,
          # handed in as a bound method rather than a reference to Drawing as a whole.
          def initialize(emitter:, lowering:, placement:, scene_preamble:, scene_art:)
            @emitter = emitter
            @lowering = lowering
            @placement = placement
            @scene_preamble = scene_preamble
            @scene_art = scene_art
            @modes = nil
            @funcs = {}
            @func_ranges = {}
          end

          attr_writer :modes
          attr_reader :funcs, :func_ranges

          def emit_functions
            cold = @funcs.reject { |name, _| @placement.fast_funcs.include?(name) }
            return if cold.empty?

            @emitter.emit(ASM.loop_forever) # fall-through guard
            cold.each { |name, fnode| emit_one_function(name, fnode) }
          end

          # One routine: save the return address, run the body, return. Shared by both
          # places routines are emitted, so where a routine lives cannot change what it
          # does.
          def emit_one_function(name, fnode)
            start = @emitter.pos
            @emitter.place_label(func_label(name))
            @emitter.emit(ASM.push(14))                          # push {lr}
            # Draws in this func lower in its resolved mode; a scene (a per-frame
            # entry point) also switches the hardware to that mode as it takes over.
            @lowering.in_mode(@modes.func_mode.fetch(name, @modes.default_mode)) do
              if @modes.scene_funcs.include?(name)
                @scene_preamble.call(name) if manage_modes?
                # ...and its own sprite pictures, which scenes share the room for, so a
                # scene taking over sends its own and one already running sends nothing.
                @scene_art.call(name)
              end
              fnode.children.each { |stmt| @lowering.statement(stmt) }
            end
            @emitter.emit(ASM.pop(15))                           # pop {pc}  (return)
            @func_ranges[name] = (start...@emitter.pos)          # byte span, for dump_func
          end

          def func_label(name)
            "func_#{name}"
          end

          # Multi-way dispatch lowers to one "if the variable equals this value, call
          # that scene" per clause — reusing the ordinary if/compare/call path. Each
          # comparison reloads from memory itself, so a scene call is free to clobber
          # every register without disturbing the dispatch.
          #
          # WHICH IS WHY THE VALUE IS COPIED ASIDE FIRST, and it is the whole of this
          # method. Reloading is right; reloading THE STATE VARIABLE would not be, because
          # the scene that just ran is usually the thing that changes it. A title screen
          # sets the state to the menu and returns, and the next comparison would ask "is
          # it the menu?", find that it is, and run the menu too — in the same pass, on the
          # same snapshot of the pad, so the menu answers the press that left the title.
          # Every clause past the one that ran is another scene the player never asked for,
          # and a game numbers its screens in the order they are met, so an ordinary
          # transition goes forward and falls the length of the table.
          #
          # Nothing a scene does can reach the copy, so the clauses all answer the state as
          # it was when the dispatch was reached and exactly one runs. That is what running
          # a scene per frame means, and it is what the interpreter does — it reads the
          # variable once and compares each clause against that reading.
          def emit_case(node)
            picked = :"_picked_#{node.var}"
            @lowering.statement(Build.copy(picked, node.var))
            node.clauses.each do |value, target|
              test = Build.binop(:==, Build.var_ref(picked), Build.int(value))
              @lowering.statement(Build.if_(test, Build.call(target)))
            end
          end

          private

          # Whether the display is switched centrally on a scene's entry — true once
          # any scene double-buffers or the program crosses the bitmap/tiled boundary.
          # A single-display-system program leaves each `screen` node to write DISPCNT
          # inline instead, so a scene never needs a preamble of its own.
          def manage_modes? = @modes.any_buffered? || @modes.mixed_display?
        end
      end
    end
  end
end
