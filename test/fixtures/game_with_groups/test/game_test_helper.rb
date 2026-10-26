# frozen_string_literal: true

require "vblank/testing"

class Minitest::Test # rubocop:disable Style/ClassAndModuleChildren
  include VBlank::Testing

  # Which lowering played this test, left as a file named for the test for the test outside to read.
  def note_lowering
    folder = ENV.fetch("GAME_SUITE_PLAYED", nil)
    File.write(File.join(folder, "#{VBlank::Testing.lowering}-#{name}"), "") if folder
  end
end
