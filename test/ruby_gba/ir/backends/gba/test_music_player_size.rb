# frozen_string_literal: true

require "test_helper"

# WHAT THE MUSIC PLAYER COSTS THE ROUTINE THE SCREEN'S INTERRUPT RUNS. That routine is weighed
# for the console's quick memory against everything else a frame runs, so its size is a fact a
# game near the line feels: grown past what is left, it runs from the cartridge, and a pass that
# fitted its frame no longer does.
#
# A song asked for `this_frame: true` is started by the game itself rather than by the
# interrupt, through the same steps — and those steps are written once, beside the player, and
# called from both places, so asking that way costs a routine's worth of calling and not a
# second copy of the player.
class TestMusicPlayerSize < Minitest::Test
  runs_on :reference

  Score = RubyGBA::Audio::Score
  Part = Score::Part
  Note = Score::Note

  # A song on seven lanes — two square parts, the wave voice, the noise voice and three
  # recordings — beside a sound effect, asked for the plain way or `this_frame: true`. With
  # +once+ it is a song that plays once and ends, which the player silences when it has.
  def program(this_frame:, once: false)
    notes = [Note.new(at: 0, key: :C4), Note.new(at: 10, key: :E4)]
    parts = [Part.new(notes: notes), Part.new(notes: notes), Part.new(plays: :wave, notes: notes),
             Part.new(plays: :noise, notes: notes), *Array.new(3) { Part.new(plays: :piano, notes: notes) }]
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 400, rate: 8000, note: :C4
      music = songs :music, [Score.new(tempo: 150, parts: parts, plays_once: once)]
      sfx = sound_effects :sfx, [Score.new(tempo: 150, parts: [Part.new(notes: notes)])]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 3).then { music.play 0, this_frame: this_frame }
        (pass == 5).then { sfx.play 0 }
      end
    end
    b.finalize_program
    b.program
  end

  def interrupt_routine_bytes(program)
    backend = GBA.new
    backend.lower(program)
    backend.func_sizes.fetch(GBA::Placement::IRQ_ROUTINE)
  end

  # A few dozen instructions of calling and switching the interrupt off, against the player's
  # frame of a seven-lane song, which is well over a kilobyte by itself.
  MOST_FOR_THIS_FRAME = 256

  def test_a_song_asked_for_this_frame_adds_no_second_copy_of_the_player
    [false, true].each do |once|
      plain = interrupt_routine_bytes(program(this_frame: false, once: once))
      this_frame = interrupt_routine_bytes(program(this_frame: true, once: once))

      assert_operator this_frame - plain, :<=, MOST_FOR_THIS_FRAME,
                      "a song that plays once: #{once}. The interrupt's routine is #{plain} bytes asked the " \
                      "plain way and #{this_frame} this_frame:"
    end
  end

  # A SONG THAT ENDS adds a few instructions a lane to the player — what silences it once it
  # has — so asking for one `this_frame: true` must not write those a second time either.
  def test_a_song_that_ends_asked_for_this_frame_adds_no_second_silencing
    plain = interrupt_routine_bytes(program(this_frame: false, once: true)) - interrupt_routine_bytes(program(this_frame: false))
    this_frame = interrupt_routine_bytes(program(this_frame: true, once: true)) - interrupt_routine_bytes(program(this_frame: true))

    assert_operator this_frame, :<=, plain, "a song that ends costs #{plain} bytes asked plainly and #{this_frame} this_frame:"
  end
end
