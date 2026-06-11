# Homebrew cask for Linko.
#
# This file is the source of truth for the published cask. On every stable
# GitHub Release (`v*` tag, non-prerelease), `.github/workflows/update-cask.yml`
# substitutes `version` + `sha256` via `scripts/render-cask.sh` and pushes the
# rendered cask to `wanggang316/homebrew-tap` so that
# `brew install --cask wanggang316/tap/linko` resolves to the latest DMG.
#
# Sparkle handles in-app updates after install; `auto_updates true` tells
# Homebrew not to flag the post-Sparkle on-disk version as drift.
cask "linko" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/wanggang316/linko/releases/download/v#{version}/Linko-#{version}.dmg",
      verified: "github.com/wanggang316/linko/"
  name "Linko"
  desc "Native macOS proxy client powered by sing-box"
  homepage "https://github.com/wanggang316/linko"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Linko.app"

  zap trash: [
    "~/Library/Application Support/Linko",
    "~/Library/Caches/com.gumpw.linko",
    "~/Library/HTTPStorages/com.gumpw.linko",
    "~/Library/Preferences/com.gumpw.linko.plist",
    "~/Library/Saved Application State/com.gumpw.linko.savedState",
  ]

  caveats <<~EOS
    Linko 的 TUN 全局模式依赖一个系统扩展。卸载前请在 App 内停用，
    必要时可用 `systemextensionsctl reset`(需关闭 SIP)清理残留。
  EOS
end
