# frozen_string_literal: true

require "zlib"

require_relative "../lib/ruby_gba"
require_relative "preview"

# Generate the PNG art the `sheet` importer example reads (examples/sheet.rb).
#
# The point of the asset pipeline is that art is DRAWN in a normal image tool and
# imported — but the examples still need a couple of real PNGs checked in to import.
# Rather than commit opaque binaries with no history, this script draws them from
# plain pixel data so anyone can see (and change) exactly what they contain, then
# re-run it to regenerate the files:
#
#   ruby tools/make_example_assets.rb
#
# It writes two sheets and a level map under examples/assets/:
#   - tiles.png  — a 2-cell tile sheet: an 8x8 brick, then an 8x8 floor.
#   - hero.png   — a 4-frame sprite sheet: 16x16 walk frames on a see-through
#                  (alpha) background, so the imported sprite is a cut-out.
#   - level.csv  — a tilemap the way a map editor (like Tiled) exports one: a grid
#                  of tile numbers (1 = brick from the sheet, 2 = floor, 0 = empty),
#                  imported by examples/level.rb via `background from:`.
module MakeExampleAssets
  Color = RubyGBA::Color

  ASSETS = File.expand_path("../examples/assets", __dir__)

  # The room examples/level.rb draws, authored here as ASCII (a wall border around
  # open floor, with a few pillars) and written out as a CSV of tile numbers. It's the
  # same 30x20 room shape as examples/sheet.rb — the point of the pair is that the map
  # can be an inline text grid OR a file exported from an editor.
  LEVEL = [
    "##############################",
    "#............................#",
    "#............................#",
    "#......####........####......#",
    "#......####........####......#",
    "#............................#",
    "#............................#",
    "#............................#",
    "#............####............#",
    "#............####............#",
    "#............####............#",
    "#............................#",
    "#............................#",
    "#......####........####......#",
    "#......####........####......#",
    "#............................#",
    "#............................#",
    "#............................#",
    "#............................#",
    "##############################",
  ].freeze

  # --- palette (5-bit-per-channel console colors) ---
  BRICK   = Color.rgb(24, 6, 4)    # a warm red brick body
  MORTAR  = Color.rgb(12, 10, 8)   # the gray lines between bricks
  FLOOR   = Color.rgb(3, 6, 3)     # a dark floor
  SPECK   = Color.rgb(7, 11, 7)    # a lighter fleck on the floor
  HERO    = Color.rgb(6, 26, 8)    # the hero's green body
  HERO_LO = Color.rgb(2, 12, 4)    # its darker legs / outline
  EYE     = Color.rgb(31, 31, 31)  # a white eye

  module_function

  def run
    Dir.mkdir(ASSETS) unless Dir.exist?(ASSETS)
    File.binwrite(File.join(ASSETS, "tiles.png"), tiles_png)
    File.binwrite(File.join(ASSETS, "hero.png"), hero_png)
    File.write(File.join(ASSETS, "level.csv"), level_csv)
    puts "wrote #{ASSETS}/tiles.png, hero.png and level.csv"
  end

  # The LEVEL room as a CSV tilemap: each character becomes a tile number — "#" the
  # brick (tile 1 of tiles.png), "." the floor (tile 2). This is the shape a map
  # editor writes when you export a layer, so examples/level.rb can import it as-is.
  def level_csv
    LEVEL.map do |row|
      row.each_char.map { |ch| ch == "#" ? 1 : 2 }.join(",")
    end.join("\n") << "\n"
  end

  # A 16x8 sheet: brick tile in cells 0, floor tile in cell 1 (each 8x8). Opaque,
  # so it encodes as a plain RGB PNG through the preview tool's encoder.
  def tiles_png
    pixels = Array.new(16 * 8, FLOOR)
    8.times do |y|
      8.times do |x|
        pixels[(y * 16) + x] = brick_pixel(x, y)          # left cell
        pixels[(y * 16) + 8 + x] = floor_pixel(x, y)      # right cell
      end
    end
    Preview.png(width: 16, height: 8, pixels: pixels)
  end

  # A brick body with mortar along the top edge and a staggered vertical seam — a
  # running-bond pattern. The cell's interior (used by the example's assertions)
  # stays solid brick.
  def brick_pixel(x, y)
    return MORTAR if y.zero? || y == 4                     # horizontal mortar lines
    return MORTAR if y < 4 && x == 7                       # upper course seam
    return MORTAR if y > 4 && x == 3                       # lower course seam (staggered)

    BRICK
  end

  def floor_pixel(x, y)
    return SPECK if (x == 3 && y == 1) || (x == 6 && y == 5)

    FLOOR
  end

  # A 64x16 sheet of four 16x16 walk frames on a transparent background, encoded as
  # an RGBA PNG so the imported sprite is a cut-out (only the figure draws).
  def hero_png
    width = 64
    rgb = Array.new(width * 16, HERO)
    alpha = Array.new(width * 16, 0) # transparent everywhere until a pixel is drawn
    4.times do |frame|
      draw_hero_frame(rgb, alpha, frame * 16, width, frame)
    end
    rgba_png(width, 16, rgb, alpha)
  end

  # Draw one walk frame into the sheet at column offset +ox+. The head and body are
  # the same every frame (so a body pixel is a stable green); only the legs swing,
  # to read as a walk cycle.
  def draw_hero_frame(rgb, alpha, ox, width, frame)
    put = lambda do |x, y, color|
      rgb[(y * width) + ox + x] = color
      alpha[(y * width) + ox + x] = 255
    end

    (2..13).each { |y| (4..11).each { |x| put.call(x, y, HERO) } } # head + torso block
    put.call(6, 5, EYE)
    put.call(9, 5, EYE)
    # Legs: two stances, alternating each frame, so it looks like walking.
    left, right = frame.even? ? [[4, 5], [10, 11]] : [[5, 6], [9, 10]]
    (14..15).each do |y|
      left.each { |x| put.call(x, y, HERO_LO) }
      right.each { |x| put.call(x, y, HERO_LO) }
    end
  end

  # Encode an RGBA (truecolor + alpha) PNG. Same shape as the preview tool's RGB
  # encoder, plus a fourth alpha byte per pixel and color type 6. Each 15-bit color
  # is expanded to 8-bit channels the same way, so ImageMagick reads it back to the
  # exact console colors it started from.
  def rgba_png(width, height, rgb, alpha)
    raw = (+"").b
    height.times do |y|
      raw << 0.chr # filter type 0 (none)
      width.times do |x|
        r, g, b = Preview.rgb(rgb[(y * width) + x])
        raw << r.chr << g.chr << b.chr << alpha[(y * width) + x].chr
      end
    end
    ihdr = [width, height].pack("N2") << [8, 6, 0, 0, 0].pack("C5") # 8-bit, RGBA, no interlace
    Preview::PNG_SIGNATURE + Preview.chunk("IHDR", ihdr) +
      Preview.chunk("IDAT", Zlib::Deflate.deflate(raw)) + Preview.chunk("IEND", "".b)
  end
end

MakeExampleAssets.run if __FILE__ == $PROGRAM_NAME
