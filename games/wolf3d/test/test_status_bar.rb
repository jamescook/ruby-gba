# frozen_string_literal: true

require_relative "test_helper"

# THE BAR ALONG THE BOTTOM, read back off the screen rather than out of the variables behind it.
#
# The figures are read by matching what was drawn against the font's own glyphs, so a test can
# say "the bar reads 100" and not merely "something was painted where the health goes". That is
# the only way to catch a bar that shows the wrong field, or the right field one place across.
class TestStatusBar < Minitest::Test
  include Wolf3DTest

  FP = Wolf3D::FirstPerson
  Bar = Wolf3D::StatusBar
  Guards = Wolf3D::Guards
  Release = Wolf3D::Fixture::Release

  SIDE = 16
  FLOOR = Wolf3D::Level::FLOOR
  WALL = Release::WALL
  GOLD_KEY = Wolf3D::Level::KEYS.key(:gold)

  def test_the_bar_takes_the_bottom_of_the_screen_and_the_view_takes_the_rest
    run = look

    assert_equal ground, run.screen.pixel(2, FP::VIEW_H), "the bar starts where the view stops"
    assert_equal ground, run.screen.pixel(2, 159), "and reaches the bottom of the screen"
    refute_equal ground, run.screen.pixel(2, FP::VIEW_H - 1), "the row above it is still the view"
  end

  def test_every_field_is_labelled
    run = look
    missing = Bar::FIELDS.reject { |field| label_shows?(run, field) }

    assert_empty missing.map(&:label), "every field should be named on the bar"
  end

  # What the player starts with, in the places the bar says they go.
  def test_the_bar_opens_with_what_the_player_starts_with
    run = look

    assert_equal FP::START_HEALTH, figure(run, :health)
    assert_equal FP::START_AMMO, figure(run, :ammo)
    assert_equal 0, figure(run, :score)
    assert_equal FP::LIVES, figure(run, :lives)
    assert_equal FP::FLOOR, figure(run, :floor)
  end

  # A HUD that does not follow the game is wallpaper. Stand in front of a guard and let him
  # shoot: the number on the bar comes down with the health behind it.
  def test_the_health_on_the_bar_comes_down_when_you_are_shot
    shot = watch(frames: 200, guards: [[11, 8, :west]])

    assert_operator figure(shot, :health), :<, FP::START_HEALTH, "he should have hit you by then"
    assert_equal shot[:health], figure(shot, :health), "and the bar should say what you have left"
  end

  # Firing spends a bullet, and the bar counts them down. There is a guard in the room because
  # the pistol is the mind's business, and a floor with nobody on it has no mind.
  def test_the_ammunition_on_the_bar_counts_down_as_you_fire
    fired = Reference.new.input_each_frame { |f| f.even? ? [:b] : [] }
                    .run(view_of(arena(guards: [[13, 8, :east]])), frames: 12)

    assert_operator figure(fired, :ammo), :<, FP::START_AMMO
    assert_equal fired[:ammo], figure(fired, :ammo)
  end

  # A hundred a guard, which is the original's own number.
  def test_killing_a_guard_puts_a_hundred_on_the_score
    killed = watch(frames: 200, guards: [[11, 8, :west]], firing: true)

    assert_operator figure(killed, :score), :>=, Guards::POINTS,
                    "one dead guard is worth a hundred"
    assert_equal killed[:score], figure(killed, :score)
  end

  # A key is a block of its own metal rather than a figure, because what a player wants to know
  # is whether the gold door will open.
  def test_a_key_lights_its_own_block_on_the_bar
    before = look
    after = Reference.new.input_each_frame { [:up] }
                    .run(view_of(arena(things: { [9, 8] => GOLD_KEY })), frames: 25)

    refute_includes key_colours(before), palette[Bar::METALS.fetch(:gold)],
                    "no key to start with, so no gold block"
    assert_includes key_colours(after), palette[Bar::METALS.fetch(:gold)],
                    "and picking one up lights it"
  end

  private

  def fixture = @fixture ||= Release.new
  def vswap = @vswap ||= Wolf3D::Vswap.new(fixture.files["VSWAP"])
  def palette = Wolf3D::Palette.game
  def ground = palette[Bar::GROUND]
  def font = RubyGBA::Fonts.get(Bar::FONT)

  def arena(player: [8, 8], facing: :east, guards: [], things: {})
    cells = Array.new(SIDE * SIDE, FLOOR)
    standing = Array.new(SIDE * SIDE, 0)
    SIDE.times do |y|
      SIDE.times do |x|
        cells[(y * SIDE) + x] = WALL if x.zero? || y.zero? || x == SIDE - 1 || y == SIDE - 1
      end
    end
    standing[(player[1] * SIDE) + player[0]] = Wolf3D::Level::FACINGS.key(facing)
    guards.each { |x, y, way| standing[(y * SIDE) + x] = Guards::STANDING + Guards::FACINGS.index(way) }
    things.each { |(x, y), code| standing[(y * SIDE) + x] = code }

    Wolf3D::Level.new(name: "Arena", width: SIDE, height: SIDE, walls: cells, things: standing)
  end

  def view_of(level)
    doors = Wolf3D::Doors.new(level, vswap)
    pushwalls = Wolf3D::Pushwalls.new(level)
    guards = Guards.new(level)
    scenery = Wolf3D::Scenery.new(level)
    atlas = Wolf3D::WallAtlas.new(vswap, palette, level, doors: doors)
    things = Wolf3D::ThingAtlas.new(vswap, palette, (guards.pictures + scenery.pictures).uniq.sort)

    RubyGBA.game("BAR", code: "ABAR", maker: "01") do
      screen :bitmap, tear_free: true
      view = Wolf3D::FirstPerson.new(build: self, level: level, atlas: atlas, doors: doors,
                                     pushwalls: pushwalls, guards: guards, things: things,
                                     scenery: scenery)
      game_loop { view.update }
    end.program
  end

  def look = Reference.new.run(view_of(arena), frames: 2)

  def watch(frames:, firing: false, **)
    Reference.new.input_each_frame { |f| firing && f.even? ? [:b] : [] }
             .run(view_of(arena(**)), frames: frames)
  end

  def field(name) = Bar::FIELDS.find { |f| f.name == name }

  # Is the field's label on the bar, in the label colour, where the layout says?
  def label_shows?(run, field)
    ink = palette[Bar::LABEL]
    y = FP::VIEW_H + Bar::LABEL_ROW
    font.text_width(field.label).times.any? do |dx|
      font.instance_variable_get(:@height).times.any? { |dy| run.screen.pixel(field.x + dx, y + dy) == ink }
    end
  end

  # READ A FIGURE BACK OFF THE SCREEN. Each digit place is matched against the font's own glyphs,
  # so what comes back is the number a player would read.
  def figure(run, name)
    f = field(name)
    left = f.x + ((font.text_width(f.label) - (f.digits * font.cell_w)) / 2)
    y = FP::VIEW_H + Bar::FIGURE_ROW
    f.digits.times.map { |place| digit_at(run, left + (place * font.cell_w), y) }.join.to_i
  end

  # Which digit is drawn here, or an empty string where the place is blank (a number is
  # right-aligned with no leading noughts).
  def digit_at(run, x, y)
    ink = palette[Bar::FIGURE]
    lit = (0...font.width).to_a.product((0...font.instance_variable_get(:@height)).to_a)
          .select { |dx, dy| run.screen.pixel(x + dx, y + dy) == ink }.to_set
    return "" if lit.empty?

    ("0".."9").find { |d| pixels_of(d) == lit } ||
      raise("the glyph at #{x},#{y} matches no digit: #{lit.to_a.sort.inspect}")
  end

  def pixels_of(digit)
    @pixels_of ||= {}
    @pixels_of[digit] ||= [].tap { |set| font.each_pixel(digit) { |dx, dy| set << [dx, dy] } }.to_set
  end

  # The colours of the two key blocks, read from the middle of each.
  def key_colours(run)
    f = field(:keys)
    wide = (Bar::METALS.length * Bar::KEY_W) + ((Bar::METALS.length - 1) * Bar::KEY_GAP)
    left = f.x + ((font.text_width(f.label) - wide) / 2)
    y = FP::VIEW_H + Bar::FIGURE_ROW - 2
    Bar::METALS.each_key.with_index.map do |_metal, n|
      run.screen.pixel(left + (n * (Bar::KEY_W + Bar::KEY_GAP)) + (Bar::KEY_W / 2), y + (Bar::KEY_H / 2))
    end
  end
end
