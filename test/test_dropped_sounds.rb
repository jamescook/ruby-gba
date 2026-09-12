# frozen_string_literal: true

require "test_helper"
require "stringio"

# A SOUND THE GAME ASKED FOR AND DID NOT GET.
#
# `play` on a sample fills one of the mixer's voices. With every voice busy the play is
# dropped — deliberately, since the alternative is cutting off a sound already sounding — and
# the console says nothing about it. Nothing on screen does either: the game carries on, one
# sound quieter than the author wrote.
#
# Whether it happens depends entirely on play (a burst of explosions, a chord of music under
# them), so no build can see it. Only a run can, and `rom.profile` is where a run reports.
class TestDroppedSounds < Minitest::Test
  include EmulatorSupport

  VOICES = RubyGBA::Sound::MIXER_VOICES

  # More sounds at once than there are voices. Each one gets bytes of its own so no two can
  # share a place in the cartridge — this is about the mixer, not about identical sounds
  # being stored once. They loop, so nothing retires and frees a voice mid-run.
  def over_subscribed(extra)
    names = (0...(VOICES + extra)).map { |i| :"s#{i}" }
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      names.each_with_index.map { |name, i| sample name, pcm: [25 + i, -25 - i] * 2000, rate: 8000 }
           .each { |s| s.play(loop: true) }
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  # LOSING A SOUND EVERY FRAME, which is what a run has to be doing for a profile to see it:
  # the mixer is filled at boot with loops that never retire, and the game then asks for one
  # more effect on every pass. Every one of those finds no room.
  def losing_every_frame
    names = (0...VOICES).map { |i| :"m#{i}" }
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      names.each_with_index.map { |name, i| sample name, pcm: [25 + i, -25 - i] * 2000, rate: 8000 }
           .each { |s| s.play(loop: true) }
      late = sample :late, pcm: [60, -60] * 2000, rate: 8000
      game_loop do
        wait_vblank
        late.play
      end
    end
    b.emit_pending_functions
    b.program
  end

  # A SONG PLAYING UNDERNEATH, so a drop finds voices in both hands. Its recorded parts take
  # voices of their own while their notes sound, and the game fills the rest and then asks for
  # one more every frame. Over-subscribing at boot alone would not do: every one of those is
  # dropped before the song has played a note, and the split would read as all the game's.
  def song_under_the_sounds
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      instrument :piano, pcm: [40, -40] * 400, rate: 8000, note: :C4
      song :tune do
        tempo 120
        voice(:lead, plays: :piano) { 8.times { note :C4, :whole } }
        voice(:harmony, plays: :piano) { 8.times { note :E4, :whole } }
      end
      play_song :tune
      (0...VOICES).map { |i| sample :"s#{i}", pcm: [25 + i, -25 - i] * 2000, rate: 8000 }
                  .each { |s| s.play(loop: true) }
      late = sample :late, pcm: [60, -60] * 2000, rate: 8000
      game_loop do
        wait_vblank
        late.play
      end
    end
    b.emit_pending_functions
    b.program
  end

  # Comfortably inside the mixer — nothing can be lost.
  def within_budget
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      sample(:hum, pcm: [25, -25] * 2000, rate: 8000).play(loop: true)
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  # --- the count, on the console ---

  # The one the bead is about: the console counts what it could not play, and the count is
  # exactly the plays past the last free voice.
  def test_the_console_counts_the_sounds_it_could_not_play
    v = assert_emulator_loads_rom(assemble_rom(over_subscribed(3)), frames: 6)

    assert_equal 3, v.sound_drops.dropped
    assert_equal VOICES, v.sound_drops.voices
  end

  # ...and a game that stays inside the mixer counts none. This is the half that makes the
  # number worth printing: a report that said "some sounds may have been dropped" about every
  # game would be noise.
  def test_a_game_inside_the_mixer_loses_nothing
    v = assert_emulator_loads_rom(assemble_rom(within_budget), frames: 6)

    refute_predicate v.sound_drops, :any?
    assert_equal 0, v.sound_drops.dropped
  end

  # THE COUNTERS START AT NOTHING, and boot has to MAKE them — which is not the same as
  # finding them at nothing, and needs an awkward test to tell the two apart.
  #
  # A counter left unwritten reads back as whatever the memory held, and a game that dropped
  # nothing would then report rubbish. The emulator hands out a cleared memory at reset, so
  # simply running a quiet game and finding 0 proves nothing at all — it passes just as well
  # with the boot store deleted. So this puts a number there FIRST, in the gap between loading
  # the cartridge and running its first frame, and then asks what boot made of it.
  def test_boot_puts_the_counters_back_to_nothing_whatever_was_in_the_memory
    require_emulator!
    rom = assemble_rom(within_budget, name: "BOOT")
    drops = rom.built.sound_drops

    Dir.mktmpdir do |dir|
      path = File.join(dir, "boot.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      begin
        probe.write32(drops.drops_at, 0xDEAD)
        probe.write32(drops.music_at, 0xBEEF)
        probe.step(2)

        assert_equal 0, probe.read32(drops.drops_at), "boot wrote the count back to nothing"
        assert_equal 0, probe.read32(drops.music_at)
      ensure
        probe.close
      end
    end
  end

  # A program that plays no samples has no counters at all, so the answer is "we could not
  # tell" rather than "nothing was wrong" — the two must never read the same.
  def test_a_program_that_plays_no_samples_is_unmeasured_rather_than_zero
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      game_loop { wait_vblank }
    end
    b.emit_pending_functions

    v = assert_emulator_loads_rom(assemble_rom(b.program), frames: 3)

    refute_predicate v.sound_drops, :measured?
    refute_predicate v.sound_drops, :any?
  end

  # --- both backends agree ---

  # The acceptance: the interpreter's count and the console's are the same number for the same
  # program. They are counted in different places by different code — the interpreter at the
  # point it finds no free slot, the console in the search that found none — so agreement is
  # a fact about the lowering rather than a restatement of it.
  def test_the_interpreter_counts_what_the_console_counts
    program = over_subscribed(2)

    interpreted = Reference.new.run(program, max_steps: 200_000).sound_drops
    console = assert_emulator_loads_rom(assemble_rom(program), frames: 6).sound_drops

    assert_equal 2, interpreted.dropped
    assert_equal interpreted.dropped, console.dropped, "both backends lose the same sounds"
    assert_equal interpreted.voices, console.voices
  end

  # --- the split ---

  # WITH NO SONG PLAYING every voice a drop found busy was the game's own, so the split says
  # so. The count of voices SOUNDING is not measured and never will be: a drop means all of
  # them were, every time.
  def test_with_no_song_the_games_own_sounds_held_every_voice
    v = assert_emulator_loads_rom(assemble_rom(over_subscribed(2)), frames: 6)

    assert_equal 0, v.sound_drops.music_held
    assert_equal VOICES, v.sound_drops.game_held
  end

  # ...and a song's recorded parts hold voices of their own while their notes sound, which is
  # the whole reason the split is worth printing: it is the half the author can act on.
  def test_a_songs_recorded_parts_show_up_as_the_voices_they_hold
    v = assert_emulator_loads_rom(assemble_rom(song_under_the_sounds), frames: 20)

    assert_predicate v.sound_drops, :any?, "more sounds than voices, so some were lost"
    assert_operator v.sound_drops.music_held, :>, 0,
                    "the song was holding voices when a sound was dropped"
    assert_equal VOICES, v.sound_drops.music_held + v.sound_drops.game_held,
                 "the two sides of the split are every voice there is"
  end

  # --- the report ---

  def profiled(program, **options)
    out = StringIO.new
    rom = assemble_rom(program, name: "DROP")
    [rom.profile(out: out, frames: 8, settle: 4, **options), out.string]
  end

  def test_the_report_says_how_many_sounds_did_not_play
    result, printed = profiled(losing_every_frame)

    assert_predicate result.sound_drops, :any?
    assert_match(/#{result.sound_drops.dropped} sounds did not play/, printed)
    assert_match(/every one of the #{VOICES} mixer voices was busy/, printed)
  end

  # WITH NO SONG the split says nothing, because it would be saying "a song held 0" — a
  # sentence about nothing, under a line that has already said every voice was busy.
  def test_a_game_with_no_song_is_not_told_what_the_song_held
    _result, printed = profiled(losing_every_frame)

    assert_match(/did not play/, printed)
    refute_match(/a song held/, printed)
  end

  # ...and where a song really was holding voices, that is printed, because it is the half the
  # author can do something about.
  def test_the_report_says_what_the_song_held_when_it_held_any
    _result, printed = profiled(song_under_the_sounds)

    assert_match(/a song held [1-9]\d* of them at the worst moment/, printed)
    assert_match(/a song's recorded part keeps a voice while its note sounds/, printed)
  end

  # A run that lost nothing says NOTHING — not "0 dropped". A report that mentions every
  # reading whether or not it found anything is a report nobody reads.
  def test_a_run_that_lost_nothing_says_nothing_about_it
    _result, printed = profiled(within_budget)

    refute_match(/did not play/, printed)
    refute_match(/mixer voices/, printed)
  end

  def test_the_same_numbers_come_back_as_data
    out = StringIO.new
    assemble_rom(losing_every_frame, name: "DROP").profile(format: :json, out: out, frames: 8,
                                                           settle: 4)
    json = JSON.parse(out.string).fetch("sound_drops")

    assert_operator json["dropped"], :>, 0
    assert_equal VOICES, json["voices"]
    assert_equal 0, json["music_held"]
  end

  # A game that plays no samples has nothing to say here either way, so the field is absent
  # rather than zero — the same distinction the printed report makes.
  def test_a_silent_game_reports_no_drops_field_at_all
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      game_loop { wait_vblank }
    end
    b.emit_pending_functions

    out = StringIO.new
    assemble_rom(b.program, name: "QUIET").profile(format: :json, out: out, frames: 8, settle: 4)

    assert_nil JSON.parse(out.string)["sound_drops"]
  end

  # THE COUNT IS ABOUT THE FRAMES MEASURED, not about every frame since the cartridge booted.
  # The profile settles the game first, and those frames are not the frames being reported on —
  # every other number in the report is about the measured window and this one has to be too.
  # The sounds here are all played at boot, so they are all lost during the settling: what the
  # measured window itself lost is nothing.
  def test_what_the_settling_lost_is_not_counted_against_the_measured_frames
    result, _printed = profiled(over_subscribed(3))

    assert_predicate result.sound_drops, :measured?
    assert_equal 0, result.sound_drops.dropped,
                 "the drops happened while the game settled, before the measuring started"
  end
end
