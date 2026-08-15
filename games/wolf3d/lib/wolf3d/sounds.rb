# frozen_string_literal: true

module Wolf3D
  # THE SOUNDS THE GAME MAKES: the pistol, the guards shouting and shooting and dying, the doors,
  # the wall that slides away.
  #
  # These are the ones Wolfenstein RECORDED. They sit in VSWAP as raw 8-bit samples at about
  # seven thousand a second, which is exactly what the framework's `sample` verb takes — so the
  # whole of the conversion is taking 128 off every byte, which Vswap::Sound already does. No
  # file format, no resampling, nothing to install.
  #
  # THE OTHER HALF OF THIS GAME'S SOUND IS NOT HERE and cannot be: walking into a wall, picking
  # something up, a locked door, and the player's own death are ADLIB effects — a recipe for a
  # synthesiser chip rather than a recording — and there is no PCM of them anywhere in the game
  # files. They want the chip emulated at build time, which is its own piece of work.
  #
  # WHICH CHUNK IS WHICH is the original's own table (wl_main.cpp, wolfdigimap) rather than
  # remembered. It maps a sound the game asks for onto a numbered chunk of VSWAP, and the numbers
  # below are that map for the sounds this game can currently make.
  #
  # A COPY OF THE GAME MAY NOT HAVE ALL OF THEM. The shareware release ships fewer chunks than the
  # registered one — the map above is `#ifndef UPLOAD` in places — so every sound here is looked
  # up against what the player's own file actually holds, and one that is not there is simply
  # never played. Nothing is a build error: a floor that is quieter than it might be is better
  # than a cartridge that will not build.
  class Sounds
    PISTOL = 5           # the player's own gun
    NOTICES_YOU = 0      # "Halt!" — a guard the moment he sees you
    GUARD_FIRES = 21     # ...and his gun
    DOOR_OPENS = 3
    DOOR_SHUTS = 2
    SECRET_WALL = 15     # a wall that slides away

    # A GUARD HAS EIGHT DEATH SCREAMS and the original picks between them at random, which is what
    # stops a firefight sounding like a loop. Two of them are in every copy of the game and the
    # rest come with the registered one; whichever are there get used.
    #
    # The first two are the original's own first three — its map points two of them at the same
    # chunk, so there are two sounds and not three.
    DEATH_SCREAMS = [12, 13, 34, 35].freeze

    # +vswap+ is the player's own copy of the game's sounds, or nil on a build with no data,
    # which makes every one of these do nothing.
    def initialize(build:, vswap: nil)
      @b = build
      @vswap = vswap
      declare
    end

    # Is there anything to play at all? A floor built without the game's data has no sounds, and
    # everything below is then a no-op rather than a missing method.
    def any? = !@clips.empty?

    # ONE PRESS, ONE SHOT, and the shot before it is cut off. The original reserves a mixer
    # channel for the player's own weapon so a new shot always replaces the last — without that,
    # tapping the trigger fills every voice with pistol and there is none left for anything else.
    def pistol = retrigger(PISTOL)

    def notices_you = play(NOTICES_YOU)
    def guard_fires = play(GUARD_FIRES)
    def door_opens = retrigger(DOOR_OPENS)
    def door_shuts = retrigger(DOOR_SHUTS)
    def secret_wall = retrigger(SECRET_WALL)

    # ...and one of his death screams, chosen as the game runs. Written out as one arm per scream
    # because a sample is played by name: which clip a `play` means is settled while the cartridge
    # is built, so a choice made as the game runs has to be a choice between plays.
    def a_guard_dies
      screams = DEATH_SCREAMS.filter_map { |n| @clips[n] }
      return if screams.empty?
      return screams.first.play if screams.length == 1

      @which.set(@b.rand(0...screams.length))
      screams.each_with_index { |clip, n| (@which == n).then { clip.play } }
    end

    private

    # Every chunk this game knows how to use. Named for the moment rather than the number, so a
    # sound the player's copy does not hold simply never reaches the list.
    WANTED = [PISTOL, NOTICES_YOU, GUARD_FIRES, DOOR_OPENS, DOOR_SHUTS, SECRET_WALL,
              *DEATH_SCREAMS].freeze

    def declare
      @clips = {}
      return if @vswap.nil?

      WANTED.uniq.each do |chunk|
        next unless chunk < @vswap.sound_count

        sound = @vswap.sound(chunk)
        next if sound.length.zero?

        @clips[chunk] = @b.sample(:"sound_#{chunk}", pcm: sound.pcm, rate: sound.rate)
      end
      @which = @b.var :_which_scream, 0 unless @clips.empty?
    end

    def play(chunk) = @clips[chunk]&.play

    # Cut whatever of this sound is still going and start it again, which is what the original's
    # reserved channels amount to for the sounds one thing makes over and over.
    def retrigger(chunk)
      clip = @clips[chunk] or return

      clip.stop
      clip.play
    end
  end
end
