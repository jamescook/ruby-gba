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
    assert_match(/flags\.set flags \| 4/, findings.first.message)
  end

  def test_the_message_warns_about_the_ruby_shorthand_too
    findings = findings_for do
      screen :bitmap
      hp = var :hp, 10
      hp += 1            # `hp.add 1` was meant
      halt
    end

    assert_equal 1, findings.length
    assert_match(/hp\.add 1/, findings.first.message)
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

  # --- ordinary code that must not be flagged ---

  def test_the_same_thing_written_correctly_is_not_reported
    assert_nothing_reported {
      screen :bitmap
      flags = var :flags, 0
      hp = var :hp, 10
      flags.set flags | 4
      hp.add 1
      (hp > 5).then { flags.set flags & ~4 }
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
        s.y.add s.vy
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
      drops.each { |d| d.y.add d.vy }
      halt
    }
  end

  # --- the real build path ---

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
      game_loop { flags.set flags | 4 }
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
    builder.emit_pending_functions
    Checks::OrphanedExpression.new(builder.expressions).detect(builder.program)

    assert_empty builder.pending_conditions.map(&:source),
                 "reporting an unused expression invented a comparison of its own"
  end

  private

  def findings_for(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
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
