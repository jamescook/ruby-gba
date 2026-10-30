# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_note_envelope"

# A NOTE'S ENVELOPE ON THE ADVANCE'S CARTRIDGE, heard in the emulator: a note that ends without a
# click, and a note that can outlast the recording it is made of. The envelope's numbers and the
# errors an author is told are in test/all/vblank/audio/test_note_envelope.rb.
#
# The click is the point of the whole feature, so the console test measures it the way the
# report that asked for this measured it: a sine of a whole number of cycles is played, and the
# biggest jump between one sample of the rendering and the next is held against the biggest jump
# the WAVE ITSELF ever makes. A note cut dead leaves the speaker wherever the wave was, and that
# jump is several times the wave's own. A note that fades does not.
class TestNoteEnvelopeCartridge < Minitest::Test
  include EmulatorSupport
  include NoteEnvelopeSounds

  # A second of the sine.
  RECORDING = (SINE * (RATE / CYCLE)).freeze

  # Six notes, each a frame longer than the last, so the six of them END AT SIX DIFFERENT POINTS
  # of the wave. That is what makes the click "only sometimes": a note that happens to end near
  # a zero crossing is quiet about it, and one that ends near a peak is not.
  #
  # The rests between them are long because the fade under test is half a second: a rest shorter
  # than the fade leaves no silence to find a note's end by, and the next note takes the voice
  # over while the last one is still sounding.
  NOTES = 6
  GAP = 55
  FRAMES = GAP * (NOTES + 1)

  # A tempo where one tick is one frame, so a note's length is said in frames.
  TEMPO = 150
  TICKS_PER_BEAT = 24

  private def score(envelope)
    notes = (0...NOTES).map { |n| VBlank::Audio::Score::Note.new(at: GAP * n, key: :C4, length: 6 + n) }
    tune_of(notes, envelope)
  end

  private def tune_of(notes, envelope)
    part = VBlank::Audio::Score::Part.new(plays: :tone, notes: notes, envelope: envelope, volume: 15)
    VBlank::Audio::Score.new(parts: [part], tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT,
                       length: GAP * (NOTES + 1))
  end

  private def build(envelope, holds_from: nil, tune: score(envelope))
    VBlank.build("ENVELOPE", console: :gba, code: "BENV", maker: "01", validate: false) do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: RECORDING, rate: RATE, note: :C4, holds_from: holds_from
      music = songs :music, [tune]
      music.play 0
      game_loop { clear_screen :black }
    end
  end

  # One channel of the rendering, and the jump from each sample to the next.
  private def rendered(rom)
    mono = VBlank::Diagnostics::Verifier.new(rom, frames: FRAMES).audio_samples.each_slice(2).map(&:first)
    [mono, mono.each_cons(2).map { |a, b| (b - a).abs }]
  end

  # THE BIGGEST JUMP THE WAVE ITSELF MAKES — the bar everything else is held against. Measured
  # on the same recording played round and round with no note ever starting or stopping, so
  # there is nothing in it but the wave, and measured rather than worked out because what
  # reaches the test is the console's output through the emulator's own resampling.
  private def the_waves_own_step
    control = VBlank.build("ENVELOPE", console: :gba, code: "BENV", maker: "01", validate: false) do
      screen :bitmap
      enable_sound
      tone = sample :tone, pcm: RECORDING, rate: RATE, note: :C4
      started = var :started, 0
      game_loop do
        (started == 0).then { started.set! 1; tone.play(loop: true) }
        clear_screen :black
      end
    end
    rendered(control).last.max
  end

  # WHERE EACH NOTE ENDS, found in the rendering itself rather than counted out in frames. Every
  # note here is followed by a rest, so a note's end is where the sound falls to nothing — and
  # the biggest jump in the run-up to that silence is the one a click would be.
  #
  # Found this way because a frame counted from the outside drifts: the run is long, and the
  # emulator hands over its sound in chunks that do not divide evenly into frames. A silence is
  # exactly where it is.
  QUIET = 400        # below this the speaker is as good as still
  QUIET_RUN = 1500   # ...and this many in a row is a rest rather than a zero crossing

  private def steps_at_note_ends(mono, steps)
    ends = []
    quiet = 0
    mono.each_index do |i|
      quiet = mono[i].abs < QUIET ? quiet + 1 : 0
      ends << (i - quiet) if quiet == QUIET_RUN && i >= quiet # the silence before the first note ends nothing
    end
    ends.map { |at| steps[[at - QUIET_RUN, 0].max..at].max }
  end

  def test_a_note_that_stops_dead_clicks_and_a_note_that_fades_does_not
    require_emulator!
    own = the_waves_own_step

    mono, steps = rendered(build(nil))
    stopping = steps_at_note_ends(mono, steps)

    assert_equal NOTES, stopping.length, "every note should be followed by a rest"
    assert_operator stopping.max, :>, own * 3,
                    "a note that stops dead should end with a jump far past the wave's own " \
                    "(#{own}); the note ends measured #{stopping.inspect}"
    assert_operator stopping.count { |step| step > mono.map(&:abs).max / 2 }, :>, 0,
                    "...and some of them by more than half the whole wave"

    mono, steps = rendered(build({ release: 0.5 }))
    fading = steps_at_note_ends(mono, steps)

    assert_equal NOTES, fading.length, "every note should still be followed by a rest"
    fading.each_with_index do |step, n|
      assert_operator step, :<=, own,
                      "note #{n} ends with a jump of #{step}, and the wave's own is #{own}"
    end
  end

  # THE FASTEST RELEASE ON A RETAIL CARTRIDGE: 89, which keeps about a third of the level each
  # frame and is silent in six. Most of that fall happens in the first frame, so a level that moved
  # only at the frame boundary took most of the wave away in one step — a click, a smaller one than
  # stopping dead but the same thing. The gain slides across the frame instead.
  FASTEST_RETAIL_RELEASE = VBlank::Audio::Envelope.new(release: 89)

  def test_the_fastest_retail_release_ends_a_note_without_a_jump
    require_emulator!
    own = the_waves_own_step

    mono, steps = rendered(build(FASTEST_RETAIL_RELEASE))
    ends = steps_at_note_ends(mono, steps)

    assert_equal NOTES, ends.length, "every note should be followed by a rest"
    ends.each_with_index do |step, n|
      assert_operator step, :<=, own, "note #{n} ends with a jump of #{step}, and the wave's own is #{own}"
    end
  end

  # A NOTE THAT COMES BEFORE THE LAST ONE HAS FINISHED FADING. The last one falls away on its own
  # voice while the new one sounds on another, so for a moment two waves are playing — and two
  # waves together can move twice as far in a sample as one. Anything past that is a break in the
  # sound: the new note taking the old one's voice would stop the old wave dead mid-fade.
  #
  # Each note lasts until the next, and each is a frame longer than the last, so they end at
  # different points of the wave. A slow release as well as the fast one, since a slow fade is
  # still loud when the next note arrives.
  def test_a_note_that_arrives_mid_fade_does_not_cut_the_fade_off
    require_emulator!
    own = the_waves_own_step
    notes = (0..NOTES).map { |n| VBlank::Audio::Score::Note.new(at: (0...n).sum { |k| 8 + k }, key: :C4) }

    [FASTEST_RETAIL_RELEASE, VBlank::Audio::Envelope.new(release: 188)].each do |shape|
      _, steps = rendered(build(shape, tune: tune_of(notes, shape)))

      assert_operator steps.max, :<=, own * 2,
                      "release #{shape.release}: a jump of #{steps.max}, and two waves together move #{own * 2} at most"
    end
  end

  # A NOTE CAN OUTLAST ITS RECORDING. Without a hold point the recording runs out and the note
  # ends there, however long the note was written; with one it reads round and lasts.
  def test_a_held_note_lasts_longer_than_its_recording
    short = (SINE * 4).freeze # a tenth of a second at most
    tune = VBlank::Audio::Score.new(
      parts: [VBlank::Audio::Score::Part.new(plays: :tone, notes: [VBlank::Audio::Score::Note.new(at: 0, key: :C4, length: 60)])],
      tempo: TEMPO, ticks_per_beat: TICKS_PER_BEAT, length: 90
    )
    held = VBlank.build("ENVELOPE", console: :gba, code: "BENV", maker: "01", validate: false) do
      screen :bitmap
      enable_sound
      instrument :tone, pcm: short, rate: RATE, note: :C4, holds_from: 0
      music = songs :music, [tune]
      music.play 0
      game_loop { clear_screen :black }
    end

    voice = assert_emulator_loads_rom(held, frames: 40).voices.first

    refute_nil voice, "the held note should still be sounding well past the recording's end"
    assert voice.loop, "a held note reads round rather than running out"
  end
end
