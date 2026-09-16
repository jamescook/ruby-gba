# frozen_string_literal: true

require "json"
require "zlib"

module RubyGBA
  # Read an Aseprite sprite-sheet export — the way pixel artists actually author sprites.
  #
  # Aseprite's "Export Sprite Sheet" writes a packed PNG plus a JSON data file. The JSON
  # is what makes it worth more than a blind grid slice: it carries the exact rectangle of
  # every frame in the sheet, each frame's duration, and — the real value — the artist's
  # NAMED animations (frameTags), like "walk" or "attack". This turns "cut the sheet into
  # a grid and hope the order matches" into "play the animations the artist defined."
  #
  # This module PARSES a JSON export into plain data (RubyGBA::Aseprite::Doc), and reads the
  # native .aseprite binary straight into decoded frames (RubyGBA::Aseprite::Sprite). Turning
  # either into sprite frames is the builder's job (see Builder#sprite `from_aseprite:`).
  module Aseprite
    # One frame's rectangle in the packed sheet, plus how long it shows (milliseconds).
    Frame = Data.define(:x, :y, :w, :h, :duration)

    # A named animation: the frames from index +from+ to +to+ (inclusive) in the sheet.
    Tag = Data.define(:name, :from, :to)

    # A parsed Aseprite export: the PNG filename it names, the frames in order, and the
    # named animations. +tags+ is empty when the sheet has none.
    Doc = Data.define(:image, :frames, :tags)

    # A decoded frame: its pixels (console colors, row-major, see-through pixels marked),
    # its size, and how long it shows.
    FrameImage = Data.define(:width, :height, :data, :transparent, :duration)

    # The whole decoded sprite: frames (in order) and named animations.
    Sprite = Data.define(:frames, :tags)

    # Aseprite defaults a frame with no stated time to 100 ms.
    DEFAULT_DURATION_MS = 100

    module_function

    # Parse the text of an Aseprite JSON data file into a {Doc}. Handles both export
    # layouts: "frames" as an Array, or as a Hash keyed by frame name (both list the
    # frames in play order). Raises {ArgumentError} with a plain-language message when the
    # text is not the JSON an Aseprite export produces.
    def parse(text)
      data = JSON.parse(text)
      unless data.is_a?(Hash) && data.key?("frames")
        raise ArgumentError, "This is not an Aseprite JSON export. It has no \"frames\". " \
                             "Export the sprite sheet from Aseprite with the JSON data option on."
      end

      meta = data["meta"] || {}
      Doc.new(meta["image"], parse_frames(data["frames"]), parse_tags(meta["frameTags"]))
    rescue JSON::ParserError => e
      raise ArgumentError, "This Aseprite file is not valid JSON. #{e.message}"
    end

    # The frames in order. An Array export lists them directly; a Hash export keys each by
    # its name, and Ruby keeps a Hash in insertion order, which Aseprite writes in frame
    # order — so the values are already the play order.
    def parse_frames(frames)
      list = frames.is_a?(Array) ? frames : frames.values
      list.map do |entry|
        rect = entry.fetch("frame")
        Frame.new(rect["x"], rect["y"], rect["w"], rect["h"], entry["duration"] || DEFAULT_DURATION_MS)
      end
    end

    # The named animations (frameTags), or an empty list when the sheet has none.
    def parse_tags(tags)
      (tags || []).map { |tag| Tag.new(tag.fetch("name").to_sym, tag.fetch("from"), tag.fetch("to")) }
    end

    # Decode the native binary (.aseprite / .ase) bytes into a {Sprite} — every frame
    # composited flat, plus the named animations. No export step. See {Decoder}.
    def load_binary(bytes)
      Decoder.new(bytes).sprite
    end

    # Reads Aseprite's own binary format directly. A .aseprite file is a 128-byte header,
    # then one block per frame, each a list of chunks (the layers, the drawn cels, the
    # palette, the named tags); a cel's pixels are usually zlib-compressed. The decoder holds
    # the shared decode state — the raw bytes, the sprite's size and color depth, its palette,
    # and its layers — as instance state, so the per-cel work reads it from here instead of
    # threading it through every call. Field layouts follow the published Aseprite file spec.
    class Decoder
      ASE_MAGIC = 0xA5E0
      NEW_PALETTE = 0x2019
      TAGS = 0x2018
      LAYER = 0x2004
      CEL = 0x2005

      def initialize(bytes)
        unless bytes.bytesize > 128 && bytes.byteslice(4, 2).unpack1("v") == ASE_MAGIC
          raise ArgumentError, "This is not an .aseprite file (its header is missing the Aseprite marker)."
        end

        @bytes = bytes
        @width = u16(8)
        @height = u16(10)
        @depth = u16(12)                 # 32 = RGBA, 16 = grayscale, 8 = indexed
        @transparent_index = bytes.getbyte(28)
        @palette = []                    # index -> [r, g, b, a], filled by a palette chunk
        @layers = []                     # index -> { visible, blend, opacity, type }
        @cels = {}                       # [frame, layer] -> a decoded cel, so a linked cel can copy it
      end

      # The whole sprite: each frame composited to a flat image, plus the named animations.
      def sprite
        frames = []
        tags = []
        offset = 128
        u16(6).times do |frame_index|
          canvas = Array.new(@width * @height) # a console color per pixel; nil stays see-through
          chunk = offset + 16
          chunk_count(offset).times do
            size = u32(chunk)
            data = chunk + 6
            case u16(chunk + 4)
            when NEW_PALETTE then read_palette(data)
            when TAGS then tags = read_tags(data)
            when LAYER then @layers << read_layer(data)
            when CEL then paint_cel(data: data, data_len: size - 6, canvas: canvas, frame_index: frame_index)
            end
            chunk += size
          end
          frames << FrameImage.new(@width, @height, canvas.map { |color| color || Image::TRANSPARENT },
                                   Image::TRANSPARENT, u16(offset + 8))
          offset += u32(offset) # bytes in this frame
        end
        Sprite.new(frames, tags)
      end

      private

      # How many chunks a frame has: the new 32-bit count when it is set, else the old 16-bit one.
      def chunk_count(offset)
        new_count = u32(offset + 12)
        new_count.positive? ? new_count : u16(offset + 6)
      end

      # Paint one cel onto the frame's canvas. A cel is one layer's picture for this frame.
      # Later layers (higher index) come after and draw on top. A hidden layer draws nothing;
      # a partly-transparent layer or cel is blended over what is already there. A blend mode
      # other than Normal, or a tilemap cel, is a friendly error — flatten those in Aseprite.
      def paint_cel(data:, data_len:, canvas:, frame_index:)
        layer = u16(data)
        info = @layers[layer]
        return if info && !info[:visible] # a hidden layer contributes nothing

        if info && info[:blend].positive?
          raise ArgumentError, "This sprite has a layer with a blend mode other than Normal, which is not " \
                               "supported yet. Set the layer to Normal, or flatten it, in Aseprite."
        end

        cel_opacity = @bytes.getbyte(data + 6)
        cel_type = u16(data + 7)
        if cel_type == 3
          raise ArgumentError, "This sprite has a tilemap layer, which is not supported yet. " \
                               "Flatten it in Aseprite (Layer, then Flatten)."
        end

        cel = read_cel(data: data, data_len: data_len, cel_type: cel_type, layer: layer)
        return unless cel

        @cels[[frame_index, layer]] = cel
        opacity = info ? (info[:opacity] * cel_opacity) / 255 : cel_opacity
        blit_cel(cel: cel, canvas: canvas, opacity: opacity)
      end

      # A cel's placed pixels: raw (type 0), zlib-compressed (type 2), or a link to an earlier
      # frame's cel for the same layer (type 1).
      def read_cel(data:, data_len:, cel_type:, layer:)
        rest = data_len - 20
        case cel_type
        when 0 then { x: s16(data + 2), y: s16(data + 4), w: u16(data + 16), h: u16(data + 18), pixels: @bytes[data + 20, rest] }
        when 2 then { x: s16(data + 2), y: s16(data + 4), w: u16(data + 16), h: u16(data + 18), pixels: Zlib::Inflate.inflate(@bytes[data + 20, rest]) }
        when 1 then @cels[[u16(data + 16), layer]]
        end
      end

      # Copy a cel's non-transparent pixels onto the canvas at its position, clipping anything
      # off the edges. At full opacity a pixel replaces what is below; below full it is blended
      # over the pixel already there (or, over nothing, drawn as-is — the console has no partial
      # transparency in the flattened frame).
      def blit_cel(cel:, canvas:, opacity:)
        per = @depth / 8
        cel[:h].times do |row|
          cel[:w].times do |col|
            color = pixel_color(cel[:pixels], ((row * cel[:w]) + col) * per)
            next if color.nil?

            px = cel[:x] + col
            py = cel[:y] + row
            next unless px.between?(0, @width - 1) && py.between?(0, @height - 1)

            at = (py * @width) + px
            below = canvas[at]
            canvas[at] = opacity >= 255 || below.nil? ? color : blend15(color, below, opacity)
          end
        end
      end

      # One pixel's console color, or nil when it is see-through. Indexed pixels look up the
      # palette (the transparent index is see-through); RGBA and grayscale carry their own
      # alpha (zero alpha is see-through).
      def pixel_color(pixels, at)
        case @depth
        when 8
          index = pixels.getbyte(at)
          return nil if index == @transparent_index

          r, g, b, = @palette[index]
          Color.rgb8(r, g, b)
        when 32
          return nil if pixels.getbyte(at + 3).zero?

          Color.rgb8(pixels.getbyte(at), pixels.getbyte(at + 1), pixels.getbyte(at + 2))
        when 16
          return nil if pixels.getbyte(at + 1).zero?

          value = pixels.getbyte(at)
          Color.rgb8(value, value, value)
        end
      end

      # Read a palette chunk into @palette (index -> [r, g, b, a]); assignment grows the array.
      def read_palette(data)
        last = u32(data + 8)
        entry = data + 20
        (u32(data + 4)..last).each do |index|
          flags = u16(entry)
          @palette[index] = [@bytes.getbyte(entry + 2), @bytes.getbyte(entry + 3), @bytes.getbyte(entry + 4), @bytes.getbyte(entry + 5)]
          entry += 6
          entry += 2 + u16(entry) if flags.anybits?(1) # skip the optional entry name
        end
      end

      # A layer's drawing properties from a layer chunk: whether it is visible, its blend mode
      # (0 = Normal), and its opacity (0-255).
      def read_layer(data)
        { visible: u16(data).anybits?(1), type: u16(data + 2), blend: u16(data + 10), opacity: @bytes.getbyte(data + 12) }
      end

      # Read a tags chunk (the named animations). Each tag record is 17 fixed bytes (from, to,
      # direction, repeat, reserved, deprecated color, an extra byte) then a name.
      def read_tags(data)
        tag = data + 10 # 2 count + 8 reserved
        Array.new(u16(data)) do
          from = u16(tag)
          to = u16(tag + 2)
          name_len = u16(tag + 17)
          name = @bytes[tag + 19, name_len]
          tag += 19 + name_len
          Tag.new(name.to_sym, from, to)
        end
      end

      # Blend +src+ over +dst+ (both 15-bit BGR555) by +opacity+ (0-255), channel by channel.
      def blend15(src, dst, opacity)
        inv = 255 - opacity
        r = (((src & 0x1F) * opacity) + ((dst & 0x1F) * inv)) / 255
        g = ((((src >> 5) & 0x1F) * opacity) + (((dst >> 5) & 0x1F) * inv)) / 255
        b = ((((src >> 10) & 0x1F) * opacity) + (((dst >> 10) & 0x1F) * inv)) / 255
        (b << 10) | (g << 5) | r
      end

      def u16(at) = @bytes.byteslice(at, 2).unpack1("v")
      def u32(at) = @bytes.byteslice(at, 4).unpack1("V")
      def s16(at) = @bytes.byteslice(at, 2).unpack1("s<")
    end
  end
end
