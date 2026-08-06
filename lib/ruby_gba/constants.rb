# frozen_string_literal: true

require_relative "ir/screen"

module RubyGBA
  # GBA hardware constants. Names follow the tonc/libgba conventions
  # so anyone familiar with GBA development recognizes them immediately.
  #
  # The GBA memory map is flat — everything is accessed by address.
  # There's no OS, no filesystem, just raw memory-mapped hardware.
  #
  # Reference: https://problemkaputt.de/gbatek.htm
  module Constants

    # ========================================================================
    # Memory Map
    #
    # The GBA CPU (ARM7TDMI) sees all hardware as memory addresses.
    # Each region has a fixed start address and size.
    # ========================================================================

    # External Work RAM — general purpose heap, large buffers.
    # 256KB, 16-bit bus (slower than IWRAM).
    EWRAM_START = 0x02000000
    EWRAM_SIZE  = 0x00040000  # 256KB

    # Internal Work RAM — stack, hot code, interrupt handlers.
    # 32KB, 32-bit bus (fastest RAM on the system).
    IWRAM_START = 0x03000000
    IWRAM_SIZE  = 0x00008000  # 32KB

    # I/O Registers — control everything: display, sound, DMA, timers, input.
    # Write to these addresses to configure hardware behavior.
    IO_START    = 0x04000000

    # Palette RAM — stores colors for backgrounds and sprites.
    # First 256 entries (512 bytes) = BG palette.
    # Next 256 entries (512 bytes) = OBJ/sprite palette.
    # Each entry is a 15-bit RGB color (5 bits per channel).
    PALETTE_START = 0x05000000
    PALETTE_SIZE  = 0x00000400  # 1KB (512 colors total)
    BG_PALETTE    = 0x05000000
    OBJ_PALETTE   = 0x05000200

    # Video RAM — tile data, tilemaps, or bitmap framebuffers.
    # Layout depends on which display mode you're using.
    VRAM_START  = 0x06000000
    VRAM_SIZE   = 0x00018000  # 96KB

    # Object Attribute Memory — defines up to 128 on-screen sprites.
    # Each sprite entry is 8 bytes (position, size, tile index, etc).
    OAM_START   = 0x07000000
    OAM_SIZE    = 0x00000400  # 1KB (128 sprites x 8 bytes)
    MAX_SPRITES = 128

    # Game Pak ROM — this is the .gba file, mapped into memory.
    # Maximum 32MB. Read-only at runtime.
    ROM_START   = 0x08000000
    ROM_MAX_SIZE = 0x02000000  # 32MB

    # Game Pak SRAM — battery-backed save memory.
    # Size varies by cartridge (typically 32KB or 64KB).
    SRAM_START  = 0x0E000000

    # ========================================================================
    # Game Pak wait-state control (REG_WAITCNT at 0x04000204)
    #
    # The cartridge (ROM) is slow memory. Every time the CPU fetches an instruction
    # or reads data from the .gba, it stalls a few cycles waiting for the ROM chip —
    # "wait states". At power-on the console picks the SLOWEST, safest timing (so any
    # cartridge works), which makes code that runs from ROM crawl.
    #
    # Real cartridges are faster than that worst case, so a game writes this register
    # once at boot to choose quicker timing AND switch on the "prefetch buffer" — a
    # small unit that reads upcoming instructions from ROM ahead of time, while the
    # CPU is busy elsewhere, so they're already there when it needs them. Together
    # this makes ROM-resident code run roughly 2–3x faster. The framework does it for
    # every ROM (see the GBA backend's emit_waitcnt_setup).
    # ========================================================================
    REG_WAITCNT   = 0x04000204
    # WS0 (the main ROM region) at 3/1 wait states, with the prefetch buffer on — the
    # standard "fast but safe" setting every real cartridge handles.
    WAITCNT_FAST  = 0x4317

    # ========================================================================
    # Display Control (REG_DISPCNT at 0x04000000)
    #
    # This single register controls what the screen shows.
    # Combine a mode with enable flags: MODE_3 | BG2_ENABLE
    # ========================================================================

    REG_DISPCNT  = 0x04000000
    REG_DISPSTAT = 0x04000004  # VBlank/HBlank status and IRQ config
    REG_VCOUNT   = 0x04000006  # Current scanline being drawn (0-227)

    # Display modes — choose one per scene:
    MODE_0 = 0x0000  # Tile mode: 4 regular BG layers (most common for RPGs, platformers)
    MODE_1 = 0x0001  # Tile mode: 2 regular + 1 affine (rotatable) BG
    MODE_2 = 0x0002  # Tile mode: 2 affine BG layers
    MODE_3 = 0x0003  # Bitmap: 240x160, 15-bit color, single buffer (simple but slow)
    MODE_4 = 0x0004  # Bitmap: 240x160, 8-bit indexed, double buffered
    MODE_5 = 0x0005  # Bitmap: 160x128, 15-bit color, double buffered

    # Layer enable flags — OR these with the mode:
    BG0_ENABLE      = 0x0100
    BG1_ENABLE      = 0x0200
    BG2_ENABLE      = 0x0400
    BG3_ENABLE      = 0x0800
    OBJ_ENABLE      = 0x1000  # Enable sprites

    # How a sprite's tiles are arranged in memory. With 1D mapping a multi-tile
    # sprite's tiles sit one after another (the simple layout); without it they're
    # spread across a 2D grid. We always use 1D so packing a sprite's tiles is just
    # "write them in order".
    OBJ_1D_MAP      = 0x0040  # DISPCNT bit 6: 1D object tile mapping
    WIN0_ENABLE     = 0x2000  # Enable window 0 (rectangular clipping region)
    WIN1_ENABLE     = 0x4000  # Enable window 1
    OBJ_WIN_ENABLE  = 0x8000  # Enable object window (sprite-shaped clipping)

    # ========================================================================
    # Background Registers
    #
    # Each BG layer has a control register and scroll registers.
    # BG2/BG3 also have affine (rotation/scale) parameters.
    # ========================================================================

    REG_BG0CNT  = 0x04000008  # BG0 control (priority, tile base, map base, size)
    REG_BG1CNT  = 0x0400000A
    REG_BG2CNT  = 0x0400000C
    REG_BG3CNT  = 0x0400000E

    # Scroll offsets — write every frame to scroll the background
    REG_BG0HOFS = 0x04000010  # BG0 horizontal scroll (0-511)
    REG_BG0VOFS = 0x04000012  # BG0 vertical scroll (0-511)
    REG_BG1HOFS = 0x04000014
    REG_BG1VOFS = 0x04000016
    REG_BG2HOFS = 0x04000018
    REG_BG2VOFS = 0x0400001A
    REG_BG3HOFS = 0x0400001C
    REG_BG3VOFS = 0x0400001E

    # Affine parameters for BG2 — 2x2 rotation/scale matrix + reference point.
    # PA/PB/PC/PD are 8.8 fixed-point. X/Y are 20.8 fixed-point.
    REG_BG2PA = 0x04000020  # cos(angle) * scale_x
    REG_BG2PB = 0x04000022  # sin(angle) * scale_x
    REG_BG2PC = 0x04000024  # -sin(angle) * scale_y
    REG_BG2PD = 0x04000026  # cos(angle) * scale_y
    REG_BG2X  = 0x04000028  # Reference point X (28-bit, 20.8 fixed)
    REG_BG2Y  = 0x0400002C  # Reference point Y

    # Same for BG3
    REG_BG3PA = 0x04000030
    REG_BG3PB = 0x04000032
    REG_BG3PC = 0x04000034
    REG_BG3PD = 0x04000036
    REG_BG3X  = 0x04000038
    REG_BG3Y  = 0x0400003C

    # ========================================================================
    # Window Registers — rectangular clipping regions
    # ========================================================================

    REG_WIN0H   = 0x04000040  # Window 0 horizontal bounds (left, right)
    REG_WIN1H   = 0x04000042
    REG_WIN0V   = 0x04000044  # Window 0 vertical bounds (top, bottom)
    REG_WIN1V   = 0x04000046
    REG_WININ   = 0x04000048  # Which layers show inside windows
    REG_WINOUT  = 0x0400004A  # Which layers show outside windows

    # ========================================================================
    # Blend Registers — fading the whole screen toward black or white
    #
    # The console can blend every layer toward white ("brightness increase") or
    # toward black ("brightness decrease") as it draws, which costs nothing and
    # redraws nothing — a fade is two register writes, whatever is on screen.
    #
    # BLDCNT says WHICH layers the effect applies to (the low six bits) and WHICH
    # effect (bits 6-7). BLDY says HOW FAR, from 0 (untouched) to 16 (fully white
    # or fully black); values above 16 act as 16.
    # ========================================================================

    REG_BLDCNT   = 0x04000050 # what to blend, and how
    REG_BLDALPHA = 0x04000052 # the two weights, for the alpha-blend effect only
    REG_BLDY     = 0x04000054 # how far toward white/black (0-16)

    # Which layers the blend applies to. All of them, plus the backdrop, so a fade
    # covers the whole screen and doesn't leave the backdrop showing through at
    # full strength.
    BLD_ALL_LAYERS = 0x003F # BG0 | BG1 | BG2 | BG3 | OBJ | backdrop

    # The effect, in bits 6-7 of BLDCNT.
    BLD_OFF      = 0x0000
    BLD_ALPHA    = 0x0040 # blend two layers together
    BLD_BRIGHTEN = 0x0080 # toward white
    BLD_DARKEN   = 0x00C0 # toward black

    BLD_MAX = 16 # BLDY's full-strength value

    # ========================================================================
    # Key Input — reading the buttons
    #
    # REG_KEYINPUT is active-low: bit=0 means pressed, bit=1 means released.
    # Common pattern: pressed = ~REG_KEYINPUT & KEY_MASK
    # ========================================================================

    REG_KEYINPUT = 0x04000130
    REG_KEYCNT   = 0x04000132  # Key interrupt control

    KEY_A      = 0x0001
    KEY_B      = 0x0002
    KEY_SELECT = 0x0004
    KEY_START  = 0x0008
    KEY_RIGHT  = 0x0010
    KEY_LEFT   = 0x0020
    KEY_UP     = 0x0040
    KEY_DOWN   = 0x0080
    KEY_R      = 0x0100
    KEY_L      = 0x0200

    # ========================================================================
    # Interrupts
    #
    # The GBA uses interrupts for VBlank timing, HBlank effects,
    # timer events, DMA completion, etc.
    # ========================================================================

    REG_IE  = 0x04000200  # Interrupt enable (which IRQs to listen for)
    REG_IF  = 0x04000202  # Interrupt flags (which IRQs have fired; write a 1 bit to clear it)
    REG_IME = 0x04000208  # Master enable (global on/off switch)

    # Two well-known spots the BIOS reads, both living in the top of Internal Work RAM
    # (mirrored, so the same bytes also answer to 0x03FFFFFC / 0x03FFFFF8):
    REG_INTR_VECTOR = 0x03007FFC # the BIOS jumps here on every IRQ — we store our handler's address
    REG_IFBIOS      = 0x03007FF8 # the BIOS's own copy of "which IRQs fired"; IntrWait/VBlankIntrWait
    #                              wait on it, so a handler must OR the acknowledged bit in here too
    DISPSTAT_VBLANK_IRQ = 0x0008 # REG_DISPSTAT bit 3: have the display raise a VBlank interrupt each frame

    IRQ_VBLANK  = 0x0001  # Fires once per frame (~60Hz) — primary game tick
    IRQ_HBLANK  = 0x0002  # Fires once per scanline — for raster effects
    IRQ_VCOUNT  = 0x0004  # Fires at a specific scanline number
    IRQ_TIMER0  = 0x0008
    IRQ_TIMER1  = 0x0010
    IRQ_TIMER2  = 0x0020
    IRQ_TIMER3  = 0x0040
    IRQ_SERIAL  = 0x0080  # SIO / link cable transfer complete
    IRQ_DMA0    = 0x0100
    IRQ_DMA1    = 0x0200
    IRQ_DMA2    = 0x0400
    IRQ_DMA3    = 0x0800
    IRQ_KEYPAD  = 0x1000  # Button press interrupt

    # ========================================================================
    # Timers — 4 hardware timers, each with a counter and control register
    # ========================================================================

    REG_TM0CNT_L = 0x04000100  # Timer 0 counter (read: current value, write: reload value)
    REG_TM0CNT_H = 0x04000102  # Timer 0 control (prescaler, IRQ, enable)
    REG_TM1CNT_L = 0x04000104
    REG_TM1CNT_H = 0x04000106
    REG_TM2CNT_L = 0x04000108
    REG_TM2CNT_H = 0x0400010A
    REG_TM3CNT_L = 0x0400010C
    REG_TM3CNT_H = 0x0400010E

    TIMER_ENABLE  = 0x0080
    TIMER_IRQ     = 0x0040
    TIMER_CASCADE = 0x0004  # Count when the previous timer overflows

    # ========================================================================
    # DMA — 4 channels for fast memory-to-memory copies
    #
    # DMA3 is general purpose (ROM→RAM, RAM→RAM).
    # DMA1/DMA2 are used for audio streaming.
    # DMA0 has highest priority.
    # ========================================================================

    REG_DMA0SAD = 0x040000B0  # Source address
    REG_DMA0DAD = 0x040000B4  # Destination address
    REG_DMA0CNT = 0x040000B8  # Word count + control flags
    REG_DMA1SAD = 0x040000BC
    REG_DMA1DAD = 0x040000C0
    REG_DMA1CNT = 0x040000C4
    REG_DMA2SAD = 0x040000C8
    REG_DMA2DAD = 0x040000CC
    REG_DMA2CNT = 0x040000D0
    REG_DMA3SAD = 0x040000D4  # Most commonly used channel
    REG_DMA3DAD = 0x040000D8
    REG_DMA3CNT = 0x040000DC

    DMA_ENABLE     = 0x80000000
    DMA_IRQ        = 0x40000000  # Fire interrupt on completion
    DMA_32BIT      = 0x04000000  # Transfer 32 bits at a time (vs 16)
    DMA_16BIT      = 0x00000000
    DMA_AT_VBLANK  = 0x10000000  # Start transfer at next VBlank
    DMA_AT_HBLANK  = 0x20000000  # Start transfer at next HBlank
    DMA_SRC_FIXED  = 0x01000000  # Keep re-reading the same source word (for fills)
    DMA_REPEAT     = 0x02000000  # Re-arm after each transfer (so a sound FIFO feed runs continuously)
    DMA_DEST_FIXED = 0x00400000  # Keep writing the same destination word (the sound FIFO register)
    DMA_SPECIAL    = 0x30000000  # Start timing "special": for DMA1/2, transfer on a sound FIFO request

    # ========================================================================
    # Sound — PSG channels + Direct Sound control
    #
    # The GBA has 4 PSG (programmable sound generator) channels inherited
    # from the Game Boy, plus 2 DMA-driven PCM channels (Direct Sound A/B).
    #
    # Channel 1: Square wave with frequency sweep
    # Channel 2: Square wave (no sweep) — simplest for beeps/chirps
    # Channel 3: Programmable waveform
    # Channel 4: Noise
    # ========================================================================

    # Master control
    REG_SOUNDCNT_L = 0x04000080  # PSG channel volume and L/R panning
    REG_SOUNDCNT_H = 0x04000082  # Direct Sound (DMA audio) control
    REG_SOUNDCNT_X = 0x04000084  # Master sound enable (bit 7)
    SOUND_MASTER_ENABLE = 0x0080 # SOUNDCNT_X bit 7: power the sound hardware on

    # Direct Sound — two DMA-driven PCM channels (A and B) for playing recorded samples.
    # Each has a small FIFO the DMA keeps topped up; a hardware timer paces how fast
    # samples are pulled out and played (so the timer's overflow rate IS the sample rate).
    # We drive channel A.
    REG_FIFO_A = 0x040000A0  # Direct Sound A's sample FIFO — the DMA writes 8-bit PCM here
    REG_FIFO_B = 0x040000A4  # Direct Sound B's sample FIFO

    # SOUNDCNT_H bits for Direct Sound A:
    PSG_VOLUME_FULL      = 0x0002  # bits 0-1 = 2: the PSG channels at 100% (what enable_sound sets)
    DSOUND_A_VOLUME_FULL = 0x0004  # bit 2: channel A at 100% volume (else 50%)
    DSOUND_A_RIGHT       = 0x0100  # bit 8: mix A into the right speaker
    DSOUND_A_LEFT        = 0x0200  # bit 9: ...and the left
    DSOUND_A_TIMER0      = 0x0000  # bit 10 = 0: timer 0 clocks A's sample rate
    DSOUND_A_TIMER1      = 0x0400  # bit 10 = 1: timer 1 clocks it instead
    DSOUND_A_RESET_FIFO  = 0x0800  # bit 11: clear A's FIFO (set once when (re)starting playback)

    # Channel 1 — square wave with sweep
    REG_SOUND1CNT_L = 0x04000060  # Sweep (shift, direction, time)
    REG_SOUND1CNT_H = 0x04000062  # Duty cycle + envelope
    REG_SOUND1CNT_X = 0x04000064  # Frequency + trigger

    # Channel 2 — square wave (no sweep, simplest for sound effects)
    REG_SOUND2CNT_L = 0x04000068  # Duty cycle + envelope
    REG_SOUND2CNT_H = 0x0400006C  # Frequency + trigger

    # Channel 3 — programmable waveform
    REG_SOUND3CNT_L = 0x04000070
    REG_SOUND3CNT_H = 0x04000072
    REG_SOUND3CNT_X = 0x04000074
    REG_WAVE_RAM    = 0x04000090  # 16 bytes of waveform data

    # Channel 4 — noise
    REG_SOUND4CNT_L = 0x04000078
    REG_SOUND4CNT_H = 0x0400007C

    # ========================================================================
    # Screen
    # ========================================================================

    # The GBA screen size. The single source of truth is the IR display contract
    # (IR::Screen); these names are the hardware-side alias for it.
    SCREEN_WIDTH  = IR::Screen::WIDTH
    SCREEN_HEIGHT = IR::Screen::HEIGHT

    # ========================================================================
    # ROM Header Offsets — used when building the .gba file
    # ========================================================================

    HEADER_ENTRY    = 0x00   # ARM branch instruction to entry point
    HEADER_LOGO     = 0x04   # Nintendo logo bitmap (0x04..0x9F, 156 bytes)
    HEADER_TITLE    = 0xA0   # Game title, up to 12 ASCII chars, NUL-padded
    HEADER_CODE     = 0xAC   # 4-char game code (e.g. "AXVE" = Pokemon Ruby)
    HEADER_MAKER    = 0xB0   # 2-char maker/publisher code
    HEADER_FIXED    = 0xB2   # Must be 0x96 — BIOS rejects the ROM otherwise
    HEADER_CHECKSUM = 0xBD   # Complement checksum of bytes 0xA0..0xBC

    # The 156-byte Nintendo logo bitmap that occupies HEADER_LOGO (0x04..0x9F).
    # The GBA BIOS decompresses and compares this region on boot; a wrong or
    # missing logo means the cartridge won't run on real hardware or on
    # accuracy-focused emulators (mGBA skips the check). These are the canonical
    # fixed bytes every GBA toolchain embeds — do not edit them.
    # SHA1: 17daa0fec02fc33c0f6abb549a8b80b6613b48ee
    HEADER_LOGO_BYTES = [
      0x24, 0xFF, 0xAE, 0x51, 0x69, 0x9A, 0xA2, 0x21, 0x3D, 0x84, 0x82, 0x0A,
      0x84, 0xE4, 0x09, 0xAD, 0x11, 0x24, 0x8B, 0x98, 0xC0, 0x81, 0x7F, 0x21,
      0xA3, 0x52, 0xBE, 0x19, 0x93, 0x09, 0xCE, 0x20, 0x10, 0x46, 0x4A, 0x4A,
      0xF8, 0x27, 0x31, 0xEC, 0x58, 0xC7, 0xE8, 0x33, 0x82, 0xE3, 0xCE, 0xBF,
      0x85, 0xF4, 0xDF, 0x94, 0xCE, 0x4B, 0x09, 0xC1, 0x94, 0x56, 0x8A, 0xC0,
      0x13, 0x72, 0xA7, 0xFC, 0x9F, 0x84, 0x4D, 0x73, 0xA3, 0xCA, 0x9A, 0x61,
      0x58, 0x97, 0xA3, 0x27, 0xFC, 0x03, 0x98, 0x76, 0x23, 0x1D, 0xC7, 0x61,
      0x03, 0x04, 0xAE, 0x56, 0xBF, 0x38, 0x84, 0x00, 0x40, 0xA7, 0x0E, 0xFD,
      0xFF, 0x52, 0xFE, 0x03, 0x6F, 0x95, 0x30, 0xF1, 0x97, 0xFB, 0xC0, 0x85,
      0x60, 0xD6, 0x80, 0x25, 0xA9, 0x63, 0xBE, 0x03, 0x01, 0x4E, 0x38, 0xE2,
      0xF9, 0xA2, 0x34, 0xFF, 0xBB, 0x3E, 0x03, 0x44, 0x78, 0x00, 0x90, 0xCB,
      0x88, 0x11, 0x3A, 0x94, 0x65, 0xC0, 0x7C, 0x63, 0x87, 0xF0, 0x3C, 0xAF,
      0xD6, 0x25, 0xE4, 0x8B, 0x38, 0x0A, 0xAC, 0x72, 0x21, 0xD4, 0xF8, 0x07
    ].pack("C*").freeze
  end
end
