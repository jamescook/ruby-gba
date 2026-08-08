# frozen_string_literal: true

module RubyGBA
  # A game the DSL block defines but has not built yet.
  #
  # `RubyGBA.game "NAME", code:, maker: do ...dsl... end` records the title, the
  # cartridge codes, and the DSL block, and hands back this handle — WITHOUT building
  # or writing anything. That separation is the point: a game file only declares the
  # game, so the tool that drives the build (the `ruby-gba` command) owns the output
  # path and how much it prints. The same handle also carries the two methods tests
  # build against — #program (the op-tree the reference interpreter runs) and
  # #build_rom (the finished cartridge) — so an example is one `RubyGBA.game` call
  # instead of a module of wiring.
  class Game
    attr_reader :title, :code, :maker

    def initialize(title, code:, maker:, block:, frame_sync: :auto, fast_cartridge: true, fast_code: true)
      @title = title
      @code = code
      @maker = maker
      @block = block
      @frame_sync = frame_sync
      @fast_cartridge = fast_cartridge
      @fast_code = fast_code
    end

    # The op-tree the DSL block builds — what the headless interpreter runs in tests.
    # Built with the same frame timing #build_rom uses, so the tree a test runs is
    # the tree that ships.
    def program
      builder = Builder.new(frame_sync: @frame_sync)
      builder.instance_eval(&@block)
      builder.emit_pending_functions
      builder.program
    end

    # The finished ROM. The out:/err: streams are injectable so a test (or the CLI)
    # captures anything the build prints.
    def build_rom(out: $stdout, err: $stderr, validate: true)
      RubyGBA.build(@title, code: @code, maker: @maker, validate: validate,
                    frame_sync: @frame_sync, fast_cartridge: @fast_cartridge,
                    fast_code: @fast_code, out: out, err: err, &@block)
    end

    # A friendly output filename from the title: "BIRD" -> "bird.gba".
    def default_filename
      base = @title.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      "#{base.empty? ? 'game' : base}.gba"
    end

    # Build this game and write the .gba beside the file that calls this — but only
    # when that file is the script Ruby was run with (`ruby game.rb`). Put it as the
    # last line of a game file so a plain run produces a cartridge, while requiring the
    # file (a test) or loading it (the `ruby-gba` command) stays silent and writes
    # nothing. Returns self.
    def write_if_main
      caller_path = caller_locations(1, 1)&.first&.path
      return self unless caller_path && main_script?(caller_path)

      rom = build_rom
      path = File.join(File.dirname(File.expand_path(caller_path)), default_filename)
      rom.write(path)
      $stdout.puts "Built #{File.basename(path)} (#{rom.size} bytes)"
      self
    end

    private

    # Is +path+ the very script Ruby was told to run? Compared as full paths so a
    # relative "examples/bird.rb" and an absolute run path still match.
    def main_script?(path)
      program = $PROGRAM_NAME
      !program.nil? && File.expand_path(path) == File.expand_path(program)
    end
  end

  class << self
    # Every game declared while this process ran, in declaration order (usually one
    # per file). The `ruby-gba` command loads a game file and reads the game it
    # declared from here.
    def registered_games
      @registered_games ||= []
    end

    # Declare a game: record its DSL block for later building and return a Game
    # handle. Building and writing are left to the caller — see Game — except for the
    # `ruby game.rb` convenience above.
    def game(title, code:, maker:, frame_sync: :auto, fast_cartridge: true, fast_code: true, &block)
      unless block
        raise ArgumentError, %(RubyGBA.game needs a block: RubyGBA.game("NAME", code: "CODE", maker: "01") { ... })
      end

      handle = Game.new(title, code: code, maker: maker, block: block, frame_sync: frame_sync,
                        fast_cartridge: fast_cartridge, fast_code: fast_code)
      registered_games << handle
      handle
    end
  end
end
