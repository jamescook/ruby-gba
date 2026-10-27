# What the runtime promises the game — the buttons, the frames, the timers, the cartridge's clock,
# stopping — handed to the driver the game runs on where the machine matters. Nothing here knows
# whether there is a window: the driver is the methods named rg_driver_*, which the driver's own
# file gives the game's class (rg_headless.rb, the one with no window).

RG_ALL_BUTTONS = 0x3FF
RG_MAX_TIMERS = 32
RG_CONSOLE_TICKS_A_SECOND = 16777216
RG_CONSOLE_TICKS_A_FRAME = 280896 # a frame of the console's, a little more than a sixtieth of a second
RG_SECONDS_A_DAY = 86400

# The readings of the clock, in IR::Clock::READINGS's order, which is the number the game asks by.
RG_CLOCK_HOUR = 0
RG_CLOCK_MINUTE = 1
RG_CLOCK_SECOND = 2
RG_CLOCK_YEAR = 3
RG_CLOCK_MONTH = 4
RG_CLOCK_DAY = 5
RG_CLOCK_WEEKDAY = 6
RG_CLOCK_PRESENT = 7
RG_CLOCK_SET = 8

# The game's own state first, then each part of the runtime's.
def initialize
  rg_runtime_setup
  rg_screen_setup
  rg_game_setup
end

def rg_runtime_setup
  @rg_held = 0    # buttons down now, a bit each
  @rg_seen = 0    # ...and at the last frame boundary, to tell a press from a hold
  @rg_pressed = 0 # buttons that went down at the last frame boundary
  # One timer each (RgTimer), and the timers in the order each was first started, which is the
  # order the interpreter walks them in.
  @rg_timers = Array.new(RG_MAX_TIMERS) { RgTimer.new }
  @rg_timers_started = []
  @rg_ticking = -1
  @rg_clock_present = 0
  @rg_clock_set = 0
  @rg_clock_counts_frames = 0 # moved on a frame at each boundary, rather than told the time
  @rg_clock_seconds = 0       # the time now, as seconds from the start of 1970...
  @rg_clock_ticks = 0         # ...and the console's ticks into the next second
  @rg_clock_kept_days = 0
  @rg_clock_kept_seconds = 0
end

# --- the buttons ---

# A button counts as pressed on the one frame it goes down, however long it is then held — the
# edge the interpreter's read_buttons finds. A driver says which are down at every frame boundary.
def rg_buttons_read(now)
  @rg_held = now & RG_ALL_BUTTONS
  @rg_pressed = @rg_held & ~@rg_seen
  @rg_seen = @rg_held
end

# Down before the first frame boundary and not yet seen there, so the first boundary still finds
# them going down — the interpreter's hold, and the console's keys from power-on.
def rg_buttons_held_from_power_on(now)
  @rg_held = now & RG_ALL_BUTTONS
end

# A button's bit in +buttons+, or any of them for -1. The buttons are numbered in the order the
# console's key register holds them: a, b, select, start, right, left, up, down, r, l.
def rg_button_down(buttons, button)
  return buttons != 0 ? 1 : 0 if button < 0

  (buttons >> button) & 1
end

def rg_held(button) = rg_button_down(@rg_held, button)
def rg_pressed(button) = rg_button_down(@rg_pressed, button)

# --- frames ---

# The frame the game drew has ended, whoever is driving and whether or not the run stops here.
def rg_wait_vblank
  rg_screen_frame_ended
  rg_driver_wait_vblank
end

# What every driver does as a frame begins, after deciding to play it, in the interpreter's order
# (Reference#advance_frame): the picture is switched on, the timers tick, the mix, then the tune,
# then every sounding note's shape, and then the frame is counted, which moves a clock started at
# a test's moment.
def rg_frame_begins
  rg_screen_frame_started
  rg_timers_frame
  rg_mix_frame
  rg_music_frame
  rg_mix_step_shapes
  rg_clock_frame
end

# --- stopping ---

# The game stopped on purpose (`halt`). The driver never comes back.
def rg_halt = rg_driver_halt

