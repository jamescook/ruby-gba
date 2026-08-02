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
  # This module only PARSES the JSON into plain data (RubyGBA::Aseprite::Doc). Slicing the
  # PNG by those rectangles and building sprite frames from them is the builder's job (see
  # Builder#sprite `from_aseprite:`), the same split as the other sheet importers.
  module Aseprite
    # One frame's rectangle in the packed sheet, plus how long it shows (milliseconds).
    Frame = Data.define(:x, :y, :w, :h, :duration)

    # A named animation: the frames from index +from+ to +to+ (inclusive) in the sheet.
    Tag = Data.define(:name, :from, :to)

    # A parsed Aseprite export: the PNG filename it names, the frames in order, and the
    # named animations. +tags+ is empty when the sheet has none.
    Doc = Data.define(:image, :frames, :tags)

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

    # --- reading the native binary (.aseprite / .ase) directly ---
    #
    # An .aseprite file is Aseprite's own binary format: a 128-byte header, then one block
    # per frame, each a list of chunks (the layers, the drawn cels, the palette, the named
    # tags). Reading it here means a game can point straight at the file the artist saves —
    # no export step. The layout below follows the published Aseprite file spec.

    # A decoded frame: its pixels (console colors, row-major, see-through pixels marked),
    # its size, and how long it shows.
    FrameImage = Data.define(:width, :height, :data, :transparent, :duration)

    # The whole decoded sprite: frames (in order) and named animations.
    Sprite = Data.define(:frames, :tags)

    ASE_MAGIC = 0xA5E0
    FRAME_MAGIC = 0xF1FA
    NEW_PALETTE = 0x2019
    TAGS = 0x2018
    CEL = 0x2005

    # Decode the bytes of an .aseprite file into a {Sprite}: every frame composited to a
    # flat image, and the named animations. Raises {ArgumentError} on a file that is not an
    # Aseprite binary.
    def load_binary(bytes)
      unless bytes.bytesize > 128 && u16(bytes, 4) == ASE_MAGIC
        raise ArgumentError, "This is not an .aseprite file (its header is missing the Aseprite marker)."
      end

      width = u16(bytes, 8)
      height = u16(bytes, 10)
      depth = u16(bytes, 12)
      transparent_index = bytes.getbyte(28)
      palette = []                # index -> [r, g, b, a], filled by a palette chunk
      tags = []
      cels = {}                   # [frame, layer] -> a decoded cel, so a linked cel can copy it
      frames = []

      offset = 128
      u16(bytes, 6).times do |frame_index|
        frame_size = u32(bytes, offset)
        new_chunks = u32(bytes, offset + 12)
        chunk_count = new_chunks.positive? ? new_chunks : u16(bytes, offset + 6)
        canvas = Array.new(width * height) # a console color per pixel; nil stays see-through

        chunk = offset + 16
        chunk_count.times do
          size = u32(bytes, chunk)
          data = chunk + 6
          case u16(bytes, chunk + 4)
          when NEW_PALETTE then palette = read_palette(bytes, data)
          when TAGS then tags = read_binary_tags(bytes, data)
          when CEL then paint_cel(bytes, data, size - 6, canvas, width, height, depth, palette, transparent_index, cels, frame_index)
          end
          chunk += size
        end

        frames << FrameImage.new(width, height, canvas.map { |color| color || Image::TRANSPARENT },
                                 Image::TRANSPARENT, u16(bytes, offset + 8))
        offset += frame_size
      end

      Sprite.new(frames, tags)
    end

    # Paint one cel onto the frame's canvas. A cel is one layer's picture for this frame,
    # placed at (x, y). Later layers (higher index) come after and draw on top. A compressed
    # cel (type 2) is zlib-deflated; a linked cel (type 1) reuses an earlier frame's cel.
    def paint_cel(bytes, data, data_len, canvas, width, height, depth, palette, transparent_index, cels, frame_index)
      layer = u16(bytes, data)
      x = s16(bytes, data + 2)
      y = s16(bytes, data + 4)
      cel_type = u16(bytes, data + 7)

      cel =
        case cel_type
        when 0 then { x: x, y: y, w: u16(bytes, data + 16), h: u16(bytes, data + 18), pixels: bytes[data + 20, data_len - 20] }
        when 2 then { x: x, y: y, w: u16(bytes, data + 16), h: u16(bytes, data + 18), pixels: Zlib::Inflate.inflate(bytes[data + 20, data_len - 20]) }
        when 1 then cels[[u16(bytes, data + 16), layer]]
        end
      return unless cel

      cels[[frame_index, layer]] = cel
      blit_cel(cel, canvas, width, height, depth, palette, transparent_index)
    end

    # Copy a cel's non-transparent pixels onto the canvas at its position, clipping anything
    # off the edges.
    def blit_cel(cel, canvas, width, height, depth, palette, transparent_index)
      per = depth / 8
      cel[:h].times do |row|
        cel[:w].times do |col|
          color = pixel_color(cel[:pixels], ((row * cel[:w]) + col) * per, depth, palette, transparent_index)
          next if color.nil?

          px = cel[:x] + col
          py = cel[:y] + row
          canvas[(py * width) + px] = color if px.between?(0, width - 1) && py.between?(0, height - 1)
        end
      end
    end

    # One pixel's console color, or nil when it is see-through. Indexed pixels look up the
    # palette (the transparent index is see-through); RGBA and grayscale carry their own
    # alpha (zero alpha is see-through).
    def pixel_color(pixels, at, depth, palette, transparent_index)
      case depth
      when 8
        index = pixels.getbyte(at)
        return nil if index == transparent_index

        r, g, b, = palette[index]
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

    # Read a palette chunk into an index -> [r, g, b, a] table.
    def read_palette(bytes, data)
      last = u32(bytes, data + 8)
      palette = Array.new(last + 1)
      entry = data + 20
      (u32(bytes, data + 4)..last).each do |index|
        flags = u16(bytes, entry)
        palette[index] = [bytes.getbyte(entry + 2), bytes.getbyte(entry + 3), bytes.getbyte(entry + 4), bytes.getbyte(entry + 5)]
        entry += 6
        entry += 2 + u16(bytes, entry) if flags.anybits?(1) # skip the optional entry name
      end
      palette
    end

    # Read a binary tags chunk (the named animations). Each tag record is 17 fixed bytes
    # (from, to, direction, repeat, reserved, deprecated color, an extra byte) then a name.
    def read_binary_tags(bytes, data)
      tag = data + 10 # 2 count + 8 reserved
      Array.new(u16(bytes, data)) do
        from = u16(bytes, tag)
        to = u16(bytes, tag + 2)
        name_len = u16(bytes, tag + 17)
        name = bytes[tag + 19, name_len]
        tag += 19 + name_len
        Tag.new(name.to_sym, from, to)
      end
    end

    def u16(bytes, at) = bytes.byteslice(at, 2).unpack1("v")
    def u32(bytes, at) = bytes.byteslice(at, 4).unpack1("V")
    def s16(bytes, at) = bytes.byteslice(at, 2).unpack1("s<")
  end
end
