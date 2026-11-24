cask "macdows" do
  version "1.35,75"
  sha256 "41331323b7f6f51d6e6f694fec29f89a099415a44616ba5b6e83f270f35cabd5"

  url "https://github.com/katlianik/macdows/releases/download/v#{version.csv.first}-build#{version.csv.second}/Macdows.dmg"
  name "Macdows"
  desc "Menu-bar utility for window switching, keyboard shortcuts and Finder"
  homepage "https://astonio.com/lab/macdows/index.html"

  depends_on macos: :big_sur

  app "Macdows.app"
end
