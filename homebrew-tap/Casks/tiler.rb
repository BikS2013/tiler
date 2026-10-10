cask "tiler" do
  version "0.4.0"
  sha256 "1b660b6ce8b9b293cc1524410207d32f456e6ff9f427d91c56106f2e7eae5aa2"

  url "https://github.com/BikS2013/tiler/releases/download/v#{version}/Tiler-#{version}.zip"
  name "Tiler"
  desc "Menu bar tiling window manager for one desktop at a time"
  homepage "https://github.com/BikS2013/tiler"

  depends_on macos: :sonoma

  app "Tiler.app"

  postflight_steps do
    run "/usr/bin/osascript",
        args: [
          "-e",
          'display notification "Open Tiler and allow Accessibility when asked." with title "Tiler installed"',
        ]
  end

  uninstall quit: "com.giorgosmarinos.tiler"

  zap trash: "~/Library/Application Support/Tiler"

  caveats <<~EOS
    First launch: open Tiler (menu bar icon, no Dock icon) and allow Accessibility:
      System Settings > Privacy & Security > Accessibility > enable Tiler
    It is the only permission Tiler needs.

    Tile a desktop: menu bar icon > Tile This Desktop, or Ctrl+Cmd+P.
    Only that desktop on that display is tiled; everything else is left alone.

    Show every shortcut: Ctrl+Cmd+/   Settings: menu bar icon > Settings...
    Move or resize any untiled window with the keyboard: Ctrl+Cmd+M, then arrows
    (Shift resizes, Option = fine, C centre, M fill, Return done).
    Focus follows mouse (optional): menu bar icon > Focus Follows Mouse.
    Upgrading: Settings > General > Add Missing Settings (adds new settings only).
    Launch at login: Settings > General.

    Decks: https://biks2013.github.io/tiler/
  EOS
end
