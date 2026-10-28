# frozen_string_literal: true

require "fiddle"
require "fileutils"
require "tmpdir"

module RubySNESEmulator
  # ONE SUPER NINTENDO, PLAYED A FRAME AT A TIME with nobody watching: a cartridge loaded into
  # bsnes (a libretro core, see CoreLibrary), its buttons set from Ruby, and everything a test
  # wants to read back handed over as plain bytes — the picture of the last frame, the work RAM,
  # the video RAM, the colour memory, the sprite table, the processor's registers and the
  # cartridge's battery-backed RAM.
  #
  #   core = RubySNESEmulator::Core.new("game.sfc")
  #   core.set_buttons(%i[right])
  #   core.run_frame
  #   core.wram_read8(0x0100)
  #   core.destroy
  #
  # A LIBRETRO CORE IS ONE CONSOLE PER LIBRARY: it keeps the whole machine in the library's own
  # globals. So each Core loads a copy of the library of its own, from a folder of its own, and
  # two Cores in one process are two consoles that cannot see each other. The copy is loaded
  # with its names kept to itself (no RTLD_GLOBAL), or the second copy's code would call into
  # the first's.
  #
  # The core talks back through functions it is handed (the libretro callbacks): it asks its
  # settings through the environment callback, hands over each finished picture and each batch
  # of sound, and asks which buttons are down. Those are Ruby blocks wrapped as C functions
  # (Fiddle closures), kept alive here for as long as the core is.
  class Core
    # libretro's names for the memories, and the probe patch's own (core/bsnes-vblank-probe.patch).
    SAVE_RAM = 0
    SYSTEM_RAM = 2
    VIDEO_RAM = 3
    CGRAM = 0x8001
    OAM = 0x8002
    REGISTERS = 0x8003

    # libretro's joypad: the number it asks about each button by.
    BUTTONS = { b: 0, y: 1, select: 2, start: 3, up: 4, down: 5, left: 6, right: 7,
                a: 8, x: 9, l: 10, r: 11 }.freeze

    # The settings the core asks for, as libretro names them. The PPU and the sound DSP are the
    # accurate ones — the fast PPU keeps its memories elsewhere, and the probe reads the accurate
    # one's — and nothing is run ahead.
    SETTINGS = { "bsnes_ppu_fast" => "OFF", "bsnes_dsp_fast" => "OFF", "bsnes_run_ahead_frames" => "OFF",
                 "bsnes_ppu_show_overscan" => "OFF", "bsnes_cpu_fastmath" => "OFF",
                 "bsnes_hotfixes" => "OFF", "bsnes_entropy" => "None" }.freeze

    # libretro's environment calls that matter here.
    GET_CAN_DUPE = 3
    GET_SYSTEM_DIRECTORY = 9
    SET_PIXEL_FORMAT = 10
    GET_VARIABLE = 15
    GET_VARIABLE_UPDATE = 17
    GET_SAVE_DIRECTORY = 31
    XRGB8888 = 1

    JOYPAD = 1

    # The console's picture: 256 pixels across and 224 lines down, the lines a television showed
    # of a game that does not ask for the taller 239.
    WIDTH = 256
    HEIGHT = 224

    attr_reader :frames, :drawn_width, :drawn_height

    # +rom_path+ is the cartridge; its battery-backed RAM is kept in a .srm file in +save_dir+,
    # read when the cartridge is loaded and written when the core is destroyed. Without
    # +save_dir+ the file goes in a folder of the core's own that is gone with it.
    def initialize(rom_path, save_dir: nil)
      @dir = Dir.mktmpdir("ruby-snes-emulator")
      @save_dir = save_dir || @dir
      @buttons = Array.new(2) { [] }
      @frames = 0
      @picture = nil
      @drawn_width = WIDTH * 2
      @drawn_height = HEIGHT * 2
      @audio = []
      @kept = [] # what the core holds a pointer to, kept from the garbage collector
      load_library
      hand_over_callbacks
      @call[:retro_init].call
      load_cartridge(rom_path)
    end

    # The buttons down on controller +port+ (0 for the first), by name (BUTTONS).
    def set_buttons(buttons, port: 0)
      unknown = buttons - BUTTONS.keys
      raise ArgumentError, "a Super Nintendo controller has no #{unknown.join(', ')} button" unless unknown.empty?

      @buttons[port] = buttons.map { |button| BUTTONS.fetch(button) }
    end

    # Plays one frame: up to the moment the console starts its next picture.
    def run_frame
      @call[:retro_run].call
      @frames += 1
      self
    end

    # The last frame's picture as bsnes drew it: drawn_width × drawn_height pixels, four bytes
    # each — blue, green, red and one unused — row by row. The accurate PPU always draws a frame
    # twice the console's size each way, so that its high-resolution and interlaced modes fit;
    # a game in neither has each of its pixels drawn as a square of four.
    def video_buffer = @picture || ("\0".b * (@drawn_width * @drawn_height * 4))

    # The last frame's picture as the console's own colours, at the console's own size (#width
    # × #height): a 15-bit number for each pixel, red in the low five bits, then green, then blue,
    # as the colour memory keeps them. Of each square of four bsnes drew, the top-left is taken.
    def width = WIDTH
    def height = HEIGHT

    def colors
      across = @drawn_width / WIDTH
      down = @drawn_height / HEIGHT
      words = video_buffer.unpack("V*")
      Array.new(WIDTH * HEIGHT) do |i|
        y, x = i.divmod(WIDTH)
        pixel = words[(y * down * @drawn_width) + (x * across)]
        ((pixel >> 19) & 0x1F) | (((pixel >> 11) & 0x1F) << 5) | (((pixel >> 3) & 0x1F) << 10)
      end
    end

    # The sound of the frames since this was last asked, as signed 16-bit samples, left and right
    # by turns, at 48000 samples a second for each side.
    def take_audio
      samples = @audio.join.unpack("s<*")
      @audio.clear
      samples
    end

    # --- the memories ---

    def wram = memory(SYSTEM_RAM)
    def vram = memory(VIDEO_RAM)
    def cgram = memory(CGRAM)
    def oam = memory(OAM)
    def save_ram = memory(SAVE_RAM)

    # The 65816's registers: pc (bank and address, 24 bits), a, x, y, s, d, db, p, and whether
    # it is in emulation mode.
    def registers
      bytes = memory(REGISTERS)
      pc = bytes.getbyte(0) | (bytes.getbyte(1) << 8) | (bytes.getbyte(2) << 16)
      a, x, y, s, d = bytes.byteslice(3, 10).unpack("v5")
      { pc: pc, a: a, x: x, y: y, s: s, d: d, db: bytes.getbyte(13), p: bytes.getbyte(14), e: bytes.getbyte(15) == 1 }
    end

    # Work RAM read and written in place, at +address+ from 0 to 0x1FFFF (bank $7E's first byte
    # is 0, bank $7F's is 0x10000), lowest byte first as the console keeps a number.
    def wram_read8(address) = live(SYSTEM_RAM, 0x20000)[address & 0x1FFFF, 1].getbyte(0)
    def wram_read16(address) = wram_bytes(address, 2).unpack1("v")
    def wram_read32(address) = wram_bytes(address, 4).unpack1("V")
    def wram_bytes(address, count) = live(SYSTEM_RAM, 0x20000)[address & 0x1FFFF, count]
    def wram_write8(address, value) = (live(SYSTEM_RAM, 0x20000)[address & 0x1FFFF, 1] = [value & 0xFF].pack("C"))
    def wram_write32(address, value) = (live(SYSTEM_RAM, 0x20000)[address & 0x1FFFF, 4] = [value & 0xFFFFFFFF].pack("V"))

    # The cartridge's battery-backed RAM, written over (for a save that starts with something in it).
    def save_ram=(bytes)
      size = @call[:retro_get_memory_size].call(SAVE_RAM)
      raise ArgumentError, "this cartridge has no battery-backed RAM" if size.zero?

      live(SAVE_RAM, size)[0, [bytes.bytesize, size].min] = bytes.byteslice(0, size)
    end

    # Unloads the cartridge (writing its .srm), shuts the core and lets go of its library.
    def destroy
      return unless @call

      @call[:retro_unload_game].call
      @call[:retro_deinit].call
      @handle.close
      @call = nil
      FileUtils.rm_rf(@dir)
    end

    private

    def memory(id)
      size = @call[:retro_get_memory_size].call(id)
      return "".b if size.zero?

      Fiddle::Pointer.new(@call[:retro_get_memory_data].call(id).to_i)[0, size]
    end

    def live(id, size) = Fiddle::Pointer.new(@call[:retro_get_memory_data].call(id).to_i, size)

    FUNCTIONS = {
      retro_set_environment: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_video_refresh: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_audio_sample: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_audio_sample_batch: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_input_poll: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_set_input_state: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID],
      retro_init: [[], Fiddle::TYPE_VOID],
      retro_deinit: [[], Fiddle::TYPE_VOID],
      retro_load_game: [[Fiddle::TYPE_VOIDP], Fiddle::TYPE_BOOL],
      retro_unload_game: [[], Fiddle::TYPE_VOID],
      retro_run: [[], Fiddle::TYPE_VOID],
      retro_set_controller_port_device: [[Fiddle::TYPE_UINT, Fiddle::TYPE_UINT], Fiddle::TYPE_VOID],
      retro_get_memory_data: [[Fiddle::TYPE_UINT], Fiddle::TYPE_VOIDP],
      retro_get_memory_size: [[Fiddle::TYPE_UINT], Fiddle::TYPE_SIZE_T]
    }.freeze

    # WHERE THE CORE CALLS BACK FROM. bsnes runs each of the console's chips as a cothread, on a
    # stack of its own, and Ruby must never run on one of those: its garbage collector scans the
    # stack it believes the thread is on. The probe patch makes the core ask for the buttons, and
    # hand over the sound and the picture, only from the stack retro_run was called on.
    def load_library
      copy = File.join(@dir, "core.so")
      FileUtils.cp(CoreLibrary.path, copy)
      @handle = Fiddle::Handle.new(copy, Fiddle::Handle::RTLD_NOW)
      @call = FUNCTIONS.to_h do |name, (args, result)|
        [name, Fiddle::Function.new(@handle[name.to_s], args, result)]
      end
      refuse_unpatched_core!
    end

    def refuse_unpatched_core!
      return if @call[:retro_get_memory_size].call(REGISTERS) == 16

      raise LoadError, "#{CoreLibrary.path} is a bsnes core built without this gem's probe patch, so it cannot hand " \
                       "over the console's memories. Build it with `rake compile_core` in ruby-snes-emulator/."
    end

    def hand_over_callbacks
      @callbacks = {
        retro_set_environment: closure(Fiddle::TYPE_BOOL, [Fiddle::TYPE_UINT, Fiddle::TYPE_VOIDP]) { |cmd, data| environment(cmd, data) },
        retro_set_video_refresh: closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_UINT, Fiddle::TYPE_UINT,
                                                             Fiddle::TYPE_SIZE_T]) { |*args| take_picture(*args) },
        retro_set_audio_sample: closure(Fiddle::TYPE_VOID, [Fiddle::TYPE_INT16_T, Fiddle::TYPE_INT16_T]) do |left, right|
          @audio << [left, right].pack("s<2")
        end,
        retro_set_audio_sample_batch: closure(Fiddle::TYPE_SIZE_T, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T]) do |data, frames|
          @audio << Fiddle::Pointer.new(data.to_i)[0, frames * 4]
          frames
        end,
        retro_set_input_poll: closure(Fiddle::TYPE_VOID, []) { nil },
        retro_set_input_state: closure(Fiddle::TYPE_INT16_T, [Fiddle::TYPE_UINT, Fiddle::TYPE_UINT, Fiddle::TYPE_UINT,
                                                              Fiddle::TYPE_UINT]) do |port, device, _index, id|
          device == JOYPAD && @buttons.fetch(port, []).include?(id) ? 1 : 0
        end
      }
      @callbacks.each { |setter, callback| @call.fetch(setter).call(callback) }
    end

    def closure(result, args, &block) = Fiddle::Closure::BlockCaller.new(result, args, &block)

    # What the core asks of its frontend. Anything not answered here is answered "no", which a
    # core takes as the frontend not having it.
    def environment(cmd, data)
      case cmd & 0xFFFF
      when GET_CAN_DUPE then write_bool(data, true)
      when SET_PIXEL_FORMAT then Fiddle::Pointer.new(data.to_i)[0, 4].unpack1("l<") == XRGB8888
      when GET_SYSTEM_DIRECTORY then write_pointer(data, kept_string(@dir))
      when GET_SAVE_DIRECTORY then write_pointer(data, kept_string(@save_dir))
      when GET_VARIABLE then answer_setting(data)
      when GET_VARIABLE_UPDATE then write_bool(data, false)
      else false
      end
    rescue StandardError
      false
    end

    def answer_setting(data)
      struct = Fiddle::Pointer.new(data.to_i, 16)
      key = Fiddle::Pointer.new(struct[0, 8].unpack1("J")).to_s
      value = SETTINGS[key] or return false

      struct[8, 8] = [kept_string(value).to_i].pack("J")
      true
    end

    def write_bool(data, value)
      Fiddle::Pointer.new(data.to_i, 1)[0, 1] = value ? "\1" : "\0"
      true
    end

    def write_pointer(data, pointer)
      Fiddle::Pointer.new(data.to_i, 8)[0, 8] = [pointer.to_i].pack("J")
      true
    end

    # A C string the core may hold on to for as long as this core lives.
    def kept_string(text) = kept_bytes("#{text}\0".b)

    # +bytes+ copied into memory of their own that does not move, kept as long as the core lives.
    def kept_bytes(bytes)
      pointer = Fiddle::Pointer.malloc([bytes.bytesize, 1].max, Fiddle::RUBY_FREE)
      pointer[0, bytes.bytesize] = bytes
      @kept << pointer
      pointer
    end

    # A picture handed over at the end of a frame. A null one is the last frame again.
    def take_picture(data, width, height, pitch)
      return if data.null?

      @drawn_width = width
      @drawn_height = height
      rows = Fiddle::Pointer.new(data.to_i)[0, pitch * height]
      @picture = pitch == width * 4 ? rows : (0...height).map { |y| rows.byteslice(y * pitch, width * 4) }.join
    end

    # libretro's retro_game_info: the path, the bytes and their count, and nothing for meta.
    def load_cartridge(rom_path)
      bytes = File.binread(rom_path)
      path = kept_string(File.expand_path(rom_path))
      data = kept_bytes(bytes)
      info = kept_bytes([path.to_i, data.to_i, bytes.bytesize, 0].pack("J4"))
      raise ArgumentError, "bsnes would not load #{rom_path}" unless @call[:retro_load_game].call(info)

      @call[:retro_set_controller_port_device].call(0, JOYPAD)
    end
  end
end
