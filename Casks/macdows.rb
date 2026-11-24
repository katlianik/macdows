cask "macdows" do
  version "1.35,76"
  sha256 "6f47eec49c21c0a3f545aff7d3a132dbe0d3763b192100085f4a67b39c1b5338"

  url "https://github.com/katlianik/macdows/releases/download/v#{version.csv.first}-build#{version.csv.second}/Macdows.dmg"
  name "Macdows"
  desc "Menu-bar utility for window switching, keyboard shortcuts and Finder"
  homepage "https://astonio.com/lab/macdows/index.html"

  depends_on macos: :big_sur

  app "Macdows.app"
end
