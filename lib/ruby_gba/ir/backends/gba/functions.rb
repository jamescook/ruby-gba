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
          def initialize(emitter:, lowering:, placement:, scene_preamble:)
            @emitter = emitter
            @lowering = lowering
            @placement = placement
            @scene_preamble = scene_preamble
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
              @scene_preamble.call(name) if manage_modes? && @modes.scene_funcs.include?(name)
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
          # comparison reloads the variable from memory itself, so a scene call is free
          # to clobber every register without disturbing the dispatch.
          def emit_case(node)
            node.clauses.each do |value, target|
              test = Build.binop(:==, Build.var_ref(node.var), Build.int(value))
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
