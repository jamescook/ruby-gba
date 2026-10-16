# frozen_string_literal: true

require "test_helper"

# An expression built and never kept did nothing, and used to say nothing.
#
# The shape that matters is the C one: setting a flag is `flags |= MASK`, and both ways
# a person carries that over are silent — `flags | MASK` on its own line throws the
# answer away, and `flags |= MASK` is read by Ruby as `flags = flags | MASK`, which
# points the Ruby name at a new expression and leaves the game's variable alone.
#
# The other half of these tests is the half that decides whether the check is usable at
# all: ordinary code that must NOT be flagged. Pushing onto a list, mutating a pool
# field, naming a handle — each of those used to look exactly like the mistake, because
# the framework built a throwaway expression of its own to borrow the scale rules.
class TestOrphanedExpression < Minitest::Test
  Checks = RubyGBA::IR::Guardrails::Checks

  # --- the mistake ---

  def test_an_expression_nobody_kept_is_reported
    findings = findings_for do
      screen :bitmap
      flags = var :flags, 0
      flags |= 4         # Ruby: `flags = flags | 4` — the Ruby name moves, the game's
      halt               # variable does not. Ruby itself says nothing about this one.
    end

    assert_equal 1, findings.length
    assert_match(/did nothing with it/, findings.first.message)
    assert_match(/flags\.set! flags \| 4/, findings.first.message)
  end

  def test_the_message_warns_about_the_ruby_shorthand_too
    findings = findings_for do
      screen :bitmap
      hp = var :hp, 10
      hp += 1            # `hp.add! 1` was meant
      halt
    end

    assert_equal 1, findings.length
    assert_match(/hp\.add! 1/, findings.first.message)
  end

  def test_it_is_an_error_not_a_warning
    findings = findings_for do
      screen :bitmap
      hp = var :hp, 10
      hp *= 2
      halt
    end

    assert_equal :error, findings.first.severity
  end

  # One finding per dropped expression, not one per node inside it: the inner parts of
  # `(a + b) | c` are wired into the outer one, so only the outer is homeless.
  def test_a_nested_expression_is_reported_once
    findings = findings_for do
      screen :bitmap
      a = var :a, 1
      b = var :b, 2
      _packed = (a + b) | a
      halt
    end

    assert_equal 1, findings.length
  end

  # `d.abs` on a line of its own used to change d. Now it is a new number nobody kept, and
  # the likeliest meaning is the `!` word, so the message names it — for each of the five.
  def test_a_word_that_used_to_change_a_variable_names_its_bang_form
    findings = findings_for do
      screen :bitmap
      d = var :d, -3
      d.abs
      d.clamp 0, 9
      d.approach 10, 2
      d.flip
      d.negate_abs
      halt
    end

    assert_equal %w[d.abs! d.clamp! d.approach! d.flip! d.negate_abs!],
                 findings.map { |finding| finding.message[/write `([^`]+)`/, 1] }
    assert_match(/`d\.abs` works out a new number/, findings.first.message)
  end

  # A number worked out from a sum has no variable to change, so nothing names a `!` word.
  def test_a_new_number_from_a_sum_gets_the_ordinary_message
    findings = findings_for do
      screen :bitmap
      d = var :d, -3
      (d + 10).abs
      halt
    end

    assert_match(/did nothing with it/, findings.first.message)
    refute_match(/abs!/, findings.first.message)
  end

  def test_a_pool_fields_old_word_names_the_field
    findings = findings_for do
      screen :bitmap
      guards = pool :guard, x: 0, capacity: 4
      guards.each { |g| g.x.clamp 0, 239 }
      halt
    end

    assert_match(/write `x\.clamp!`/, findings.first.message)
  end

  # The flat verbs that name a variable have no new number to give, so the old spelling
  # stops the build on the spot.
  def test_a_flat_verb_without_its_bang_is_a_friendly_error
    err = assert_raises(ArgumentError) { findings_for { abs :d } }

    assert_match(/`abs :d` does not change a variable/, err.message)
    assert_match(/write `abs! :d`/, err.message)
  end

  # --- ordinary code that must not be flagged ---

  def test_the_same_thing_written_correctly_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      flags = var :flags, 0
      hp = var :hp, 10
      flags.set! flags | 4
      hp.add! 1
      (hp > 5).then { flags.set! flags & ~4 }
      halt
    }
  end

  # A handle names a place that keeps a number, so writing one down is pointless but
  # harmless — unlike an expression, there was no work to throw away.
  def test_naming_a_handle_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      hp = var :hp, 10
      _named = hp
      halt
    }
  end

  # Pushing onto a list checks the value against what the list holds. That check used to
  # build a throwaway expression, so this ordinary line reported an orphan.
  def test_pushing_onto_a_list_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      xs = list :xs, capacity: 8
      xs.push 3
      xs[0] = 4
      halt
    }
  end

  def test_pushing_a_fraction_onto_a_list_that_holds_them_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      speeds = list :speeds, capacity: 8, holds: 0.0
      speeds.push 1.5
      halt
    }
  end

  # Mutating a pool field goes through a handle whose node is never read, so it looked
  # unparented; and spawning checks each field the same way a list checks an item.
  def test_working_a_pool_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      sparks = pool :spark, x: 0, y: 0, vy: 0, capacity: 8
      sparks.spawn(x: 10, y: 0, vy: 2)
      sparks.each do |s|
        s.y.add! s.vy
        (s.y > 160).then { s.remove }
      end
      halt
    }
  end

  def test_a_pool_field_holding_a_fraction_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      drops = pool :drop, y: 0.0, vy: 0.0, capacity: 8
      drops.spawn(y: 0.0, vy: 1.5)
      drops.each { |d| d.y.add! d.vy }
      halt
    }
  end

  # --- what the framework hands a block is not the author's to have thrown away ---

  # A ROUTINE OF A POOL IS HANDED THE INSTANCE THE WALK IS ON, and it is the framework that
  # builds that instance's place for it. A routine with nothing to say about its instance —
  # a kind of thing with no picture, in a cast that each run a routine to draw — left that
  # unused, and the game was told it had worked out a number and thrown it away.
  def test_a_pool_routine_that_does_nothing_with_its_instance_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      things = pool :things, x: 0, y: 0, capacity: 2
      things.func(:thing_waits) { |_thing| }
      game_loop { things.each { call :thing_waits } }
    }
  end

  # A bend is handed the row it is working out, and a bend the same on every row ignores it.
  def test_a_row_bend_that_ignores_its_row_is_not_reported
    assert_nothing_reported {
      screen :tiled
      image(:bar, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :stripes, "#" => :bar
      water = background :water, tiles: :stripes, map: Array.new(20) { "#" * 30 }
      drift = var :drift, 0
      water.scroll_each_row { |_row| drift }
      game_loop { drift.add! 1 }
    }
  end

  # A drawing order's block is handed each thing of a pool, and one that keeps every thing of
  # that pool at one depth ignores it.
  def test_a_drawing_order_that_ignores_a_pools_thing_is_not_reported
    assert_nothing_reported {
      screen :tiled
      image(:block, "#" => :red) { (["#" * 16] * 16).join("\n") }
      hero = sprite :block, at: [40, 40]
      puffs = pool :puff, x: 0, y: 0, capacity: 2, image: :block
      draw_in_order(hero, puffs) { |thing| thing == hero ? hero.y : 200 }
      game_loop { hero.move :down, by: 1 }
    }
  end

  # What a routine is handed is still not a variable of the game's: the number of the slot its
  # instance is in can be read and worked from, and not written over.
  def test_the_slot_a_pool_routine_is_handed_cannot_be_written_over
    error = assert_raises(ArgumentError) do
      findings_for do
        screen :bitmap
        things = pool :things, x: 0, y: 0, capacity: 2
        things.func(:thing_jumps) { |thing| thing.index.set! 1 }
        game_loop { things.each { call :thing_jumps } }
      end
    end

    assert_match(/only a variable can be changed/, error.message)
  end

  # ...and a number that really is worked out and dropped inside such a routine still is
  # reported, at the routine's own line.
  def test_a_number_thrown_away_inside_a_pool_routine_is_reported_at_its_line
    line = nil
    findings = findings_for do
      screen :bitmap
      things = pool :things, x: 0, y: 0, capacity: 2
      things.func(:thing_drifts) do |thing|
        line = __LINE__ + 1
        thing.x + 1
      end
      game_loop { things.each { call :thing_drifts } }
    end

    assert_equal 1, findings.size
    assert_match(/test_orphaned_expression\.rb:#{line}\z/, findings.first.source)
  end

  # --- the real build path ---

  # The smallest game that used to be stopped: a pool, a routine with nothing in it, a walk.
  def test_a_game_whose_pool_routine_is_empty_builds
    err = StringIO.new
    rom = RubyGBA.build("EMPTY", err: err, out: StringIO.new) do
      screen :bitmap
      things = pool :things, x: 0, y: 0, capacity: 2
      things.func(:thing_waits) { |_thing| }
      game_loop { things.each { call :thing_waits } }
    end

    assert rom, "the game builds"
    refute_match(/did nothing with it/, err.string)
  end

  def test_it_stops_a_real_build_and_says_where
    err = StringIO.new

    ex = assert_raises(RubyGBA::ROMError) do
      RubyGBA.build("FLAGS", code: "BFLG", maker: "01", err: err) do
        screen :bitmap
        flags = var :flags, 0
        game_loop { flags |= 4 }
      end
    end

    assert_match(/stopped/, ex.message)
    assert_match(/did nothing with it/, err.string)
    assert_match(/test_orphaned_expression\.rb:\d+/, err.string, "it must name the author's line")
  end

  def test_the_same_game_written_correctly_builds
    rom = RubyGBA.build("FLAGS", code: "BFLG", maker: "01", err: StringIO.new) do
      screen :bitmap
      flags = var :flags, 0
      game_loop { flags.set! flags | 4 }
    end

    assert rom, "correct code must still build"
  end

  # A finding has to be able to say WHERE, or it sends the reader nowhere.
  def test_a_finding_names_the_line_the_author_wrote
    findings = findings_for do
      screen :bitmap
      hp = var :hp, 10
      hp += 1
      halt
    end

    assert_match(/test_orphaned_expression\.rb:\d+/, findings.first.source)
  end

  # A Value answers `==` with a comparison to be branched on later, not with a boolean.
  # Anything asking a finding's node `== :program` therefore got a truthy Condition —
  # the wrong answer, and a stray comparison left behind for the orphaned-Condition
  # guardrail to report. Building a finding must leave the build exactly as it found it.
  def test_reporting_one_leaves_no_stray_comparison_behind
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      hp = var :hp, 10
      hp += 1
      halt
    end
    builder.finalize_program
    Checks::OrphanedExpression.new(builder.expressions).detect(builder.program)

    assert_empty builder.pending_conditions.map(&:source),
                 "reporting an unused expression invented a comparison of its own"
  end

  private

  def findings_for(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    program = builder.program
    Checks::OrphanedExpression.new(builder.expressions).detect(program)
  end

  # Assert nothing was reported, saying WHERE rather than dumping the whole finding —
  # a finding holds a Value, which holds the builder, which inspects to several pages.
  def assert_nothing_reported(&block)
    reported = findings_for(&block).map(&:source)

    assert_empty reported, "ordinary code was reported as an expression nobody kept"
  end
end
