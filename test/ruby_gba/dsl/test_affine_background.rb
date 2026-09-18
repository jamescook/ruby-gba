# frozen_string_literal: true

require "test_helper"
require "differential"
require "tmpdir"

# Affine backgrounds: `screen :rotozoom` gives a background handle `rotate`/`scale`,
# the same names and units a hardware sprite's `face_angle`/`scale` already use,
# applied to a whole tiled layer instead of one picture. Asserted here against the
# reference interpreter's fake screen — see .claude/CLAUDE.md's testing altitude
# rule: behavior (what a turned/resized picture looks like), not the IR it builds.
class TestAffineBackground < Minitest::Test
  include Differential

  def interpret(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    Reference.new.run(builder.program)
  end

  # A 32x32 map, blank except the given (col, row) => character marks, so a
  # transform is judged by which mark lands under a fixed screen point rather than
  # by re-deriving the matrix math in the test itself.
  def marked_map(marks)
    Array.new(32) { Array.new(32, " ") }.tap do |rows|
      marks.each { |(col, row), ch| rows[row][col] = ch }
    end.map(&:join)
  end

  # No turn, no resize: the picture reads exactly as drawn. Column 25, row 10 (a
  # screen point 80px right of center, on the center row) shows the tile placed
  # there — the plain identity case every other assertion here is a change from.
  def test_untouched_background_reads_as_drawn
    map = marked_map({ [25, 10] => "#" })
    i = interpret do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      tiles :t, "#" => :white
      background :board, tiles: :t, map: map
      halt
    end

    assert_equal Color.resolve(:white), i.screen.pixel(200, 80)
  end

  # Zoom in 2x: a screen point 80px from center now samples a texture point only
  # 40px from center (stepping through the picture at half a pixel per screen
  # pixel) — column 20, not column 25.
  def test_scale_zooms_in_toward_the_center
    map = marked_map({ [25, 10] => "#", [20, 10] => "$" })
    i = interpret do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      board = background :board, tiles: :t, map: map
      board.scale(2.0)
      halt
    end

    assert_equal Color.resolve(:red), i.screen.pixel(200, 80)
  end

  # Turn 90 degrees clockwise: a screen point straight right of center now samples
  # a texture point straight ABOVE center instead (row 0, column 15) — turning the
  # picture, not sliding it.
  def test_rotate_turns_the_picture_around_its_center
    map = marked_map({ [25, 10] => "#", [15, 0] => "$" })
    i = interpret do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      image :green, "#" => :green do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :green
      board = background :board, tiles: :t, map: map
      board.rotate(90)
      halt
    end

    assert_equal Color.resolve(:green), i.screen.pixel(200, 80)
  end

  # The affine matrix is read live every frame, whether a program reaches it
  # through `rotate`/`scale` or mutates the underlying angle/scale Value directly
  # (`board.scale.approach!`, the same idiom a sprite's size already supports) — see
  # Builder#affine_each_frame, registered once a background is made affine at all.
  def test_a_directly_mutated_scale_value_still_takes_effect
    map = marked_map({ [25, 10] => "#", [20, 10] => "$" })
    i = interpret do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      board = background :board, tiles: :t, map: map
      board.scale.set!(2.0) # bypasses the #scale setter entirely
      game_loop { wait_vblank }
    end

    assert_equal Color.resolve(:red), i.screen.pixel(200, 80)
  end

  # --- the zoom is a SIZE change, not just a different picture ---
  #
  # "The pixels changed from one frame to the next" is not evidence of a zoom: a
  # matrix that is merely wrong changes them too. What a zoom means is that the
  # squares of a checkerboard get BIGGER, so these measure the squares.

  # A checkerboard of 8x8 tiles, sized +size+.
  def checkerboard_at(size)
    rows = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "L" : "D" }.join }
    interpret do
      screen :rotozoom
      image :light, "#" => :white do "########\n" * 8 end
      image :dark, "#" => :blue do "########\n" * 8 end
      tiles :checker, "L" => :light, "D" => :dark
      board = background :board, tiles: :checker, map: rows
      board.scale(size)
      halt
    end
  end

  # How wide the checkerboard's squares read along a screen row: the run lengths of
  # same-colored pixels, dropping the first and last (those are cut by the screen edge).
  def square_widths(screen, y = 80)
    runs = []
    (0...240).each do |x|
      color = screen.pixel(x, y)
      if runs.last && runs.last.first == color
        runs.last[1] += 1
      else
        runs << [color, 1]
      end
    end
    runs[1..-2].to_a.map(&:last)
  end

  def test_scaling_up_makes_the_squares_bigger
    at_1x = square_widths(checkerboard_at(1.0).screen)
    at_2x = square_widths(checkerboard_at(2.0).screen)
    at_3x = square_widths(checkerboard_at(3.0).screen)

    assert_equal [8], at_1x.uniq, "as drawn, the squares are the tile's own 8px"
    assert_equal [16], at_2x.uniq, "twice the size: 16px squares"
    # A third of a texel per pixel is not a whole number of 256ths, so at 3x the
    # squares land a pixel either side of 24 — the console's own rounding, not slack.
    assert_empty (at_3x.uniq - [24, 25]), "three times: 24px squares, got #{at_3x.uniq.inspect}"
    # ...and fewer of them fit across the screen, which is the same fact from the
    # other side — a zoom, not a scroll or a redraw of the same picture.
    assert_operator at_3x.size, :<, at_1x.size
  end

  # A checkerboard of two colours, as a whole program, for the two tests below.
  def board_program(scale: nil)
    rows = (0...32).map { |r| (0...32).map { |c| (r + c).even? ? "L" : "D" }.join }
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :light, "#" => :white do "########\n" * 8 end
      image :dark, "#" => :blue do "########\n" * 8 end
      tiles :checker, "L" => :light, "D" => :dark
      board = background :board, tiles: :checker, map: rows
      board.scale(scale) if scale
      game_loop { wait_vblank }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_scaling_up_makes_the_squares_bigger_on_the_console
    rom = ROM.assemble(GBA.new.lower(board_program(scale: 2.0)), title: "AFFINE", code: "BAFF", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 3)

    runs = []
    (0...240).each do |x|
      color = v.pixel_gba(x, 80)
      if runs.last && runs.last.first == color
        runs.last[1] += 1
      else
        runs << [color, 1]
      end
    end
    assert_equal [16], runs[1..-2].map(&:last).uniq, "at twice the size the console draws 16px squares"
    # ...and they are the two colours the board was drawn from, in turn. Run LENGTHS alone
    # pass on a board of any two colours at all, which is how a board coming out black and
    # white went unnoticed.
    assert_equal [Color.resolve(:white), Color.resolve(:blue)].sort,
                 runs[1..-2].map(&:first).uniq.sort,
                 "and they are white and blue, the colours it was drawn from"
  end

  # HOW A TURNING LAYER READS ITS COLOURS, which is not a choice: that pair of hardware
  # layers reads a whole byte per pixel whatever the art is drawn from, because its map
  # holds one byte a cell with no room to name a group of sixteen colours. A board drawn
  # from two colours is the case that catches it — few enough colours to be sorted into
  # such a group, which would store the tiles at half size under a layer reading them at
  # full size: half of every tile blank, every colour after the first black.
  def test_a_turning_background_drawn_from_few_colours_draws_the_same_on_both
    assert_backends_agree(board_program, frames: 4)
  end

  # --- WHICH POINT THE PICTURE TURNS AROUND ---
  #
  # A turning background pivots on the middle of the screen unless the game says
  # otherwise, and the middle of the screen is one game's answer rather than a general
  # one. The Minish Cap's title screen turns its sword on the middle of the screen raised
  # by eight pixels; at the size that animation starts — sixteen times magnified — eight
  # pixels is most of a screen, so the sword flies in from off the edge instead of from
  # the middle.
  #
  # Said once on the background, because a picture turns around one point however many
  # times the game turns it: the display is given a single place the picture is pinned to,
  # not one per turn.
  # Zoomed 2x about (40, 80), the screen point 160 pixels right of that pivot samples a
  # texture point only 80 right of it — column 15. The same zoom about the middle of the
  # screen samples column 20, which is what test_scale_zooms_in_toward_the_center pins, so
  # the two marks tell a moved pivot from an unmoved one.
  private def a_board_zoomed_about(x, y)
    map = marked_map({ [20, 10] => "#", [15, 10] => "$" })
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      background(:board, tiles: :t, map: map).turns_around(x, y).scale(2.0)
      game_loop { wait_vblank }
    end
    builder.emit_pending_functions
    builder.program
  end

  ZOOM_SAMPLED = [200, 80].freeze

  def test_scale_zooms_toward_the_point_it_is_told_to_turn_around
    i = Reference.new.run(a_board_zoomed_about(40, 80), frames: 4)

    assert_equal Color.resolve(:red), i.screen.pixel(*ZOOM_SAMPLED),
                 "the picture zoomed toward the middle of the screen, not toward the point it was given"
  end

  def test_the_console_turns_it_around_that_point_too
    v = assert_emulator_loads_rom(assemble_rom(a_board_zoomed_about(40, 80), name: "AFFPIV"), frames: 4)

    assert_equal Color.resolve(:red), v.pixel_gba(*ZOOM_SAMPLED),
                 "the console zoomed toward the middle of the screen, not toward the point it was given"
  end

  # Every pixel rather than the one sampled above, and a pivot off both axes so a backend
  # that had swapped or dropped one of the two numbers cannot pass.
  def test_the_two_backends_agree_about_the_point_it_turns_around
    assert_backends_agree(a_board_zoomed_about(40, 120), frames: 4)
  end

  # Nothing about the picture moves when only the pivot does: at its drawn size, upright,
  # a background lands in exactly the same place whatever it is told to turn around. That
  # is what makes this safe to say on a background whose animation has not started.
  def test_an_unturned_picture_lands_in_the_same_place_whatever_it_turns_around
    plain = marked_map({ [20, 10] => "#" })
    picture = lambda do |pivot|
      builder = Builder.new
      builder.instance_eval do
        screen :rotozoom
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        board = background :board, tiles: :t, map: plain
        board.turns_around(*pivot) if pivot
        board.rotate(0)
        game_loop { wait_vblank }
      end
      builder.emit_pending_functions
      Reference.new.run(builder.program, frames: 4).screen
    end

    # Where the mark is drawn, untouched: column 20 of the map is screen pixels 160..167.
    where_it_was_drawn = [164, 84]

    assert_equal Color.resolve(:white), picture.call([17, 133]).pixel(*where_it_was_drawn),
                 "naming a pivot moved a picture that is not turning"
    assert_equal Color.resolve(:white), picture.call(nil).pixel(*where_it_was_drawn)
  end

  # A pivot named in the MIDDLE of a declaration must not break the line it is in: the
  # size written after it is still the size the picture starts at, which a scene's body
  # would otherwise put back on every frame it runs. Written as a scene because that is
  # the only place the difference shows — the sword flying at the player is exactly this
  # line, and it sticking is what sent this work here in the first place.
  def test_a_pivot_between_the_declaration_and_its_size_leaves_the_size_free_to_ease
    map = marked_map({ [20, 10] => "#" })
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      tiles :t, "#" => :white
      var :state, 0
      scene :title do
        board = background(:board, tiles: :t, map: map).turns_around(40, 80).scale(4.0)
        board.scale.approach! 1.0, 1.0
      end
      game_loop { case_var(:state) { when_val 0, :title } }
    end
    builder.emit_pending_functions
    i = Reference.new.run(builder.program, frames: 8)

    # Eased back to its drawn size, the mark is where it was drawn: column 20 of the map
    # is screen pixels 160..167. Stuck partway, that pixel samples column 10, which is blank.
    assert_equal Color.resolve(:white), i.screen.pixel(164, 84),
                 "the size never eased back — naming the pivot broke the declaration it sits in"
  end

  # The point is settled while the program is written. A pivot the game worked out as it
  # ran would be its own effect — a picture that turns around something that moves — and
  # saying so plainly beats half-doing it.
  def test_a_pivot_the_game_works_out_is_a_friendly_error
    map = marked_map({})
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :rotozoom
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        aim = var :aim, 40
        background(:board, tiles: :t, map: map).turns_around(aim, 80)
      end
    end

    assert_match(/turns_around/, err.message)
    assert_match(/whole number/, err.message, "it says what to write instead")
  end

  # --- THE TURN IS WRITTEN ONLY ON A FRAME WHERE IT CHANGED ---
  #
  # A picture that has stopped moving is told to hold still by being told nothing, and
  # the console holds it: the six numbers that say how a layer is turned and where it is
  # pinned stay where they were put. Writing them again every frame is not merely waste.
  # The console reads where the layer is pinned as it draws, so a write that lands while
  # the screen is being drawn moves the layer for the rest of the picture — one frame
  # showing a jump, and then it snaps back. A frame that starts late is a frame whose
  # writes land there, and every game has those.
  #
  # Nine other registers are written on those same late frames and none of them shows: a
  # scroll written late is invisible. So this is not about a game being slow, it is about
  # one write that must not happen while the display is drawing happening on a frame where
  # the program asked for nothing at all.
  #
  # Which is also the bargain the framework already makes for a whole map and for a
  # scroll, in the same place — the gap between frames — and for the same reason.
  TURN_REGISTERS = [RubyGBA::Cartridge::Constants::REG_BG2PA,
                    RubyGBA::Cartridge::Constants::REG_BG2PB,
                    RubyGBA::Cartridge::Constants::REG_BG2PC,
                    RubyGBA::Cartridge::Constants::REG_BG2PD,
                    RubyGBA::Cartridge::Constants::REG_BG2X,
                    RubyGBA::Cartridge::Constants::REG_BG2Y].freeze

  # How many of those six the console was written on each frame, in order — read off its
  # own log of what the cartridge wrote to the display, which is the only place the
  # question can be asked: both backends draw the same picture either way, and what
  # separates them is how often the hardware was told.
  private def turn_writes_each_frame(prog, name:, frames:)
    Dir.mktmpdir("affine-writes") do |dir|
      path = File.join(dir, "#{name.downcase}.gba")
      assemble_rom(prog, name: name).write(path)
      probe = RubyGBA::Diagnostics::Emulator.probe(path)
      begin
        probe.watch_display
        counted = 0
        return Array.new(frames) do
          probe.step(1)
          seen = probe.display_writes.count { |w| w.kind == :register && TURN_REGISTERS.include?(w.address) }
          (seen - counted).tap { counted = seen }
        end
      ensure
        probe.close
      end
    end
  end

  # A picture zoomed in once, where it is declared, and never spoken to again — the
  # simplest shape of a title screen whose animation has finished.
  private def a_board_that_never_moves_again
    map = marked_map({ [20, 10] => "#" })
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      tiles :t, "#" => :white
      background(:board, tiles: :t, map: map).scale(2.0)
      game_loop { wait_vblank }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_turn_that_has_settled_is_not_written_again
    each_frame = turn_writes_each_frame(a_board_that_never_moves_again, name: "AFFHELD", frames: 10)

    assert_operator each_frame.first(2).sum, :>, 0,
                    "the turn was never written at all, so the picture is not zoomed"
    assert_equal [0] * 6, each_frame.last(6),
                 "the picture stopped moving and the console is still being told about it every " \
                 "frame: #{each_frame.inspect}"
  end

  # ...and the other half of it: a picture that IS moving is written on every frame it
  # moves. Zoomed out a whole step a frame from four times the size, it takes three steps
  # to arrive — and the display is told the size the pass BEFORE settled on, which is what
  # every picture the framework draws for you does, so telling it takes one frame longer
  # than moving it does. Five frames of writes, then nothing.
  private def a_board_that_zooms_out_and_stops
    map = marked_map({ [20, 10] => "#" })
    builder = Builder.new
    builder.instance_eval do
      screen :rotozoom
      image :white, "#" => :white do "########\n" * 8 end
      tiles :t, "#" => :white
      board = background(:board, tiles: :t, map: map).scale(4.0)
      game_loop { board.scale.approach! 1.0, 1.0 }
    end
    builder.emit_pending_functions
    builder.program
  end

  def test_a_turn_that_is_still_moving_is_written_on_every_frame_it_moves
    each_frame = turn_writes_each_frame(a_board_that_zooms_out_and_stops, name: "AFFEASE", frames: 10)
    moving, rested = each_frame.partition.with_index { |_, frame| frame < 5 }

    assert_equal [6] * 5, moving,
                 "the picture was easing out and the display was not told on every frame of it: " \
                 "#{each_frame.inspect}"
    assert_equal [0] * 5, rested, "it arrived and the writes carried on: #{each_frame.inspect}"
  end

  # A scene that turns a background, a scene that does not, and a game that goes back and
  # forth between them. Leaving the turning one puts the display back to no-turn-no-zoom,
  # because whatever comes next must not keep showing this scene's zoom — so coming back
  # has to say the zoom again, though the program has not mentioned it since the line that
  # declared it. Zoomed 2x the sampled point shows the red mark at column 20; left as
  # drawn it shows the white one at column 25, so the two tell each other apart.
  private def a_zoom_the_game_leaves_and_comes_back_to
    map = marked_map({ [25, 10] => "#", [20, 10] => "$" })
    blank = Array.new(32) { " " * 32 }
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image :white, "#" => :white do "########\n" * 8 end
      image :red, "#" => :red do "########\n" * 8 end
      tiles :t, "#" => :white, "$" => :red
      state = var :state, 0
      waiting = var :waiting, VISIT

      scene :zoomed do
        background(:board, tiles: :t, map: map).scale(2.0)
        waiting.sub! 1
        (waiting == 0).then { state.set! 1 }
        (state == 1).then { waiting.set! VISIT }
      end

      scene :away do
        background :blank, tiles: :t, map: blank
        waiting.sub! 1
        (waiting == 0).then { state.set! 0 }
      end

      game_loop { case_var(:state) { when_val 0, :zoomed; when_val 1, :away } }
    end
    builder.emit_pending_functions
    builder.program
  end

  VISIT = 4 # frames in each scene before the game moves to the other

  def test_a_zoom_comes_back_with_the_scene_that_owns_it
    v = assert_emulator_loads_rom(assemble_rom(a_zoom_the_game_leaves_and_comes_back_to, name: "AFFBACK"),
                                  frames: 2 * VISIT + 3)

    assert_equal Color.resolve(:red), v.pixel_gba(*ZOOM_SAMPLED),
                 "the scene came back and the picture came back as drawn: the display was never told " \
                 "the zoom again after another scene took the turning layer"
  end

  # --- guardrails: the two footguns this feature makes plain-language errors ---

  def test_rotating_a_bitmap_background_is_a_friendly_error
    map = marked_map({})
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :bitmap
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        board = background :board, tiles: :t, map: map
        board.rotate(45)
      end
    end
    # A tile screen is what this needs, and there are two of those — a bitmap screen is
    # the one that cannot turn a background at all, because it has none to turn.
    assert_match(/has no background layer/, err.message)
    assert_match(/screen :bitmap/, err.message, "it names the screen the program is actually on")
  end

  def test_scrolling_an_affine_background_is_a_friendly_error
    map = marked_map({})
    err = assert_raises(ArgumentError) do
      Builder.new.instance_eval do
        screen :rotozoom
        image :white, "#" => :white do "########\n" * 8 end
        tiles :t, "#" => :white
        board = background :board, tiles: :t, map: map
        board.scroll_by(1, 0)
      end
    end
    assert_match(/rotate|scale/, err.message)
  end
end
