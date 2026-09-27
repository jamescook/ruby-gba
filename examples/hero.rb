#!/usr/bin/env ruby
# frozen_string_literal: true

# Hero — walk a character through a world bigger than the screen, with the camera
# following along.
#
# This is the follow-you camera almost every adventure game uses: the hero stays
# planted in the middle of the screen, and when you walk, the WORLD slides past
# underneath. That's two things you've seen on their own — a SPRITE (the hero) and
# a scrolling BACKGROUND (the world) — working together. The console draws the
# hero on top of the moving scenery for free, so the hero never smears and the
# scenery never tears.
#
# You say it once — `camera_follows hero, across: world` — and from then on the hero
# is an ORDINARY SPRITE you move with `move`, exactly like one in a game that fits on
# a single screen. The framework does the swap: every frame it sees how far the hero
# walked, slides the world by that much, and puts the hero back where it stands. The
# world is a torus, so you can walk forever in any direction and it wraps around.
#
# That the hero stays an ordinary sprite is the part that matters. Written by hand,
# a world bigger than the screen forces you to keep the hero's world position in
# variables of your own — and then the hero is a pair of numbers rather than a
# sprite, so `move` and its automatic facing, walk cycles and poses are all out of
# reach.
#
# And there is WEATHER. Walk north and mist closes in; walk back south and it clears.
# Two things make that work, and neither is a drawing:
#
#     layers :ground, :actors, :air        # the fog is declared in FRONT of the hero
#     layer :air, transparency: 100 - mist do ... end
#
# The first line is why the mist covers the hero rather than hiding behind them. Scenery
# is normally behind everything that moves, so a background in front of a sprite is the
# one arrangement a picture cannot fall into by accident — you say it, in the one line
# that says what is in front of what.
#
# The second is how thick it is, and the point is that it is not a number. `transparency:`
# is how much of what is BEHIND the layer shows through, so `100 - mist` thins as the mist
# thickens — and `mist` is an ordinary variable the game adds to when you walk north. The
# display blends the two layers as it draws each line, so nothing is redrawn however thick
# the fog gets; the only per-frame cost is telling it the new amount, which is one write.
#
# And there are SAVE FILES. The game opens on a file screen with three of them, each saying
# how far its walk got. Pick one, then NEW GAME starts a walk in it, START saves the walk
# while you are out walking, and SELECT comes back to the file screen, where CONTINUE puts
# you back exactly where you saved — even after the console was switched off.
# A walk you never saved is gone when the power goes, which is what a save file is for.
#
#     files = save_data :file, copies: 3 do keep px, py, mist, steps end
#     files[slot].save        files[slot].load        files[n].peek(steps)
#
# CONTINUE, COPY TO NEXT and ERASE are grey while the picked file is empty: a menu row can
# ask a question the game works out, `enabled: files[slot].good?`, and it is asked every
# frame. A save cut off by the power going out keeps the last good one — each file is kept
# twice — and none of that is anything the game says.
#
# What you never touch: object memory, tile numbers, palettes, the sprite table, save
# memory, or a single scroll register. A tile is an `image`, the world is a `background`,
# and the hero is a `sprite`.
#
# Its companion, examples/scroll.rb, pans the same kind of world with no hero —
# the camera on its own. This is that camera locked onto a character.
#
# Run it to build examples/hero.gba:
#   ruby examples/hero.rb

require_relative "../lib/ruby_gba"

