# frozen_string_literal: true

module Wolf3D
  # HOW MANY GOES YOU GET, and what happens when you use one up.
  #
  # The death itself is Dying's story — turn toward what killed you, then the view dots over to
  # red — and it ends with the screen red and nothing running. This is what comes after: one life
  # comes off, and with any left the floor starts again from the top, which is what the original
  # does (wl_game.cpp, Died). With none left the game is over.
  #
  # WHAT IT DOES NOT OWN is putting the floor back. That is a great many things — where every
  # guard stands, which doors are open, which keys are still on the floor — and all of them belong
  # to the view, which is where their starting values were worked out in the first place. This
  # says WHEN, and asks for it by name.
  class Lives
    # How many goes a new game hands you, which is the original's number.
    START = 3

    # White, out of the game's own 256, for words over a red screen.
    INK = 15

    # A CHANGED PICTURE IS PAINTED TWICE, because the screen keeps two pages and shows them in
    # turn. Painted once, half the frames would show the picture that was there before it — which
    # here is a plain red screen, so the words would flicker rather than sit still.
    PAGES = 2

    WORDS = "GAME OVER"
    AGAIN = "PRESS START"

    # How far above and below the eye line the two lines of words sit.
    ABOVE = 12
    BELOW = 8

    FONT = :default

    # +dying+ may be nil: a floor with nothing on it that can kill you still shows a number of
    # lives, and never spends one. +score+ is zeroed when a new game starts, which is the one
    # thing a death does NOT do to it.
    def initialize(build:, score:, dying: nil)
      @b = build
      @score = score
      @dying = dying
      declare
    end

    # What the bar along the bottom shows.
    def left = @left

    # ONE PASS OF THE GAME LOOP, and it does nothing at all until the death has finished telling
    # its story.
    #
    # CALLED WHERE THE DEATH IS DRAWN rather than where the game is played, because that is where
    # a death finishes: the fizzle is drawing, and the pass that puts the last dot down is the
    # pass on which there is something to count.
    #
    # A ROUTINE RATHER THAN CODE IN THE LOOP, for the reason the status bar and the guards' minds
    # are: the console's quick memory holds 32K, the game loop's own body wants nearly all of it,
    # and this is a few hundred bytes that do nothing on all but a handful of passes in a whole
    # game. Written straight in it measured as a hundred bytes, which was enough to push the
    # routine that draws the guards out of that memory — and everything that routine does then
    # costs about two and a half times as much.
    def update
      @b.call(:after_a_death) if @dying
    end

    private

    # WHAT A FINISHED DEATH COMES TO, and the two arms are the whole of it. With a life left the
    # floor starts again and the death is put back to the beginning, so the test above stops being
    # true by itself. With none left there is nothing to put back, so a flag says the game is over
    # and holds it there — without one, the same finished death would take another life off on
    # every pass that followed.
    #
    # Then the words, if the game is over, over the red the fizzle left. Nothing else is being
    # drawn by then.
    def count_a_death
      (@ended == 0).then do
        @dying.finished.then do
          @left.sub 1
          (@left > 0).then { @b.call(:start_the_floor) }.else { end_the_game }
        end
      end.else { start_another_game }

      (@todo > 0).then do
        @todo.sub 1
        @b.call(:draw_the_game_over)
      end
    end

    def end_the_game
      @ended.set 1
      @todo.set PAGES
    end

    # A NEW GAME, which is the same machinery a new life is plus the two things a life does not
    # touch: the score goes back to nothing and the goes go back to three.
    def start_another_game
      @b.pressed(:start).then do
        @left.set START
        @score.set 0
        @ended.set 0
        @b.call(:start_the_floor)
      end
    end

    def declare
      @left = @b.var :lives, START
      return unless @dying

      # Whether the game has ended, and how many pages still want the words. Both start at
      # nothing: a game that has not been played cannot be over.
      @ended = @b.var :game_over, 0
      @todo = @b.var :_over_todo, 0

      lives = self
      @b.func(:after_a_death, fast: false) { lives.send(:count_a_death) }
      @b.func(:draw_the_game_over) { lives.send(:paint) }
    end

    def paint
      @b.draw_text WORDS, centred_x(WORDS), FirstPerson::HORIZON - ABOVE, colour, font: FONT
      @b.draw_text AGAIN, centred_x(AGAIN), FirstPerson::HORIZON + BELOW, colour, font: FONT
    end

    # Where a line of words starts if it is to sit in the middle of the screen.
    def centred_x(words) = (FirstPerson::ACROSS - font.text_width(words)) / 2
    def font = RubyGBA::Fonts.get(FONT)
    def colour = Palette.game[INK]
  end
end
