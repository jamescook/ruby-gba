# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # A GAME BUILT AS RUBY, IN THIS PROCESS, to be played live: the printed program and its
        # runtime made into a class of its own each time, so two games never share a thing, with
        # the live driver (runtime/rg_live.rb) as the machine it runs on.
        #
        # #play hands it whoever plays it, which is asked one thing at the end of every frame:
        #
        #   buttons_after(pixels, left, right)  the picture as the screen shows it, a 15-bit colour
        #                          a pixel, a row at a time, drawn over next frame, and the sound of
        #                          the frame just played, the left speaker's 16-bit samples and the
        #                          right's at #sound_rate; gives back the buttons held for the pass
        #                          that starts (IR::Buttons.mask), or nil to stop the play
        class LiveGame
          def initialize(source)
            @game = Class.new { class_eval(source, "(the game, as Ruby)") }.new
          end

          # The size of the picture it shows.
          def width = @game.class::RG_SCREEN_WIDTH
          def height = @game.class::RG_SCREEN_HEIGHT

          # The samples a second its sound is made at.
          def sound_rate = @game.class::RG_SOUND_RATE

          # How long one of its console's frames lasts, in seconds.
          def frame_seconds = Rational(@game.class::RG_CONSOLE_TICKS_A_FRAME, @game.class::RG_CONSOLE_TICKS_A_SECOND)

          # Plays until +player+ says stop, or the game halts or ends, and gives back the picture a
          # game that stopped itself stopped on (nil when the player stopped it). A game that does
          # something the interpreter refuses stops with IR::ProgramError, in the same words.
          def play(player)
            @game.rg_live_main(player)
          rescue @game.class::RgFault => e
            raise IR::ProgramError, e.message
          end
        end
      end
    end
  end
end