module Hero
  SPEED = 2 # pixels the hero walks per frame while a direction is held

  # The weather. Walking north thickens the mist and south thins it, a couple of points a
  # step, so a second or so of walking takes you from clear air into a whiteout.
  MIST_PER_STEP = 2
  THICKEST = 90 # never quite solid — you can always see where you are going

  # Where a new game starts in the world: standing by a corner of the pond.
  START_X = 120
  START_Y = 80

  # A pond of water tiles, a few cells across, dropped into the grass as a landmark
  # you can watch slide by as you walk (and walk back around to, since the world wraps).
  POND_COLS = (10..12)
  POND_ROWS = (10..11)

  # A 32x32 world (256x256 pixels — far bigger than the screen): grass, the pond, and
  # trees scattered across it so there's plenty of scenery moving past as you walk.
  MAP = Ractor.make_shareable((0...32).map do |r|
    (0...32).map do |c|
      if POND_ROWS.cover?(r) && POND_COLS.cover?(c) then "~" # the pond
      elsif ((r * 3) + (c * 5)) % 11 == 0            then "T" # scattered trees
      else "."                                              # grass
      end
    end.join
  end)

  GAME = RubyGBA.game("HERO") do
    screen :tiled # tile mode: a scrolling background for the world + a hardware sprite on top

    image :grass, "." => rgb(3, 18, 5), "'" => rgb(5, 24, 7) do
      <<~ART
        ........
        ..'.....
        ........
        .....'..
        ........
        ...'....
        ........
        ......'.
      ART
    end
    image :tree, "^" => rgb(0, 26, 0), "|" => rgb(12, 7, 2), "." => rgb(3, 18, 5) do
      <<~ART
        ...^^...
        ..^^^^..
        .^^^^^^.
        ^^^^^^^^
        ..^^^^..
        ...||...
        ...||...
        ..|||...
      ART
    end
    image :water, "~" => :blue, "=" => rgb(12, 12, 31) do
      <<~ART
        ~~~~~~~~
        ~~==~~~~
        ~~~~~~~~
        ~~~~~~==
        ==~~~~~~
        ~~~~~~~~
        ~~~==~~~
        ~~~~~~~~
      ART
    end

    tiles :terrain, "." => :grass, "T" => :tree, "~" => :water

    # A sheet of pale mist, in tiles like anything else. On its own it would be a flat
    # white wall over the game; it is the layer it goes in that makes it weather.
    image :cloud, "." => rgb(28, 29, 31), "'" => rgb(31, 31, 31) do
      <<~ART
        ........
        ..'.....
        ....'...
        ........
        .'......
        ......'.
        ........
        ...'....
      ART
    end
    tiles :weather, "#" => :cloud

    # THE STACK, back to front. The fog is declared IN FRONT of the hero, which is the one
    # arrangement a picture cannot fall into by accident — normally scenery is behind
    # everything that moves. Saying it here is the whole of it; once one background is in
    # front of a sprite, every background and sprite has to say where it sits, which is why
    # the world and the hero get blocks of their own below. The file screen's words go on
    # top of everything, mist included.
    layers :ground, :actors, :air, :words

    world = layer(:ground) { background :world, tiles: :terrain, map: MAP }

    # The hero: a little round face, its corners see-through so the grass shows around
    # it, its eyes and nose a second color. It's pinned to the center of the screen and
    # never moves from there — the world moves instead.
    #
    # It is drawn LOOKING RIGHT, and that is the only way it is drawn. The left-facing
    # pose is `mirror(:guy_right)` — the same picture the other way round, which is how
    # nearly every 2D game faces a character. The console reverses a sprite for nothing,
    # so the left pose keeps no pixels of its own: half the sprite memory of a character
    # that faces both ways, and half the art to draw.
    image :guy_right, "." => :transparent, "#" => :red, "o" => :white do
      <<~ART
        ..####..
        .######.
        ###o##o#
        ########
        #######o
        ########
        .######.
        ..####..
      ART
    end

    # `move :left` turns them as well as walking them, so nothing below says `face`.
    hero = layer(:actors) do
      sprite :guy, at: [0, 0], facing: { right: :guy_right, left: mirror(:guy_right) }
    end
    hero.center_on_screen # the middle of the screen, worked out from the hero's own size

    # HOW THICK THE MIST IS, which the game works out as you walk: 0 in the south, 100 in
    # the north. `transparency:` is how much of what is BEHIND the layer shows through, so
    # it is 100 minus the mist — thicker mist, less world.
    #
    # A number written here would be sent to the display once and never again. A value is
    # sent again before every frame, and that is the only difference: one register write
    # per frame, and nothing is redrawn.
    mist = var :mist, 0
    layer(:air, transparency: 100 - mist) do
      background :fog, tiles: :weather, map: Array.new(32) { "#" * 32 }
    end

    # ...and the camera follows them. From here the hero is an ordinary sprite you move
    # with `move`, and the world slides underneath instead: every frame the framework
    # sees how far they walked, scrolls the world by exactly that, and puts them back.
    camera_follows hero, across: world, at: [START_X, START_Y] # standing by a corner of the pond

    # --- SAVE FILES ---
    #
    # Three files, each a walk kept in the cartridge's save memory: where the hero stands in
    # the world, how thick the mist is there, and how many steps it took to get there.
    # Nothing is saved until the player presses START, so a walk the console is switched off
    # in the middle of comes back as it was at the last save — which is what a save file is.
    #
    # Where the hero stands in the WORLD is the game's own to keep. The follow camera keeps
    # the hero in one place on the screen and slides the world instead, so the hero's own
    # position never says how far they walked; these two do, moved by the same steps.
    px = var :px, START_X
    py = var :py, START_Y
    steps = var :steps, 0
    files = save_data(:file, copies: 3) { keep px, py, mist, steps }

    slot = var :slot, 0     # the file picked on the file screen, and the one START saves to
    saved = var :saved, 0   # frames left of "SAVED" after START
    mode = var :mode, :files
    shown = Array.new(3) { |n| var :"shown#{n}", 0 } # each file's steps, for the file screen
    number = var :number, 1 # the picked file's number, as the second step shows it

    # The file screen is two steps: pick a file, then say what to do with it. Which step is
    # on screen changes at the top of a frame, never part way through one — both menus read
    # the A button, and a press that opened the second step must not also choose in it.
    choosing = var :choosing, 0
    next_choosing = var :next_choosing, 0

    # Put the world back around the hero at the place a file says. The window's corner sits
    # as far back from the hero's world position as the hero sits into the screen.
    place_hero = -> { world.scroll_to px - hero.x, py - hero.y }

    # A plain backdrop for the file screen, so its words are not read over scenery.
    image :panel, "#" => rgb(2, 4, 12) do
      "########\n" * 8
    end
    tiles :panels, "#" => :panel

    # THE FILE SCREEN. First the three files, each with how far its walk got — read out of
    # the save without loading it — or EMPTY. Pick one, and then what to do with it:
    # CONTINUE, COPY TO NEXT and ERASE are grey while it is empty, because the menu reads
    # `files[slot].good?` every frame.
    scene :files do
      hero.hide
      choosing.set! next_choosing
      number.set! slot + 1
      layer(:words) do
        background :backdrop, tiles: :panels, map: Array.new(20) { "#" * 30 }

        # Second step, written first: on the frame a file is picked this menu is not yet up,
        # so the press that picked the file is not taken as a choice here too.
        actions = nil
        (choosing == 1).then do
          draw_text "FILE", 72, 32, :yellow
          draw_number number, 104, 32, :yellow, digits: 1
          actions = menu :actions, at: [72, 60], starts_on: 1 do |m|
            m.item("CONTINUE", enabled: files[slot].good?) do
              files[slot].load
              place_hero.call
              mode.set! :walking
            end
            m.item("NEW GAME") do
              files.reset
              place_hero.call
              mode.set! :walking
            end
            m.item("COPY TO NEXT", enabled: files[slot].good?) do
              files.copy slot, to: (slot + 1) % 3
              next_choosing.set! 0
            end
            m.item("ERASE", enabled: files[slot].good?) do
              files[slot].erase
              next_choosing.set! 0
            end
            m.item("BACK") { next_choosing.set! 0 }
          end
        end

        # EVERY LETTER ON THIS SCREEN IS A SPRITE, and a game has 128 of those for all its
        # screens together — so the words here are kept short. A row that greys itself is
        # drawn both ways, and costs its letters twice.
        (choosing == 0).then do
          3.times do |n|
            row = 60 + (n * 16)
            shown[n].set! files[n].peek(steps)
            files[n].good?.then { draw_number shown[n], 136, row, :white, digits: 4 }
                          .else { draw_text "NEW", 136, row, :gray }
          end
          menu :files, at: [64, 60], spacing: 16 do |m|
            3.times do |n|
              m.item("FILE #{n + 1}") do
                slot.set! n
                # The cursor opens on CONTINUE for a file there is something in, and on NEW
                # GAME for an empty one.
                files[n].good?.then { actions.picked.set! 0 }.else { actions.picked.set! 1 }
                next_choosing.set! 1
              end
            end
          end
        end
      end
    end

    scene :walking do
      hero.show
      # Hold a direction to walk. This is the same `move` any sprite takes — nothing
      # here knows the world is bigger than the screen. The world is a torus, so there's
      # no edge to bump into: keep going and it wraps.
      held(:left).then do
        hero.move :left, by: SPEED
        px.sub! SPEED
      end
      held(:right).then do
        hero.move :right, by: SPEED
        px.add! SPEED
      end
      # Walking north takes you into the mist and south brings you back out of it. The
      # layer is see-through by whatever this holds, so the weather is one variable.
      held(:up).then do
        hero.move :up, by: SPEED
        py.sub! SPEED
        mist.add! MIST_PER_STEP
      end
      held(:down).then do
        hero.move :down, by: SPEED
        py.add! SPEED
        mist.sub! MIST_PER_STEP
      end
      mist.clamp! 0, THICKEST
      (held(:left) | held(:right) | held(:up) | held(:down)).then { steps.add! 1 }

      # START saves the walk into the picked file; SELECT goes back to the file screen.
      pressed(:start).then do
        files[slot].save
        saved.set! 60
      end
      pressed(:select).then do
        next_choosing.set! 0
        mode.set! :files
      end
      (saved > 0).then { saved.sub! 1 }
      layer(:words) { (saved > 0).then { draw_text "SAVED", :center, 16, :white } }
    end

    # Whichever screen `mode` names runs this frame, and owns what it shows while it runs.
    game_loop { call mode }
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Hero::GAME.write_if_main
