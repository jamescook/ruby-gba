# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/dsl/test_affine_background"

# A TURNING BACKGROUND ON THE ADVANCE'S CARTRIDGE, read in the emulator: the size of its squares,
# the point it turns around, and how often the display is told the turn. What a game is told when
# it asks for a turn it cannot have is in test/all/vblank/dsl/test_affine_background.rb.
class TestAffineBackgroundCartridge < Minitest::Test
  include AffineBackgroundGames

  # --- the zoom is a SIZE change, not just a different picture ---
  #
  # "The pixels changed from one frame to the next" is not evidence of a zoom: a
  # matrix that is merely wrong changes them too. What a zoom means is that the
  # squares of a checkerboard get BIGGER, so these measure the squares.

  # A checkerboard of two colours, as a whole program, for the test below.
  private def board_program(scale: nil)
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
    builder.finalize_program
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
    builder.finalize_program
    builder.program
  end

  ZOOM_SAMPLED = [200, 80].freeze

  def test_the_console_turns_it_around_that_point_too
    v = assert_emulator_loads_rom(assemble_rom(a_board_zoomed_about(40, 80), name: "AFFPIV"), frames: 4)

    assert_equal Color.resolve(:red), v.pixel_gba(*ZOOM_SAMPLED),
                 "the console zoomed toward the middle of the screen, not toward the point it was given"
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
  TURN_REGISTERS = [VBlank::Console::Hardware::REG_BG2PA,
                    VBlank::Console::Hardware::REG_BG2PB,
                    VBlank::Console::Hardware::REG_BG2PC,
                    VBlank::Console::Hardware::REG_BG2PD,
                    VBlank::Console::Hardware::REG_BG2X,
                    VBlank::Console::Hardware::REG_BG2Y].freeze

  # How many of those six the console was written on each frame, in order — read off its
  # own log of what the cartridge wrote to the display, which is the only place the
  # question can be asked: both backends draw the same picture either way, and what
  # separates them is how often the hardware was told.
  private def turn_writes_each_frame(prog, name:, frames:)
    Dir.mktmpdir("affine-writes") do |dir|
      path = File.join(dir, "#{name.downcase}.gba")
      assemble_rom(prog, name: name).write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
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
    builder.finalize_program
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
    builder.finalize_program
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
    builder.finalize_program
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
end
