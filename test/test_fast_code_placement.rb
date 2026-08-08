# frozen_string_literal: true

require "test_helper"
require "differential"

# Keeping hot code in the console's quick memory. The build works out on its own which
# routines a frame spends its time in and copies them there at boot, where the same
# instructions run about two and a half times faster; the author can overrule it either
# way, and `rom.explain` says what it chose.
#
# The strongest thing to assert here is that NOTHING CHANGES: the same program draws the
# same pixels, on the interpreter and on the console, whether its code runs from the
# cartridge or not. Everything else is the placement being visible and steerable.
class TestFastCodePlacement < Minitest::Test
  include Differential

  Placement = RubyGBA::IR::Backends::GBA::Placement

  # A program with a real inner loop — the shape this feature exists for. It walks a
  # counter a few hundred times a frame and paints a bar whose width the loop works out,
  # so there is something to see and something to time.
  def looping_program(passes: 40, fast: nil, halt_after: 3)
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      total = var :total, 0
      f = var :f, 0
      func(:work, fast: fast) do
        total.set 0
        repeat(passes) { |i| total.add i }
      end
      game_loop do
        wait_vblank
        call :work
        fill_rect 0, 0, 40, 8, :green
        f.add 1
        (f >= halt_after).then { halt } if halt_after
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  def placement_of(program, **opts)
    backend = GBA.new(**opts)
    backend.lower(program)
    backend.iwram_report
  end

  # --- it changes nothing ---

  # The same program, both ways, every pixel compared — on the interpreter and on the
  # real console. Where code lives is not allowed to change what it draws.
  def test_the_console_draws_the_same_picture_whether_or_not_code_moves
    program = looping_program
    refute_empty placement_of(program)[:funcs], "the program has something worth moving"
    assert_backends_agree(program, frames: 3)
  end

  # ...and the two builds agree with each other, which is the tighter statement: it is the
  # SAME program lowered two ways, so any difference is the placement's fault and nothing
  # else's.
  def test_both_builds_draw_the_same_picture_on_the_console
    program = looping_program
    moved = console_pixels(program, fast_code: true)
    left = console_pixels(program, fast_code: false)
    differing = moved.each_index.count { |i| moved[i] != left[i] }
    assert_equal 0, differing, "#{differing} pixels differ between the two builds"
  end

  def console_pixels(program, **opts)
    rom = RubyGBA::ROM.assemble(GBA.new(**opts).lower(program), title: "PLACE", code: "PLC1", maker: "01")
    verifier = assert_gemba_loads_rom(rom, frames: 4)
    height = RubyGBA::IR::Screen::HEIGHT
    width = RubyGBA::IR::Screen::WIDTH
    (0...height).flat_map { |y| (0...width).map { |x| verifier.pixel_gba(x, y) } }
  end

  # --- it is actually faster ---

  # The whole point. A program whose loop moved does the same work in fewer cycles.
  #
  # Sized to stay well inside one frame either way: past ~228 scanlines the reading
  # saturates and both builds come back at the ceiling, which would make a real speed-up
  # look like none at all. It must not halt either — a halted console spins, which reads
  # as a full frame of work whatever the program was doing before it stopped.
  def test_moving_the_hot_code_makes_the_frame_cheaper
    program = looping_program(passes: 60, halt_after: nil)
    quick = frame_scanlines(program, fast_code: true)
    cart = frame_scanlines(program, fast_code: false)
    assert_operator cart / quick, :>, 1.5,
                    "expected a real speed-up, got #{format('%.2fx', cart / quick)} (#{cart} -> #{quick})"
  end

  def frame_scanlines(program, **opts)
    rom = RubyGBA::ROM.assemble(GBA.new(**opts).lower(program), title: "SPEED", code: "SPD1", maker: "01")
    require_gemba_core!
    Tempfile.create(["place", ".gba"]) do |file|
      file.binmode
      rom.write(file.path)
      file.flush
      probe = GembaCore.open(file.path)
      reading = 3.times.map { probe.busy_scanlines(settle: 20) }.min
      probe.close
      return reading
    end
  end

  # --- the author is in charge ---

  # `fast_code: false` stops the framework choosing. Nothing moves.
  def test_the_choosing_can_be_turned_off
    assert_empty placement_of(looping_program, fast_code: false)[:funcs]
  end

  # ...but a routine the author names still goes, which is the point of having both
  # switches: turn the automatic choosing off, then say where you want it yourself.
  def test_a_named_routine_still_moves_with_the_choosing_off
    report = placement_of(looping_program(fast: true), fast_code: false)
    assert_equal [:work], report[:funcs]
  end

  # And a routine marked `fast: false` is left alone even when the framework would have
  # taken it.
  def test_a_routine_can_be_kept_out
    report = placement_of(looping_program(fast: false))
    refute_includes report[:funcs], :work
  end

  # The game loop's body has no name in the program, but it is where nearly all of a
  # frame's time goes, so the framework treats it as a routine and moves it. Without this
  # a game that puts everything in its loop — which is most of them — would get nothing.
  def test_the_game_loops_own_body_can_move
    assert_includes placement_of(looping_program)[:funcs], Placement::FRAME_ROUTINE
  end

  # --- it says what it did ---

  def test_the_report_names_what_it_kept_in_quick_memory
    rom = RubyGBA.build("FASTC", code: "FSTC", maker: "01", err: StringIO.new) do
      screen :bitmap
      clear_screen :black
      t = var :t, 0
      game_loop do
        wait_vblank
        repeat(50) { |i| t.add i }
        fill_rect 0, 0, 40, 8, :green
      end
    end
    out = StringIO.new
    rom.explain(out: out, color: false)

    assert_match(/kept in quick memory/, out.string)
    assert_match(/the game loop/, out.string)
    assert_match(/of 32K used/, out.string)
  end

  # The estimate has to follow the code. Moving a routine makes it genuinely cheaper, so
  # an estimate that ignored the move would read nearly three times over for any game
  # whose loop went — which is most of them.
  def test_the_estimate_follows_the_code_into_quick_memory
    program = looping_program(passes: 200)
    cart = RubyGBA::IR::CostModel.new.steady_cost(program)
    quick = RubyGBA::IR::CostModel.new(fast_frame: true).steady_cost(program)
    speedup = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS[:fast_code_speedup]

    assert_in_delta cart / speedup, quick, 0.01
  end

  # A routine that is NOT in the quick memory is priced as it always was — the discount is
  # per routine, not a blanket one.
  def test_a_routine_left_in_the_cartridge_is_priced_as_before
    program = looping_program(passes: 200)
    assert_in_delta RubyGBA::IR::CostModel.new.steady_cost(program),
                    RubyGBA::IR::CostModel.new(fast_routines: [:something_else]).steady_cost(program), 0.001
  end

  # --- the memory is accounted for ---

  # Whatever it chooses on its own, it can never overrun the memory: the choice is made
  # afresh each build from where the variables actually reached. So a program that grows
  # gets a smaller share rather than a broken build.
  def test_the_automatic_choice_always_fits
    report = placement_of(looping_program)
    assert_operator report[:used_bytes], :<=, report[:total_bytes]
    assert_operator report[:free_bytes], :>=, 0
  end

  # A routine the author insists on that will not fit is a plain error naming it — the one
  # case where the memory can be overrun, because the author asked.
  def test_a_named_routine_that_cannot_fit_is_a_friendly_error
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      clear_screen :black
      list :big, capacity: 7000 # eats nearly all of the quick memory
      big = var :b, 0
      func(:work, fast: true) { 400.times { big.add 1 } }
      game_loop { wait_vblank; call :work }
    end
    builder.emit_pending_functions

    err = assert_raises(GBA::LoweringError) { GBA.new.lower(builder.program) }
    assert_match(/fast: true/, err.message)
    assert_match(/work/, err.message)
  end
end