# The game did something the interpreter refuses: says so in +message+, and stops. The driver
# never comes back.
def rg_fault(message) = rg_driver_fault(message)

def rg_dump_variable(name, value) = rg_driver_dump_variable(name, value)
def rg_dump_list(list) = rg_driver_dump_list(list)

# --- timers (Reference @timers) ---

# One timer: whether it has ever been started, whether it is running, its rate, and how far it has
# ticked since it was last started, in +frames_a_second+-ths of a tick — each frame adds its rate,
# and the whole ticks are how many whole +frames_a_second+ that comes to. Whole numbers, as the
# interpreter keeps them (Reference#accrue_timer), so the two cross a whole tick on the same frame.
class RgTimer
  attr_accessor :started, :running, :ticks_a_second, :frames_a_second, :parts

  def initialize
    @started = false
    @running = false
    @ticks_a_second = 0
    @frames_a_second = 1
    @parts = 0
  end

  # How many whole times it has ticked since it was started (Reference#whole_overflows).
  def whole_ticks = @parts / @frames_a_second
end

def rg_fault_unless_timer(timer)
  return if timer >= 0 && timer < RG_MAX_TIMERS

  rg_fault("timer number #{timer} is not one of the #{RG_MAX_TIMERS} there is room for")
end

# Reference#exec_timer_start: started again from nought.
def rg_timer_start(number, ticks_a_second, frames_a_second)
  rg_fault_unless_timer(number)
  timer = @rg_timers[number]
  @rg_timers_started << number unless timer.started
  timer.started = true
  timer.running = true
  timer.ticks_a_second = ticks_a_second
  timer.frames_a_second = frames_a_second
  timer.parts = 0
end

# Reference#exec_timer_stop: a timer never started has nothing to stop.
def rg_timer_stop(number)
  rg_fault_unless_timer(number)
  @rg_timers[number].running = false
end

# Reference#timer_ticks
def rg_timer_ticks(number)
  rg_fault_unless_timer(number)
  timer = @rg_timers[number]
  timer.started ? timer.whole_ticks % 65536 : 0
end

def rg_timer_ticking(timer) = timer == @rg_ticking ? 1 : 0

# Reference#accrue_timer, for every running timer: a frame's worth of ticks more, and the game's
# handler once for each whole tick crossed. How many that is is settled before the first of them
# runs, so a handler that stops its own timer, or starts it again, still finishes the ticks this
# frame crossed.
def rg_timers_frame
  @rg_timers_started.each do |number|
    timer = @rg_timers[number]
    next unless timer.running

    before = timer.whole_ticks
    timer.parts += timer.ticks_a_second
    crossed = timer.whole_ticks - before
    @rg_ticking = number
    crossed.times { rg_game_timer_ticks }
    @rg_ticking = -1
  end
end

# --- the cartridge's clock (Reference#value_of_clock) ---

# The windowless driver starts the clock at a moment of the test's: +seconds+ from the start of
# 1970 as such a clock counts them, +ticks+ more of the console's 2^24 a second, and whether the
# clock was ever set. From then it moves on one of the console's frames at each frame boundary.
def rg_clock_starts_at(seconds, ticks, set)
  @rg_clock_present = 1
  @rg_clock_set = set != 0 ? 1 : 0
  @rg_clock_counts_frames = 1
  @rg_clock_seconds = seconds
  @rg_clock_ticks = ticks
end

