# frozen_string_literal: true

require "test_helper"
require "differential"

# THE OTHER WORK MEMORY, and what it is for.
#
# The console has two, and they are not two sizes of the same thing: a quick one of 32K on the
# processor's own die, and a roomy one of 256K on a chip of its own that makes the processor
# wait about six times as long for a whole number. Everything a program declared used to come
# out of the quick one, and a program asking for more than fits did not build — while a quarter
# of a megabyte sat idle, touched by nothing but the audio mixer's two output buffers.
#
# And the quick one is also where the hot code goes, so a big cold collection sitting there
# quietly pushes a routine the frame spends its time in out to the cartridge. That is the
# expensive half, and it is invisible from the program.
#
# What an author writes is nothing, nearly always. `fast: false` says "I know this is cold —
# give it room"; `fast: true` insists. It is the same word `func` already takes for the same
# question about code.
class TestRoomyMemory < Minitest::Test
  include Differential

  private def build(title, &block)
    RubyGBA.build(title, code: "B#{title[0, 3]}", maker: "01",
                         out: StringIO.new, err: StringIO.new, &block)
  end

  private def roomy_of(rom) = rom.built.roomy_memory

  # --- a game that used to fail to build ---

  # 32K is 8192 whole numbers, and the quick memory also holds the variables and the code kept
  # there — so three lists of 4000 cannot all be in it. They used to be a build failure.
  def test_more_state_than_the_quick_memory_holds_still_builds
    rom = build("BIG") do
      screen :bitmap
      big_a = list :big_a, capacity: 4000
      big_b = list :big_b, capacity: 4000
      big_c = list :big_c, capacity: 4000
      game_loop { big_a.push 1; big_b.push 2; big_c.push 3 }
    end

    assert_operator rom.size, :>, 0, "it builds"
    assert_operator roomy_of(rom).used, :>, 0, "and something went in the roomy memory"
  end

  # --- the choice is made from what a frame touches, not declaration order ---

  # The bug this exists to prevent: a cold collection declared FIRST taking the quick memory
  # and pushing the one a frame walks every pass into the memory that waits.
  def test_a_cold_list_declared_first_does_not_push_a_hot_one_out
    rom = build("ORDER") do
      screen :bitmap
      cold = list :cold, capacity: 5000
      hot = list :hot, capacity: 5000
      cold.push 1 # touched once, at boot, and never again
      game_loop { hot.push 2 }
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, :cold, "the one no frame touches moved"
    refute_includes moved, :hot, "and the one a frame walks stayed where reads are quick"
  end

  # A routine the frame calls counts as the frame touching it — otherwise a game that puts its
  # work in `func`s, which is every game of any size, would look entirely cold.
  def test_a_list_touched_from_a_routine_the_frame_calls_counts_as_hot
    rom = build("CALLED") do
      screen :bitmap
      cold = list :cold, capacity: 5000
      hot = list :hot, capacity: 5000
      cold.push 1
      func(:step) { hot.push 2 }
      game_loop { call :step }
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, :cold
    refute_includes moved, :hot, "reached through a call, so a frame touches it"
  end

  # A game of any size puts its per-frame work in SCENES, reached by a multi-way dispatch
  # rather than by a plain call. Following only calls reads such a game as entirely cold —
  # measured on a raycaster, all twenty-six of its collections came back untouched — which
  # would move the very things a frame walks into the memory that waits.
  def test_a_list_touched_from_a_scene_counts_as_hot
    rom = build("SCENE") do
      screen :bitmap
      cold = list :cold, capacity: 5000
      hot = list :hot, capacity: 5000
      cold.push 1
      var :state, 0
      scene(:playing) { hot.push 2 }
      game_loop { case_var(:state) { when_val 0, :playing } }
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, :cold
    refute_includes moved, :hot, "a scene is where a game's per-frame work lives"
  end

  # --- what the author can say ---

  def test_fast_false_gives_the_quick_memory_back
    rom = build("SAID") do
      screen :bitmap
      world = list :world, capacity: 64, fast: false
      game_loop { world.push 1 }
    end

    assert_includes roomy_of(rom).collections.keys, :world,
                    "it moved although there was plenty of room"
  end

  def test_fast_true_keeps_a_list_in_the_quick_memory
    rom = build("KEPT") do
      screen :bitmap
      cold = list :cold, capacity: 5000, fast: true
      other = list :other, capacity: 5000
      cold.push 1
      game_loop { other.push 2 }
    end

    refute_includes roomy_of(rom).collections.keys, :cold,
                    "the author insisted, so it stayed however cold it looks"
  end

  # --- data and code share the quick memory by one rule ---

  # A ROUTINE THE AUTHOR INSISTED ON OUTRANKS A LIST NOBODY SAID ANYTHING ABOUT, however busy:
  # the list moves to the roomy memory and the build goes on, where it used to stop because the
  # list had taken the room first.
  def test_an_insisted_routine_moves_a_list_out_rather_than_stop_the_build
    rom = build("INSIST") do
      screen :bitmap
      hoard = list :hoard, capacity: 7300
      total = var :total, 0
      func(:tally, fast: true) { 200.times { total.add! 1 } }
      game_loop do
        hoard.push 1
        call :tally
      end
    end

    assert_includes rom.built.placement.funcs, :tally
    assert_includes roomy_of(rom).collections.keys, :hoard
  end

  # ...and the list the build moved for it still holds what was put in it: a stripe as wide as
  # what the game read back, the same on the console as on the interpreter.
  private def insisting_beside_a_hoard
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      hoard = list :hoard, capacity: 7300
      total = var :total, 0
      spin = var :spin, 0
      func(:tally, fast: true) { 200.times { spin.add! 1 } }
      clear_screen :black
      repeat(8) { hoard.push 3 }
      repeat(8) { |n| total.add! hoard[n] }
      draw_rect_at 0, 10, total, 4, :green
      game_loop { call :tally }
    end
    builder.finalize_program
    builder.program
  end

  def test_a_list_moved_for_an_insisted_routine_plays_as_the_oracle_does
    backend = GBA.new
    backend.lower(insisting_beside_a_hoard)

    assert_includes backend.roomy_memory_report.collections.keys, :hoard
    assert_backends_agree(insisting_beside_a_hoard, frames: 4)
  end

  # A POOL GIVES WAY WHOLE. It is a list for each field and a few of its own, and a walk of it
  # reads them side by side, so the build moves all of them or none — never the x of a thing to
  # the memory that waits while its y stays in the quick one.
  def test_a_pool_moved_for_an_insisted_routine_moves_all_its_columns
    rom = build("POOLMOVE") do
      screen :bitmap
      rocks = pool :rock, x: 0, y: 0, capacity: 400
      dust = list :dust, capacity: 5700
      spin = var :spin, 0
      func(:tally, fast: true) { 150.times { spin.add! 1 } }
      game_loop do
        rocks.spawn(x: 1, y: 2)
        rocks.each { |rock| rock.x.add! 1 }
        dust.push 1
        call :tally
      end
    end
    moved = roomy_of(rom).collections.keys.select { |name| name.to_s.include?("rock") }

    refute_empty moved, "the pool is what gave way"
    assert_equal %i[__poolfield_rock__x __poolfield_rock__y].to_set, moved.select { |name| name.to_s.start_with?("__poolfield") }.to_set
  end

  # A LIST NO FRAME TOUCHES GIVES WAY TO CODE A FRAME RUNS. Kept in the quick memory it buys
  # nothing — nobody waits on it — and it used to hold the room the game loop wanted, so the
  # whole frame ran from the cartridge.
  def test_a_list_no_frame_touches_gives_way_to_the_game_loop
    rom = build("GIVEWAY") do
      screen :bitmap
      cold = list :cold, capacity: 7300
      spin = var :spin, 0
      cold.push 1
      game_loop { 300.times { spin.add! 1 } }
    end

    assert_includes rom.built.placement.funcs, GBA::Placement::FRAME_ROUTINE
    assert_includes roomy_of(rom).collections.keys, :cold
  end

  # A list every frame writes to once, and a routine every frame runs a few thousand instructions
  # of, where the quick memory has room for one of the two.
  private def trickle_beside_busy_work
    RubyGBA.game("TRICKLE") do
      screen :bitmap
      trickle = list :trickle, capacity: TRICKLE_WORDS
      spin = var :spin, 0
      func(:busy) { BUSY_ADDS.times { spin.add! 1 } }
      game_loop do
        trickle[3] = spin
        call :busy
      end
    end
  end

  TRICKLE_WORDS = 6000
  BUSY_ADDS = 600

  # A LIST A FRAME BARELY READS GIVES WAY TO A ROUTINE IT RUNS ALL THE TIME, once the game is
  # measured. A word kept in the roomy memory costs a few cycles each time it is read, and a frame
  # that touches it once loses a few cycles; a routine left in the cartridge costs a cycle or so on
  # every instruction it runs. Without a measurement nothing says how often the list is read, so
  # the list a frame touches keeps the place it always had.
  def test_a_list_a_frame_barely_reads_gives_way_to_busy_code_once_measured
    measured = trickle_beside_busy_work.build_rom(out: StringIO.new, err: StringIO.new, profile: true).built
    guessed = trickle_beside_busy_work.build_rom(out: StringIO.new, err: StringIO.new, profile: false).built

    refute_includes moved_lists(guessed), :trickle, "unmeasured, the touched list keeps its place"
    refute_includes guessed.placement.funcs, :busy, "and the routine does not fit beside it"
    assert_includes measured.placement.funcs, :busy, "measured, the busy routine is kept"
    assert_includes moved_lists(measured), :trickle, "and the list moves to the roomy memory"
  end

  # Two screens, each with a routine of its own that a frame of it runs all the time, and a list
  # both write to once a frame. The left screen's routine is the smaller and runs three times a
  # frame, so it is the busier. The two routines do not fit together; the left one fits beside the
  # list, and the right one does not.
  private def trickle_beside_two_busy_screens
    RubyGBA.game("TRICKLE2") do
      screen :bitmap
      trickle = list :trickle, capacity: SHARED_TRICKLE_WORDS
      spin = var :spin, 0
      var :where, 0
      func(:left_work) { LEFT_ADDS.times { spin.add! 1 } }
      func(:right_work) { RIGHT_ADDS.times { spin.add! 2 } }
      scene(:left) { 3.times { call :left_work } }
      scene(:right) { call :right_work }
      game_loop do
        trickle[3] = spin
        pressed(:start).then { set! :where, 1 }
        case_var(:where) do
          when_val 0, :left
          when_val 1, :right
        end
      end
    end
  end

  SHARED_TRICKLE_WORDS = 2500
  LEFT_ADDS = 750
  RIGHT_ADDS = 1375

  # ...AND THE SAME IN A GAME THAT KEEPS A SET FOR EACH SCREEN. Each screen's routine goes in its
  # own screen's set, and the list a frame barely touches is what gives way. Weighed as something
  # every frame needs, the list went in ahead of both routines, and the right screen's routine ran
  # from the cartridge.
  def test_a_list_a_frame_barely_reads_gives_way_to_each_screens_busy_code
    built = trickle_beside_two_busy_screens.build_rom(out: StringIO.new, err: StringIO.new, profile: true).built
    kept = built.placement.funcs + built.placement.scenes.values.flatten

    assert_includes kept, :left_work
    assert_includes kept, :right_work, "each screen keeps its own busy routine"
    assert_includes moved_lists(built), :trickle
  end

  # The lists a build moved to the roomy memory; none where it moved nothing.
  private def moved_lists(built) = built.roomy_memory&.collections&.keys || []

  # A pool is one list per field, so it is the thing most likely to want this.
  def test_a_pool_can_be_given_room
    rom = build("POOL") do
      screen :bitmap
      pool :spark, x: 0, y: 0, life: 0, capacity: 64, fast: false
      game_loop {}
    end

    moved = roomy_of(rom).collections.keys
    assert_includes moved, RubyGBA::DSL::Pool.field_list(:spark, :x), "every one of its columns moved together"
    assert_includes moved, RubyGBA::DSL::Pool.field_list(:spark, :life)
  end

  # --- a collection's own counters go with it ---

  # A list keeps how many items it holds, and a list that is shifted keeps where its oldest
  # item is; a pool keeps a dozen more (how many are live, the first and last of its order,
  # where each walk of it has got to). Those are variables, and they used to stay in the quick
  # memory whatever the collection said, so a game that moved everything cold out still found
  # thirty to sixty variables a pool left behind.
  HARDWARE = RubyGBA::Console::Hardware
  QUICK = HARDWARE::IWRAM_START...(HARDWARE::IWRAM_START + HARDWARE::IWRAM_SIZE)

  POOL_NAMES = %i[pool_field pool_part].freeze

  # The variables the build made for a collection, by the name the author gave it.
  private def counters_of(rom, words)
    rom.var_addresses.select do |name, _address|
      kind, = RubyGBA::Messages::MadeNames.read(name)
      collection = name.to_s.delete_suffix("__len").delete_suffix("__head")
      POOL_NAMES.include?(kind) ? RubyGBA::Messages::MadeNames.collection_words(name) == words
                                : "list :#{collection}" == words
    end
  end

  private def in_quick_memory(counters) = counters.select { |_name, address| QUICK.cover?(address) }.keys

  def test_a_pool_given_room_keeps_its_own_counters_there
    rom = build("POOLVARS") do
      screen :tiled
      image(:dot, "#" => :white) { "########\n" * 8 }
      stood = pool :stood, x: 0, y: 0, hp: 0, capacity: 8, image: :dot, fast: false
      game_loop do
        pressed(:a).then { stood.spawn(x: 10, y: 10) }
        stood.each { |one| one.x.add! 1 }
      end
    end
    counters = counters_of(rom, "pool :stood")

    assert_includes counters.keys, RubyGBA::DSL::Pool.count_var(:stood), "the pool's count is among them"
    assert_empty in_quick_memory(counters), "these of the pool's own are still in the quick memory"
  end

  def test_a_list_given_room_keeps_its_length_and_its_oldest_there
    rom = build("LISTVARS") do
      screen :bitmap
      queue = list :queue, capacity: 16, width: :byte, fast: false
      game_loop do
        queue.push 3
        (queue.length > 8).then { queue.shift }
      end
    end
    counters = counters_of(rom, "list :queue")

    assert_equal 2, counters.size, "how many it holds, and where its oldest is"
    assert_empty in_quick_memory(counters)
  end

  # The build moves a collection no frame touches when the quick memory runs short, and its
  # counters go with it then too: the rule is where the collection went, not who said so.
  def test_a_list_the_build_moved_takes_its_length_with_it
    rom = build("MOVEDVARS") do
      screen :bitmap
      cold = list :cold, capacity: 5000
      hot = list :hot, capacity: 5000
      cold.push 1
      game_loop { hot.push 2 }
    end

    assert_empty in_quick_memory(counters_of(rom, "list :cold")), "the cold list's length moved with it"
    refute_empty in_quick_memory(counters_of(rom, "list :hot")), "and the hot one's stayed where it is quick"
  end

  # The counters are read and written on every spawn, removal, walk and draw, so a pool and a
  # list kept in the roomy memory are played here on both backends and every pixel compared:
  # things spawned, walked, removed when they reach the edge and drawn oldest in front, and a
  # list pushed and shifted whose length is a bar's width.
  private def roomy_counters_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:dot, "#" => :white) { "########\n" * 8 }
      image(:bar, "#" => :green) { "########\n" * 8 }
      stood = pool :stood, x: 0, y: 0, capacity: 4, image: :dot, fast: false
      queue = list :queue, capacity: 8, width: :byte, fast: false
      bar = sprite :bar, at: [0, 140]
      ticks = var :ticks, 0
      game_loop do
        ticks.add! 1
        ((ticks % 6) == 1).then { stood.spawn(x: 0, y: ticks) }
        stood.each do |one|
          one.x.add! 4
          (one.x > 40).then { one.remove }
        end
        queue.push 1
        (queue.length > 5).then { queue.shift }
        bar.move_to queue.length * 8, 140
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_the_console_plays_a_pool_and_a_list_kept_in_the_roomy_memory_as_the_oracle_does
    assert_backends_agree(roomy_counters_program, frames: 30)
  end

  # --- and it has to actually work ---

  # The one that matters: a list in the roomy memory is read and written like any other, and
  # the program comes out with the right answer. Held on both backends, since the interpreter
  # has one memory and the console has two — so agreeing means the addresses are right.
  private def counting_program
    builder = Builder.new
    builder.instance_eval do
      screen :bitmap
      far = list :far, capacity: 5000, fast: false
      total = var :total, 0
      clear_screen :black
      repeat(8) { far.push 3 }
      repeat(8) { |n| total.add! far[n] }
      # A stripe as wide as the total, so the console can be asked what it read back.
      draw_rect_at 0, 10, total, 4, :green
      game_loop { wait_vblank }
    end
    builder.finalize_program
    builder.program
  end

  def test_a_list_in_the_roomy_memory_holds_what_was_put_in_it
    assert_equal 24, Reference.new.run(counting_program)[:total]
  end

  # The counting program paints a stripe as wide as the total it read back, so the console
  # says the same number the oracle does — through a list the console keeps in its other
  # memory and the oracle keeps in a Ruby array.
  def test_the_console_reads_it_back_the_same
    rom = ROM.assemble(GBA.new.lower(counting_program), title: "FARLIST", code: "BFAR", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)

    assert v.pixel_is?(23, 10, :green), "24 pixels of stripe, so the total came back as 24"
    assert v.pixel_is?(24, 10, :black), "...and no more than 24"
  end

  # --- what the build says about it ---

  def test_the_report_names_what_moved_and_how_much_room_is_left
    rom = build("SAYS") do
      screen :bitmap
      world = list :world, capacity: 4096, fast: false
      game_loop { world.push 1 }
    end

    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: out)
    printed = out.string
    assert_match(/roomy memory/, printed)
    assert_match(/:world/, printed, "it names what moved")
    assert_match(/waits/, printed, "and says what that costs")
  end

  # A LIST THE MEASUREMENT MOVED SAYS WHAT IT WAS MEASURED AT, which is the reason it moved: the
  # trickle is written once a frame, and the routine kept in its place runs far more than that.
  def test_the_report_says_how_often_a_frame_touched_a_list_it_moved
    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(trickle_beside_busy_work.build_rom(out: StringIO.new, err: StringIO.new),
                                             out: out)

    assert_match(/list :trickle, read or written 1 time a frame/, out.string)
    assert_match(/code kept in its place saves more time/, out.string, "and why that moved it")
  end

  # A build that measured nothing has no count to say, and no reason of that kind.
  def test_an_unmeasured_report_names_a_moved_list_without_a_count
    rom = build("UNCOUNTED") do
      screen :bitmap
      world = list :world, capacity: 64, fast: false
      game_loop { world.push 1 }
    end
    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: out)

    assert_match(/list :world\n/, out.string, "the list is named, and nothing follows it on its line")
    refute_match(/saves more time/, out.string)
  end

  # A pool is one list a field and several of its own, under names the build made up. An
  # author declared one pool, so the report says one pool, with the bytes of all of them.
  def test_the_report_names_a_pool_that_moved_once_and_by_its_own_name
    rom = build("POOLSAYS") do
      screen :bitmap
      pool :spark, x: 0, y: 0, life: 0, capacity: 64, fast: false
      world = list :world, capacity: 64, fast: false
      game_loop { world.push 1 }
    end

    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: out)
    printed = out.string
    moved = roomy_of(rom).collections
    spark_bytes = moved.sum { |name, bytes| name.to_s.include?("spark") ? bytes : 0 }

    assert_equal 1, printed.scan("pool :spark").size, "one line for the one pool"
    assert_match(/#{Regexp.escape(format('%.1fK', spark_bytes / 1024.0))}\s+pool :spark/, printed)
    assert_match(/list :world/, printed, "and a list beside it reads as a list")
    refute_match(/__pool/, printed, "none of the names the build made up")
  end

  # A game whose state fits reads nothing about a second memory it never met.
  def test_a_game_that_fits_says_nothing_about_it
    rom = build("SMALL") do
      screen :bitmap
      small = list :small, capacity: 8
      game_loop { small.push 1 }
    end

    out = StringIO.new
    RubyGBA::Diagnostics::BuildReport.render(rom, out: out)
    refute_match(/roomy memory/, out.string)
  end
end
