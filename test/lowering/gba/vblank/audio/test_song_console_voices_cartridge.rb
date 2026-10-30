# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/audio/test_song_console_voices"

# A SONG PART ON THE WAVE VOICE AND ON THE NOISE VOICE, on the Advance's own cartridge: what the
# lowering wrote to the console's sound registers and its wave memory, read back in the emulator.
# What a game does with these voices, asked of every run, is in
# test/all/vblank/audio/test_song_console_voices.rb, which keeps the games both files play.
class TestSongConsoleVoicesCartridge < Minitest::Test
  include VBlank::Console::Hardware
  include SongConsoleVoicesGames

  # A tune whose parts cover every voice there is: two square, one wave, one noise, one recorded.
  private def every_voice_game(frames: 60)
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
    b.finalize_program
    b.program
  end

  # A wave part really reaches the wave voice's registers, and a noise part the noise voice's.
  # Read off the running console rather than off the score, so this is what the lowering did.
  #
  # THE RATE AND NOT THE TRIGGER, because the pitch is the part that says the right note
  # arrived. Neither can be read back off SOUND3CNT_X — the restart bit and the rate bits are
  # both write-only, so the register says 0 whatever is playing — so the rate is asked of the
  # sound circuit, which holds the one it is actually sounding.
  def test_the_console_sounds_both_voices
    rom = assemble_rom(every_voice_game, name: "VOICES")
    v = assert_emulator_loads_rom(rom, frames: 8)

    assert_equal Registers.wave_rate(VBlank::Audio::Music::NOTE_FREQUENCIES[:C2]),
                 v.wave_rate, "the wave voice is playing the pad's note"
    refute_equal 0, v.mem16(REG_SOUND3CNT_H), "...at a level you can hear"
    refute_equal 0, v.mem16(REG_SOUND4CNT_L), "the noise voice was hit"
  end

  # Both backends sound the same thing, which is the contract that makes the interpreter an
  # oracle for this at all.
  def test_both_backends_agree_about_what_the_wave_voice_plays
    program = every_voice_game
    interpreted = game_player.run(program, frames: 8).audio.select { |e| e.first == :wave }.map(&:last).first
    v = assert_emulator_loads_rom(assemble_rom(program, name: "VOICES"), frames: 10)

    assert_equal Registers.wave_rate(interpreted[:frequency]), v.wave_rate
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
      probe = VBlank::Diagnostics::Emulator.probe(path)
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
  private def wave_ram(probe)
    (0...(Registers.wavetable_halfwords(:triangle).length / 2)).flat_map do |word|
      value = probe.read32(REG_WAVE_RAM + (word * 4))
      [value & 0xFFFF, (value >> 16) & 0xFFFF]
    end
  end

  # EVERY PART CARRIES THEM, and only a noise part is ever asked. They are fields with defaults
  # rather than keys that might not be there, so a square part answers what a drum would and
  # nothing reads it — which is worth pinning, because the risk a default introduces is that it
  # LEAKS. A drum's default fade must not reach a square part, which holds its notes unless it
  # says how they fade (test_song_note_fades.rb), and a rattle is the hiss's alone.
  def test_a_drums_settings_change_nothing_a_square_part_plays
    assert_equal GBA.new.lower(square_song), GBA.new.lower(square_song(rattles: true)),
                 "a square part's notes are its pitch and its tone — a drum's settings cannot reach them"
  end

  # The same tune twice: one square-wave part, optionally told that a drum hit would rattle.
  private def square_song(rattles: false)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song :tune do
        voice :lead do |v|
          v.metallic true if rattles
          v.note :C4, :quarter
        end
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # --- a waveform of the game's own, rather than one of the names ---

  # Wave RAM as the console really holds it — the eight halfwords of the bank the CPU is shown.
  private def wave_ram_of(program, name)
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
    b.finalize_program

    assert_equal Registers.wavetable_halfwords(PULSE_50), wave_ram_of(b.program, "WVERB")
  end
end
