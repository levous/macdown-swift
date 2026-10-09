cask "levous-macdown" do
  version "1.0"
  sha256 "14ac59adc0144f9a71cd3ac354869f368fa59bc2845a93a92b391971aa7130a3"

  url "https://github.com/levous/macdown-swift/releases/download/v#{version}/MacDown-#{version}.zip"
  name "MacDown"
  desc "Markdown editor with live preview and syntax highlighting"
  homepage "https://github.com/levous/macdown-swift"

  livecheck do
    url :url
    strategy :github_latest
  end

  conflicts_with cask: "macdown"
  depends_on macos: :sequoia

  app "MacDown.app"
  binary "#{appdir}/MacDown.app/Contents/SharedSupport/bin/macdown"

  uninstall quit: "io.github.levous.macdown-swift"

  zap trash: [
    "~/Library/Preferences/io.github.levous.macdown-swift.plist",
    "~/Library/Saved Application State/io.github.levous.macdown-swift.savedState",
  ]
end
