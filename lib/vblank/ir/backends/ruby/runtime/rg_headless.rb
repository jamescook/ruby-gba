# The driver with no window: what the tests run a game against.
#
#   ruby game.rb FRAMES [options] < buttons
#
# plays FRAMES frames and stops at the start of the next one, the way the interpreter's
# run(program, frames: FRAMES) does. Each line of standard input is the buttons held during one
# frame, as a number with a bit per button (bit 0 is a, in the order rg_runtime.rb lists them); a
# missing line holds nothing.
#
# At every frame boundary it prints "frame N", every variable as "var name value", every list as
# "list name" and its items (see rg_driver_dump_list), every sprite the game last drew as "sprite"
# and four numbers, and where the window sits over the picture as "camera X Y", then "buttons?",
# and only then reads that frame's line. So whoever is feeding it can answer from what the game
# has done so far — a test that presses a button only once the game has reached somewhere — or
# write every line up front and ignore the question. That is the order the interpreter asks its
# own input script in, after the frame before has finished.
#
# At the end it prints "end", every variable and every sprite the same way, and the picture as
# shown: "picture" and every pixel, row by row, as four hex digits — and then the same page as it
# is stored ("stored"), with no window moved over it and no fade mixed in, and how many pages the
# screen has ("pages", 2 for a tear-free one). A frame's moment carries only a check number of its
# picture ("picture-crc"), or with --every-picture the whole picture.
#
# The options:
#
#   --every-picture             the whole picture at every frame, not only a check number
#   --picture-out FILE          the picture of every moment written to FILE, over the one before:
#                               every pixel as shown and then as stored, row by row, each two
#                               bytes with the low byte first, there before "buttons?" is asked
#   --held-from-power-on MASK   the buttons in MASK are down before the game's first statement
#   --clock-at SECONDS TICKS SET  the cartridge has a clock, reading SECONDS from the start of
#                               1970 and TICKS of the console's 2^24 a second more at power-on,
#                               set when SET is 1; without it the cartridge has no clock

require "zlib"

RG_GAME_WENT_WRONG = 3 # how a run ends when the game did something the interpreter refuses

def rg_headless_main(argv)
  if argv.empty?
    $stderr.puts "give the number of frames to play, and the buttons for each frame on standard input"
    exit 2
  end
  @rg_frames_to_play = argv[0].to_i
  @rg_frame = 0 # frames started so far
  @rg_every_picture = false
  @rg_picture_out = nil
  i = 1
  while i < argv.length
    case argv[i]
    when "--every-picture" then @rg_every_picture = true
    when "--picture-out"
      i += 1
      @rg_picture_out = File.open(argv[i], "wb")
    when "--held-from-power-on"
      i += 1
      rg_buttons_held_from_power_on(argv[i].to_i)
    when "--clock-at"
      rg_clock_starts_at(argv[i + 1].to_i, argv[i + 2].to_i, argv[i + 3].to_i)
      i += 3
    end
    i += 1
  end
  rg_game_main
  rg_headless_finish
end

def rg_driver_wait_vblank
  rg_headless_finish if @rg_frame >= @rg_frames_to_play
  rg_frame_begins
  @rg_frame += 1
  rg_headless_print_moment("frame #{@rg_frame}", @rg_every_picture)
  $stdout.write("buttons?\n")
  $stdout.flush
  line = $stdin.gets
  rg_buttons_read(line ? line.to_i : 0)
end

def rg_driver_halt = rg_headless_finish

# Said on the error stream, and the run ends badly, which is how a test sees it.
def rg_driver_fault(message)
  $stdout.flush
  $stderr.puts message
  exit RG_GAME_WENT_WRONG
end

# "var" first, so no name a game gives a variable can be read as one of the other lines.
def rg_driver_dump_variable(name, value)
  $stdout.write("var #{name} #{value}\n")
end

# "list", the game's name for it, a tab, and its items oldest first — the order the game reads
# them in, which in a list the game shifts is not the order they sit in memory. The tab ends the
# name, since a pool's field may be called anything, spaces and all.
def rg_driver_dump_list(list)
  items = Array.new(list.length) { |i| list.items[rg_list_slot(list, i)] }
  $stdout.write("list #{list.name}\t#{items.join(' ')}\n")
end

def rg_headless_print_moment(heading, with_picture)
  $stdout.write("#{heading}\n")
  rg_game_dump_state
  # Every sprite the game last said is on screen, back to front, a line each: whose it is and
  # which picture it shows, both as the number of a name the game was built with, and where it is.
  rg_screen_drawn_count.times do |place|
    name, picture, x, y = rg_screen_drawn_sprite(place)
    $stdout.write("sprite #{name} #{picture} #{x} #{y}\n")
  end
  $stdout.write("camera #{rg_screen_camera_x} #{rg_screen_camera_y}\n")
  shown = rg_screen_shown
  if with_picture
    rg_headless_print_pixels("picture", shown)
  else
    # The CRC-32 of the pixels, each as two bytes with the low byte first: the number the C
    # driver prints for the same picture, and the one Ruby's Zlib.crc32 gives.
    $stdout.write(format("picture-crc %08x\n", Zlib.crc32(shown.pack("v*"))))
  end
  rg_headless_write_picture(shown) if @rg_picture_out
end

# A whole picture as one line: +word+ and then every pixel, row by row, as four hex digits.
def rg_headless_print_pixels(word, pixels)
  $stdout.write("#{word} #{pixels.map { |pixel| format('%04x', pixel) }.join}\n")
end

def rg_headless_write_picture(shown)
  @rg_picture_out.rewind
  @rg_picture_out.write(shown.pack("v*"), rg_screen_stored.pack("v*"))
  @rg_picture_out.flush
end

def rg_headless_finish
  rg_headless_print_moment("end", !@rg_picture_out)
  rg_headless_print_pixels("stored", rg_screen_stored) unless @rg_picture_out
  $stdout.write("pages #{rg_screen_two_pages != 0 ? 2 : 1}\n")
  $stdout.flush
  @rg_picture_out&.close
  exit 0
end
