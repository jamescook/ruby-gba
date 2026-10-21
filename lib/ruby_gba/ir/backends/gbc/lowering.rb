# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBC
        # ONE PROGRAM, AS THE STATEMENTS A GAME BOY COLOR CARTRIDGE IS COMPILED FROM.
        #
        # It is the native lowering's own (Native::Lowering): the same STATEMENTS and VALUES tables,
        # the same semantics written down once — a `case` that reads its variable once, a `repeat`
        # that counts once, the frame counters moved where the interpreter moves them — so the
        # cartridge can only differ from the desktop build in how its runtime does a thing, which the
        # checked run finds. What the Color does with the picture and the sound is its own, and is
        # said here as it is written; until it is, a program that reaches it is refused by name
        # (NOT_LOWERED_YET), as Native refused what it could not yet write.
        class Lowering < Native::Lowering
          C = Native::C

          # EVERY KIND THIS LOWERING CANNOT MAKE YET, by what it is part of. A kind leaves the list
          # the day the Color does it; test_gbc_kind_coverage.rb holds the list to every kind.
          NOT_LOWERED_YET = Ractor.make_shareable({
            "the picture" => %i[inside camera blit blit_pose draw_column_at save_region restore_region
                                scroll_rows shade_outside set_tile show_map background_colors
                                copy_tiles copy_owed_tiles pixelate],
            "sound" => %i[play_from_list play_sound_effect play_sample stop_sample]
          })

          # The kinds the Color cannot do at all, refused in the words its answers have
          # (#refuse_color_answer_errors!): a layer seen through another.
          REFUSED = %i[see_through].freeze

          # The kinds of the picture and the sound the Color makes, which come off NOT_LOWERED_YET as
          # each is made.
          MADE = %i[screen background scroll_background present_objects pixels_overlap color_list_holds
                    clear_screen fill_rect dma_fill_rect draw_rect_at pixel draw_text draw_digit fade tint
                    affine_background
                    enable_sound beep noise wave stop_wave play_song stop_music
                    save_init save_store save_write save_erase save_read save_sum].freeze

          include Picture
          include Sound
          include Timers

          # Every variable the program keeps, by the game's name, beside the name the statements
          # call it by — so a reader of the running cartridge can find each one's place.
          def variable_names_in_statements = variable_names.to_h { |name| [name, variable(name).text] }

          # Every list, the same way.
          def list_names_in_statements = @lists.keys.to_h { |name| [name, list(name).text] }

          # The routine the cartridge starts the game with.
          def main_routine = @names.own("main").text

          # THE PROGRAM AS STATEMENTS: its variables and lists, its tables of numbers, the tables of
          # routines a call by number picks from, and every routine, the program itself last.
          def top_level
            refuse_unlowered_kinds!
            refuse_color_answer_errors!
            refuse_too_many_paint_colors!
            refuse_unsupported_save_memory!
            refuse_routines_that_call_themselves!
            routines = @called.map { |name| C::Function.new(name: routine(name), body: body_of(@funcs.fetch(name))) }
            # The timers' routines are written before the tables are gathered below, since a tick's
            # handler is what first needs some of them (a number it draws, say).
            timer_routines = timer_frame_functions
            main = C::Function.new(name: @names.own("main"), body: lower(@program), exported: true)
            [*variable_names.map { |name| C::Global.new(name: variable(name)) },
             *(@scenes.empty? ? [] : [C::Global.new(name: @names.own("scene"), value: -1)]),
             *held_colors_globals, *timer_globals, *list_storage, *constant_arrays, *@drawing_arrays,
             *routine_table_declarations, *routines, *timer_routines, main]
          end

          private

          def build_name = "the Game Boy Color build"

          # The screen is switched off from power-on until the first frame is ready (Runtime::Boot),
          # which is the interpreter's held picture, so a program says nothing to start.
          def power_on = []

          # Each statement of a body. Native paints a rebuild of its picture it owes before some of
          # them; the Color's picture is the console's own and is never rebuilt in software.
          def body_of(node) = node.children.flat_map { |child| lower(child) }

          # What is refused, as Native refuses it, said for this build: a console-only step, and a
          # kind the Color does not do yet.
          def refuse_unlowered_kinds!
            kinds = @reachable.map(&:kind).uniq
            hardware = kinds.select { |kind| Portability.hardware_only?(kind) }
            unless hardware.empty?
              raise LoweringError, "this program uses #{hardware.map(&:inspect).join(', ')}, which only means " \
                                   "something on the Game Boy Advance, so #{build_name} cannot make it."
            end

            missing = NOT_LOWERED_YET.select { |_, listed| listed.intersect?(kinds) }
            return if missing.empty?

            uses = missing.values.flatten & kinds
            raise LoweringError, "this program uses #{uses.map(&:inspect).join(', ')}, which #{build_name} cannot " \
                                 "make yet (#{missing.keys.join(', ')})."
          end

          # What a Color cannot do at all — a shoulder button, one layer seen through another, a
          # light — refused as a game's build refuses it (Guardrails::Checks::ColorAnswers, the one
          # place those answers are said). A program handed straight to the lowering, as a test's
          # is, never passes through the build's checks, and without this it would play on without
          # what it asked for.
          def refuse_color_answer_errors!
            refused = Guardrails::Checks::ColorAnswers.new.detect(@program).find { |finding| finding.severity == :error }
            raise LoweringError, refused.message if refused
          end

          # A Game Boy Color cartridge saves in 32K of battery-backed memory (Runtime::Saving): a game
          # that asks for flash, an EEPROM or more memory is refused, naming what it asked for.
          def refuse_unsupported_save_memory!
            return unless Native::Saving.named_by?(@program)

            memory = SaveLayout.memory_of(@program)
            return if memory.chip == :battery && memory.size == Runtime::Saving::SIZE

            raise LoweringError, "this game saves in #{memory.kilobytes}K of #{memory.kind_words}, and a Game Boy Color " \
                                 "cartridge saves in 32K of battery-backed memory. To fix this, leave `save_memory:` " \
                                 "out of RubyGBA.game, or say 32."
          end

          # A routine's own numbers are kept at fixed places (see Compiler), so a routine that can
          # come round to calling itself again would write over its own numbers while it still
          # needs them.
          def refuse_routines_that_call_themselves!
            calls = @called.to_h { |name| [name, routines_named(statements_under(@funcs.fetch(name))).uniq & @called] }
            @called.each do |start|
              seen = []
              waiting = calls.fetch(start).dup
              until waiting.empty?
                name = waiting.shift
                if name == start
                  raise LoweringError, "the routine #{start.inspect} can call itself again before it has finished, " \
                                       "which #{build_name} cannot make yet."
                end
                next if seen.include?(name)

                seen << name
                waiting.concat(calls.fetch(name))
              end
            end
          end
        end
      end
    end
  end
end
