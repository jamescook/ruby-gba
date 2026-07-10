#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick sanity check: build ROMs with ruby-gba, run them in teek-mgba
# for 100 frames via --frames, confirm they don't crash.
#
# Usage:
#   ruby test/test_rom_in_mgba.rb

require_relative "test_helper"
require "tempfile"

unless MGBA_BIN
  warn "teek-mgba not found — skipping integration tests (gem install teek-mgba)"
  exit 0
end

def build_and_run(name, &block)
  rom = RubyGBA.build(name, code: "BTST", maker: "01", &block)

  Tempfile.create([name.downcase, ".gba"]) do |f|
    rom.write(f.path)
    puts "Built #{name}: #{rom.size} bytes → #{f.path}"
    puts RubyGBA::Inspector.from_rom(rom).header_report
    puts RubyGBA::Inspector.from_rom(rom).code_report(max_instructions: 20)
    puts

    cmd = "#{MGBA_BIN} --frames 100 --headless #{f.path} 2>&1"
    puts "Running: #{cmd}"
    output = `#{cmd}`
    status = $?
    puts "Exit: #{status.exitstatus}"
    puts output unless output.strip.empty?
    puts "-" * 60
    puts
  end
end

puts "=== Test 1: Empty (just halt) ==="
build_and_run("EMPTY") do
  entry { loop_forever }
end

puts "=== Test 2: Display mode only ==="
build_and_run("MODEONLY") do
  display :bitmap
  halt
end

puts "=== Test 3: Single red pixel ==="
build_and_run("REDPIXEL") do
  display :bitmap
  pixel 120, 80, :red
  halt
end

puts "=== Test 4: Three pixels ==="
build_and_run("THREEPIX") do
  display :bitmap
  pixel 0, 0, :red
  pixel 120, 80, :green
  pixel 239, 159, :blue
  halt
end

puts "=== Test 5: Small fill_rect ==="
build_and_run("FILLRECT") do
  display :bitmap
  fill_rect 100, 60, 40, 40, :red
  halt
end

puts "Done."
