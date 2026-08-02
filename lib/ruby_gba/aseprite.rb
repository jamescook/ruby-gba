# frozen_string_literal: true

require "json"

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
    Frame = Struct.new(:x, :y, :w, :h, :duration)

    # A named animation: the frames from index +from+ to +to+ (inclusive) in the sheet.
    Tag = Struct.new(:name, :from, :to)

    # A parsed Aseprite export: the PNG filename it names, the frames in order, and the
    # named animations. +tags+ is empty when the sheet has none.
    Doc = Struct.new(:image, :frames, :tags)

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
  end
end
