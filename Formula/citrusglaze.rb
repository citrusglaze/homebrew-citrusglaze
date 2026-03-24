class Citrusglaze < Formula
  desc "AI Security & Observability Platform — MITM proxy for AI API calls"
  homepage "https://github.com/citrusglaze/citrusglaze"
  version "0.1.0"
  license "Apache-2.0"

  if Hardware::CPU.arm?
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.0/citrusglaze-v0.1.0-darwin-arm64.tar.gz"
    sha256 "d2479cbda8f8d552312dfb8eec92fbe63791ae54715e986d443140587fbd8dc3"
  else
    # Intel builds will be added when CI produces them
    odie "CitrusGlaze currently only supports Apple Silicon (arm64)"
  end

  def install
    bin.install "citrusglaze"
    bin.install "citrusglazed"

    # Install uninstall helper
    (bin/"citrusglaze-brew-cleanup").write <<~BASH
      #!/bin/bash
      # Run BEFORE `brew uninstall citrusglaze`
      if command -v citrusglaze &>/dev/null; then
        echo "yes" | citrusglaze uninstall
      else
        pkill -f citrusglazed 2>/dev/null || true
        for label in com.citrusglaze.daemon com.citrusglaze.orchestrator; do
          plist="$HOME/Library/LaunchAgents/${label}.plist"
          [ -f "$plist" ] && launchctl unload "$plist" 2>/dev/null && rm -f "$plist"
        done
      fi
      echo "Cleanup complete. Now run: brew uninstall citrusglaze"
    BASH
    (bin/"citrusglaze-brew-cleanup").chmod 0755
  end

  def post_install
    (var/"log/citrusglaze").mkpath
    (var/"run/citrusglaze").mkpath
  end

  def caveats
    <<~EOS
      To complete setup, run:
        citrusglaze setup

      To start as a background service:
        brew services start citrusglaze

      Before uninstalling:
        citrusglaze-brew-cleanup
        brew uninstall citrusglaze
    EOS
  end

  service do
    run [opt_bin/"citrusglazed"]
    keep_alive true
    log_path var/"log/citrusglaze/daemon.log"
    error_log_path var/"log/citrusglaze/daemon.err"
    environment_variables RUST_LOG: "info"
  end

  test do
    assert_match "citrusglaze", shell_output("#{bin}/citrusglaze --help")
  end
end
