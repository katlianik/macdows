cask "macdows" do
  version "1.35,74"
  sha256 "e6bb4c4558e200b7dd06a1faf1d770518498e92f1065908a2a99d3e99bf58e44"

  url "https://github.com/katlianik/macdows/releases/download/v#{version.csv.first}-build#{version.csv.second}/Macdows.dmg"
  name "Macdows"
  desc "Menu-bar utility for window switching, keyboard shortcuts and Finder"
  homepage "https://astonio.com/lab/macdows/index.html"

  depends_on macos: :big_sur

  app "Macdows.app"
end
