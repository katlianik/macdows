cask "macdows" do
  version "1.35,73"
  sha256 "2ed321a9c0a3efab4ee283b9dee255d7006f84f9adc30c252389981c3d39e53b"

  url "https://github.com/katlianik/macdows/releases/download/v#{version.csv.first}-build#{version.csv.second}/Macdows.dmg"
  name "Macdows"
  desc "Menu-bar utility for window switching, keyboard shortcuts and Finder"
  homepage "https://astonio.com/lab/macdows/index.html"

  depends_on macos: ">= :big_sur"

  app "Macdows.app"
end
