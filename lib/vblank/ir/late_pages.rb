# frozen_string_literal: true

module VBlank
  module IR
    # WHEN A PAGE FINISHED TOO LATE IS SHOWN, on a screen that keeps two pages and shows a
    # finished one between pictures.
    #
    # A pass of the game that misses the break it was meant for has two choices: wait for the
    # next break, which never tears but makes a frame that is a little late cost a whole one,
    # or be shown as soon as it is done, which is only as late as it really is but can tear —
    # the picture changes part way down. The game decides, per `screen`: a screen's +late+ is
    # nil to wait, or the rows above which a late page is shown at once (ANY_ROW for anywhere).
    #
    # WHAT LATE MEANS is the screen's +late_pace+: how many breaks a pass may take and be on
    # time, one for a game aiming at sixty pictures a second, two for one aiming at thirty. A
    # page that misses the break its game aims at is late; one a game aiming at thirty finishes
    # in its second frame is not, and waits like any page on time.
    #
    # It says when a page is SHOWN, never what is on it, so a backend with no breaks between
    # pictures to miss draws exactly the same game and has nothing here to read.
    class LatePages
      # Every row of the picture: a late page is shown at once wherever the picture has got to.
      ANY_ROW = Screen::HEIGHT

      # The pictures a second a game can aim at, by the breaks a pass may take for each.
      PACES = { 60 => 1, 30 => 2, 20 => 3, 15 => 4 }.freeze

      # What one screen does: +rows+ as above, nil to wait, and +pace+ in breaks a pass.
      Setting = Data.define(:rows, :pace)
      WAIT = Setting.new(rows: nil, pace: 1)

      def self.setting_of(screen) = screen&.late ? Setting.new(rows: screen.late, pace: screen.late_pace || 1) : WAIT

      def self.of(program) = new(program)

      # Is the routine named +name+ a scene? A scene draws on a screen of its own choosing, and a
      # plain routine on whatever screen is up.
      def self.scene?(name) = Modes.strip_scene_prefix(name) != name.to_s

      def initialize(program)
        @any = program.walk.any? { |node| node.kind == :screen && node.late }
        @game_screen = program.children.find { |node| node.kind == :screen }
      end

      # Does any screen in the program show a late page at once?
      def any? = @any

      # The setting of a scene whose own `screen` is +screen+ (see SceneHandover::Arrival), or the
      # game's when it has none.
      def setting_on(screen) = self.class.setting_of(screen || @game_screen)

      # ...and of the game's own screen, the one up before any scene says otherwise.
      def game_setting = setting_on(nil)
    end
  end
end
