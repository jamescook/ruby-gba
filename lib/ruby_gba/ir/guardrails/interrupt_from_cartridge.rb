# frozen_string_literal: true

require RubyGBA.root.join("lib/ruby_gba/messages/plain_words").to_s

module RubyGBA
  module IR
    module Guardrails
      module Checks
        # WHAT THE AUTHOR INSISTED ON, LEAVING OUT WHAT RUNS EVERY FRAME. The routine the console
        # jumps into when the display or a timer announces something runs on every frame of every
        # screen: it plays the music and the sound effects, and it counts the frames. The build
        # weighs it for the quick memory ahead of everything it chooses for itself — but behind
        # what the author marked `fast: true`, which goes in first by promise. So a routine
        # insisted on for the sake of one moment (a save, which runs on a few passes now and then)
        # can take the room, and the routine every frame needs runs from the cartridge instead.
        #
        # Nothing showed it. The heaviest frames of play ran late, and only a test that happened
        # to play those frames found it, one screen from where the cause was written. So the build
        # says it, naming what was insisted on, since that is the line to change.
        #
        # ONLY WHERE WHAT WAS INSISTED ON TOOK THE ROOM: the insisted routines kept in the share the
        # routine missed — the whole game's, or one scene's — have to come to at least what it was
        # short by. A routine that missed on its own size, or behind what the build chose, is not
        # the author's word's doing, and naming that word would send them to the wrong line.
        class InterruptFromCartridge
          NAME = :interrupt_from_cartridge
          PLAIN_NAME = "the routine that answers the display, left out by `fast: true`"

          # The most routines the warning names, so a game that insists on many reads one line.
          NAMED = 3

          def initialize(placement)
            @placement = placement
          end

          def detect(_program)
            over = @placement&.passed_over&.find { |o| o.name == Backends::GBA::Placement::IRQ_ROUTINE } or return []
            taken = insisted_in_its_share(over)
            return [] if taken.sum { |name| @placement.sizes.fetch(name, 0) } < over.bytes - over.room

            [Finding.new(check: NAME, severity: :warning, message: message(over, taken), node: :program)]
          end

          private

          # What the author insisted on that was kept where the routine wanted to be: for the whole
          # game, or in the scene whose share it missed.
          def insisted_in_its_share(over)
            share = @placement.funcs + Array(@placement.scenes[over.scene])
            @placement.insisted.select { |name| share.include?(name) }
          end

          def message(over, taken)
            "One routine did not fit in the console's #{Messages::PlainWords::QUICK_MEMORY}. It is " \
              "#{Messages::PlainWords.routine(Backends::GBA::Placement::IRQ_ROUTINE)}. It runs on every frame of " \
              "every screen. It needs #{kilobytes(over.bytes)}, and #{kilobytes(over.room)} was free when its turn " \
              "came. Before its turn, the build put in the routines that this game marks `fast: true`: " \
              "#{named(taken)}. So it runs from the cartridge, which is about two and a half times slower. Then the " \
              "heaviest frames can run late. To fix this, remove `fast: true` from a routine that runs only now and " \
              "then. A build that measures the game then keeps that routine in the " \
              "#{Messages::PlainWords::QUICK_MEMORY} if there is room after what runs every frame."
          end

          def named(taken)
            words = taken.first(NAMED).map { |name| Messages::PlainWords.routine(name) }
            words << "and #{taken.size - NAMED} more" if taken.size > NAMED
            words.join(", ")
          end

          def kilobytes(bytes) = format("%.1fK", bytes / 1024.0)
        end
      end
    end
  end
end
