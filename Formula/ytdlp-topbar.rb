class YtdlpTopbar < Formula
  desc "YouTube downloader for macOS menu bar"
  homepage "https://github.com/core6quad/ytdlp-topbar"
  url "https://github.com/core6quad/ytdlp-topbar/releases/download/v0.1.0/ytdlp-topbar.tar.gz"
  sha256 "REPLACE_WITH_SHA256"
  license "MIT"

  def install
    bin.install "ytdlp-topbar"
    prefix.install "ytdlp-topbar.app" if File.exist?("ytdlp-topbar.app")
  end

  def caveats
    <<~EOS
      To launch the menu bar app, run:
        ytdlp-topbar

      Or, open the app bundle:
        open #{opt_prefix}/ytdlp-topbar.app

      If you want the app to start at login, use the Options menu.
    EOS
  end
end
