# frozen_string_literal: true

require "test_helper"

require "stringio"
require "tmpdir"

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

  # What any console's cartridge is asked (Console::Kit, "the cartridge"), answered the same way by
  # each. Its profile needs the emulator, so it is asked of in the tests of each profiler.
  def test_every_consoles_cartridge_answers_what_a_cartridge_is_asked
    Console.kits.each do |kit|
      rom = RubyGBA.build("KITCART", console: kit.name, out: nil, err: nil) do
        var :score, 3
        game_loop { pixel 1, 1, :white }
      end
      Dir.mktmpdir do |dir|
        path = File.join(dir, "kit#{kit.description.extension}")
        rom.write(path)

        assert_equal rom.buffer.b, File.binread(path), kit.name
      end

      assert_equal rom.buffer.bytesize, rom.size, kit.name
      assert kit.cartridge.header?(rom.buffer), kit.name
      assert_match(/\AKITCART/, rom.header_title, kit.name)
      assert_equal kit.name, rom.console, kit.name
      refute_nil rom.built, kit.name
      assert_equal :program, rom.source_program.kind, kit.name
      assert rom.var_addresses.key?(:score), kit.name
    end
  end

  # A console setting (one only some consoles have) set for a build for a console without it is
  # refused rather than dropped: the author asked for something the cartridge would not have.
  def test_a_setting_only_the_advance_has_is_refused_on_a_color_build
    [{ stack_room: 512 }, { fast_code: false }, { fast_cartridge: false }, { code: "QZXW" }, { maker: "ZZ" },
     { profile: "measured.json" }].each do |set|
      error = assert_raises(ArgumentError) do
        RubyGBA.build("ADVONLY", console: :gbc, out: nil, err: nil, **set) { halt }
      end

      assert_match(/`#{set.keys.first}:`/, error.message)
      assert_match(/only the Game Boy Advance/i, error.message)
      assert_match(/`console:`/, error.message)
    end
  end

  # A game for both consoles says its Advance settings once, where it is named, and its Color
  # cartridge is built without them.
  def test_a_game_for_both_consoles_builds_its_color_cartridge_without_advance_settings
    game = RubyGBA.game("BOTHSET", consoles: %i[gba gbc], stack_room: 512, fast_code: false) { halt }

    assert_instance_of RubyGBA::Cartridge::GBCROM, game.build_rom(out: nil, err: nil, profile: false, console: :gbc)
  end

  # A game for the Color alone that says an Advance setting is refused where it is named.
  def test_a_color_game_that_says_an_advance_setting_is_refused
    error = assert_raises(ArgumentError) { RubyGBA.game("COLORSET", consoles: %i[gbc], stack_room: 512) { halt } }

    assert_match(/`stack_room:`/, error.message)
    assert_match(/COLORSET is for the Game Boy Color/, error.message)
    assert_match(/`consoles:`/, error.message)
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
