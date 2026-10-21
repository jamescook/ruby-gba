# frozen_string_literal: true

require "test_helper"

# A BEAT — `every` and `after` — is counted in frames, and IR::Frames says it as the plain
# statements every lowering already makes (an add, a comparison, an if), so no lowering writes
# the rule again. Each test plays the beat on the interpreter, the answer key, beside the same
# program with the beat replaced by its plain statements, and the two must end the same.
class TestFrames < Minitest::Test
  include RubyGBA::IR::Build

  Frames = RubyGBA::IR::Frames

  # A one-shot reached before the first frame, a repeating beat and a one-shot in the loop,
  # played with every second pass worth two frames, so a pass can step over a frame a beat
  # was waiting for.
  def test_plain_statements_count_frames_as_beat_does
    soon = after(:_soon, 1, add(:fired, 1))
    beat = every(:_beat, 3, add(:ticks, 1))
    late = after(:_late, 5, add(:landed, 1))

    as_beats = played(program(soon, loop_(wait_vblank, beat, late)))
    as_plain = played(program(*plain(soon), loop_(wait_vblank, *plain(beat), *plain(late))))

    assert_equal as_beats.game_state, as_plain.game_state
    assert_equal 1, as_plain[:fired], "a one-shot reached before the first frame counts that pass as one frame"
    assert_operator as_plain[:ticks], :>, 1, "the repeating beat came round more than once"
  end

  private

  def played(program)
    Reference.new.frames_each_pass { |pass| pass.even? ? 2 : 1 }.run(program, frames: 12)
  end

  def plain(beat) = Frames.beat_statements(beat)
end
