# frozen_string_literal: true

module RubyGBA
  module Console
    # THE GAME BOY COLOR'S HARDWARE, NAMED: where its memory is, and the addresses and flags of the
    # registers that drive its picture, its sound, its buttons and its cartridge. Names follow Pan
    # Docs (gbdev.io/pandocs), so anyone who has read it recognises them.
    #
    # Like the Advance, the Game Boy Color has no operating system: everything is an address. Its
    # processor sees 64K of them:
    #
    #   0x0000-0x3FFF  the cartridge's bank 0, always in view
    #   0x4000-0x7FFF  one more bank of the cartridge, whichever the game asks for
    #   0x8000-0x9FFF  video memory: tiles and the grids of them (two banks on a Color)
    #   0xA000-0xBFFF  the cartridge's own memory, battery-backed for saves
    #   0xC000-0xCFFF  work memory, always in view
    #   0xD000-0xDFFF  more work memory, one of seven banks
    #   0xFE00-0xFE9F  the sprite table (OAM): forty sprites, four bytes each
    #   0xFF00-0xFF7F  the hardware's registers
    #   0xFF80-0xFFFE  a little quick memory inside the processor (HRAM)
    #   0xFFFF         which interrupts are switched on
    module GBCHardware
      # --- memory ---
      ROM0 = 0x0000
      ROMX = 0x4000
      VRAM = 0x8000
      SRAM = 0xA000
      WRAM0 = 0xC000
      WRAMX = 0xD000
      OAM = 0xFE00
      HRAM = 0xFF80
      HRAM_END = 0xFFFE

      # How much of each there is.
      VRAM_SIZE = 0x2000
      SRAM_BANK_SIZE = 0x2000
      WRAM_BANK_SIZE = 0x1000
      OAM_SIZE = 0xA0

      # Where the grids of tiles a background shows live: two of them, 32×32 cells each.
      TILE_MAP0 = 0x9800
      TILE_MAP1 = 0x9C00

      # --- the processor's entry points ---

      # Where each interrupt calls: the display's vertical blank, its status (a chosen line, or
      # the start of a line's blank), the timer, the serial port and the buttons.
      VBLANK_VECTOR = 0x40
      STAT_VECTOR = 0x48
      TIMER_VECTOR = 0x50
      SERIAL_VECTOR = 0x58
      JOYPAD_VECTOR = 0x60

      # Where the processor starts, after the console's own start-up program has checked the
      # cartridge.
      ENTRY = 0x100

      # --- the cartridge header (0x0100-0x014F) ---
      LOGO_AT = 0x104
      TITLE_AT = 0x134
      MANUFACTURER_AT = 0x13F
      CGB_FLAG_AT = 0x143
      NEW_LICENSEE_AT = 0x144
      SGB_FLAG_AT = 0x146
      CARTRIDGE_TYPE_AT = 0x147
      ROM_SIZE_AT = 0x148
      RAM_SIZE_AT = 0x149
      DESTINATION_AT = 0x14A
      OLD_LICENSEE_AT = 0x14B
      VERSION_AT = 0x14C
      HEADER_CHECKSUM_AT = 0x14D
      GLOBAL_CHECKSUM_AT = 0x14E
      HEADER_END = 0x150

      # The logo the console's start-up program compares against the cartridge's, byte for byte,
      # and refuses to start a cartridge without.
      LOGO = [0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
              0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
              0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E].freeze

      # 0xC0: the game runs on a Game Boy Color only.
      CGB_ONLY = 0xC0
      # MBC5 with its own memory and a battery to keep it: the controller that switches banks.
      MBC5_RAM_BATTERY = 0x1B
      # 0x33 in the old licensee byte says the new one (two letters) is used.
      USE_NEW_LICENSEE = 0x33

      # --- the memory bank controller (MBC5), written by storing into the cartridge's address range ---
      MBC_RAM_ENABLE = 0x0000 # 0x0A switches the cartridge's memory on, anything else off
      MBC_ROM_BANK_LOW = 0x2000 # the low eight bits of the bank in view at 0x4000
      MBC_ROM_BANK_HIGH = 0x3000 # its ninth bit
      MBC_RAM_BANK = 0x4000 # which 8K of the cartridge's memory is in view at 0xA000
      MBC_RAM_ON = 0x0A

      # --- the clock chip beside an MBC3 (Pan Docs, "MBC3") ---
      #
      # The MBC3 is the controller the console's own games with a clock carried. 0x0A at
      # MBC_RAM_ENABLE switches its clock on for the processor along with the memory, and one of
      # these five numbers at MBC_RAM_BANK puts that register of the clock in view at 0xA000 in
      # place of a bank of memory: the seconds, minutes and hours, and the day count's low eight
      # bits and the high register, which holds its ninth bit, the halt bit that stops the clock
      # counting, and the carry bit the clock sets when the count passes 511 days. The clock counts
      # on all the time; 0 and then 1 at MBC_CLOCK_LATCH copies all five into what the processor
      # reads, so they are read at one moment. A real chip wants a few microseconds between two
      # accesses to it, and its counters written only while it is halted.
      MBC_CLOCK_LATCH = 0x6000
      CLOCK_SECONDS = 0x08
      CLOCK_MINUTES = 0x09
      CLOCK_HOURS = 0x0A
      CLOCK_DAY_LOW = 0x0B
      CLOCK_DAY_HIGH = 0x0C
      CLOCK_DAY_NINTH_BIT = 0x01
      CLOCK_HALT = 0x40
      CLOCK_CARRY = 0x80

      # --- buttons ---
      P1 = 0xFF00 # write 0x20 to read the directions, 0x10 to read the four buttons; 0 means held

      # --- timer and interrupts ---
      DIV = 0xFF04
      TIMA = 0xFF05
      TMA = 0xFF06
      TAC = 0xFF07
      IF = 0xFF0F # which interrupts are waiting
      IE = 0xFFFF # which interrupts are switched on

      INT_VBLANK = 0x01
      INT_STAT = 0x02
      INT_TIMER = 0x04
      INT_SERIAL = 0x08
      INT_JOYPAD = 0x10

      # --- sound ---
      NR10 = 0xFF10 # voice 1 (square, with a sweep): sweep
      NR11 = 0xFF11 #   duty and length
      NR12 = 0xFF12 #   volume and envelope
      NR13 = 0xFF13 #   period, low eight bits
      NR14 = 0xFF14 #   period, high three bits, length on, start
      NR21 = 0xFF16 # voice 2 (square)
      NR22 = 0xFF17
      NR23 = 0xFF18
      NR24 = 0xFF19
      NR30 = 0xFF1A # voice 3 (wave): on
      NR31 = 0xFF1B #   length
      NR32 = 0xFF1C #   volume
      NR33 = 0xFF1D #   period, low
      NR34 = 0xFF1E #   period, high, start
      NR41 = 0xFF20 # voice 4 (noise): length
      NR42 = 0xFF21 #   volume and envelope
      NR43 = 0xFF22 #   the noise's clock
      NR44 = 0xFF23 #   length on, start
      NR50 = 0xFF24 # master volume, left and right
      NR51 = 0xFF25 # which voice goes to which side
      NR52 = 0xFF26 # sound on
      WAVE_RAM = 0xFF30 # the wave voice's 32 steps, two to a byte

      # --- the picture ---
      LCDC = 0xFF40 # the display's switches (below)
      STAT = 0xFF41 # what the display is doing, and which of that raises the status interrupt
      SCY = 0xFF42 # the background's scroll
      SCX = 0xFF43
      LY = 0xFF44 # the line being drawn, 0-153; 144 and up is the vertical blank
      LYC = 0xFF45
      DMA = 0xFF46 # copies 160 bytes into the sprite table from (value × 256)
      WY = 0xFF4A # the window's place
      WX = 0xFF4B
      KEY1 = 0xFF4D # double speed: set bit 0, then STOP, and the processor runs twice as fast
      VBK = 0xFF4F # which bank of video memory is in view
      HDMA1 = 0xFF51 # a copy into video memory: from (high, low)
      HDMA2 = 0xFF52
      HDMA3 = 0xFF53 # to (high, low)
      HDMA4 = 0xFF54
      HDMA5 = 0xFF55 # how many 16-byte blocks less one; bit 7 asks for it a line at a time
      BCPS = 0xFF68 # which background colour BCPD writes, bit 7 to move on after each byte
      BCPD = 0xFF69
      OCPS = 0xFF6A # the same for the sprites' colours
      OCPD = 0xFF6B
      SVBK = 0xFF70 # which bank of work memory is in view at 0xD000

      LCDC_ON = 0x80
      LCDC_WINDOW_MAP1 = 0x40
      LCDC_WINDOW_ON = 0x20
      LCDC_TILES_8000 = 0x10 # the background's tiles numbered from 0x8000, unsigned
      LCDC_BG_MAP1 = 0x08
      LCDC_TALL_SPRITES = 0x04 # sprites 8×16
      LCDC_SPRITES_ON = 0x02
      LCDC_BG_PRIORITY = 0x01 # on a Color: the background and window can be in front of sprites

      # A cell's attributes in bank 1 of video memory, beside its tile number in bank 0.
      ATTR_PALETTE = 0x07
      ATTR_TILE_BANK = 0x08
      ATTR_X_FLIP = 0x20
      ATTR_Y_FLIP = 0x40
      ATTR_IN_FRONT = 0x80

      # A sprite's attributes, its table entry's fourth byte.
      OBJ_PALETTE = 0x07
      OBJ_TILE_BANK = 0x08
      OBJ_X_FLIP = 0x20
      OBJ_Y_FLIP = 0x40
      OBJ_BEHIND = 0x80
      # A sprite's table entry holds its place plus these, so 0 is just off the top and left.
      OBJ_Y_OFFSET = 16
      OBJ_X_OFFSET = 8

      # --- the machine's size ---
      SCREEN_WIDTH = 160
      SCREEN_HEIGHT = 144
      LINES = 154
      SPRITES = 40
      SPRITES_ON_A_LINE = 10
      PALETTES = 8
      PALETTE_COLORS = 4
      MAP_CELLS = 32

      # One frame is 70,224 cycles of the 4,194,304 a second clock (154 lines of 456), about 59.7
      # frames a second — the Advance's rate exactly, since its clock is four times this one and
      # its frame four times as many cycles. Double speed doubles the cycles, not the frames.
      CLOCK_HZ = 4_194_304
      CYCLES_PER_FRAME = 70_224
    end
  end
end
