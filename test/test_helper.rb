# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# Find teek-mgba binary. Lookup order:
#   1. MGBA_BIN env var (explicit override)
#   2. Installed gem
#   3. Sibling directory (~/open_source/teek-mgba alongside ~/open_source/ruby-gba)
#   4. PATH
def self.find_mgba_bin
  from_env = ENV.fetch("MGBA_BIN", nil)
  return from_env if from_env && !from_env.empty?

  candidates = []

  begin
    spec = Gem::Specification.find_by_name("teek-mgba")
    candidates << File.join(spec.bin_dir, "teek-mgba")
  rescue Gem::MissingSpecError
    # not installed as a gem
  end

  candidates << File.expand_path("../../teek-mgba/bin/teek-mgba", __dir__)

  path = `which teek-mgba 2>/dev/null`.strip
  candidates << path unless path.empty?

  # Return first candidate that exists and can load its dependencies.
  # --version exits before loading C extensions, so we test with --frames
  # on a minimal ROM to verify the full stack works.
  candidates.each do |bin|
    next unless File.exist?(bin)
    require "tempfile"
    rom = RubyGBA.build("TST", code: "BTST", maker: "01") { halt }
    Tempfile.create(["mgba_check", ".gba"]) do |f|
      rom.write(f.path)
      system(bin, "--frames", "1", "--headless", f.path, out: File::NULL, err: File::NULL)
      return bin if $?.success?
    end
  end

  nil
end

MGBA_BIN = find_mgba_bin