# The days from the start of 1970 to a date, and back. A calendar of plain arithmetic, so the
# computer's time zone never comes into it: every fourth year a leap year, but not every
# hundredth, but every four hundredth. The year is counted from March, so the leap day falls at
# the end of it, and the counting goes in whole 400-year cycles, which always hold the same
# number of days. Ruby's / rounds down, which is the rounding a moment before 1970 needs.
def rg_days_from_date(year, month, day)
  year -= 1 if month <= 2
  era = year / 400
  year_of_era = year - (era * 400)
  day_of_year = (((153 * (month > 2 ? month - 3 : month + 9)) + 2) / 5) + day - 1
  day_of_era = (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
  (era * 146097) + day_of_era - 719468
end

# [year, month, day]
def rg_date_from_days(days)
  days += 719468
  era = days / 146097
  day_of_era = days - (era * 146097)
  year_of_era = (day_of_era - (day_of_era / 1460) + (day_of_era / 36524) - (day_of_era / 146096)) / 365
  day_of_year = day_of_era - ((365 * year_of_era) + (year_of_era / 4) - (year_of_era / 100))
  from_march = ((5 * day_of_year) + 2) / 153
  day = day_of_year - (((153 * from_march) + 2) / 5) + 1
  month = from_march < 10 ? from_march + 3 : from_march - 9
  [year_of_era + (era * 400) + (month <= 2 ? 1 : 0), month, day]
end

# A window says what the computer's own clock reads instead, before the game starts and as each
# frame boundary hands the game its next frame.
def rg_clock_reads(year, month, day, hour, minute, second)
  @rg_clock_present = 1
  @rg_clock_set = 1
  @rg_clock_counts_frames = 0
  @rg_clock_seconds = (rg_days_from_date(year, month, day) * RG_SECONDS_A_DAY) + (hour * 3600) + (minute * 60) + second
  @rg_clock_ticks = 0
end

# A frame of the console's later.
def rg_clock_frame
  return if @rg_clock_counts_frames == 0

  @rg_clock_ticks += RG_CONSOLE_TICKS_A_FRAME
  @rg_clock_seconds += @rg_clock_ticks / RG_CONSOLE_TICKS_A_SECOND
  @rg_clock_ticks %= RG_CONSOLE_TICKS_A_SECOND
end

def rg_clock_reading(reading, offset_days, offset_seconds)
  return 0 if @rg_clock_present == 0
  return 1 if reading == RG_CLOCK_PRESENT
  return 0 if @rg_clock_set == 0
  return 1 if reading == RG_CLOCK_SET

  now = @rg_clock_seconds + (offset_days * RG_SECONDS_A_DAY) + offset_seconds
  days = now / RG_SECONDS_A_DAY
  into_day = now - (days * RG_SECONDS_A_DAY)
  year, month, day = rg_date_from_days(days)
  case reading
  when RG_CLOCK_HOUR then into_day / 3600
  when RG_CLOCK_MINUTE then (into_day / 60) % 60
  when RG_CLOCK_SECOND then into_day % 60
  when RG_CLOCK_YEAR then year
  when RG_CLOCK_MONTH then month
  when RG_CLOCK_DAY then day
  when RG_CLOCK_WEEKDAY then (days + 4) % 7 # 1 January 1970 was a Thursday
  else rg_fault("the clock has no reading numbered #{reading}")
  end
end

# SETTING THE CLOCK (Reference#exec_set_clock): how far the time set is from the clock's own, to
# the whole second, in days and the seconds left over, kept until the game takes the two parts
# into its saved numbers. The clock itself is never changed, and from then on it reads as set.
def rg_clock_set_to(year, month, day, hour, minute, second)
  return if @rg_clock_present == 0

  today = @rg_clock_seconds / RG_SECONDS_A_DAY
  days = rg_days_from_date(year, month, day) - today
  seconds = (hour * 3600) + (minute * 60) + second - (@rg_clock_seconds - (today * RG_SECONDS_A_DAY))
  if seconds < 0
    seconds += RG_SECONDS_A_DAY
    days -= 1
  end
  @rg_clock_kept_days = rg_i32(days)
  @rg_clock_kept_seconds = rg_i32(seconds)
  @rg_clock_set = 1
end

# The days and the seconds rg_clock_set_to kept — or +current+, the game's own number as it was,
# with no clock to have set.
def rg_clock_kept_days(current) = @rg_clock_present != 0 ? @rg_clock_kept_days : current
def rg_clock_kept_seconds(current) = @rg_clock_present != 0 ? @rg_clock_kept_seconds : current
