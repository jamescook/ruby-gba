# frozen_string_literal: true

require "test_helper"

# `list :name, capacity: N` — a bounded, ordered collection whose length changes
# at run time. Assert its behavior through the reference interpreter (the oracle):
# build a small program that pushes, drops, indexes, and iterates, then read the
# variables it leaves behind. Overflow / underflow / out-of-range surface as
# friendly ProgramErrors, checked headlessly.
class TestList < Minitest::Test
  Build = RubyGBA::IR::Build

  # Run a DSL block through the interpreter and hand back the finished run, so a
  # test can read `interpret { ... }[:var]`. The block runs in the builder's
  # context. (Not named `run` — that would shadow Minitest::Test#run.)
  def interpret(&block)
    builder = Builder.new
    builder.instance_eval(&block)
    builder.emit_pending_functions
    Reference.new.run(builder.program)
  end

  # --- reading back what was pushed ---

  def test_push_then_read_by_index
    result = interpret do
      body = list :body, capacity: 8
      body.push 10
      body.push 20
      body.push 30
      set :a, body[0]
      set :b, body[1]
      set :c, body[2]
      halt
    end

    assert_equal 10, result[:a]
    assert_equal 20, result[:b]
    assert_equal 30, result[:c]
  end

  def test_length_tracks_pushes_and_drops
    result = interpret do
      body = list :body, capacity: 8
      body.push 1
      body.push 2
      body.push 3
      set :after_pushes, body.length
      body.shift
      set :after_shift, body.length
      body.pop
      set :after_pop, body.length
      halt
    end

    assert_equal 3, result[:after_pushes]
    assert_equal 2, result[:after_shift]
    assert_equal 1, result[:after_pop]
  end

  def test_shift_drops_the_oldest
    result = interpret do
      body = list :body, capacity: 8
      body.push 10
      body.push 20
      body.push 30
      body.shift # drops 10
      set :first, body.first
      set :len, body.length
      halt
    end

    assert_equal 20, result[:first], "the front is now the second item pushed"
    assert_equal 2, result[:len]
  end

  def test_pop_drops_the_newest
    result = interpret do
      body = list :body, capacity: 8
      body.push 10
      body.push 20
      body.push 30
      body.pop # drops 30
      set :last, body.last
      set :len, body.length
      halt
    end

    assert_equal 20, result[:last], "the back is now the second-to-last item pushed"
    assert_equal 2, result[:len]
  end

  def test_index_assignment_overwrites_a_slot
    result = interpret do
      body = list :body, capacity: 8
      body.push 10
      body.push 20
      body.push 30
      body[1] = 99
      set :a, body[0]
      set :b, body[1]
      set :c, body[2]
      halt
    end

    assert_equal [10, 99, 30], [result[:a], result[:b], result[:c]]
  end

  # --- iterating ---

  def test_each_visits_every_item_front_to_back
    result = interpret do
      body = list :body, capacity: 8
      body.push 10
      body.push 20
      body.push 30
      # Copy each item, in order, into a second list — so the order is observable.
      seen = list :seen, capacity: 8
      body.each { |cell| seen.push cell }
      set :s0, seen[0]
      set :s1, seen[1]
      set :s2, seen[2]
      set :count, seen.length
      halt
    end

    assert_equal [10, 20, 30], [result[:s0], result[:s1], result[:s2]]
    assert_equal 3, result[:count]
  end

  def test_each_over_an_empty_list_runs_the_body_no_times
    result = interpret do
      body = list :body, capacity: 8
      set :ran, 0
      body.each { |_cell| set :ran, 1 }
      halt
    end

    assert_equal 0, result[:ran], "the body never runs for an empty list"
  end

  # --- values flow through the coercion boundary ---

  def test_push_and_index_accept_variables_and_value_expressions
    result = interpret do
      v = var :v, 42
      body = list :body, capacity: 8
      body.push v            # push a Value
      body.push :v           # push by variable name (a Symbol)
      i = var :i, 1
      set :by_value, body[i] # index with a Value
      set :by_symbol, body[:i]
      halt
    end

    assert_equal 42, result[:by_value]
    assert_equal 42, result[:by_symbol]
  end

  # --- capacity ---

  # A LIST HOLDS WHAT IT WAS ASKED FOR, exactly. It used to hold the next power of two up,
  # because its storage was a ring whose index was wrapped with a mask — so `capacity: 3` quietly
  # held four, and the slots nobody planned for came out of the console's 32K. How the storage is
  # arranged is the backend's business; how full the list gets is the author's number.
  def test_a_list_holds_the_capacity_it_was_given_and_no_more
    result = interpret do
      body = list :body, capacity: 3
      body.push 1
      body.push 2
      body.push 3
      set :len, body.length
      halt
    end

    assert_equal 3, result[:len], "three fit"
    assert_raises(RubyGBA::IR::Backends::Reference::ProgramError) do
      interpret do
        body = list :body, capacity: 3
        4.times { |n| body.push n }
        halt
      end
    end
  end

  def test_pushing_past_capacity_raises_a_friendly_error
    err = assert_raises(Reference::ProgramError) do
      interpret do
        body = list :body, capacity: 2
        body.push 1
        body.push 2
        body.push 3 # capacity is 2 — overflow
        halt
      end
    end
    assert_match(/full/i, err.message)
  end

  # --- friendly errors on misuse ---

  def test_shifting_an_empty_list_raises
    err = assert_raises(Reference::ProgramError) do
      interpret do
        body = list :body, capacity: 4
        body.shift
        halt
      end
    end
    assert_match(/empty/i, err.message)
  end

  def test_popping_an_empty_list_raises
    err = assert_raises(Reference::ProgramError) do
      interpret do
        body = list :body, capacity: 4
        body.pop
        halt
      end
    end
    assert_match(/empty/i, err.message)
  end

  def test_indexing_out_of_range_raises
    err = assert_raises(Reference::ProgramError) do
      interpret do
        body = list :body, capacity: 8
        body.push 10
        set :oops, body[5] # only index 0 exists
        halt
      end
    end
    assert_match(/out of range/i, err.message)
  end

  def test_using_a_list_before_it_is_created_raises
    # Built straight from the IR: the DSL can't express this (a handle only comes
    # from `list`), but a stray push must still fail loudly rather than silently.
    err = assert_raises(Reference::ProgramError) do
      Reference.new.run(Build.program(Build.list_push(:ghost, 1), Build.halt))
    end
    assert_match(/before it was created/i, err.message)
  end

  # --- Build-level: the constructors and the capacity rule ---

  class BuildContract < Minitest::Test
    Build = RubyGBA::IR::Build

    def test_list_new_stores_the_capacity_it_was_given
      assert_equal 3, Build.list_new(:x, 3).capacity
      assert_equal 100, Build.list_new(:x, 100).capacity
    end

    # The rounding is still here, and is still the rule every backend shares — but what it
    # decides now is how much ROOM a backend sets aside for a list it wraps an index into,
    # not how many items the list holds.
    def test_round_up_capacity_covers_the_boundaries
      {
        1 => 1, 2 => 2, 3 => 4, 4 => 4, 5 => 8,
        8 => 8, 9 => 16, 100 => 128, 256 => 256
      }.each do |requested, rounded|
        assert_equal rounded, Build.round_up_capacity(requested),
                     "#{requested} rounds up to #{rounded}"
      end
    end

    def test_capacity_must_be_a_positive_whole_number
      assert_raises(ArgumentError) { Build.list_new(:x, 0) }
      assert_raises(ArgumentError) { Build.list_new(:x, -4) }
    end

    def test_list_drop_direction_must_be_front_or_back
      assert Build.list_drop(:x, from: :front)
      assert Build.list_drop(:x, from: :back)
      assert_raises(ArgumentError) { Build.list_drop(:x, from: :sideways) }
    end
  end

  # --- `estimate: { usually: N }`, which the estimate reads and the game never does ---

  # The whole claim of the hint: it says something about the list to `rom.explain` and
  # changes nothing about what the program does. Same pushes, same reads, same answers.
  def test_saying_how_long_a_list_usually_is_changes_nothing_about_the_run
    plain = interpret do
      body = list :body, capacity: 8
      3.times { |n| body.push n }
      set :len, body.length
      set :last, body[2]
      halt
    end
    hinted = interpret do
      body = list :body, capacity: 8, estimate: { usually: 2 }
      3.times { |n| body.push n }
      set :len, body.length
      set :last, body[2]
      halt
    end

    assert_equal 3, hinted[:len]
    assert_equal plain[:len], hinted[:len]
    assert_equal plain[:last], hinted[:last]
  end

  # A range says a length that moves. The estimate counts its top, so this is stored as
  # one number — the surface takes the range, the program keeps the answer.
  def test_a_range_is_kept_as_its_top
    builder = Builder.new
    builder.instance_eval { list :body, capacity: 64, estimate: { usually: 4..12 } }

    assert_equal 12, builder.program.walk.find { |n| n.kind == :list_new }.usually
  end

  # A hint the surface does not know is an ERROR, not a shrug. A misspelled key that
  # quietly did nothing would leave the report calling the number a guess while the author
  # believed they had answered it.
  def test_a_hint_it_does_not_know_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval { list :body, capacity: 8, estimate: { usualy: 2 } }
    end
    assert_match(/usualy/, error.message)
    assert_match(/usually/, error.message, "and names the one it does know")
  end

  # A range so wide it covers the whole list is not an answer — it is the assumption the
  # estimate already had to make, dressed up as a fact somebody checked.
  def test_a_range_wider_than_half_the_capacity_is_refused
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval { list :body, capacity: 64, estimate: { usually: 0..63 } }
    end
    assert_match(/usual length/, error.message)
  end

  def test_a_length_bigger_than_the_capacity_is_refused
    assert_raises(ArgumentError) { Build.list_new(:x, 8, usually: 9) }
    assert_raises(ArgumentError) { Build.list_new(:x, 8, usually: 0) }
    assert_equal 8, Build.list_new(:x, 8, usually: 8).usually
  end
end
