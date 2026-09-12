# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A SONG PART ON THE WAVE VOICE AND ON THE NOISE VOICE — the console's other two.
#
# A part played the square wave or a recorded instrument, and the console had two more voices a
# tune could use and did not: the wave voice, which loops a short waveform (rounder than a square
# wave, and it reaches an octave lower), and the noise voice, which makes a hiss (the drums).
#
# WHAT THEY ARE WORTH is that they cost NO mixer voice. A part that plays a recording keeps one
# of the mixer's voices for as long as its note sounds; these two the console makes itself. So a
# busy song reaches for them before it reaches for another recording, and the voices it does not
# spend stay free for the game's own sounds.
class TestSongConsoleVoices < Minitest::Test
  include RubyGBA::Constants

  Registers = RubyGBA::Sound::Registers

  # A tune whose parts cover every voice there is: two square, one wave, one noise, one recorded.
  def every_voice_game(frames: 60)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      song :full do
        tempo 150 # a quarter is 24 frames
        voice(:lead) { note :C5, :whole }
        voice(:bass) { note :C3, :whole }
        voice(:pad, plays: :triangle) { note :C2, :whole }
        voice(:drums, plays: :noise) { note :C2, :quarter; note :C5, :quarter }
        voice(:keys, plays: :piano) { note :E4, :whole }
      end
      play_song :full
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  # --- the interpreter ---

  # The interpreter logs a song's wave and noise notes the way it logs the `wave` and `noise`
  # VERBS, because they really are the same voice — so one read of the log answers both.
  def logged(program, frames: 6)
    Reference.new.run(program, frames: frames).audio
  end

  def test_a_wave_part_sounds_its_waveform_on_the_interpreter
    played = logged(every_voice_game).select { |entry| entry.first == :wave }.map(&:last)

    refute_empty played, "the pad part sounded the wave voice"
    assert_equal :triangle, played.first[:shape], "at the timbre the part named"
    assert_equal RubyGBA::Music::NOTE_FREQUENCIES[:C2], played.first[:frequency]
  end

  def test_a_noise_part_sounds_a_hit_on_the_interpreter
    hits = logged(every_voice_game).select { |entry| entry.first == :noise }.map(&:last).compact

    refute_empty hits, "the drum part hit the noise voice"
    assert_equal RubyGBA::Music::NOTE_FREQUENCIES[:C2], hits.first[:pitch]
    assert_equal :fast, hits.first[:decay], "a drum hit rings out rather than being held"
  end

  # THE POINT OF THE WHOLE THING. Five parts, and only the one playing a recording keeps a
  # mixer voice — so a tune with a pad and drums leaves fifteen of the sixteen for the game.
  def test_only_the_recorded_part_keeps_a_mixer_voice
    i = Reference.new.run(every_voice_game, frames: 6)

    assert_equal [:piano], i.active_samples
    assert_equal 1, i.peak_voices, "the wave and noise parts took none"
  end

  # --- the console ---

  # A wave part really reaches the wave voice's registers, and a noise part the noise voice's.
  # Read off the running console rather than off the score, so this is what the lowering did.
  #
  # THE RATE AND NOT THE TRIGGER, because the bit that restarts a voice is write-only: it does
  # what it does and reads back as nothing. So what a reader can see is the pitch, which is the
  # part that says the right note arrived.
  RATE = 0x07FF

  def test_the_console_sounds_both_voices
    rom = assemble_rom(every_voice_game, name: "VOICES")
    v = assert_emulator_loads_rom(rom, frames: 8)

    assert_equal Registers.wave_rate(RubyGBA::Music::NOTE_FREQUENCIES[:C2]),
                 v.mem16(REG_SOUND3CNT_X) & RATE, "the wave voice is playing the pad's note"
    refute_equal 0, v.mem16(REG_SOUND3CNT_H), "...at a level you can hear"
    refute_equal 0, v.mem16(REG_SOUND4CNT_L), "the noise voice was hit"
  end

  # THE WAVEFORM REACHES WAVE RAM, which is the half a note cannot do for itself: the voice
  # loops a table, and a table nobody uploaded is whatever the memory held. Uploaded once when
  # the tune starts, so a note stays two register writes.
  def test_the_waveform_is_uploaded_when_the_tune_starts
    rom = assemble_rom(every_voice_game, name: "VOICES")
    v = assert_emulator_loads_rom(rom, frames: 8)
    want = Registers.wavetable_halfwords(:triangle)

    got = (0...want.length).map { |i| v.mem16(REG_WAVE_RAM + (i * 2)) }

    assert_equal want, got, "the part's own waveform, not whatever was there"
  end

  # ...AND IT REACHES BOTH BANKS, which is the console's own trap and not visible from the one
  # bank a reader happens to be shown. Wave RAM is two banks: the voice loops one and the CPU
  # reaches the other, so a table written to the bank being played is simply not heard — the
  # classic source of a wave voice that runs and makes no sound. Writing both means whichever
  # it loops, it loops this waveform.
  #
  # So this flips which bank is played, which swaps which one the CPU sees, and asks again.
  # Reading only the bank on show passes with half the upload deleted.
  def test_the_waveform_reaches_both_banks_of_wave_ram
    require_emulator!
    rom = assemble_rom(every_voice_game, name: "VOICES")
    want = Registers.wavetable_halfwords(:triangle)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "voices.gba")
      rom.write(path)
      probe = RubyGBA::Emulator.probe(path)
      begin
        probe.step(8)

        assert_equal want, wave_ram(probe), "the bank the CPU is shown"
        # SOUND3CNT_L and SOUND3CNT_H sit in one word; bit 6 of L says which bank plays.
        control = probe.read32(REG_SOUND3CNT_L)
        probe.write32(REG_SOUND3CNT_L, control ^ 0x0040)

        # THE CONTENTS AND NOT THEIR ORDER. Swapping the bank under a voice that is already
        # playing turns the window round as well, which is a fact about reaching in and
        # flipping the register mid-note rather than about the upload. What is being asked here
        # is whether the waveform reached this bank at all: leave one bank out and it reads
        # back as nothing, which is exactly the silence this guards against.
        assert_equal want.sort, wave_ram(probe).sort, "and the one behind it"
      ensure
        probe.close
      end
    end
  end

  # Wave RAM as its eight halfwords. Read by the word, since a halfword read at an odd offset
  # is not aligned.
  def wave_ram(probe)
    (0...(Registers.wavetable_halfwords(:triangle).length / 2)).flat_map do |word|
      value = probe.read32(REG_WAVE_RAM + (word * 4))
      [value & 0xFFFF, (value >> 16) & 0xFFFF]
    end
  end

  # Both backends sound the same thing, which is the contract that makes the interpreter an
  # oracle for this at all.
  def test_both_backends_agree_about_what_the_wave_voice_plays
    program = every_voice_game
    interpreted = logged(program, frames: 8).select { |e| e.first == :wave }.map(&:last).first
    v = assert_emulator_loads_rom(assemble_rom(program, name: "VOICES"), frames: 10)

    assert_equal Registers.wave_rate(interpreted[:frequency]), v.mem16(REG_SOUND3CNT_X) & RATE
  end

  # --- a note on the noise voice ---

  # A hiss has no pitch the way a melody does; what it has is a CLOCK, and a faster clock is a
  # higher, thinner hiss. So a note picks the clock nearest to it — which is what makes a low
  # note a kick and a high one a hat, and it has to be monotonic for that to be true.
  def test_a_higher_note_gives_a_faster_hiss
    low = Registers.noise_frequency(*Registers.noise_clock(RubyGBA::Music::NOTE_FREQUENCIES[:C2]))
    high = Registers.noise_frequency(*Registers.noise_clock(RubyGBA::Music::NOTE_FREQUENCIES[:C5]))

    assert_operator high, :>, low, "a higher note sits higher on the ladder"
  end

  def test_the_clock_chosen_is_the_nearest_one_there_is
    want = 1000
    divisor, shift = Registers.noise_clock(want)
    best = (Registers.noise_frequency(divisor, shift) - want).abs
    every = Registers::NOISE_DIVISORS.product(Registers::NOISE_SHIFT_RANGE.to_a)
                                     .map { |d, s| (Registers.noise_frequency(d, s) - want).abs }.min

    assert_in_delta best, every, 0.001
  end

  # A rest silences the voice rather than leaving the last hit ringing.
  def test_a_rest_on_either_voice_silences_it
    assert_equal [[REG_SOUND3CNT_H, 0], [REG_SOUND3CNT_X, 0]],
                 Registers.wave_note(frequency: 0, volume: 12)
    assert_equal [[REG_SOUND4CNT_L, 0], [REG_SOUND4CNT_H, 0x8000]],
                 Registers.noise_note(frequency: 0, decay: :fast, volume: 12, metallic: false)
  end

  # --- what `plays:` accepts ---

  def part_for(plays)
    RubyGBA::Music::VoiceContext.new(RubyGBA::Music::SongContext.new, plays: plays).to_voice
  end

  def test_plays_names_a_voice_by_what_it_sounds_like
    assert_equal :triangle, part_for(:wave).wave, "bare :wave is the middle timbre"
    assert_equal :sine, part_for(:sine).wave
    assert part_for(:noise).noise
    assert_equal :piano, part_for(:piano).instrument
    assert_equal :square, RubyGBA::IR::Tunes.part_kind(part_for(nil))
  end

  # `plays: :square` reads two ways and the wrong reading is silent: the author means "this part
  # plays a square wave", which is what a part does with NO `plays:` — and would get the wave
  # voice instead, a different voice and one of the two the song may be short of.
  def test_plays_square_is_a_friendly_error_naming_both_readings
    error = assert_raises(ArgumentError) { part_for(:square) }

    assert_match(/remove `plays:` from this part/, error.message)
    assert_match(/`plays: :wave`/, error.message)
  end

  def test_plays_something_that_is_not_a_name_says_what_it_takes
    error = assert_raises(ArgumentError) { part_for(42) }

    assert_match(/:wave/, error.message)
    assert_match(/:noise/, error.message)
  end

  # --- the noise part's own settings ---

  def test_a_noise_part_says_how_its_hits_fade_and_whether_they_rattle
    part = RubyGBA::Music::VoiceContext.new(RubyGBA::Music::SongContext.new, plays: :noise)
    part.decay :slow
    part.metallic true
    part.note :C3, :quarter

    assert_equal :slow, part.to_voice.decay
    assert part.to_voice.metallic
  end

  # EVERY PART CARRIES THEM, and only a noise part is ever asked. They are fields with defaults
  # rather than keys that might not be there, so a square part answers what a drum would and
  # nothing reads it — which is worth pinning, because the risk a default introduces is that it
  # LEAKS. A part that holds its note until the next one has no fade to apply, so saying one on
  # a square part must change nothing it plays.
  def test_a_fade_said_on_a_part_that_is_not_a_drum_changes_nothing_it_plays
    assert_equal GBA.new.lower(square_song), GBA.new.lower(square_song(fade: true)),
                 "a square part's notes are its pitch and its tone — a fade cannot reach them"
  end

  # The same tune twice: one square-wave part, optionally told how a drum hit would fade.
  def square_song(fade: false)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song :tune do
        voice :lead do |v|
          if fade
            v.decay :slow
            v.metallic true
          end
          v.note :C4, :quarter
        end
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  # --- a waveform of the game's own, rather than one of the names ---

  # THE NAMED SHAPES ARE A CONVENIENCE, NOT THE TRUTH. The console's wave voice is 32 steps of
  # four bits that a game writes, so a game whose music came from somewhere else — decoded out
  # of another cartridge — arrives holding those 32 numbers, and no name would be the waveform
  # it actually has. A 50% pulse is the common case and is none of :sine, :triangle, :sawtooth
  # or :square: played as a triangle it is a different instrument.
  PULSE_50 = ([15] * 16 + [0] * 16).freeze

  # One part on the wave voice, playing whatever it is given.
  def pad_song(plays)
    b = Builder.new
    shape = plays
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) { voice(:pad, plays: shape) { note :C4, :whole } }
      play_song :tune
      game_loop { wait_vblank }
    end
    b.emit_pending_functions
    b.program
  end

  # Wave RAM as the console really holds it — the eight halfwords of the bank the CPU is shown.
  def wave_ram_of(program, name)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(program), title: name, code: "BWAV", maker: "01",
                                               built: backend.build_record(program))
    v = assert_emulator_loads_rom(rom, frames: 6)
    (0...Registers.wavetable_halfwords(:sine).length).map { |i| v.mem16(REG_WAVE_RAM + (i * 2)) }
  end

  # THE POINT IS THE DIFFERENCE, so it is asserted rather than assumed: the steps the game gave
  # reach the console, and what reaches it is NOT what the same part would have played as a
  # triangle. A waveform that merely arrived somewhere would prove nothing.
  def test_a_waveform_of_the_games_own_reaches_the_console_and_is_not_a_triangle
    pulse = wave_ram_of(pad_song(PULSE_50), "PULSE")

    assert_equal Registers.wavetable_halfwords(PULSE_50), pulse, "the game's own steps, packed"
    refute_equal wave_ram_of(pad_song(:triangle), "TRI"), pulse,
                 "a pulse must not come out as the triangle it would have been named"
  end

  # The bare `wave` verb takes one too, not just a song part.
  def test_the_wave_verb_takes_a_waveform_of_its_own
    b = Builder.new
    steps = PULSE_50
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      wave steps, :C4
      game_loop { wait_vblank }
    end
    b.emit_pending_functions

    assert_equal Registers.wavetable_halfwords(PULSE_50), wave_ram_of(b.program, "WVERB")
  end

  # The interpreter carries it too, so both backends are told the same waveform.
  def test_the_interpreter_plays_the_waveform_it_was_given
    played = logged(pad_song(PULSE_50)).select { |entry| entry.first == :wave }.map(&:last).compact

    refute_empty played
    assert_equal PULSE_50, played.first[:shape]
  end

  # A waveform that cannot be one is refused at the line that wrote it, not at the cartridge.
  def test_a_waveform_the_console_cannot_hold_is_a_friendly_error
    short = assert_raises(ArgumentError) { pad_song([15] * 8) }
    assert_match(/32 steps/, short.message)

    loud = assert_raises(ArgumentError) { pad_song(([15] * 31) + [99]) }
    assert_match(/0 to 15/, loud.message)
  end

  # --- a Score says it the same way ---

  def test_a_score_part_names_the_console_voices_too
    notes = [RubyGBA::Score::Note.new(at: 0, key: 48)]
    pad = RubyGBA::Score::Part.new(plays: :wave, notes: notes)
    drums = RubyGBA::Score::Part.new(plays: :noise, notes: notes, decay: :slow, metallic: true)
    song = RubyGBA::Score.new(parts: [pad, drums]).to_song

    assert_equal :triangle, song[:voices].first.wave
    assert song[:voices].last.noise
    assert_equal :slow, song[:voices].last.decay
    assert_nil song[:voices].first.instrument, "a part on the console's own voice plays no recording"
  end
end
