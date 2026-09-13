# frozen_string_literal: true

module RubyGBA
  module IR
    module Backends
      class GBA
        # WHERE EACH SPRITE'S PICTURES GO IN SPRITE MEMORY, and how much of it a game needs.
        #
        # TWO SPRITES THAT SHOW THE SAME PICTURES STORE THEM ONCE.
        #
        # Sprite pictures live in 32K and every one a game might ever show is in there at
        # once. Nothing used to notice that two sprites were showing the same art, so a
        # game with twenty enemies all walking the same eight-frame walk stored that walk
        # twenty times — and a POOL is the same thing said in one line, since each of its
        # slots is a sprite of its own. Thirty-two slots of a four-picture guard was
        # thirty-two copies.
        #
        # Nobody asks for this and nobody can tell. The sameness is judged on the encoded
        # bytes, so two sprites drawing the same picture out of different banks of colours
        # correctly stay apart.
        #
        # Sprite memory is counted in 32-byte units whichever way a picture is stored, so
        # a picture stored the big way — 64 bytes to a tile — has to start on an even one
        # or the console would read it starting halfway through a tile. The gap that
        # leaves is at most 32 bytes and only ever appears where a small picture is
        # followed by a big one.
        class ObjectArt
          def initialize(emit)
            @emit = emit
            @units = 0        # how far the pictures have grown, in 32-byte units
            @at = {}          # encoded bytes -> the unit they were stored at
            @saved = 0        # ...and what not storing them twice came to
            @peak = 0         # the most ever needed at once: the resident art plus one scene's
            @resident_units = 0
            @resident = {}
            @scene_blobs = nil # while a scene's art is being laid out: what it has to send
          end

          # How much sprite memory the game needs at its fullest — the always-there art
          # plus the biggest single scene's, since no two scenes' pictures are wanted at
          # the same time.
          def bytes = [@units, @peak].max * 32
          attr_reader :saved

          # The always-there art is finished: remember where it ended and what it holds,
          # so every scene starts from the same place and can still share it.
          def seal_resident
            @resident_units = @units
            @resident = @at.dup
            @peak = @units
          end

          # A scene's art goes over the room the last scene's used.
          def begin_scene
            @units = @resident_units
            @at = @resident.dup
            @scene_blobs = []
          end

          # Room for a sprite that keeps one frame at a time, which is filled while the game
          # runs rather than sent: nothing is stored, and nothing can share it, since two
          # sprites showing the same pictures are not showing the same frame.
          def reserve(units, narrow:)
            @units += 1 if @units.odd? && !narrow
            at = @units
            @units += units
            at
          end

          # What the always-there art and the scene being laid out come to together, which is
          # what that scene has to fit into.
          def bytes_so_far = @units * 32

          # ...and this is what it has to send when it takes over: each blob, where it
          # goes, and how many units it is.
          def end_scene
            @peak = [@peak, @units].max
            sent = @scene_blobs
            @scene_blobs = nil
            sent
          end

          # Where this sprite's pictures are, storing them if they are new. Returns the
          # blob to upload (nil when the art is already there) and its first tile number.
          def place(name, tiles, narrow:)
            at = @at[tiles]
            if at
              @saved += tiles.bytesize
              return [nil, at]
            end

            @units += 1 if @units.odd? && !narrow
            at = @units
            @units += tiles.bytesize / 32
            @at[tiles] = at
            blob = :"__obj_tiles_#{name}"
            @emit.data_blobs[blob] = tiles
            @scene_blobs&.push([blob, at, tiles.bytesize / 32])
            [blob, at]
          end
        end
      end
    end
  end
end
