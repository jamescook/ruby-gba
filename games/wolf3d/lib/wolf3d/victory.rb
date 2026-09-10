# frozen_string_literal: true

module Wolf3D
  # WHAT WINNING AN EPISODE IS, which is the other way a game can stop.
  #
  # Its sibling is Lives, and deliberately so: the two are the same shape — a flag that says the
  # game has ended, words over the last picture, and START to begin another. What differs is
  # which of them you reached and what it says. Written against that shape rather than beside it
  # so the menus have one question to ask ("is a game still being played") and not two.
  #
  # WHAT ENDS AN EPISODE IS WALKING OUT OF IT, not killing the boss — see Level::EXIT. The boss
  # stands between you and a gold-locked door, and the corridor behind it is where the way out
  # lies, so the key he leaves is what killing him buys. That is the original's own arrangement
  # and it is a better fight than "the boss falls and the screen changes": you still have to get
  # past him and out.
  #
  # WHAT THIS IS NOT YET is the original's victory: the march up the screen, the text of what
  # you did, the tally of the floor. That is a screen of its own and is filed as its own piece of
  # work. This is the ending the game needs in order to HAVE one — reach the way out and the
  # episode is over rather than the lift opening onto a floor the cartridge does not hold.
  class Victory
    # White, out of the game's own 256, for words over whatever was last drawn.
    INK = 15

    # A CHANGED PICTURE IS PAINTED TWICE, because the screen keeps two pages and shows them in
    # turn. Painted once, half the frames would show the picture that was there before it. The
    # same reason Lives paints its words twice, and the same number.
    PAGES = 2

    WORDS = "EPISODE COMPLETE"
    AGAIN = "PRESS START"

    # How far above and below the eye line the two lines of words sit.
    ABOVE = 12
    BELOW = 8

    FONT = :default

    # +lives+ is who owns "the game has ended" — see Lives#ended_by_winning for why the flag is
    # kept there and not here, and why START is answered there too.
    def initialize(build:, lives:)
      @b = build
      @lives = lives
      declare
    end

    # Whether an episode has been won and is still on the screen. What the world reads to stop
    # running: winning stops the game exactly as dying does.
    def over = @won

    # WALKED OUT OF THE EPISODE. Called from the walk, on the frame the player reaches the way
    # out. Once only, so that standing on the tile does not keep re-winning it.
    def won
      (@won == 0).then do
        @won.set 1
        @todo.set PAGES
        # ...and the game has ended, which is the fact the menus and the restart both read.
        @lives.ended_by_winning
      end
    end

    # A NEW GAME PUTS THIS BACK. Called wherever one begins, alongside Lives#start_again.
    def start_again
      @won.set 0
      @todo.set 0
    end

    # ONE PASS. Nothing at all until an episode has been won, and then the words while either
    # page still wants them.
    #
    # A ROUTINE RATHER THAN CODE IN THE LOOP, for the reason Lives gives: the console's quick
    # memory holds 32K, the game loop's own body wants nearly all of it, and this is a few
    # hundred bytes that do nothing on all but a handful of passes in a whole game.
    def update = @b.call(:after_a_victory)

    private

    def declare
      @won = @b.var :episode_won, 0
      @todo = @b.var :_won_todo, 0

      @b.func(:after_a_victory, fast: false) { show_the_words }
      @b.func(:draw_the_victory) { paint }
    end

    def show_the_words
      (@todo > 0).then do
        @todo.sub 1
        @b.call(:draw_the_victory)
      end
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
