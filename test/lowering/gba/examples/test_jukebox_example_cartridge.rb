# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "console/gba/examples/test_jukebox_example"

# The Jukebox example (examples/jukebox.rb) as the Advance's cartridge: built, and read back in
# the emulator — its sound, and its mixer's voices frame by frame with somebody at the buttons.
# What the run's own player hears is in test/console/gba/examples/test_jukebox_example.rb.
class TestJukeboxExampleCartridge < Minitest::Test
  include JukeboxListening

  # The same listener's run on the console: every frame's Moment, from the first press.
  private def console_jukebox(listener, frames:)
    require_emulator!
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "jukebox.gba")
      rom.write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      moments = Array.new(frames) do
        voices = rom.built.voices.read { |address| probe.read32(address) }
        owners = voices.map(&:owner)
        feed = probe.sound_feed(frames: 1, keys: listener.keys(owners))
        Moment.new(owners: owners, voices: voices, loudness: probe.audio_energy,
                   played: feed.played.map { |sample| [sample.value, sample.due] })
      end
      probe.close
      from_the_press(moments, listener)
    end
  end

  def test_the_example_builds_clean
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    assert_operator rom.size, :>, 0, "the built ROM should be non-empty"
  end

  # ...and the console dips too: loud, a stretch of quiet as the cursor moves, then loud again.
  def test_the_console_dips_between_tunes
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    down = ->(frame) { (40..41).cover?(frame) ? VBlank::Console::Hardware::KEY_DOWN : 0 }
    energy = assert_emulator_loads_rom(rom, frames: 110, keys: down).audio_energy_by_frame
    loud = energy.max / 4

    assert_operator energy[20..38].max, :>, loud, "the first tune plays (#{energy.inspect})"
    assert_operator energy[42..70].min, :<, loud / 8, "it goes quiet as the cursor moves (#{energy.inspect})"
    assert_operator energy[85..].max, :>, loud, "and the next tune comes up (#{energy.inspect})"
  end

  # HOORAY ON THE BIG CHORD takes a voice from the tune, which has every one; the part that lost
  # it has it back at the next big chord, two measures on — on the console as on the interpreter.
  def test_hooray_takes_a_voice_from_the_tunes_big_chord_on_the_console
    assert_hooray_takes_a_voice_from_the_big_chord(console_jukebox(Listener.new(chord: :big, presses: [[:a, 0]]),
                                                                   frames: 560))
  end

  # BLIP ranks below the tune: on the big chord there is no voice for it, and every voice is as it
  # would have been with nobody pressing B — on the small chord, it is heard.
  def test_blip_is_not_played_on_the_big_chord_and_is_on_the_small_one_on_the_console
    assert_blip_waits_for_a_voice(console_jukebox(Listener.new(chord: :big, presses: [[:b, 0]]), frames: 300),
                                  console_jukebox(Listener.new(chord: :big, presses: []), frames: 300),
                                  console_jukebox(Listener.new(chord: :small, presses: [[:b, 0]]), frames: 200))
  end

  # A SECOND PRESS STARTS HOORAY AGAIN from its first note: on the console, a few frames after the
  # second press, HOORAY's voice is reading the first note's pitch again where its second note
  # would otherwise be sounding.
  def test_hooray_pressed_again_starts_from_its_first_note
    moments = console_jukebox(Listener.new(chord: :small, presses: [[:a, 0], [:a, 7]]), frames: 200)
    steps = moments.first(30).map { |now| now.voices.find { |voice| voice.owner == HOORAY }&.step }
    first_note = steps.compact.first

    assert_equal first_note, steps[14], "the first note again, where the second was due (#{steps.inspect})"
  end

  # HOORAY KEEPS SOUNDING, AT ITS OWN VOLUME, while the music fades: A, then DOWN moves the cursor
  # off the tune. The console keeps its voice through the fade, and says how loud.
  def test_hooray_does_not_fade_with_the_music
    moments = console_jukebox(Listener.new(**HOORAY_THEN_DOWN), frames: 200)
    assert_hooray_sounds_through_the_fade(moments)

    hooray = moments.first(25).filter_map { |now| now.voices.find { |voice| voice.owner == HOORAY }&.volume }
    tune = moments.first(25).map { |now| now.voices.select { |voice| voice.owner.first == :song }.sum(&:volume) }
    assert_equal [hooray.first], hooray.uniq, "at one volume"
    assert_operator tune.last, :<, tune.first, "while the tune goes quiet"
  end

  # HOORAY OVER THE SMALL CHORD, heard on the console: louder than the same frames with nobody
  # pressing A, and once it has ended, frame for frame the same sound as those — the tune was not
  # touched and did not slip.
  #
  # "The same sound" is every sample the console's recorded-sound channel played and the cycle it
  # fell due, not how loud the speaker was. The emulator places a sample in what it sends to the
  # speaker by when it got round to it, which is a few cycles after it fell due behind whatever
  # instruction was running — and the run that played HOORAY has run other code, so its
  # instructions fall against the sample clock a little differently ever after. The speaker then
  # differs by a fraction on a few frames with every sample the same, which is the emulator and not
  # the cartridge (see Probe#sound_feed).
  def test_hooray_adds_to_the_sound_and_leaves_the_tune_as_it_was
    pressed = console_jukebox(Listener.new(chord: :small, presses: [[:a, 0]]), frames: 200)
    quiet = console_jukebox(Listener.new(chord: :small, presses: []), frames: 200) # waits for the same frame

    assert_operator pressed.first(40).sum(&:loudness), :>, quiet.first(40).sum(&:loudness), "HOORAY is heard"
    assert_equal quiet[60, 60].map(&:played), pressed[60, 60].map(&:played), "and after it, the tune as it was"
  end

  # On real hardware: the ROM boots and the music channel is actually driven.
  def test_the_music_channel_is_driven_on_the_console
    rom = Jukebox.build_rom(out: StringIO.new, err: StringIO.new)
    v = assert_emulator_loads_rom(rom, frames: 12)
    assert v.sound?, "the highlighted tune should drive the music channel"
  end
end
