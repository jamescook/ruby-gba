#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick sanity check: build ROMs with ruby-gba, run them in gemba
# in-process for 100 frames, and confirm they don't crash.
#
# Usage:
#   ruby test/test_rom_in_mgba.rb

require_relative "test_helper"
require "tempfile"

def build_and_run(name, &block)
  rom = RubyGBA.build(name, code: "BTST", maker: "01", &block)
  puts "Built #{name}: #{rom.size} bytes"
  puts RubyGBA::Inspector.from_rom(rom).header_report
  puts RubyGBA::Inspector.from_rom(rom).code_report(max_instructions: 20)
  puts

  Tempfile.create([name.downcase, ".gba"]) do |f|
    rom.write(f.path)
    core = Gemba::Core.new(f.path)
    100.times { core.run_frame }
    core.destroy
  end
  puts "Ran 100 frames in gemba OK"
  puts "-" * 60
  puts
end

# Only execute when run directly. Rake globs test/**/test_*.rb, so guard the
# script body — otherwise it would run (and exit) during the test suite.
if __FILE__ == $PROGRAM_NAME
  unless GembaSupport.gem_available?
    warn "gemba not available — skipping run (gem install gemba)"
    exit 0
  end

  puts "=== Test 1: Empty (just halt) ==="
  build_and_run("EMPTY") do
    entry { loop_forever }
  end

  puts "=== Test 2: Display mode only ==="
  build_and_run("MODEONLY") do
    screen :bitmap
    halt
  end

  puts "=== Test 3: Single red pixel ==="
  build_and_run("REDPIXEL") do
    screen :bitmap
    pixel 120, 80, :red
    halt
  end

  puts "=== Test 4: Three pixels ==="
  build_and_run("THREEPIX") do
    screen :bitmap
    pixel 0, 0, :red
    pixel 120, 80, :green
    pixel 239, 159, :blue
    halt
  end

  puts "=== Test 5: Small fill_rect ==="
  build_and_run("FILLRECT") do
    screen :bitmap
    fill_rect 100, 60, 40, 40, :red
    halt
  end

  puts "Done."
end
