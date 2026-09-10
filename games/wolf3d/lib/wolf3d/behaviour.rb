# frozen_string_literal: true

module Wolf3D
  # THE STATES OF EVERY KIND A CARTRIDGE HOLDS, laid end to end and numbered straight through.
  #
  # WHICH KIND SOMETHING IS, IS WHICH RUN OF STATES IT IS IN, and that is the whole trick of
  # having five kinds at all. Nothing in the pool remembers a kind, nothing branches on one, and
  # no table is indexed by one: a state number already says everything a kind decides — which
  # picture it wears, how fast it walks, what it does when it has a clear line at you, how it
  # falls over and what it leaves. So five kinds cost exactly what one costs, in the frame and
  # in the pool alike, and the only thing that grows is a handful of read-only tables.
  #
  # ONLY THE KINDS THE CARTRIDGE CAN MEET are in it. A game with no dogs anywhere emits no dog
  # states, no hunting and no biting, and a game with nothing but guards comes out exactly as it
  # did before there was more than one kind — the same bargain doors and scenery are built on.
  #
  # Everything below is asked at BUILD time and comes out as a column of a table. What the mind
  # does at run time is read those tables by state number, which is one number it already holds.
  class Behaviour
    attr_reader :kinds, :states

    def self.for(names) = new(names)

    def initialize(names)
      @kinds = Enemy::ALL.select { |kind| names.include?(kind.name) }
      @kinds = [Enemy::GUARD] if @kinds.empty?
      @first = {}
      @states = []
      @kinds.each do |kind|
        @first[kind.name] = @states.length
        @states.concat(kind.states)
      end
      @states.freeze
    end

    def length = @states.length

    # Where one kind's state sits in the whole table.
    def number_of(kind, name)
      within = Enemy[kind].state_number(name)
      raise ArgumentError, "there is no #{kind} state #{name.inspect}" if within.nil?

      @first.fetch(kind) + within
    end

    # ...and which kind a state number belongs to, which is what turns a state back into every
    # other number about the thing standing in it.
    def kind_at(number) = @kinds.reverse.find { |kind| @first.fetch(kind.name) <= number }

    def state_at(number) = @states.fetch(number)

    # --- what the thing in this state does next --------------------------------------------
    #
    # Each of these is asked of a STATE rather than of a kind, which is what lets the mind hold
    # one number and never ask what it is looking at.

    def becomes_from(number) = number_of(kind_at(number).name, state_at(number).becomes)
    def chase_from(number) = number_of(kind_at(number).name, :chase1)
    def fall_from(number) = number_of(kind_at(number).name, :fall1)

    # What it does when it has you: a gun comes up, or a dog gathers itself to jump.
    def attack_from(number)
      kind = kind_at(number)
      number_of(kind.name, kind.has?(:shoot1) ? :shoot1 : :jump1)
    end

    # ...and what a wound that does not kill it does.
    #
    # A KIND WITH NO FLINCH IS LEFT EXACTLY WHERE IT WAS, which is the original's own arrangement
    # and is not the same as sending it back into the chase. Its damage code switches on the kind
    # and has arms for the guard, the officer, the mutant and the SS — and none at all for a dog
    # or for a boss. No arm means no new state: the thing carries on doing whatever it was doing,
    # with the count it already had.
    #
    # THAT IS THE WHOLE OF WHY A BOSS IS FRIGHTENING. He fires six times to a burst, and a hit
    # that landed mid-burst would cancel it if it moved him — so you could hold the trigger down
    # and he would never get a shot away. Left alone, he finishes the burst whatever you do to
    # him. A dog has one hit point, so no wound it takes is ever survived and this never shows.
    def flinch_from(number, second: false)
      kind = kind_at(number)
      wanted = second ? :hurt2 : :hurt1
      kind.has?(wanted) ? number_of(kind.name, wanted) : number
    end

    # Does the thing in this state flinch at all? What reads it is the wounding, which leaves one
    # that does not entirely alone rather than writing the same state back over itself — writing
    # it back would restart the count and rob it of the rest of the picture it was in.
    def flinches_from(number) = kind_at(number).has?(:hurt1) ? 1 : 0

    # How far the thing in this state walks each think. Only the beat and the chase ever walk;
    # everything else is standing still, and reads whatever this says without using it.
    def step_from(number)
      kind_at(number).speed(chasing: !state_at(number).name.to_s.start_with?("path"))
    end

    # Where a state's picture sits in the numbering VSWAP's sprites use.
    def picture_of(number) = kind_at(number).picture_of(state_at(number))

    # ...and the numbers that go with the kind rather than with the state it is in.
    def points_from(number) = kind_at(number).points
    def leaves_from(number) = Enemy::LEAVES.fetch(kind_at(number).leaves)

    # HOW MUCH KILLING EACH KIND TAKES, one row per setting, laid end to end — because the mutant
    # is the one kind a harder game toughens and the setting is not known until somebody picks.
    # Where a kind's four begin is what one carries into the cartridge; which of the four is read
    # is settled when a floor starts.
    def hit_points = @kinds.flat_map(&:hit_points)
    def hit_points_at(kind) = @kinds.index(Enemy[kind]) * Guards::SETTINGS.length

    def starting_state(guard) = number_of(guard.kind, guard.patrolling ? :path1 : :stand)

    # Every picture the cartridge needs for the kinds it holds.
    def pictures = @kinds.flat_map(&:pictures).uniq.sort

    # Does anything on this cartridge do this at all? A game with no dogs emits no hunting and
    # no biting, so neither costs a comparison.
    def any?(job) = @states.any? { |s| s.think == job || s.fires == job }

    # ...and how many arms the one choice a think makes really has, which is what the report
    # needs to be told: exactly one of them runs, and nothing at build time can see that.
    def jobs = @states.map(&:think).compact.uniq.length
  end
end
