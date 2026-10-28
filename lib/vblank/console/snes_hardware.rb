# frozen_string_literal: true

module VBlank
  module Console
    # THE SUPER NINTENDO'S HARDWARE, NAMED: where its memory is, and the addresses and flags of the
    # registers that drive its picture, its buttons, its copying engine and its arithmetic units.
    # Names follow the ones every Super Nintendo document uses (fullsnes, the SNESdev wiki), so
    # anyone who has read one recognises them.
    #
    # The processor sees 16 megabytes of addresses, as 256 banks of 64K. A LoROM cartridge and the
    # console share them like this (the same in banks $80-$FF as in $00-$7F, only faster):
    #
    #   $00-$3F:$0000-$1FFF  the first 8K of work RAM, in view from every one of these banks
    #   $00-$3F:$2100-$21FF  the picture chip's registers (the PPU), and the sound chip's ports
    #   $00-$3F:$4200-$43FF  the processor's own: interrupts, arithmetic, the buttons, copying
    #   $00-$7D:$8000-$FFFF  the cartridge, 32K a bank
    #   $70-$7D:$0000-$7FFF  the cartridge's battery-backed RAM, when it has some
    #   $7E-$7F:$0000-$FFFF  all 128K of work RAM
    #
    # Video RAM (64K: the tiles and the maps of them), the colour memory (256 colours) and the
    # sprite table (128 sprites) are not in that view at all. They belong to the picture chip, and
    # are written through its ports, a byte or a word at a time — or, far faster, by the copying
    # engine (DMA), and only while the screen is not being drawn: in the vertical blank, or with
    # the screen switched off ("forced blank").
    module SNESHardware
      # --- memory ---
      WRAM_BANK = 0x7E # all 128K of work RAM starts at $7E:0000
      LOW_WRAM_SIZE = 0x2000 # the part in view from the cartridge's banks
      WRAM_SIZE = 0x20000
      VRAM_SIZE = 0x10000
      SRAM_BANK = 0x70

      # --- the picture chip (PPU) ---
      INIDISP = 0x2100 # bit 7 forced blank (the screen off); bits 0-3 brightness
      OBSEL = 0x2101 # sprite sizes and where their tiles are in video RAM
      OAMADDL = 0x2102
      OAMADDH = 0x2103
      OAMDATA = 0x2104
      BGMODE = 0x2105 # which of the eight background arrangements, and tile sizes
      MOSAIC = 0x2106
      BG1SC = 0x2107 # where each background's map is in video RAM, and how many screens it is
      BG2SC = 0x2108
      BG3SC = 0x2109
      BG4SC = 0x210A
      BG12NBA = 0x210B # where backgrounds 1 and 2 find their tiles
      BG34NBA = 0x210C
      BG1HOFS = 0x210D # each background's scroll, written twice: low byte, then high
      BG1VOFS = 0x210E
      BG2HOFS = 0x210F
      BG2VOFS = 0x2110
      BG3HOFS = 0x2111
      BG3VOFS = 0x2112
      BG4HOFS = 0x2113
      BG4VOFS = 0x2114
      VMAIN = 0x2115 # how the video RAM address moves on after each write
      VMADDL = 0x2116
      VMADDH = 0x2117
      VMDATAL = 0x2118
      VMDATAH = 0x2119
      M7SEL = 0x211A
      M7A = 0x211B
      M7B = 0x211C
      M7C = 0x211D
      M7D = 0x211E
      M7X = 0x211F
      M7Y = 0x2120
      CGADD = 0x2121 # which colour the next write to CGDATA goes to
      CGDATA = 0x2122 # a colour, written twice: low byte, then high
      W12SEL = 0x2123
      W34SEL = 0x2124
      WOBJSEL = 0x2125
      WH0 = 0x2126
      WH1 = 0x2127
      WH2 = 0x2128
      WH3 = 0x2129
      WBGLOG = 0x212A
      WOBJLOG = 0x212B
      TM = 0x212C # which layers are on the main screen
      TS = 0x212D # ...and on the sub screen, which colour maths mixes in
      TMW = 0x212E
      TSW = 0x212F
      CGWSEL = 0x2130 # colour maths: what is added or subtracted
      CGADSUB = 0x2131 # colour maths: which layers, add or subtract, halved or not
      COLDATA = 0x2132 # the fixed colour colour maths can use
      SETINI = 0x2133 # screen height (224 or 239 lines), interlace
      SLHV = 0x2137
      RDOAM = 0x2138
      RDVRAML = 0x2139
      RDVRAMH = 0x213A
      RDCGRAM = 0x213B
      OPHCT = 0x213C
      OPVCT = 0x213D
      STAT77 = 0x213E
      STAT78 = 0x213F

      # The sound processor's four ports (APUIO0-3), the mailboxes between the console and the
      # sound unit.
      APUIO0 = 0x2140
      APUIO1 = 0x2141
      APUIO2 = 0x2142
      APUIO3 = 0x2143

      # Work RAM through a port, for the copying engine.
      WMDATA = 0x2180
      WMADDL = 0x2181

      # --- the processor's own registers ---
      NMITIMEN = 0x4200 # bit 7: the vertical blank's interrupt; bit 0: read the buttons for us
      WRIO = 0x4201
      WRMPYA = 0x4202 # the 8×8 multiplier: write one byte here...
      WRMPYB = 0x4203 # ...and the other here; 16 bits come out at RDMPYL, eight cycles later
      WRDIVL = 0x4204 # the 16÷8 divider: the 16-bit number here...
      WRDIVH = 0x4205
      WRDIVB = 0x4206 # ...divided by this byte; 16 cycles later, quotient at RDDIVL, rest at RDMPYL
      HTIMEL = 0x4207
      HTIMEH = 0x4208
      VTIMEL = 0x4209
      VTIMEH = 0x420A
      MDMAEN = 0x420B # start copying on these channels (a bit each)
      HDMAEN = 0x420C # copy on these channels a line at a time, as the screen is drawn
      MEMSEL = 0x420D # bit 0: read banks $80-$FF of the cartridge at the faster speed
      RDNMI = 0x4210 # reading it says (bit 7) a vertical blank began since it was last read
      TIMEUP = 0x4211
      HVBJOY = 0x4212 # bit 7: in the vertical blank; bit 0: the buttons are still being read
      RDIO = 0x4213
      RDDIVL = 0x4214
      RDDIVH = 0x4215
      RDMPYL = 0x4216
      RDMPYH = 0x4217
      JOY1L = 0x4218 # the first controller's buttons, as the console read them in the blank
      JOY1H = 0x4219

      # The copying engine: eight channels, each sixteen registers from $4300 + $10 × channel.
      DMA_BASE = 0x4300
      DMAP = 0x0 # how it copies: which way, and how the port address moves (DMA_TO_ONE_PORT...)
      BBAD = 0x1 # the picture chip's port it copies to or from ($21xx, the low byte)
      A1TL = 0x2 # where in the processor's memory, 24 bits
      A1TH = 0x3
      A1B = 0x4
      DASL = 0x5 # how many bytes (0 means 65536)
      DASH = 0x6

      # DMAP's ways of copying: to one port each byte, to two ports by turns (VMDATAL and VMDATAH),
      # to one port written twice in a row (CGDATA, OAMDATA); and the source left where it is
      # (a fill from one byte) rather than moving on.
      DMA_TO_ONE_PORT = 0x00
      DMA_TO_TWO_PORTS = 0x01
      DMA_TO_ONE_PORT_TWICE = 0x02
      DMA_FIXED_SOURCE = 0x08

      # --- flags ---
      FORCED_BLANK = 0x80
      FULL_BRIGHTNESS = 0x0F
      NMI_ON = 0x80
      AUTO_JOYPAD = 0x01
      VMAIN_WORD = 0x80 # move on after the high byte (VMDATAH) is written, by one word

      # The buttons as JOY1L/JOY1H read them, a bit each in the 16-bit word.
      JOYPAD_BITS = { b: 15, y: 14, select: 13, start: 12, up: 11, down: 10, left: 9, right: 8,
                      a: 7, x: 6, l: 5, r: 4 }.freeze

      # --- where the processor goes (each a 16-bit address in bank $00) ---
      NATIVE_COP_VECTOR = 0xFFE4
      NATIVE_BRK_VECTOR = 0xFFE6
      NATIVE_ABORT_VECTOR = 0xFFE8
      NATIVE_NMI_VECTOR = 0xFFEA
      NATIVE_IRQ_VECTOR = 0xFFEE
      EMULATION_COP_VECTOR = 0xFFF4
      EMULATION_ABORT_VECTOR = 0xFFF8
      EMULATION_NMI_VECTOR = 0xFFFA
      RESET_VECTOR = 0xFFFC
      EMULATION_IRQ_VECTOR = 0xFFFE

      # --- the cartridge header, at $FFC0 of the first bank (offset $7FC0 of a LoROM file) ---
      HEADER_AT = 0x7FC0
      TITLE_AT = 0x7FC0
      TITLE_LENGTH = 21
      MAP_MODE_AT = 0x7FD5
      CARTRIDGE_TYPE_AT = 0x7FD6
      ROM_SIZE_AT = 0x7FD7
      RAM_SIZE_AT = 0x7FD8
      DESTINATION_AT = 0x7FD9
      MAKER_AT = 0x7FDA
      VERSION_AT = 0x7FDB
      COMPLEMENT_AT = 0x7FDC
      CHECKSUM_AT = 0x7FDE
      VECTORS_AT = 0x7FE0

      # The map mode: LoROM ($20), read at the faster speed ($10).
      LOROM_FAST = 0x30
      # The cartridge type: ROM alone, or ROM with battery-backed RAM.
      ROM_ONLY = 0x00
      ROM_RAM_BATTERY = 0x02
      # Destination: North America, whose consoles draw sixty frames a second (NTSC).
      NORTH_AMERICA = 0x01

      # --- the extended header, the 16 bytes before the header ---
      #
      # A cartridge whose maker byte (MAKER_AT) is $33 has 16 more bytes just before the header: a
      # maker code and a game code in letters, and the size of any RAM a chip on the board has of its
      # own (its "expansion RAM", 2^n kilobytes). Emulators and flash carts read that size to give the
      # chip its RAM; the console itself reads none of it. (fullsnes, "SNES Cartridge ROM Header";
      # bsnes, heuristics/super-famicom.cpp, expansionRamSize.)
      EXTENDED_HEADER = 0x33
      MAKER_CODE_AT = 0x7FB0
      GAME_CODE_AT = 0x7FB2
      EXPANSION_RAM_AT = 0x7FBD

      # LoROM read at the slow speed: a board whose ROM cannot keep up with the faster one.
      LOROM_SLOW = 0x20
      # The cartridge type of a board with a Super FX: its high four bits $1, its low ones "ROM, the
      # chip and its RAM" ($4), or that RAM kept by a battery ($5). (fullsnes, "SNES Cartridge ROM
      # Header"; bsnes, heuristics/super-famicom.cpp, board.)
      SUPER_FX_RAM = 0x14
      SUPER_FX_RAM_BATTERY = 0x15

      # --- the Super FX's registers, which the console sees at $3000-$32FF of banks $00-$3F ---
      #
      # (fullsnes, "SNES Cart GSU-n I/O Map"; bsnes, sfc/coprocessor/superfx/io.cpp.)
      GSU_R0 = 0x3000      # its sixteen 16-bit registers, R0 to R15, two bytes each, low byte first.
      GSU_R15 = 0x301E     # R15 is its program counter: writing the high byte ($301F) starts it.
      GSU_SFR = 0x3030     # its status: bit 5 (GO) is set while it runs and cleared when it stops.
      GSU_SFR_HIGH = 0x3031 # reading it clears the chip's interrupt.
      GSU_PBR = 0x3034     # the bank its program is read from.
      GSU_CFGR = 0x3037    # bit 7 set: the chip does not interrupt the console when it stops.
      GSU_SCBR = 0x3038    # where in its RAM the picture it plots starts, in kilobytes.
      GSU_CLSR = 0x3039    # bit 0 set: run at 21 MHz rather than 10.7.
      GSU_SCMR = 0x303A    # which of the cartridge's ROM (bit 4) and RAM (bit 3) it may use, and how
                           # the picture it plots is laid out (its colours and height).
      GSU_VCR = 0x303B     # the chip's version, read only.
      GSU_GO = 0x20
      GSU_IRQ_OFF = 0x80
      GSU_FAST_CLOCK = 0x01
      GSU_OWNS_ROM = 0x10
      GSU_OWNS_RAM = 0x08
      # Where the console sees the chip's RAM: bank $70.
      GSU_RAM_BANK = 0x70
    end
  end
end
