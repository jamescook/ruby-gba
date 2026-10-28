# frozen_string_literal: true

# WHICH SPEAKER A VOICE IS HEARD FROM, read off a cartridge's sound in the emulator: a voice on one
# speaker is far louder there than on the other, which hears only what the emulator's filter leaves
# of nothing, and a voice on both is as loud from each.
module Speakers
  # A voice heard from one speaker is at least this many times louder there than from the other.
  APART = 20

  # +voice+'s loudest frame from the left speaker and from the right, as [left, right], over
  # +frames+ frames of +program+'s cartridge from frame +from+ on.
  def loudest_on_each_side(program, voice, frames:, from:)
    %i[left right].map do |side|
      heard = VBlank::Diagnostics::SoundRecording.of(program, on: :cartridge, frames: frames, only: voice, side: side)
      heard.frames.drop(from).map(&:loudness).max
    end
  end

  # +loudest+ is a voice's [left, right] (#loudest_on_each_side); +side+ is :left, :right or :both.
  def assert_heard_from(side, loudest, what)
    left, right = loudest
    case side
    when :left then assert_operator left, :>, right * APART, "#{what} is heard from the left alone (#{left}, #{right})"
    when :right then assert_operator right, :>, left * APART, "#{what} is heard from the right alone (#{left}, #{right})"
    else assert_in_delta 1.0, left.to_f / right, 0.2, "#{what} is heard from both (#{left}, #{right})"
    end
  end
end
