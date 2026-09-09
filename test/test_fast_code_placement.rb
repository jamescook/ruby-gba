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

  # A cartridge that can report on itself, built the way RubyGBA.build builds one: the
  # record of what the build worked out is handed over whole, at assembly.
  def rom_of(program, title:, code:, **opts)
    backend = GBA.new(**opts)
    machine_code = backend.lower(program)
    RubyGBA::ROM.assemble(machine_code, title: title, code: code, maker: "01",
                                        built: backend.build_record(program))
  end

  # --- it changes nothing ---

  # The same program, both ways, every pixel compared — on the interpreter and on the
  # real console. Where code lives is not allowed to change what it draws.
  def test_the_console_draws_the_same_picture_whether_or_not_code_moves
    program = looping_program
    refute_empty placement_of(program).funcs, "the program has something worth moving"
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
    assert_empty placement_of(looping_program, fast_code: false).funcs
  end

  # ...but a routine the author names still goes, which is the point of having both
  # switches: turn the automatic choosing off, then say where you want it yourself.
  def test_a_named_routine_still_moves_with_the_choosing_off
    report = placement_of(looping_program(fast: true), fast_code: false)
    assert_equal [:work], report.funcs
  end

  # And a routine marked `fast: false` is left alone even when the framework would have
  # taken it.
  def test_a_routine_can_be_kept_out
    report = placement_of(looping_program(fast: false))
    refute_includes report.funcs, :work
  end

  # The game loop's body has no name in the program, but it is where nearly all of a
  # frame's time goes, so the framework treats it as a routine and moves it. Without this
  # a game that puts everything in its loop — which is most of them — would get nothing.
  def test_the_game_loops_own_body_can_move
    assert_includes placement_of(looping_program).funcs, Placement::FRAME_ROUTINE
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
  #
  # EVERYTHING THIS PROGRAM SPENDS ITS FRAME ON IS INSIDE :work, so :work is what has to
  # move for the frame to get cheaper. Naming only the frame's own body would leave the
  # routine in the cartridge, and a game whose loop moved while its routine did not is a
  # real build rather than a hypothetical one — that is what quick memory running out
  # looks like.
  #
  # The frame's own boundary comes off both readings first. Waiting for the screen is the
  # console's own doing and takes the same time wherever our code lives, so it is the one
  # part of a frame the move cannot make cheaper.
  def test_the_estimate_follows_the_code_into_quick_memory
    program = looping_program(passes: 200)
    boundary = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS[:frame_overhead]
    cart = RubyGBA::IR::CostModel.new.steady_cost(program) - boundary
    quick = RubyGBA::IR::CostModel.new(fast_frame: true, fast_routines: [:work]).steady_cost(program) -
            boundary
    speedup = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS[:fast_code_speedup]

    assert_in_delta cart / speedup, quick, 0.01
  end

  # ...and the half of that which is easy to lose: moving the frame's own body does NOT carry
  # the routine it calls along with it. A routine is emitted once and jumped to, so one left
  # behind runs from the cartridge whoever called it.
  def test_moving_the_frame_body_does_not_move_the_routine_it_calls
    program = looping_program(passes: 200)
    cart = RubyGBA::IR::CostModel.new.steady_cost(program)
    loop_only = RubyGBA::IR::CostModel.new(fast_frame: true).steady_cost(program)
    both = RubyGBA::IR::CostModel.new(fast_frame: true, fast_routines: [:work]).steady_cost(program)

    assert_operator loop_only, :>, both * 1.5,
                    "the routine is still in the cartridge, so most of the frame is undiscounted"
    assert_operator loop_only, :<, cart, "though the loop's own statements did move"
  end

  # A routine that is NOT in the quick memory is priced as it always was — the discount is
  # per routine, not a blanket one.
  def test_a_routine_left_in_the_cartridge_is_priced_as_before
    program = looping_program(passes: 200)
    assert_in_delta RubyGBA::IR::CostModel.new.steady_cost(program),
                    RubyGBA::IR::CostModel.new(fast_routines: [:something_else]).steady_cost(program), 0.001
  end

  # --- the routine the console interrupts into ---

  # A background bending row by row is answered after every line the display draws, 228
  # times a frame, which makes the routine those answers run in the busiest thing in the
  # program. It has no name the author wrote, like the game loop's body, and it is placed
  # the same way.
  #
  # It bends FOUR layers, which is what puts it on the interrupt: three is as many copying
  # engines as there are to lend out, so a fourth layer is one more than there is an engine
  # for and the display has to be interrupted for all of them. Give the helper a block
  # instead and it bends one layer, which an engine feeds and which lands there not at all
  # (see BendForm, and the test below).
  def bending_program(&block)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:bar, "." => :transparent, "#" => :red) { (["##......"] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      map = Array.new(20) { "#" * 30 }
      if block
        instance_exec(background(:water, tiles: :stripes, map: map), &block)
      else
        4.times do |i|
          background(:"water#{i}", tiles: :stripes, map: map).scroll_each_row { |row| (row + i) % 8 }
        end
      end
      game_loop { }
    end
    b.emit_pending_functions
    b.program
  end

  def test_the_routine_the_display_interrupts_into_moves_when_a_background_bends
    assert_includes placement_of(bending_program).funcs, Placement::IRQ_ROUTINE
  end

  # ...and it is not placed at all for a bend a copying engine feeds, because nothing lands
  # there: the display announces no lines, and the block runs in the frame with the rest of
  # the code. The room goes to whatever else earns it.
  def test_nothing_is_placed_there_for_a_bend_the_copier_feeds
    program = bending_program { |water| water.scroll_each_row { |row| row % 8 } }
    refute_includes placement_of(program).funcs, Placement::IRQ_ROUTINE
  end

  # ...and it does NOT move for a program that only sleeps until the next frame. That
  # program enters it once a frame and leaves again immediately, so the room is better spent
  # on anything else — the same "has to earn its place" rule every routine is held to.
  def test_it_stays_in_the_cartridge_when_nothing_interrupts_often
    refute_includes placement_of(looping_program).funcs, Placement::IRQ_ROUTINE
  end

  # A timer is the other thing that can make it busy: `per_second: 4000` runs its handler 67
  # times a frame, off the timer rather than the frame loop. So it moves for that too, which
  # is what "this helps every interrupt, not only bends" has to mean in practice.
  def ticking_program(per_second: 4000)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      n = var :n, 0
      timer(:beat, per_second: per_second).on_tick { n.add 1 }
      game_loop { fill_rect 0, 0, 40, 8, :green }
    end
    b.emit_pending_functions
    b.program
  end

  def test_the_routine_moves_for_a_busy_timer_too
    assert_includes placement_of(ticking_program).funcs, Placement::IRQ_ROUTINE
  end

  # A timer that ticks a handful of times a second is not worth the room, the same as a
  # program with no timer at all.
  def test_a_slow_timer_does_not_earn_the_room
    refute_includes placement_of(ticking_program(per_second: 2)).funcs, Placement::IRQ_ROUTINE
  end

  def test_a_busy_timers_frame_is_cheaper_once_that_routine_moves
    quick = frame_scanlines(ticking_program, fast_code: true)
    cart = frame_scanlines(ticking_program, fast_code: false)
    assert_operator cart / quick.to_f, :>, 1.3,
                    "expected a real saving, got #{format('%.2fx', cart / quick.to_f)} (#{cart} -> #{quick})"
  end

  def test_it_stays_in_the_cartridge_with_the_choosing_off
    refute_includes placement_of(bending_program, fast_code: false).funcs, Placement::IRQ_ROUTINE
  end

  # The whole point of moving it, measured on the console: the same bend, the same picture,
  # for about half the frame. This is the one assertion that cannot be argued with — the
  # routine really is running from the quick memory, because nothing else would show here.
  def test_a_bending_background_costs_much_less_once_that_routine_moves
    quick = frame_scanlines(bending_program, fast_code: true)
    cart = frame_scanlines(bending_program, fast_code: false)
    assert_operator cart / quick.to_f, :>, 1.5,
                    "expected a real saving, got #{format('%.2fx', cart / quick.to_f)} (#{cart} -> #{quick})"
  end

  # And it changes nothing about the picture. The handler is copied bytes running from a
  # different address, so a branch inside it that did not survive the move, or a vector left
  # pointing at the cartridge, would show up as rows bending by the wrong amount.
  def test_the_console_bends_the_same_rows_whether_that_routine_moves
    program = bending_program
    moved = console_pixels(program, fast_code: true)
    left = console_pixels(program, fast_code: false)
    differing = moved.each_index.count { |i| moved[i] != left[i] }
    assert_equal 0, differing, "#{differing} pixels differ between the two builds"
  end

  # A block that does more than work one number out — it sets a variable, calls a routine,
  # and reads the result. Those statements run 160 times in the frame's own body, which is
  # itself kept in the quick memory, and a call out of there to a routine still in the
  # cartridge is four instructions instead of one — so this is the path that breaks if the
  # crossing is not handled.
  def test_a_block_that_calls_a_routine_still_bends_the_same_rows
    program = bending_program do |water|
      shift = var :shift, 0
      func(:pick) { shift.set 4 }
      water.scroll_each_row do |row|
        call :pick
        shift.add row % 2
        shift
      end
    end
    assert_includes placement_of(program).funcs, Placement::FRAME_ROUTINE
    assert_backends_agree(program, frames: 3, name: "CBND")
  end

  # --- and the price follows it ---

  # Moving it makes bending genuinely cheaper, so an estimate that ignored the move would
  # read nearly twice over for every program that ripples.
  def test_the_estimate_follows_the_interrupt_into_quick_memory
    program = bending_program
    cart = RubyGBA::IR::CostModel.new.bend_verdict(program).feeding
    quick = RubyGBA::IR::CostModel.new(fast_interrupts: true).bend_verdict(program).feeding
    assert_operator quick, :<, cart
  end

  # It buys less than the general fast-memory factor, and that is not a rounding error:
  # stopping the game, saving registers and handing control over is the console's own work
  # and runs at the console's own speed however fast ours is. Measured, so the two cases are
  # two weights rather than one weight and a discount.
  def test_an_interrupt_gains_less_from_quick_memory_than_ordinary_code
    weights = RubyGBA::IR::CostModel::DEFAULT_WEIGHTS
    gain = weights[:bend_line] / weights[:bend_line_fast]
    assert_operator gain, :>, 1.5, "moving it is still worth a lot"
    assert_operator gain, :<, weights[:fast_code_speedup],
                    "but less than ordinary code gains, because part of an interrupt is not ours"
  end

  def test_the_report_names_the_routine_the_display_interrupts_into
    rom = rom_of(bending_program, title: "BENDP", code: "BNDP")

    out = StringIO.new
    rom.explain(out: out, color: false)
    assert_match(/kept in quick memory/, out.string)
    assert_match(/answers the display and the timers/, out.string)
  end

  # --- the memory is accounted for ---

  # Whatever it chooses on its own, it can never overrun the memory: the choice is made
  # afresh each build from where the variables actually reached. So a program that grows
  # gets a smaller share rather than a broken build.
  def test_the_automatic_choice_always_fits
    report = placement_of(looping_program)
    assert_operator report.used_bytes, :<=, report.total_bytes
    assert_operator report.free_bytes, :>=, 0
  end

  # A game of scenes with a live score in it — the two shapes whose calls the author never
  # wrote. A multi-way dispatch calls one scene per clause, and a run-time digit calls a
  # shared glyph routine per digit place; neither is a `call` in the tree.
  def game_of_scenes
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      state = var :state, 0
      score = var :score, 0
      func(:tally) { score.add 1 }
      scene(:title) { clear_screen :black }
      scene(:playing) do
        clear_screen :blue
        draw_number :score, 10, 20, :white, digits: 6
        call :tally
        repeat(300) { |i| score.add i }
      end
      scene(:over) { draw_number :score, 10, 30, :white, digits: 6 }
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :playing
          when_val 2, :over
        end
      end
    end
    builder.emit_pending_functions
    builder.program
  end

  # WHAT A ROUTINE IS CHARGED HAS TO COVER WHAT IT COMES OUT AT, and this is the only place
  # that can say so, because being short does not fail where it happens.
  #
  # The chooser adds up what each routine WILL come to once moved and takes routines while the
  # total still fits. It works from a throwaway pass where nothing has moved, so it has to
  # predict the one way a routine grows: a call that ends up crossing between the cartridge and
  # the quick memory stops being a four-byte branch and becomes an address built in full, a
  # move, and a jump through it. Charge less than that for any of them and nothing goes wrong
  # until the very end of a build that FITS, where the block comes out bigger than the room it
  # was given and the author is told to mark a routine `fast: false` — advice about a program
  # that was never the problem.
  def test_a_routine_is_charged_at_least_what_it_comes_out_at
    backend = GBA.new
    backend.lower(game_of_scenes)
    charges = backend.charged_against_emitted

    refute_empty charges, "the program has something worth moving"
    short = charges.select { |_name, (charged, emitted)| charged < emitted }
    assert_empty short, "these routines came out bigger than the chooser was told: " \
                        "#{short.map { |name, (c, e)| "#{name} charged #{c}, emitted #{e}" }.join(', ')}"
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
