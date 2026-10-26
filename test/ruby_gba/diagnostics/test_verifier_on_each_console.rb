# frozen_string_literal: true

require "test_helper"

require "stringio"

# ONE READER PLAYS EVERY CONSOLE'S CARTRIDGE BACK (Verifier), asking that console's part of it
# (Console::Kit#reading) for what only its way of keeping things can answer: the same test reads
# an Advance cartridge and a Color one, and a question only one console's cartridges answer is
# refused by name on the other's.
class TestVerifierOnEachConsole < Minitest::Test
  def setup
    require_emulator!
  end

  def test_one_reader_reads_sprites_and_pixels_off_every_consoles_cartridge
    RubyGBA::Console.kits.each do |kit|
      reader = RubyGBA::Diagnostics::Verifier.new(dot_game(kit.name), frames: 10)

      assert_equal kit.description.screen_size, [reader.screen_width, reader.screen_height], kit.title
      dot = reader.sprites(:dot)
      assert_equal [[:dot, 16, 24]], dot.map { |row| [row.name, row.x, row.y] }, kit.title
      assert reader.pixel_is?(19, 27, :red), "the #{kit.title}'s dot is drawn where its row says"
      refute reader.pixel_is?(15, 27, :red), "the #{kit.title}'s dot starts where its row says"
    end
  end

  # The processor and the mixer of recordings are the Advance's, so only a reader over an Advance
  # cartridge has questions about them.
  def test_only_a_reader_over_an_advance_cartridge_has_the_advances_questions
    advance_only = %i[registers run_until wave_rate pad_reads voices sounding sample_clock sound_drops]
    advance = RubyGBA::Diagnostics::Verifier.new(dot_game(:gba), frames: 2)
    color = RubyGBA::Diagnostics::Verifier.new(dot_game(:gbc), frames: 2)

    assert_equal advance_only, advance_only.select { |question| advance.respond_to?(question) }
    assert_empty advance_only.select { |question| color.respond_to?(question) }
  end

  # The emulator writes a clock chip's own bytes after the save memory, more on a Color than on an
  # Advance; what the reader hands back is the save memory alone, the 32K this Color cartridge keeps.
  def test_a_color_cartridges_save_memory_is_read_without_its_clocks_bytes
    rom = RubyGBA.build("SAVED", console: :gbc, out: StringIO.new, err: StringIO.new) do
      now = clock
      hour = var :hour, -1
      game_loop do
        pressed(:a).then { now.set_to(year: 2030, month: 6, day: 15, hour: 12, minute: 0, second: 0) }
        hour.set! now.hour
      end
    end
    reader = RubyGBA::Diagnostics::Verifier.new(rom, frames: 6, keys: ->(frame) { frame == 3 ? RubyGBA::IR::Buttons.mask([:a]) : 0 })

    assert_equal 0x8000, reader.save_image.to_sav.bytesize
  end

  private def dot_game(console)
    RubyGBA.build("READER", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:dot, "#" => :red) { "########\n" * 8 }
      sprite :dot, at: [16, 24]
      game_loop {}
    end
  end
end
