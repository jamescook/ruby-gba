# frozen_string_literal: true

require "fiddle"
require "fiddle/import"
require "json"
require "zlib"
require_relative "../lib/vblank/root"

# Regenerate lib/vblank/data/menu_font/inter-15.json — the letters the window menu is written in,
# drawn once into pictures so that no frontend needs a font library or a font file of its own: the
# desktop build, the web page and vblank run each draw a word by copying its letters out of these.
#
# The letters are Inter Regular (tools/fonts/Inter-Regular.ttf, under the SIL Open Font License,
# whose text goes with the pictures), at 15 points, drawn at two pixel densities: once for an
# ordinary screen, and once at twice the pixels each way for a Retina one, so the menu is sharp on
# both. For each density the file keeps one picture holding every letter side by side (the atlas),
# where each letter is in it and how it sits on the line, how far the pen moves after it, and the
# pairs of letters that sit closer together or further apart than that (kerning: "AV" closer).
#
# The pictures hold only how much of each pixel the letter covers, from 0 to 255; a frontend
# paints them in whatever colour the menu asks for.
#
# It draws with SDL3_ttf, through Fiddle, which only this tool needs. Run it after changing the
# letters kept or the size:
#
#   ruby tools/make_menu_font.rb
module MakeMenuFont
  FONT = VBlank.root.join("tools/fonts/Inter-Regular.ttf").to_s
  OUT = VBlank.root.join("lib/vblank/data/menu_font/inter-15.json").to_s
  POINTS = 15
  DENSITIES = [1, 2].freeze
  # The letters the menu can write: the printable ASCII, and a few more it uses.
  LETTERS = ((32..126).map(&:chr) + %w[✓ × …]).freeze
  ATLAS_WIDTH = 512 # pixels at an ordinary screen's density; twice that at twice the density
  LIBRARIES = %w[libSDL3_ttf.dylib /opt/homebrew/lib/libSDL3_ttf.dylib /usr/local/lib/libSDL3_ttf.dylib
                 libSDL3_ttf.so.0 libSDL3_ttf.so].freeze

  # SDL's ways of laying out a pixel's four bytes, and which of them is the coverage.
  ALPHA_BYTE = { 0x16362004 => 3, 0x16762004 => 3, 0x16462004 => 0, 0x16862004 => 0 }.freeze

  def self.ttf
    @ttf ||= Module.new do
      extend Fiddle::Importer
      found = LIBRARIES.find do |name|
        Fiddle.dlopen(name).close
        true
      rescue Fiddle::DLError
        false
      end
      raise "This tool needs SDL3_ttf. On macOS, run `brew install sdl3_ttf`." unless found

      dlload found
      extern "char TTF_Init()"
      extern "void* TTF_OpenFont(const char*, float)"
      extern "void TTF_CloseFont(void*)"
      extern "int TTF_GetFontHeight(void*)"
      extern "int TTF_GetFontAscent(void*)"
      extern "char TTF_FontHasGlyph(void*, unsigned int)"
      extern "void* TTF_GetGlyphImage(void*, unsigned int, void*)"
      extern "char TTF_GetGlyphMetrics(void*, unsigned int, void*, void*, void*, void*, void*)"
      extern "void* TTF_CreateText(void*, void*, const char*, size_t)"
      extern "char TTF_GetTextSubString(void*, int, void*)"
      extern "void TTF_DestroyText(void*)"
      extern "void SDL_DestroySurface(void*)"
    end
  end

  def self.run
    ttf.TTF_Init
    densities = DENSITIES.to_h { |density| [density.to_s, at_density(density)] }
    data = { "font" => "Inter Regular 4.1", "license" => "Inter-LICENSE.txt", "points" => POINTS,
             "letters" => LETTERS.join, "densities" => densities }
    File.write(OUT, "#{JSON.pretty_generate(data)}\n")
    puts "Wrote #{OUT}."
  end

  def self.at_density(density)
    font = ttf.TTF_OpenFont(FONT, (POINTS * density).to_f)
    raise "SDL3_ttf cannot open #{FONT}." if font.null?

    images = LETTERS.to_h { |letter| [letter, glyph(font, letter)] }
    advances, kerning = pen_moves(font, images.transform_values { |image| image[:left] })
    atlas_width = ATLAS_WIDTH * density
    glyphs, atlas_height = place(images, atlas_width)
    alpha = "\0".b * (atlas_width * atlas_height)
    images.each do |letter, image|
      x, y = glyphs[letter]
      image[:rows].each_with_index { |row, dy| alpha[((y + dy) * atlas_width) + x, row.bytesize] = row }
    end
    { "line_height" => ttf.TTF_GetFontHeight(font), "atlas_width" => atlas_width, "atlas_height" => atlas_height,
      "alpha" => [Zlib::Deflate.deflate(alpha, Zlib::BEST_COMPRESSION)].pack("m0"),
      "glyphs" => images.to_h do |letter, image|
        [letter, [*glyphs[letter], image[:width], image[:height], image[:left], image[:top], advances[letter]]]
      end,
      "kerning" => kerning }
  ensure
    ttf.TTF_CloseFont(font) if font && !font.null?
  end

  # One letter's picture, as rows of coverage bytes, and where it sits: +left+ pixels right of the
  # pen and +top+ pixels below the top of the line. How far the pen then goes is #pen_moves's.
  def self.glyph(font, letter)
    code = letter.ord
    raise "Inter has no #{letter.inspect}." if ttf.TTF_FontHasGlyph(font, code).zero?

    minx, _maxx, _miny, maxy, = metrics(font, letter)
    rows = []
    width = height = 0
    unless letter == " "
      surface = ttf.TTF_GetGlyphImage(font, code, nil)
      raise "SDL3_ttf cannot draw #{letter.inspect}." if surface.null?

      rows, width, height = coverage(surface)
      ttf.SDL_DestroySurface(surface)
    end
    { rows: rows, width: width, height: height, left: minx, top: ttf.TTF_GetFontAscent(font) - maxy }
  end

  # The surface's pixels as rows of coverage, one byte a pixel.
  def self.coverage(surface)
    format, width, height, pitch = surface[4, 16].unpack("L4")
    at = ALPHA_BYTE.fetch(format) { raise "SDL3_ttf drew a letter in pixel format #{format.to_s(16)}, which this tool cannot read." }
    pixels = Fiddle::Pointer.new(surface[24, 8].unpack1("Q"))
    rows = Array.new(height) do |y|
      row = pixels[y * pitch, width * 4]
      (0...width).map { |x| row.getbyte((x * 4) + at) }.pack("C*")
    end
    [rows, width, height]
  end

  # Where each letter goes in the atlas: in rows, left to right, a pixel apart so no letter bleeds
  # into the next when a frontend scales them. Gives the places and the atlas's height.
  def self.place(images, atlas_width)
    x = y = 1
    row_height = 0
    places = images.to_h do |letter, image|
      if x + image[:width] + 1 > atlas_width
        x = 1
        y += row_height + 1
        row_height = 0
      end
      place = [x, y]
      x += image[:width] + 1
      row_height = [row_height, image[:height]].max
      [letter, place]
    end
    [places, y + row_height + 1]
  end

  # HOW FAR THE PEN GOES AFTER EACH LETTER, and the pairs of letters the font sets closer or
  # further apart than that (kerning), in pixels. Inter keeps its kerning in the part of the font a
  # text shaper reads (its GPOS table), not the older table a single pair can be asked of, and the
  # width a letter is laid out with is not quite the one its metrics say, so both are read from
  # text laid out by SDL3_ttf: every pair, and where the second letter of it starts. After most
  # letters it starts at the same place whatever the second is: that is the first letter's
  # width. A pair whose second letter starts elsewhere is kerned, by the difference.
  #
  # A space is the exception: SDL3_ttf leaves out a space a text starts with, and a space has no
  # ink to place, so its width is its metrics' and no pair with a space in it is kerned.
  def self.pen_moves(font, lefts)
    substring = Fiddle::Pointer.malloc(SUBSTRING_BYTES, Fiddle::RUBY_FREE)
    inked = LETTERS - [" "]
    starts = inked.to_h do |first|
      [first, inked.to_h do |second|
        pair = first + second
        text = ttf.TTF_CreateText(nil, font, pair, pair.bytesize)
        ttf.TTF_GetTextSubString(text, first.bytesize, substring)
        ttf.TTF_DestroyText(text)
        [second, substring[SUBSTRING_X_AT, 4].unpack1("l") - lefts.fetch(second)]
      end]
    end
    advances = starts.transform_values { |after| after.values.tally.max_by { |_, count| count }.first }
    advances[" "] = space_width(font)
    kerning = starts.each_with_object({}) do |(first, after), pairs|
      after.each { |second, at| pairs[first + second] = at - advances[first] unless at == advances[first] }
    end
    [advances, kerning]
  end

  def self.space_width(font) = metrics(font, " ").last

  # A letter's measures, as SDL3_ttf gives them: the left, right, bottom and top of its ink from
  # the pen and the line it sits on, and how far its metrics say the pen moves after it.
  def self.metrics(font, letter)
    out = Fiddle::Pointer.malloc(20, Fiddle::RUBY_FREE)
    ttf.TTF_GetGlyphMetrics(font, letter.ord, out, out + 4, out + 8, out + 12, out + 16)
    out[0, 20].unpack("l5")
  end

  # A TTF_SubString: five ints (its flags, where it starts, how long, its line and its cluster),
  # then the rectangle it takes up, whose x is where it starts across.
  SUBSTRING_BYTES = 36
  SUBSTRING_X_AT = 20
end

MakeMenuFont.run if $PROGRAM_NAME == __FILE__
