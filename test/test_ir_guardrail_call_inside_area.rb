# frozen_string_literal: true

require "test_helper"

require "stringio"

# `inside` clips what it draws DIRECTLY — but a `call` to a routine is a branch to
# code built once, outside any area. If that routine draws, the reference
# interpreter (which re-checks the area every time it runs the routine) clips it;
# the console (which bakes the clip into the routine's own instructions wherever
# the routine happens to be lowered, never at the call site) does not. The two
# backends show a different picture and nothing crashes to say so — this is what
# hit Wolfenstein's status bar.
#
# The first test PROVES that on the emulated console before any guardrail is
# involved, the same way test_ir_guardrail_bitmap_draw_on_tiled.rb does: it
# lowers straight from the IR, bypassing the validation pass, and keeps proving
# the hardware behavior now that the guardrail stops such a program from being
# built at all.
class TestIRGuardrailCallInsideArea < Minitest::Test

  Check = RubyGBA::IR::Guardrails::Checks::CallInsideArea

  def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.emit_pending_functions
    b.program
  end

  # A routine that fills the whole screen, called from inside a small area.
  def game_with_call_that_draws
    program do
      screen :bitmap
      func(:draw_something) { fill_rect 0, 0, 240, 160, :red }
      game_loop { inside(0, 0, 100, 100) { call :draw_something } }
    end
  end

  # --- Proof that the footgun is real ---

  def test_the_console_does_not_clip_a_routine_called_from_inside_an_area
    prog = game_with_call_that_draws
    interp = Reference.new.run(prog, frames: 2)
    assert_equal 0, interp.screen.pixel(200, 50),
                 "the interpreter clips the routine's fill to the area"

    rom = ROM.assemble(GBA.new.lower(prog), title: "CIAR", code: "BCIA", maker: "01")
    v = assert_gemba_loads_rom(rom, frames: 3)
    assert v.red?(200, 50),
           "the console draws the routine's fill everywhere — the bug this check exists for"
  end

  # --- the check ---

  def test_it_flags_a_call_that_draws_and_names_the_routine_and_verb
    findings = Check.new.detect(game_with_call_that_draws)

    assert_equal 1, findings.size
    assert findings.first.error?, "a picture that differs by backend is a definite bug"
    assert_equal :call, findings.first.node.kind, "it blames the call, not the routine's own body"
    assert_match(/:draw_something/, findings.first.message, "it names the routine")
    assert_match(/fill_rect/, findings.first.message, "it names the verb that draws")
  end

  def test_it_catches_a_stretched_column_the_same_way
    prog = program do
      screen :bitmap
      image :bars, width: 1, height: 4, data: %i[red red blue blue]
      func(:draw_wall) { draw_column_at :bars, slice: 0, x: 50, top: -40, height: 240 }
      game_loop { inside(0, 0, 100, 100) { call :draw_wall } }
    end

    findings = Check.new.detect(prog)
    assert_equal 1, findings.size
    assert_match(/draw_column_at/, findings.first.message,
                 "draw_column_at is the shape that actually broke Wolfenstein — it must not be missed")
  end

  def test_it_flags_a_call_that_draws_through_another_routine_it_calls
    prog = program do
      screen :bitmap
      func(:paint) { fill_rect 0, 0, 240, 160, :red }
      func(:wrapper) { call :paint }
      game_loop { inside(0, 0, 100, 100) { call :wrapper } }
    end

    findings = Check.new.detect(prog)
    assert_equal 1, findings.size
    assert_match(/:wrapper/, findings.first.message, "it names the routine actually called from inside")
    assert_match(/fill_rect/, findings.first.message, "and the verb the draw eventually happens through")
  end

  # --- what it must NOT flag ---

  def test_a_direct_draw_inside_the_area_is_not_flagged
    prog = program do
      screen :bitmap
      game_loop { inside(0, 0, 100, 100) { fill_rect 0, 0, 50, 50, :red } }
    end

    assert_empty Check.new.detect(prog), "no call is involved, so both backends already agree"
  end

  def test_a_call_to_a_routine_that_does_not_draw_is_not_flagged
    prog = program do
      screen :bitmap
      x = var :x, 0
      func(:bump) { x.add 1 }
      game_loop { inside(0, 0, 100, 100) { call :bump } }
    end

    assert_empty Check.new.detect(prog), "a routine with nothing to clip is not this bug"
  end

  # The fix this check recommends — the routine carrying its own `inside` — must not be
  # flagged in turn. That area is baked into the routine, so the console clips it there
  # just as the interpreter does; a game that already did the right thing (Wolfenstein's
  # standing things, drawn by a routine that wraps its columns in the view's area) was
  # being told to do it again.
  def test_a_call_to_a_routine_that_clips_its_own_drawing_is_not_flagged
    prog = program do
      screen :bitmap
      func(:paint) { inside(0, 0, 100, 100) { fill_rect 0, 0, 240, 160, :red } }
      game_loop { inside(0, 0, 200, 128) { call :paint } }
    end

    assert_empty Check.new.detect(prog), "the routine holds its own drawing to an area already"
  end

  # ...but only the draws under that area are excused: one beside it is still loose.
  def test_a_routine_that_clips_some_drawing_and_not_the_rest_is_still_flagged
    prog = program do
      screen :bitmap
      func(:paint) do
        inside(0, 0, 100, 100) { fill_rect 0, 0, 240, 160, :red }
        pixel 5, 5, :red
      end
      game_loop { inside(0, 0, 200, 128) { call :paint } }
    end

    findings = Check.new.detect(prog)
    assert_equal 1, findings.size
    assert_match(/pixel/, findings.first.message)
  end

  def test_a_call_that_draws_outside_any_area_is_not_flagged
    prog = program do
      screen :bitmap
      func(:paint) { fill_rect 0, 0, 240, 160, :red }
      game_loop { call :paint }
    end

    assert_empty Check.new.detect(prog), "with no `inside` in force there is nothing to disagree about"
  end

  # --- the build surfaces it ---

  def test_the_build_stops_and_explains
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("CIAR", code: "BCIA", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        func(:draw_something) { fill_rect 0, 0, 240, 160, :red }
        game_loop { inside(0, 0, 100, 100) { call :draw_something } }
      end
    end

    assert_match(/:draw_something/, err.string)
    assert_match(/fill_rect/, err.string)
    assert_match(/inside .* itself/, err.string, "it says where to move the `inside` block instead")
  end
end
