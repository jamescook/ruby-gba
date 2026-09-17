# frozen_string_literal: true

require "test_helper"

# More background layers than the console can stack.
#
# The console arranges its tile layers one of two ways: four that scroll and none that
# turn, or two that scroll plus one that turns and resizes. A game that declares more
# than the arrangement holds has a layer with nowhere to go, and a layer with nowhere
# to go is simply not drawn — which looks like a bug in the art rather than a budget.
#
# Until this check existed the refusal came out of the ROM lowering, so it reached only
# a game that built a cartridge. A game's own tests run on the headless interpreter,
# where the same program drew as many layers as it liked and said nothing — a green
# suite and a build that fails, over a fact about the console that was knowable the
# whole time.
class TestIRGuardrailBackgroundLayers < Minitest::Test
  Guardrails = RubyGBA::IR::Guardrails

  def validator
    Guardrails::Validator.new(checks: [Guardrails::Checks::TooManyBackgroundLayers.new])
  end

  # A solid 8x8 tile, so a background is a background and nothing about the art matters.
  def solid_tile(builder, name)
    builder.image(name, "#" => :blue) { "########\n" * 8 }
  end

  def filled_map(cols, rows) = Array.new(rows) { "#" * cols }

  # Five scrolling layers where the console stacks four.
  def five_scrolling_layers
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    b.instance_eval do
      tiles :t, "#" => :i_blue
      %i[one two three four five].each { |name| background name, tiles: :t, map: map }
      halt
    end
    b.emit_pending_functions
    b.program
  end

  # The mixed arrangement, where the room is smaller: +scrolling+ plain layers beside
  # one that resizes.
  def scrolling_layers_beside_a_turning_one(scrolling)
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    square = filled_map(32, 32)
    b.instance_eval do
      tiles :t, "#" => :i_blue
      scrolling.each { |name| background name, tiles: :t, map: map }
      background(:spin, tiles: :t, map: square).scale(1.0)
      halt
    end
    b.emit_pending_functions
    b.program
  end

  def test_more_scrolling_layers_than_the_console_stacks_is_refused
    report = validator.run(five_scrolling_layers, autofix: false)

    refute report.ok?, "five scrolling backgrounds fit no arrangement the console has"
    message = report.errors.first.message
    assert_match(/shows 5 scrolling backgrounds at one time/, message, "it says how many are on screen at once")
    assert_match(/:five/, message, "...and names them")
    assert_match(/4 scrolling backgrounds/, message, "...and how many the console stacks")
  end

  # THE SMALLER COUNT. Once a layer turns there are two scrolling ones rather than
  # four, so a third has nowhere to go — and the message has to say which background
  # cost it the other two, or the count looks arbitrary.
  def test_a_third_scrolling_layer_beside_a_turning_one_is_refused
    report = validator.run(scrolling_layers_beside_a_turning_one(%i[one two three]), autofix: false)

    refute report.ok?
    message = report.errors.first.message
    assert_match(/shows 3 scrolling backgrounds at one time/, message, "it says how many are on screen at once")
    assert_match(/shows 2 scrolling backgrounds at one time/, message, "...and how many fit beside a turning one")
    assert_match(/:spin/, message, "...and which background costs the other two")
  end

  # No false alarm: two scrolling layers and one that turns is an arrangement the
  # console has.
  def test_two_scrolling_layers_beside_a_turning_one_are_left_alone
    report = validator.run(scrolling_layers_beside_a_turning_one(%i[one two]), autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  # No false alarm: four scrolling layers and nothing turning is the other one.
  def test_four_scrolling_layers_are_left_alone
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    b.instance_eval do
      tiles :t, "#" => :i_blue
      %i[one two three four].each { |name| background name, tiles: :t, map: map }
      halt
    end
    b.emit_pending_functions

    report = validator.run(b.program, autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  # TWO SCREENS THAT TAKE TURNS EACH HOLD THEIR OWN LAYERS. A title that zooms, handing
  # over to a game with four scrolling layers, is two arrangements one after the other —
  # the console is never in both at once. Counting them together would refuse a program
  # that has always built.
  def test_a_turning_title_screen_does_not_cost_a_tiled_scene_its_layers
    b = Builder.new
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    square = filled_map(32, 32)
    b.instance_eval do
      var :state, 0
      tiles :t, "#" => :i_blue
      scene(:title) do
        screen :rotozoom
        background(:turner, tiles: :t, map: square).scale(1.0)
      end
      scene(:play) do
        screen :tiled
        %i[one two three four].each { |name| background name, tiles: :t, map: map }
      end
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions

    report = validator.run(b.program, autofix: false)
    assert report.ok?, "the title's turning layer is on a screen of its own"
  end

  # ...AND SO DOES A TITLE THAT TURNS ON THE TILED SCREEN, which is the arrangement a real
  # game wants: two scrolling layers with something flying at the player over them, handing
  # over to a game played with four scrolling layers and nothing turning. Both are the tiled
  # screen, so the test above does not cover it — that title is a screen of another kind.
  #
  # The console is told which arrangement it is in as each screen is set up, so what has to
  # fit is one screen's worth. Counted for the whole program, one turning background
  # anywhere capped every screen in the game at two scrolling layers.
  def test_a_tiled_title_that_turns_does_not_cost_the_play_scene_its_layers
    b = Builder.new
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    square = filled_map(32, 32)
    b.instance_eval do
      screen :tiled
      var :state, 0
      tiles :t, "#" => :i_blue
      scene(:title) do
        background :rays, tiles: :t, map: map
        background :name, tiles: :t, map: map
        background(:sword, tiles: :t, map: square).scale(1.0)
      end
      scene(:play) do
        %i[ground scenery panel letters].each { |name| background name, tiles: :t, map: map }
      end
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.emit_pending_functions

    report = validator.run(b.program, autofix: false)

    assert report.ok?, "the title's turning layer cost the play scene its four: #{messages(report)}"
  end

  # ...and the screen that DOES turn one is still held to what fits beside it. Said here
  # because the change above loosens the count, and a loosened count that stopped refusing
  # anything at all would be worse than the one it replaced.
  def test_a_scene_that_turns_one_still_cannot_stack_three_beside_it
    b = Builder.new
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    square = filled_map(32, 32)
    b.instance_eval do
      screen :tiled
      var :state, 0
      tiles :t, "#" => :i_blue
      scene(:title) do
        %i[one two three].each { |name| background name, tiles: :t, map: map }
        background(:sword, tiles: :t, map: square).scale(1.0)
      end
      game_loop do
        wait_vblank
        case_var(:state) { when_val 0, :title }
      end
    end
    b.emit_pending_functions

    report = validator.run(b.program, autofix: false)

    refute report.ok?, "three scrolling layers were allowed beside a turning one"
    assert_match(/:title/, messages(report), "the refusal does not say which scene ran out")
  end

  # TWO SCENES CAN EACH TURN A BACKGROUND OF THEIR OWN. The console turns one at a time, and
  # these two are never up at the same time — a title that zooms, handing over to a map
  # screen that spins. Counted across the program they read as two turners and the game was
  # refused outright.
  def test_two_scenes_can_each_turn_a_background_of_their_own
    b = Builder.new
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    square = filled_map(32, 32)
    b.instance_eval do
      screen :tiled
      var :state, 0
      tiles :t, "#" => :i_blue
      scene(:title) do
        background :backdrop, tiles: :t, map: map
        background(:sword, tiles: :t, map: square).scale(1.0)
      end
      scene(:map_screen) do
        background :paper, tiles: :t, map: map
        background(:world, tiles: :t, map: square).scale(1.0)
      end
      game_loop do
        wait_vblank
        case_var(:state) do
          when_val 0, :title
          when_val 1, :map_screen
        end
      end
    end
    b.emit_pending_functions

    report = validator.run(b.program, autofix: false)

    assert report.ok?, "two scenes that never share a screen were counted together: #{messages(report)}"
  end

  # ...and ONE screen still cannot turn two, which is the fact about the console that the
  # count above must not lose. The message names the scene and points at the turning
  # background, not at a scrolling one — advice that pointed at the wrong layer could not be
  # followed.
  def test_one_scene_still_cannot_turn_two_backgrounds
    b = Builder.new
    solid_tile(b, :i_blue)
    square = filled_map(32, 32)
    b.instance_eval do
      screen :tiled
      var :state, 0
      tiles :t, "#" => :i_blue
      scene(:title) do
        background(:sword, tiles: :t, map: square).scale(1.0)
        background(:shield, tiles: :t, map: square).scale(1.0)
      end
      game_loop do
        wait_vblank
        case_var(:state) { when_val 0, :title }
      end
    end
    b.emit_pending_functions

    report = validator.run(b.program, autofix: false)

    refute report.ok?, "one screen was allowed to turn two backgrounds"
    assert_match(/:title/, messages(report), "the refusal does not say which scene ran out")
    assert_match(/turns or resizes 2/, messages(report))
  end

  private def messages(report) = report.findings.map(&:message).join(" | ")

  # No false alarm: a program drawn entirely on a bitmap screen stamps each background
  # into its one picture where it is declared, so it has no layers to run out of. A
  # program that ALSO has a tiled scene is a different case, and its bitmap backgrounds
  # are counted — see the note on which side of the count is per screen.
  def test_a_program_drawn_only_on_a_bitmap_screen_has_no_layers_to_run_out_of
    b = Builder.new
    b.instance_eval { screen :bitmap }
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    b.instance_eval do
      tiles :t, "#" => :i_blue
      %i[one two three four five six].each { |name| background name, tiles: :t, map: map }
      halt
    end
    b.emit_pending_functions

    report = validator.run(b.program, autofix: false)
    assert report.ok?
    assert_empty report.findings
  end

  # WHERE THE AUTHOR IS SENT. A finding blames a node, and the node it blames is the
  # first layer with nowhere to go — not the first layer in the stack, which fits.
  def test_the_finding_blames_a_layer_that_has_nowhere_to_go
    report = validator.run(five_scrolling_layers, autofix: false)
    assert_equal :five, report.errors.first.node.name
  end

  # A SECOND BACKGROUND THAT TURNS is the other refusal, and it is reported FIRST when a
  # program has both problems: cutting a scrolling layer would not save it, and the
  # arrangement the scrolling ones were counted against is not one the console has.
  def test_a_second_turning_background_is_reported_before_the_count
    b = Builder.new
    b.instance_eval { screen :tiled }
    solid_tile(b, :i_blue)
    map = filled_map(30, 20)
    square = filled_map(32, 32)
    b.instance_eval do
      tiles :t, "#" => :i_blue
      %i[one two three].each { |name| background name, tiles: :t, map: map }
      background(:spin, tiles: :t, map: square).scale(1.0)
      background(:whirl, tiles: :t, map: square).scale(1.0)
      halt
    end
    b.emit_pending_functions

    message = validator.run(b.program, autofix: false).errors.first.message
    assert_match(/turns or resizes 2 backgrounds/, message, "it says how many turn")
    assert_match(/can turn 1 background/, message, "...and how many the console turns")
    refute_match(/scrolling/, message, "and does not send the author to cut a scrolling layer")
  end

  # THE GAP THIS CLOSES. The interpreter is the answer key a game's own tests run
  # against, and it has no layers of its own — only a picture — so it drew five happily
  # while the cartridge refused them. Now it refuses in the same sentence.
  def test_the_interpreter_refuses_what_the_console_could_not_show
    error = assert_raises(Reference::ProgramError) { Reference.new.run(five_scrolling_layers) }
    assert_equal validator.run(five_scrolling_layers, autofix: false).errors.first.message,
                 error.message
  end

  # ONE RULE, ONE WORDING. The lowering keeps a refusal of its own, so a program that
  # skipped the guardrails still cannot build a cartridge that drops a layer — and it
  # comes here for the words, so the three can never say different things.
  def test_the_lowering_refuses_in_exactly_the_same_words
    error = assert_raises(GBA::LoweringError) { GBA.new.lower(five_scrolling_layers) }
    assert_equal validator.run(five_scrolling_layers, autofix: false).errors.first.message,
                 error.message
  end

  # At build time this stops the build, with the explanation on the err stream.
  def test_build_stops_on_more_layers_than_the_console_stacks
    err = StringIO.new
    assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("LAYERS", out: StringIO.new, err: err) do
        screen :tiled
        image(:i_blue, "#" => :blue) { "########\n" * 8 }
        tiles :t, "#" => :i_blue
        %i[one two three four five].each { |name| background name, tiles: :t, map: Array.new(20) { "#" * 30 } }
        game_loop { wait_vblank }
      end
    end
    assert_match(/shows 5 scrolling backgrounds at one time/, err.string)
    assert_match(/4 scrolling backgrounds/, err.string, "and says how many the console stacks")
  end
end
