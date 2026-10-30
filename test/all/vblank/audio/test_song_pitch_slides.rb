# frozen_string_literal: true

require "test_helper"

# A SONG'S NOTES THAT SLIDE THEIR PITCH UP OR DOWN BY THEMSELVES, on the first square voice.
#
# That voice has a circuit the others lack: struck at a pitch, it moves the pitch by a small part
# of itself every so many 128ths of a second, up or down, with nothing from the game — a zap, a
# laser, a swoop down. Sliding up, the pitch climbs faster and faster until it runs past the top
# of what the voice can play, and the voice goes silent, which is how most zaps end.
#
# What the Advance's cartridge tells that voice, read in the emulator, is in
# test/lowering/gba/vblank/audio/test_song_pitch_slides_cartridge.rb.

# The song game, shared with the cartridge's test.
module SongPitchSlidesGames
  include SharedConstants

  # One song, written by the block, played until its notes have all started.
  private def song_game(&parts)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150 # a quarter is 24 frames
        instance_eval(&parts)
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end

class TestSongPitchSlides < Minitest::Test
  include SongPitchSlidesGames

  PitchSlide = VBlank::Audio::PitchSlide

  # What the song set its voices to, in the order it set them: [voice, pitch, volume, slide]. Two
  # quarters are 48 frames, so 40 is every note of a two-note part once, before it comes round.
  private def voices_set(program, frames: 40)
    game_player.run(program, frames: frames).audio
               .select { |entry| entry.first == :voice }
               .map { |_, voice, _song, pitch, volume, _fade, slide| [voice, pitch, volume, slide] }
  end

  def test_a_note_that_slides_says_so_to_its_voice
    c5 = VBlank::Audio::Music::NOTE_FREQUENCIES[:C5]
    a5 = VBlank::Audio::Music::NOTE_FREQUENCIES[:A5]
    played = voices_set(song_game do
      voice :lead do |v|
        v.note :C5, :quarter, slide_up: :fast
        v.note :A5, :quarter, slide_down: :slow
      end
    end)

    assert_equal [[1, c5, 12, PitchSlide.upward(every: 1, shift: 5)], [1, a5, 12, PitchSlide.downward(every: 7, shift: 5)]],
                 played
  end

  # A PART CAN SLIDE EVERY NOTE, and a note can say its own in place of the part's — the voice's own
  # numbers, for music converted from another game, or :none to hold its pitch.
  def test_a_notes_own_slide_comes_before_its_parts
    played = voices_set(song_game do
      voice :lead do |v|
        v.slide_down :medium
        v.note :C5, :eighth
        v.note :D5, :eighth, slide_up: { every: 2, shift: 6 }
        v.note :E5, :eighth, slide_down: :none
        v.note :F5, :eighth
      end
    end)

    assert_equal [PitchSlide.downward(every: 3, shift: 5), PitchSlide.upward(every: 2, shift: 6), PitchSlide::NONE,
                  PitchSlide.downward(every: 3, shift: 5)], played.map(&:last)
  end

  # A SCORE SAYS IT THE SAME WAY, for a game that converts another game's music into one.
  def test_a_score_says_how_its_notes_slide
    score = VBlank::Audio::Score
    # A beat each, 24 ticks, at 150 beats a minute: 24 frames.
    lead = score::Part.new(slide_up: :slow, notes: [score::Note.new(at: 0, key: 60, length: 24),
                                                    score::Note.new(at: 24, key: 64, length: 24, slide_down: :fast)])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      songs(:music, [score.new(parts: [lead], tempo: 150)]).play 0
      game_loop { wait_vblank }
    end
    b.finalize_program

    sounding = voices_set(b.program).reject { |_, pitch| pitch.zero? }
    assert_equal [PitchSlide.upward(every: 7, shift: 5), PitchSlide.downward(every: 1, shift: 5)], sounding.map(&:last)
  end

  # THE MUSIC VOLUME REACHES A HELD NOTE BY STRIKING IT AGAIN, which would start a sliding note's
  # slide over. So a note that slides is left to slide, as a fading note is.
  def test_a_new_music_volume_leaves_a_sliding_note_alone
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        voice(:lead) { |v| v.slide_down :slow; v.note :C5, :whole }
        voice(:bass) { |v| v.note :C3, :whole }
      end
      play_song :tune
      count = var :count, 0
      game_loop do
        count.add! 1
        (count == 10).then { music_volume 50 }
        wait_vblank
      end
    end
    b.finalize_program

    log = game_player.run(b.program, frames: 20).audio
    after = log.drop(log.index([:loudness, 2, 12]) + 1)

    assert_equal [[:loudness, 2, 6]], after.select { |entry| entry.first == :loudness },
                 "the bass is struck again at half; the sliding lead is left to slide"
  end

  # --- what a slide cannot be said of ---
  # (A slide on a song's second square part is the guardrail's: test_ir_guardrail_slide_off_first_square.rb.)

  def test_a_part_on_another_voice_cannot_slide
    error = assert_raises(ArgumentError) do
      song_game { voice(:pad, plays: :wave) { |v| v.note :C3, :whole, slide_down: :slow } }
    end

    assert_match(/:pad/, error.message)
    assert_match(/only the song's first square part can slide/i, error.message)
  end

  def test_a_note_that_slides_both_ways_is_refused
    error = assert_raises(ArgumentError) do
      song_game { voice(:lead) { |v| v.note :C4, :quarter, slide_up: :fast, slide_down: :fast } }
    end

    assert_match(/both `slide_up:` and `slide_down:`/, error.message)
  end

  def test_a_slide_that_is_not_one_says_what_it_can_be
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.slide_up({ every: 9, shift: 2 }) } } }

    assert_match(/:fast, :medium, :slow or :none/, error.message)
    assert_match(/every: 1..7, shift: 1..7/, error.message)
  end
end
