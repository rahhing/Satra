cask "satra" do
  version "2.25.0"
  sha256 "74eebe378496d87b6c2d675ebfa8cf399301799445f57f160df0a46a7e54fa9d"

  url "https://github.com/rahhing/Satra/releases/download/#{version}/plezy-macos.dmg"
  name "Satra"
  desc "Modern Plex and Jellyfin client built with Flutter"
  homepage "https://github.com/rahhing/Satra"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true

  app "Satra.app"

  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-cr", "{{appdir}}/Satra.app"],
        sudo: false
  end

  uninstall quit: "com.rahhing.satra"

  zap trash: [
    "~/Library/Application Support/com.rahhing.satra",
    "~/Library/Caches/com.rahhing.satra",
    "~/Library/HTTPStorages/com.rahhing.satra",
    "~/Library/Preferences/com.rahhing.satra.plist",
    "~/Library/Saved Application State/com.rahhing.satra.savedState",
    "~/Library/WebKit/com.rahhing.satra",
  ]
end
