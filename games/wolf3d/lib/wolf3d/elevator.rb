# frozen_string_literal: true

module Wolf3D
  # THE LIFT AT THE END OF A FLOOR: the little room you step into and the lever you pull.
  #
  # It is built out of ordinary walls rather than being a thing of its own, and the original does
  # not model a lift at all — there is no car object anywhere in it. There is a lever, which is a
  # wall code; and there is the cell the player happens to be standing on when they pull it,
  # which is what says where the lift goes. This keeps that shape, because inventing a car turns
  # out to be both more code and wrong: in an open room every floor cell beside a lever looks
  # like a car, and the maps only get away with it because their cars are walled in.
  #
  # ALL OF THE NUMBERS BELOW WERE READ OUT OF A REAL GAMEMAPS and checked against the original's
  # own Cmd_Use, because every one of them is the kind that is easy to half-remember and
  # expensive to get wrong. Across the ten floors of the first episode:
  #   - Wall code 21 is the lever. It appears three times per floor, which is the three walls of
  #     one little room, and six times on floor one, which is two lifts.
  #   - Every floor has exactly one lift except floor one, which has two, and the boss floor,
  #     which has none at all — you finish that one by killing the boss.
  #   - Wall code 22 is the lever pulled down. NO MAP CONTAINS IT; it is only ever written by the
  #     game, which is why it has to be added to the pictures a floor needs by hand.
  #   - Floor code 107 is the mark for "this lift goes somewhere other than the next floor". It
  #     is the lowest floor code there is, so it wears an ordinary area code's clothes, and
  #     across all ten floors of the episode it appears exactly once — on the secret lift of
  #     floor one. Checking for it is exact rather than a guess.
  class Elevator
    # The lever, and the lever pulled.
    SWITCH = 21
    PULLED = 22

    # The cell you stand on for a lift that goes somewhere other than the next floor.
    SECRET_CAR = Level::FLOOR

    Lever = Data.define(:x, :y)

    attr_reader :levers

    def initialize(level)
      @level = level
      @levers = level.each_cell.filter_map { |x, y| Lever.new(x: x, y: y) if switch?(x, y) }
    end

    def count = @levers.length

    def empty? = @levers.empty?

    # Which lever this cell is, counting from one, or nil for every other cell.
    def number_at(x, y)
      @number ||= @levers.each_with_index.to_h { |lever, index| [[lever.x, lever.y], index + 1] }
      @number[[x, y]]
    end

    # The cells a player can stand on that send them to the secret floor rather than the next
    # one. A floor has one of these or none; the game compares where the player is standing
    # against it at the moment the lever goes down, which is exactly what the original does.
    def secret_cars
      @secret_cars ||= @level.each_cell
                             .select { |x, y| @level.wall_code(x, y) == SECRET_CAR }
                             .map { |x, y| (y * @level.width) + x }
    end

    # The two pictures of a pulled lever, which no map asks for and every floor with a lift
    # needs. Lit face first, the way a wall's pair is always kept.
    def pictures
      return [] if empty?

      [WallAtlas.texture_index(PULLED, WallAtlas::LIT), WallAtlas.texture_index(PULLED, WallAtlas::DARK)]
    end

    private

    def switch?(x, y) = @level.wall_code(x, y) == SWITCH
  end
end
