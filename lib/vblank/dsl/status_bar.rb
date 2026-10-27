# frozen_string_literal: true

module VBlank
  module DSL
    # A handle to a status bar, which `status_bar :score, ...` hands back: a strip of tiles fixed
    # to the screen from its top row down to the bottom, over a field that scrolls under it.
    #
    #   bar = status_bar :score, tiles: :hud, map: SCORE_BAR, top: screen_height - 16
    #   game_loop do
    #     bar.move_to bar.top + 3      # slides down, a few rows a frame, until it is out of view
    #     bar.set_tile 5, 0, "7"       # a digit of the score changes
    #   end
    #
    # It never scrolls: where it sits is its top row, and nothing else.
    class StatusBar
      Build = IR::Build

      # Built by the `status_bar` verb.
      #
      # @param builder [Builder] the build these operations record into
      # @param name [Symbol] the bar
      # @param top_var [Symbol] the hidden variable its top row is kept in
      # @param background [Background] the background it is drawn as, whose cells `set_tile`
      #   changes
      def initialize(builder, name:, top_var:, background:)
        @builder = builder
        @name = name
        @top_var = top_var
        @background = background
      end

      attr_reader :name

      # PUT THE BAR'S TOP AT SCREEN ROW +row+, which may be something the game works out. The
      # bar covers the screen from there to the bottom, so a row at the bottom of the screen or
      # past it puts the whole bar out of view, and a row above the top is the top.
      #
      # Like a scroll, it is shown from the gap between frames, so a game can say it anywhere
      # in a frame, as many times as it likes, and the picture never shows the bar in two
      # places at once.
      def move_to(row)
        @builder.set!(@top_var, Value.node_for(row))
        @builder.record_inline_bar_node(@builder.record_statement(Build.place_bar(@name, top: Build.var_ref(@top_var))))
        self
      end

      # The row the bar's top is at, as the game last said it, as a {Value}.
      def top = Value.new(@builder, Build.var_ref(@top_var), name: @top_var)

      # PUT A DIFFERENT TILE IN ONE CELL OF THE BAR: a digit of the score, a heart lost. The
      # same as a background's `set_tile`: +col+ and +row+ are cells of the bar's map, and the
      # tile is named the way the map was written.
      def set_tile(col, row, tile)
        @background.set_tile(col, row, tile)
        self
      end
    end
  end
end
