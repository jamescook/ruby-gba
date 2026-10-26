# frozen_string_literal: true

# A fade watched frame by frame, and the long fade the tests of how finely a fade steps play: on
# every console (test_screen_fade.rb) and on the Advance's alone
# (test_screen_fade_on_the_advance.rb).
module FadeWatch
  private

  # What one spot shows on each of the first +frames+ frames.
  def ramp(prog, frames) = watch(prog, frames) { |run| run.screen.pixel(120, 80) }

  # What +read+ gives back on each of the first +frames+ frames, read from ONE run as each
  # frame settles. Playing the game again for every frame looked at costs the square of the
  # frames, which the game built as C, started afresh each time, makes a long wait. The first
  # look comes at the frame boundary before the first pass, so the run plays one frame more
  # and that look is dropped: what is left for frame n is what a run of n frames ends on.
  def watch(prog, frames, &read)
    seen = []
    run = game_player
    run.each_vblank { seen << read.call(run) }
    run.run(prog, frames: frames + 1)
    seen.drop(1).first(frames)
  end

  # A red screen that fades up to white over 33 frames from frame 2, and back from frame
  # 50. Red toward white leaves the red channel alone and walks green and blue from 0 to
  # 31, which is 32 levels: a new picture on every frame of the fade but its first.
  def long_fade(screen_kind, frames: 33, toward: :white, color: :red)
    tile = (["#" * 8] * 8).join("\n")
    b = VBlank::Builder.new
    b.instance_eval do
      screen screen_kind
      if screen_kind == :tiled
        image(:red_art, "#" => color) { tile }
        tiles :set, "#" => :red_art
        background :field, tiles: :set, map: Array.new(20) { "#" * 30 }
      end
      frame = var :frame, 0
      level = var :fade_level_seen, 0
      game_loop do
        clear_screen color unless screen_kind == :tiled
        level.set! fade_level.to_i
        frame.add! 1
        (frame == 2).then { fade_out toward, frames: frames }
        (frame == 50).then { fade_in }
      end
    end
    b.finalize_program
    b.program
  end
end
