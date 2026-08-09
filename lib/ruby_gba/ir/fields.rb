# frozen_string_literal: true

module RubyGBA
  module IR
    # WHAT EACH KIND OF NODE CARRIES: every field a kind has, tagged with what that field
    # must hold. This is part of the node model — the declaration of what a node of a given
    # kind IS — so the model itself can refuse a read of a field a kind does not have, and
    # so anything else that wants to know can ask one table instead of keeping its own.
    #
    # A tag of +:value+ marks a value slot: a wrapped operand that may be an author-time
    # literal or something worked out at run time. Every other tag names an author-time
    # literal of a stated type. What those tags MEAN, and the checking of them, belongs to
    # {Verifier} — this table only says which fields exist and what each one is for.
    #
    # A field absent from a node is fine; the constructors decide what a verb must pass.
    # This says what a field must be when it is there, and which fields can be there at all.
    #
    # Kept complete by the coverage test, which asserts every Node::CATEGORY kind has a row
    # here — so a new verb cannot slip the net.
    module Fields
      module_function

      BY_KIND = {
        program: {},

        # variable operations
        set:        { var: :name, value: :value },
        add:        { var: :name, operand: :value },
        sub:        { var: :name, operand: :value },
        copy:       { dest: :name, src: :name },
        negate:     { var: :name },
        abs:        { var: :name },
        negate_abs: { var: :name },
        clamp:      { var: :name, min: :value, max: :value }, # bounds may be run-time values
        # persistence: boot-load the saved variables (a list of {name, default, slot}
        # hashes plus a marker), and mirror one back to its slot when it changes.
        save_init:  { vars: :list, magic: :int },
        save_store: { var: :name, slot: :int },

        # drawing / screen
        screen:        { mode: :mode, buffered: :flag }, # buffered: opt into double buffering
        pixel:         { x: :value, y: :value, color: :color },
        fill_rect:     { x: :int, y: :int, w: :int, h: :int, color: :color }, # fixed position
        clear_screen:  { color: :color },
        draw_text:     { text: :text, x: :int, y: :int, color: :color, font: :name },   # fixed origin
        draw_digit:    { value: :value, x: :int, y: :int, color: :color, font: :name }, # run-time digit
        draw_rect_at:  { x: :value, y: :value, w: :value, h: :value, color: :color }, # runtime position and size
        dma_fill_rect: { x: :int, y: :int, w: :int, h: :int, color: :color },
        blit:          { name: :name, x: :value, y: :value },
        blit_pose:     { poses: :list, index: :value, x: :value, y: :value }, # one image of a same-size set
        # a tiled background: the distinct tile images, the grid of indices into them
        # (nil = empty cell), and the tile size — all author-time (the picture is fixed).
        background:    { name: :name, tiles: :list, map: :list, tile_w: :int, tile_h: :int },
        # move the visible window over a background: which background, and the run-time
        # top-left offset (x, y) in pixels.
        scroll_background: { name: :name, x: :value, y: :value },
        # bend a background row by row: which background, the variable the row number is
        # put in, and the sideways offset worked out from it. #children run first.
        scroll_rows:       { name: :name, row: :name, offset: :value },
        # move the window over the whole displayed picture: the run-time top-left
        # offset (x, y) in pixels. Nothing is named — it moves everything.
        camera:            { x: :value, y: :value },
        # blend the whole picture toward a color: which color (author-time, :black or
        # :white) and how far, 0-100, at run time.
        fade:              { toward: :option, amount: :value },
        # a composited moving object: its same-size poses, a run-time index picking
        # which to show (facing/animation), and its run-time position/visibility.
        # present_objects names which to draw this frame.
        object:          { name: :name, poses: :list, pose: :value, x: :value, y: :value, active: :value,
                           angle: :value, scale: :value },
        present_objects: { names: :list },
        # save/restore the pixels under a moving object; the patch size comes from
        # the named backing buffer, so these carry only where (x/y, run-time).
        save_region:    { buffer: :name, x: :value, y: :value },
        restore_region: { buffer: :name, x: :value, y: :value },

        # audio
        enable_sound: {},
        define_sound: { name: :name, frequency: :int, duty: :option, decay: :option, volume: :int },
        beep:         { tone: :tone, duty: :option, decay: :option, volume: :int },
        noise:        { preset: :option, pitch: :option, decay: :option, volume: :int, metallic: :flag },
        wave:         { shape: :option, frequency: :int, volume: :option },
        stop_wave:    {},
        song:         { name: :name, voices: :list, total_frames: :int },
        play_song:    { name: :name },
        stop_music:   {},
        play_sample:  { name: :name, loop: :flag, volume: :option, pitch: :option }, # loop/level/pitch
        stop_sample:  { name: :name }, # stop a sample's voices (or all if no name)

        # control flow (bodies nest as #children; an if's else is a :branch attr).
        if:         { cond: :value, else: :branch },
        else:       {},
        loop:       {},
        repeat:     { count: :value, index: :name },
        # timed triggers: the body nests as #children; the counter is a hidden var
        # name, the period/delay an author-time whole number of frames.
        every:      { counter: :name, period: :int },
        after:      { counter: :name, frames: :int },
        # hardware timers: a named counter at an author-time rate in Hz; stop by name.
        timer_start: { name: :name, hz: :int },
        timer_stop:  { name: :name },
        on_timer:    { timer: :name }, # handler body is #children, run on each overflow
        # fast: where the routine wants to live, for a target with more than one kind of
        # memory to run code from. nil (the usual) leaves it to the target.
        func:       { name: :name, fast: :flag },
        call:       { target: :name },
        case:       { var: :name, clauses: :list },
        wait_vblank: {},
        halt:       {},
        raw:        { bytes: :text },

        # embedded data
        data:      { name: :name, bytes: :text },
        data_byte: { name: :name, index: :int }, # a fixed index into the blob
        bitmap:    { name: :name, width: :int, height: :int, pixels: :text, transparent: :int },
        backing_buffer: { name: :name, width: :int, height: :int }, # a RAM patch a sprite saves under itself
        sample:    { name: :name, bytes: :text, rate: :int, note: :option }, # PCM data + rate + recorded pitch
        table:     { name: :name, values: :list, width: :option, signed: :flag }, # a build-time array of numbers

        # lists
        list_new:  { name: :name, capacity: :int, declared: :int, usually: :int },
        list_push: { name: :name, value: :value },
        list_drop: { name: :name, from: :option },
        list_set:  { name: :name, index: :value, value: :value },
        list_get:  { name: :name, index: :value },
        list_len:  { name: :name },
        table_get: { name: :name, index: :value }, # read a ROM table at a run-time index

        # expression values
        int:     { value: :int },
        var_ref: { name: :name },
        binop:   { op: :option, lhs: :value, rhs: :value },
        neg:     { operand: :value },
        # a full-width multiply of two numbers carrying the same fraction bits
        mul_fix: { lhs: :value, rhs: :value, fraction_bits: :int },
        # a division whose numerator is widened first, so the answer keeps a fraction
        div_fix: { lhs: :value, rhs: :value, fraction_bits: :int },
        shift_right: { operand: :value, bits: :int },
        held:    { button: :option },
        pressed: { button: :option },
        chance:  { draw: :value, percent: :int }, # draw is the 0..99 value; percent an author-time bound
        read_scanline: {}, # the current scanline (VCOUNT) — a hardware-only value read, no operands
        timer_ticks: { name: :name }, # how many times a named timer has overflowed since it started
        # do two posed sprites' solid pixels overlap? each side: its poses (image names),
        # the run-time pose index, and where it sits (value operands)
        pixels_overlap: { a_poses: :list, a_pose: :value, a_x: :value, a_y: :value,
                          b_poses: :list, b_pose: :value, b_x: :value, b_y: :value },
      }.freeze

      # Whether this kind is in the table at all. A kind that is not is a kind nothing has
      # been taught about, which the verifier turns into a loud error.
      def known?(kind)
        BY_KIND.key?(kind)
      end

      # The fields of one kind, each mapped to its tag. Empty for a kind carrying nothing,
      # and empty for a kind nobody declared — so a caller asking about an unknown kind gets
      # "no fields" rather than an exception; proving the kind is known is the verifier's job.
      def of(kind)
        BY_KIND.fetch(kind, EMPTY)
      end

      EMPTY = {}.freeze
    end
  end
end
