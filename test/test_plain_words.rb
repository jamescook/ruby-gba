# frozen_string_literal: true

require "test_helper"
require "ripper"
require "stringio"

# ONE THING, ONE NAME.
#
# A build talks in four places that never meet — a progress line while it works, a guardrail's
# warning, a build error, `rom.explain` at the end — and each of them has the same small job
# somewhere in it: say what the machine knows in English. Done four times, the answers drift
# apart, and the console's 32K of fast memory is what that looks like — three different names
# for it in ONE build. A learner cannot tell three names for one thing from three things.
#
# So the English lives in {RubyGBA::PlainWords} and this fails when a second name for one
# thing turns up. Two shapes of drift, and they need different tests:
#
#   A WORD COMES BACK. Nothing stops somebody typing "fast RAM" into a new message, and no
#   other test would notice — the message would read fine on its own. So every string a build
#   can print is scanned for the names this thing must NOT be given. Comments are left alone
#   on purpose: a comment teaches the hardware and may name IWRAM outright.
#
#   A SECOND COPY APPEARS. A reader that stopped asking PlainWords would drift the moment
#   somebody reworded one and not the other, and until then nothing would show. So the name
#   is replaced and both readers are made to say the new one — which they can only do if
#   they really are reading the one place.
class TestPlainWords < Minitest::Test
  PlainWords = RubyGBA::PlainWords
  Placement = RubyGBA::IR::Backends::GBA::Placement

  LIB = File.expand_path("../lib", __dir__)

  # --- a word that came back ---

  def test_the_quick_memory_is_called_that_and_nothing_else
    banned = PlainWords::NOT_CALLED.fetch(PlainWords::QUICK_MEMORY)
    found = string_literals_in_lib.select { |s| banned.any? { |pattern| s[:text].match?(pattern) } }

    assert_empty found.map { |s| "#{s[:file]}:#{s[:line]}  #{s[:text].strip}" },
                 "a build says #{PlainWords::QUICK_MEMORY.inspect} and nothing else — write " \
                 "PlainWords::QUICK_MEMORY, or say it in a comment where the hardware can be named"
  end

  # A scan that read nothing would pass in silence, which is the one way a test like the last
  # one is worse than no test at all. So make it show its work: a body of strings, the right
  # name among them, and a wrong one it really would catch.
  def test_the_scan_reads_the_whole_framework
    literals = string_literals_in_lib

    assert_operator literals.length, :>, 1000, "the string scan found almost nothing — is it reading lib/?"
    assert(literals.any? { |s| s[:text].include?(PlainWords::QUICK_MEMORY) },
           "the right name should turn up in the strings the scan reads")
    assert_match(PlainWords::NOT_CALLED.fetch(PlainWords::QUICK_MEMORY).first,
                 "This program reserves about 40KB of fast RAM.",
                 "...and a wrong one should match a pattern")
  end

  # --- a second copy of a name ---

  # The two routines nobody wrote. The build treats a game loop's body and the routine the
  # console interrupts into as routines, so both turn up in a progress line and again in
  # `rom.explain` minutes later — two places far enough apart that only a shared name keeps
  # them saying the same thing.
  def test_the_routines_nobody_wrote_are_named_in_one_place
    said = "a routine with one name"
    progress = StringIO.new
    explained = StringIO.new

    while_it_says(:routine, said) do
      rom = a_game_worth_moving(progress: RubyGBA::Progress.to(progress))
      rom.explain(out: explained)
    end

    assert_includes progress.string, said, "the progress line names a routine from PlainWords"
    assert_includes explained.string, said, "...and so does rom.explain"
  end

  # ...and the machine names it answers to are the build's own, not a second copy of the two
  # symbols. Placement decides what a routine is called internally; PlainWords only says it.
  def test_the_names_it_answers_to_are_the_builds_own
    assert_equal [Placement::FRAME_ROUTINE, Placement::IRQ_ROUTINE,
                  RubyGBA::IR::Backends::GBA::Divide::ROUTINE,
                  RubyGBA::IR::Backends::GBA::Divide::FIX_ROUTINE,
                  RubyGBA::IR::Backends::GBA::Mixer::ROUTINE],
                 PlainWords::ROUTINES.keys
  end

  # A routine somebody did write is given back the way they would type it, from the same place.
  def test_a_routine_the_author_wrote_is_named_the_way_they_wrote_it
    assert_equal "func :draw_hud", PlainWords.routine(:draw_hud)
  end

  # THE SAME DRIFT ONE STEP FURTHER OUT. The glyph routine each font gets is named by the
  # lowering, by building the name up out of the font's own, so PlainWords cannot hold the
  # symbol and has to know the SHAPE of it instead — which is a second copy of a naming rule
  # rather than of a name, and drifts the same way. A real build is the only thing that
  # settles it: reword either side and this routine goes back to being reported as a `func`
  # nobody wrote.
  def test_the_glyph_routine_a_font_gets_is_named_from_what_the_author_typed
    rom = RubyGBA.build("DIGIT", code: "DIGI", maker: "01") do
      screen :bitmap
      var :score, 0
      game_loop { draw_number :score, 10, 10, :white, digits: 3 }
    end

    made_up = rom.built.routines.keys.grep(/digit/)
    refute_empty made_up, "a game that draws a number gets a glyph routine to draw it with"
    made_up.each do |name|
      assert_match(/draw_number/, PlainWords.routine(name),
                   "#{name} is reported in terms of the verb the author typed")
    end
  end

  # The verb an author typed. A `draw_number` becomes a `draw_digit` node and a `sprite` becomes
  # a `blit_pose`, so a message naming the kind names something nobody wrote. Two messages have
  # to get this right — a guardrail's, and the builder's refusal to put paint in a layer.
  def test_one_table_says_what_verb_an_author_typed
    said = "the verb you typed"

    both = while_it_says(:verb, said) do
      [assert_raises(ArgumentError) { a_number_drawn_in_a_layer }.message,
       RubyGBA::IR::Guardrails::TiledDisplay.verb_for(:draw_digit)]
    end

    both.each { |said_by_a_reader| assert_includes said_by_a_reader, said }
  end

  def test_the_verb_an_author_typed_is_the_one_they_would_recognize
    assert_equal "draw_number", PlainWords.verb(:draw_digit)
    assert_equal "sprite", PlainWords.verb(:blit_pose)
    assert_equal "fill_rect", PlainWords.verb(:fill_rect) # a kind that IS the verb, unchanged
  end

  # --- what a guardrail check is called ---

  # A check's name reaches a person in exactly one place: the progress line while the build
  # works. A finding says what went wrong in a sentence of its own and never names the check
  # that found it. So the name has to say what the check LOOKS FOR, and the check is the only
  # thing that knows — which is why it declares one instead of the pass guessing from the
  # identifier.
  def test_every_check_says_its_own_plain_name
    missing = checks.reject { |check| check.class.const_defined?(:PLAIN_NAME, false) }

    assert_empty missing.map { |check| check.class.name },
                 "each check declares PLAIN_NAME beside NAME — a short phrase for what it looks for"
  end

  def test_no_check_answers_to_a_name_another_one_uses
    names = named_checks.map { |klass| klass::PLAIN_NAME }

    assert_equal names.uniq, names, "two checks with one name make a progress line that lies"
  end

  # Spelling the identifier out is the easy name and the wrong one: it hands a learner whatever
  # hardware word happens to be in it ("vblank sync", "iwram budget"). A declared name equal to
  # that spelling is the guess left standing.
  def test_no_check_is_named_by_spelling_its_identifier_out
    spelled_out = named_checks.select do |klass|
      klass.const_defined?(:NAME, false) && klass::PLAIN_NAME == klass::NAME.to_s.tr("_", " ")
    end

    assert_empty spelled_out.map { |klass| klass::PLAIN_NAME },
                 "say what the check looks for, not its identifier with the underscores taken out"
  end

  # The one check whose identifier IS a hardware word, so its declared name has the most to do.
  def test_the_quick_memory_check_is_named_after_the_memory_a_person_reads_about
    named = named_checks.find { |klass| klass.const_defined?(:NAME, false) && klass::NAME == :iwram_budget }

    assert_includes named::PLAIN_NAME, PlainWords::QUICK_MEMORY
  end

  private

  # The checks that declare a name, so a check that declares NONE fails one test — the coverage
  # one above, which says so plainly — instead of raising out of every test that reads a name.
  def named_checks
    checks.map(&:class).select { |klass| klass.const_defined?(:PLAIN_NAME, false) }
  end

  # Give PlainWords a different answer for the length of the block. A reader that really asks
  # it says the new word; one that kept a copy of its own carries on saying the old one, which
  # is the drift this file exists to catch.
  def while_it_says(method, said)
    was = PlainWords.method(method)
    in_place_of(method, ->(_) { said })
    yield
  ensure
    in_place_of(method, was)
  end

  # Take the definition out before putting one in, so swapping a name back and forth does not
  # fill the run with "method redefined" on a file that is only doing what it says.
  def in_place_of(method, body)
    PlainWords.singleton_class.remove_method(method)
    PlainWords.define_singleton_method(method, body)
  end

  def checks
    RubyGBA::IR::Guardrails.default_checks
  end

  # Every string literal under lib/, with where it was written. Ripper rather than a grep so a
  # comment cannot be mistaken for something a person is shown — the difference is the whole
  # point of the scan. Interpolation is not string content, so a message built from
  # PlainWords::QUICK_MEMORY reads as the hole between two literals and never matches.
  def string_literals_in_lib
    Dir["#{LIB}/**/*.rb"].sort.flat_map do |path|
      Ripper.lex(File.read(path)).filter_map do |(line, _col), type, text, _state|
        { file: path.delete_prefix("#{LIB}/"), line: line, text: text } if type == :on_tstring_content
      end
    end
  end

  # A game with enough per-frame work that the build finds a routine worth moving, so both the
  # progress line and the report have something to name.
  def a_game_worth_moving(progress:)
    RubyGBA.build("NAMES", code: "ANAM", maker: "01", out: StringIO.new, err: StringIO.new,
                           progress: progress) do
      screen :bitmap
      spin = var :spin, 0
      game_loop do
        spin.add 1
        spin.clamp 0, 200
        fill_rect 0, 0, 40, 40, :blue
        pixel 10, 10, :red
      end
    end
  end

  # `draw_number` inside a layer on a bitmap screen: the framebuffer keeps the pixels where they
  # were painted, so no depth can move them afterwards, and the refusal has to name the verb the
  # author typed rather than the `draw_digit` node it became.
  def a_number_drawn_in_a_layer
    RubyGBA.build("LAYER", code: "ALAY", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      layers :world, :ui
      score = var :score, 0
      layer(:ui) { draw_number score, 8, 8, :white }
      game_loop { score.add 1 }
    end
  end
end
