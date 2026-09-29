class Omaquote < Formula
  desc "Native desktop Quote Surface for macOS"
  homepage "https://github.com/snikulin/omaquote"
  url "file:///Users/nik/pro/omaquote-macos", using: :git, branch: "main"
  version "0.1.0"

  depends_on :macos

  def install
    system "zsh", "Scripts/build-app.sh", "release", (libexec/"OmaQuote.app").to_s
    bin.install_symlink libexec/"OmaQuote.app/Contents/MacOS/omaquote"
  end

  def caveats
    <<~EOS
      Run `omaquote` to start the menu bar app. This first formula builds from
      the local checkout at /Users/nik/pro/omaquote-macos with Xcode.
    EOS
  end
end
