# frozen_string_literal: true

# A GAME OF MANY ROOMS, shaped like an adventure game's play scene: one scene for the whole
# world, laid out as a grid of rooms, and the player walking from room to room. Walking off an
# edge slides the screen to the room across it, and while it slides both rooms are up: the
# things of the room left behind slide off one side as the next room's slide in from the other.
#
# Each room has things of its own standing in it, drawn from two pools by picture size, and a
# thing shows a picture by a number in a field of its own: three pots of 32x32 and two statues of
# 64x64 a room. A room's things are spawned as the slide to it starts and removed once the slide
# away from it ends. Every room's pictures together are many times the console's 32K of sprite
# memory, so the game groups them by room, and a room can be up only with a room across one of
# its edges. The hero and the heart are in every room and are in no group.
#
# Played by a test on every lowering for its pictures, and built by another for what its map of
# sprite memory says, so it is written once, here.
module ManyRoomsGame
  INKS = (1..15).map { |i| RubyGBA::Graphics::Color.rgb(i * 2, 31 - (i * 2), 10) }.freeze

  COLUMNS = 6
  ROWS = 4
  ROOMS = COLUMNS * ROWS
  POTS = 3    # 32x32 pictures a room: 512 bytes each, stored with fifteen colours and see-through
  STATUES = 2 # 64x64 pictures a room: 2048 bytes each

  POT_PICTURES = (0...(ROOMS * POTS)).map { |n| :"pot_#{n}" }.freeze
  STATUE_PICTURES = (0...(ROOMS * STATUES)).map { |n| :"statue_#{n}" }.freeze

  # What one room's pictures come to, worked by hand: three pots and two statues.
  ROOM_BYTES = (POTS * 512) + (STATUES * 2048)

  # What every screen shows, worked by hand: the hero's two 32x32 frames and the 16x16 heart.
  EVERYWHERE_BYTES = (2 * 512) + 128

  # The rooms the walk goes through, each across an edge of the last: right, right, down, down,
  # right, down.
  PATH = [0, 1, 2, 8, 14, 15, 21].freeze

  # The player crosses a room every ten passes, and the last four of them slide to the next room.
  PASSES_A_ROOM = 10
  SLIDE_PASSES = 4
  SLIDE_STARTS = PASSES_A_ROOM - SLIDE_PASSES

  # How far the screen slides a pass, across and down: a whole screen in SLIDE_PASSES.
  SLIDE_ACROSS = 240 / SLIDE_PASSES
  SLIDE_DOWN = 160 / SLIDE_PASSES

  # Each room across an edge of each other, as up_together: wants them.
  def self.rooms_beside
    (0...ROOMS).flat_map do |room|
      right = [room, room + 1] if (room % COLUMNS) < COLUMNS - 1
      down = [room, room + COLUMNS] if room + COLUMNS < ROOMS
      [right, down].compact
    end
  end

  # A square picture of +size+ filling its square and differing from every other: a slanted stripe
  # pattern shifted by +number+, with the number written along the top row.
  def self.art(number, size)
    (0...size).flat_map do |y|
      (0...size).map do |x|
        next INKS[(number >> (x % 8)) & 1] if y.zero?

        INKS[((x * 5) + (y * 3) + number) % 15]
      end
    end
  end

  # Spawn the things of the room in +room+ (a Value), as the slide to it starts or at power-on.
  def self.spawn_things(pots, statues, room)
    POTS.times { |n| pots.spawn(x: 0, y: 0, room: room, n: n) }
    STATUES.times { |n| statues.spawn(x: 0, y: 0, room: room, n: n) }
  end

  # Stand +thing+ where its room is on the screen: its own place in the room, less how far the
  # screen has slid, and a screen further on for a thing of the room being slid to.
  def self.stand(thing, here, across, down, home_x, home_y)
    coming = thing.room != here
    thing.x.set! home_x - across
    thing.y.set! home_y - down
    coming.then do
      thing.x.add!(across.clamp(0, 1) * 240)
      thing.y.add!(down.clamp(0, 1) * 160)
    end
  end

  # The game's own lines, for a block handed to Builder or RubyGBA.build.
  def self.declare(builder)
    builder.instance_eval do
      screen :tiled
      POT_PICTURES.each_with_index { |name, n| image name, width: 32, height: 32, data: ManyRoomsGame.art(n, 32) }
      STATUE_PICTURES.each_with_index { |name, n| image name, width: 64, height: 64, data: ManyRoomsGame.art(1000 + n, 64) }
      image :hero_a, width: 32, height: 32, data: ManyRoomsGame.art(2000, 32)
      image :hero_b, width: 32, height: 32, data: ManyRoomsGame.art(2001, 32)
      image :heart, width: 16, height: 16, data: ManyRoomsGame.art(2002, 16)
      path = table :path, PATH + [PATH.last]
      var :state, 0
      tick = var :tick, 0
      scene(:play) do
        step = var :step, 0
        phase = var :phase, 0
        here = var :here, 0
        beside = var :beside, 0
        across = var :across, 0
        down = var :down, 0
        rooms = picture_groups :rooms, (0...ROOMS).to_h { |room|
          [room, POT_PICTURES[room * POTS, POTS] + STATUE_PICTURES[room * STATUES, STATUES]]
        }, up_together: ManyRoomsGame.rooms_beside
        pots = pool :pot, x: 0, y: 0, room: 0, n: 0, capacity: POTS * 2,
                          facing: POT_PICTURES.to_h { |name| [name, name] }
        statues = pool :statue, x: 0, y: 0, room: 0, n: 0, capacity: STATUES * 2,
                                facing: STATUE_PICTURES.to_h { |name| [name, name] }
        hero = sprite :hero, frames: %i[hero_a hero_b], rate: 4, at: [104, 120]
        sprite :heart, facing: { full: :heart }, at: [4, 4]

        step.set!((tick / PASSES_A_ROOM).clamp(0, PATH.length - 1))
        phase.set!(tick % PASSES_A_ROOM)
        here.set! path[step]
        beside.set! here
        across.set! 0
        down.set! 0
        # The slide: the room ahead is up as well, and the screen moves a step towards it a pass.
        sliding = (phase >= SLIDE_STARTS) & (step < PATH.length - 1)
        sliding.then do
          beside.set! path[step + 1]
          slid = phase - SLIDE_STARTS + 1
          (beside == here + 1).then { across.set!(slid * SLIDE_ACROSS) }.else { down.set!(slid * SLIDE_DOWN) }
        end
        rooms.show here, beside

        (pots.count == 0).then { ManyRoomsGame.spawn_things(pots, statues, here) }
        (sliding & (phase == SLIDE_STARTS)).then { ManyRoomsGame.spawn_things(pots, statues, beside) }
        # The slide has ended: the room left behind's things go.
        pots.each { |pot| ((pot.room != here) & (pot.room != beside)).then { pot.remove } }
        statues.each { |statue| ((statue.room != here) & (statue.room != beside)).then { statue.remove } }

        pots.each do |pot|
          ManyRoomsGame.stand(pot, here, across, down, 8 + (pot.n * 72), 24)
          pot.face POT_PICTURES, showing: (pot.room * POTS) + pot.n
        end
        statues.each do |statue|
          ManyRoomsGame.stand(statue, here, across, down, 16 + (statue.n * 120), 64)
          statue.face STATUE_PICTURES, showing: (statue.room * STATUES) + statue.n
        end
        hero.x.set!(20 + (phase * 20))
      end
      game_loop do
        tick.add! 1
        case_var(:state) { when_val 0, :play }
      end
    end
  end

  def self.program
    builder = RubyGBA::Builder.new
    declare(builder)
    builder.finalize_program
    builder.program
  end
end
