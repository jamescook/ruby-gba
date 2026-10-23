# frozen_string_literal: true

require "test_helper"

# THE COLOR'S LOWERING, the IR straight to SM83 (GBC::Lowering). Each game here is built by it and
# played as a Color cartridge against the interpreter after every pass (GBC::CheckedRun), so a
# variable or a pixel that differs anywhere fails the test besides what it asserts.
class TestGBCLowering < Minitest::Test
  GBC = RubyGBA::IR::Backends::GBC

  def test_step_not_made_yet_is_refused_by_name
    score = RubyGBA::Audio::Score
    blip = score.new(parts: [score::Part.new(notes: [score::Note.new(at: 0, key: :C5)])])
    effects = program do
      enable_sound
      sfx = sound_effects :sfx, [blip]
      game_loop { sfx.play 0 }
    end
    error = assert_raises(GBC::LoweringError) { GBC.new.build(effects) }

    assert_match(/:play_sound_effect, which the Game Boy Color build cannot make yet \(sound\)/, error.message)
  end

  def test_what_the_hardware_lacks_is_refused_naming_it
    error = assert_raises(GBC::LoweringError) { GBC.new.build(program { pixelate 4 }) }

    assert_match(/a Game Boy Color cannot: a Game Boy Color cannot show the screen in blocks: it has no mosaic/,
                 error.message)
  end

  # A tiled screen: a background, a sprite moved by a held button and drawn from another colour
  # list once it is held, a second sprite it collides with, and a fade coming in.
  def test_tiled_game_plays_as_the_interpreter_plays_it
    game = program do
      screen :tiled
      image(:grass, "g" => :green) { "#{'g' * 8}\n" * 8 }
      image(:mud, "m" => :orange) { "#{'m' * 8}\n" * 8 }
      tiles :ground, "#" => :grass, "." => :mud
      background :field, tiles: :ground, map: ["#.#.", ".#.#"]
      image :dot, "." => :transparent, "r" => :red, colors: %i[transparent red] do
        "rr\nrr\n"
      end
      colors :warm, %i[transparent yellow]
      hero = sprite :dot, at: [10, 10]
      rock = sprite :dot, at: [40, 10]
      hits = var :hits, 0
      fading = var :fading, 100
      game_loop do
        held(:right).then { hero.x.add! 3 }
        held(:right).then { hero.draw_with :warm }
        hero.overlaps?(rock).then { hits.add! 1 }
        fade :black, fading
        fading.set! fading.approach(0, 10)
      end
    end

    GBC::CheckedRun.new.hold(:right).run(game, frames: 12)
  end

  # Every statement of the first slice, in one game: a scene picked by a `case` that changes the
  # scene it reads, a counted loop that stops early, beats, a call picked by a number past the end
  # of its list, a button held, and the sums and tests between them.
  def test_game_plays_as_the_interpreter_plays_it
    game = program do
      var :state, 0
      total = var :total, 0
      which = var :which, 0
      var :beats, 0
      func(:one) { add! :total, 100 }
      func(:two) { add! :total, 1000 }
      scene(:title) { set! :state, 1 }
      scene(:play) do
        repeat(5, stop_when: total > 40) { |i| add! :total, i * 3 }
        call %i[one two], number: which
        add! :which, 1
      end
      game_loop do
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
        every(3) { add! :beats, 1 }
        held(:a).then { sub! :total, 7 }.else { clamp! :total, -5, 5000 }
      end
    end

    run = GBC::CheckedRun.new.hold(:a).run(game, frames: 12)
    assert_equal 4, run[:beats]
    assert_operator run[:which], :>, 2, "the call picked past the end of its list called nothing and went on"
  end

  # Lists of bytes and of words, grown, shrunk from both ends, written into, filled and copied from
  # a table; a table of halves whose length is a power of two, read past its end (it wraps), and one
  # of bytes read past its end (it is held to its last entry). 300 in a byte reads back as 44.
  def test_lists_and_tables_play_as_the_interpreter_plays_them
    game = program do
      steps = table :steps, [3, -2, 300, 7], width: :half, signed: true
      odd = table :odd, [5, 6, 7], width: :byte
      trail = list :trail, capacity: 8, width: :byte
      words = list :words, capacity: 4
      bytes = list :bytes, capacity: 4, width: :byte
      i = var :i, 0
      sum = var :sum, 0
      game_loop do
        trail.push steps[i]
        (trail.length > 5).then { trail.shift }
        bytes.copy_from(odd, at: i % 2, count: 2)
        words.push bytes[1]
        words.push odd[i + 10]
        words.push i
        words.fill 9, from: 2, count: 1
        words[0] = trail.last
        sum.set! sum + words[0] + words[1] + words[2] + trail.first
        3.times { words.pop }
        i.add! 1
      end
    end

    run = GBC::CheckedRun.new.run(game, frames: 10)
    assert_equal 5, run.list(:trail).length
  end

  # A number kept over the power going off, and a record saved, loaded back and checked by the game
  # itself: the cartridge's save memory ends as the interpreter's, byte for byte.
  def test_saves_play_as_the_interpreter_plays_them
    game = program do
      best = save_var :best, 5
      score = var :score, 0
      loaded = var :loaded, 0
      files = save_data(:files) { keep score }
      game_loop do
        best.add! 2
        score.add! 3
        (score == 9).then { files[0].save }
        (score == 15).then do
          score.set! 0
          files[0].load
          loaded.set! score
        end
      end
    end

    store = SaveImage.new
    run = GBC::CheckedRun.new(save: store).run(game, frames: 40)
    assert_equal 9, run[:loaded]
  end

  # Two timers: a slow one read by its ticks, and a fast one whose ticks call a routine and stop it
  # once enough have gone by — a pass crossing two of its ticks runs its handler twice.
  def test_timers_play_as_the_interpreter_plays_them
    game = program do
      fast_count = var :fast_count, 0
      func(:count_tick) { add! :fast_count, 1 }
      slow = timer :slow, per_second: 7
      fast = timer :fast, per_second: 90
      fast.on_tick do
        call :count_tick
        (fast_count >= 20).then { fast.stop }
      end
      var :seen, 0
      game_loop { set! :seen, slow.ticks }
    end

    run = GBC::CheckedRun.new.run(game, frames: 30)
    assert_equal 21, run[:fast_count], "stopped on the 20th tick, the first of a frame's two, and the second still ran"
  end

  # A song with its volume faded, a defined beep, a hit on the noise voice and a tone on the wave
  # voice: built by the lowering, and the game around them plays as the interpreter plays it. What
  # the speaker makes is not compared on the Color's run yet.
  def test_game_with_sound_plays_as_the_interpreter_plays_it
    game = program do
      enable_sound
      define_sound :ping, frequency: 880, duty: :quarter, decay: :fast, volume: 12
      song(:tune) { note :C4, :quarter }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 1).then { play_song :tune }
        (pass == 2).then { beep :ping }
        (pass == 3).then { noise :explosion }
        (pass == 4).then { wave :triangle, :C4 }
        (pass == 6).then { stop_wave }
        (pass == 7).then { fade_music_out }
        (pass == 9).then { stop_music }
      end
    end

    GBC::CheckedRun.new.run(game, frames: 12)
  end

  # A chance taken on the game's random numbers, and a byte read out of a block of data the
  # program declares, built as IR since no verb says either alone.
  def test_chance_and_data_byte_play_as_the_interpreter_plays_them
    build = RubyGBA::IR::Build
    game = build.program(
      build.data(:bytes, "\x05\xFA\x07".b),
      build.set(:roll, 30),
      build.loop_(build.wait_vblank,
                  build.set(:third, build.data_byte(:bytes, 1)),
                  build.if_(build.chance(build.var_ref(:roll), 40), build.add(:lucky, 1)),
                  build.add(:roll, 7)),
      console: :gbc
    )

    run = GBC::CheckedRun.new.run(game, frames: 6)
    assert_equal 250, run[:third]
  end

  # A game loop far bigger than a bank of the cartridge holds is cut into parts, each a routine of
  # its own called where its statements stood, and still plays as the interpreter plays it.
  def test_routine_bigger_than_bank_is_cut_into_parts
    game = program do
      total = var :total, 0
      game_loop do
        3000.times { |n| total.add! n % 7 }
        (total > 1_000_000).then { total.set! 0 }
      end
    end

    built = GBC.new.build(game).built
    assert built.code.key?("main_part1"), "the game loop was cut"
    run = GBC::CheckedRun.new.run(game, frames: 3)
    assert_operator run[:total], :>, 0
  end

  private

  def program(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.tap { |built| built.console = :gbc }
  end
end
