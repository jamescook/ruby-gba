# frozen_string_literal: true

module RubyGBA
  module DSL
    # A RUN OF TILES THE GAME PAINTS ITSELF, handed back by `tiles :box, from: list, count: n`.
    #
    # The pixels live in the game's own list; this is how the game says they moved. Writing
    # into the list changes nothing on screen by itself, because the screen draws its tiles
    # out of video memory, not out of the list. `changed` asks for the list to be copied there
    # in the gap before the next frame, so the player never sees a picture half copied. Saying
    # it several times in one frame is still one copy, and saying it every frame copies every
    # frame — which is what a box typing a letter a frame wants.
    class TileRun
      attr_reader :name

      def initialize(builder, name)
        @builder = builder
        @name = name
      end

      # The list's pixels show on the next frame.
      def changed
        @builder.request_tile_copy(@name)
        nil
      end
    end
  end
end
