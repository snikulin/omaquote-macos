class Omaquote < Formula
  desc "Native desktop Quote Surface for macOS"
  homepage "https://github.com/snikulin/omaquote-macos"
  url "https://github.com/snikulin/omaquote-macos.git", using: :git, tag: "v0.1.3"
  version "0.1.3"

  depends_on :macos

  def install
    system "zsh", "Scripts/build-app.sh", "release", (libexec/"OmaQuote.app").to_s
    bin.install_symlink libexec/"OmaQuote.app/Contents/MacOS/omaquote"
  end

  def caveats
    <<~EOS
      Run `omaquote` to start the menu bar app. Xcode 26.6 or later is required to build
      the app from source. The app is not notarized.
    EOS
  end
end
