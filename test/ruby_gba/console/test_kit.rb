# frozen_string_literal: true

require "test_helper"

require "stringio"

# WHICH PARTS OF THE LIBRARY SERVE EACH CONSOLE, asked of one place (Console::Kit): a game for a
# console is built by that console's build into its own kind of cartridge, and nothing outside a
# console's own code asks which console it is by comparing names.
class TestKit < Minitest::Test
  Console = RubyGBA::Console

  def test_each_consoles_game_is_its_kits_kind_of_cartridge
    Console.kits.each do |kit|
      rom = RubyGBA.build("KIT", console: kit.name, out: StringIO.new, err: StringIO.new) do
        screen :tiled
        image(:dot, "#" => :white) { "########\n" * 8 }
        sprite :dot, at: [8, 8]
        game_loop {}
      end

      assert_kind_of kit.cartridge, rom, "a game for :#{kit.name}"
      assert_equal kit.name, rom.console
    end
  end

  def test_a_console_named_in_words_is_the_same_kit
    assert_same Console.for(:gbc), Console.for("gbc")
  end

  def test_a_console_named_in_words_is_held_by_its_symbol
    assert_equal :gbc, Console.named("gbc")
  end

  def test_a_console_nobody_has_is_refused_with_the_names_there_are
    [:snes, nil].each do |name|
      error = assert_raises(ArgumentError) { Console.for(name) }

      assert_match(/:gba and :gbc/, error.message, name.inspect)
    end
  end

  # Where a console's own code lives: its lowering, its build and its own reader. Anywhere else, a
  # part that needs to know asks the console's kit.
  OWN = %w[lib/ruby_gba/ir/backends/gba lib/ruby_gba/ir/backends/gba.rb lib/ruby_gba/ir/backends/gbc
           lib/ruby_gba/ir/backends/gbc.rb lib/ruby_gba/cartridge/advance_build.rb lib/ruby_gba/cartridge/color_build.rb
           lib/ruby_gba/cartridge/rom.rb lib/ruby_gba/cartridge/gbc_rom.rb lib/ruby_gba/console].freeze

  # `rom.console == :gbc`, `console.name != :gba` and the like: a console told apart by its name.
  # (A lowering's run is named :gba or :gbc too, and that is not a console.)
  NAME_COMPARED = /console[\w.]*\s*[!=]=\s*:(#{RubyGBA::Console::KITS.keys.join('|')})\b/

  def test_nothing_outside_a_consoles_own_code_compares_console_names
    root = RubyGBA.root
    compared = Dir[root.join("lib/**/*.rb").to_s].flat_map do |path|
      relative = path.delete_prefix("#{root}/")
      next [] if OWN.any? { |own| relative == own || relative.start_with?("#{own}/") }

      File.readlines(path).each_with_index.filter_map do |line, at|
        "#{relative}:#{at + 1}" if line.match?(NAME_COMPARED) && !line.lstrip.start_with?("#")
      end
    end

    assert_empty compared, "these ask which console it is by its name; ask Console.for(name) instead"
  end
end
