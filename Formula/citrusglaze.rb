class Citrusglaze < Formula
  desc "AI Security & Observability Platform — MITM proxy for AI API calls"
  homepage "https://citrusglaze.dev"
  version "0.1.7-beta"
  license "FSL-1.1-ALv2"

  if Hardware::CPU.arm?
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.7-beta/citrusglaze-v0.1.7-beta-darwin-arm64.tar.gz"
    sha256 "4861f271659903297e18ebd7073bcb7d961239c4272d96264c7ed2fd099dbc2e"
  else
    odie "CitrusGlaze currently only supports Apple Silicon (arm64)"
  end

  # Desktop app (.app bundle) — downloaded separately and installed to /Applications
  resource "app" do
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.7-beta/CitrusGlaze-v0.1.7-beta-darwin-arm64.app.zip"
    sha256 "60e738fe9bdfc100eceec4a7d8db4b082267edbb52b8c03bc0e7af1dfe50c05a"
  end

  def install
    bin.install "citrusglaze"
    bin.install "citrusglazed"

    # Install the desktop app to /Applications
    resource("app").stage do
      (prefix/"CitrusGlaze.app").install Dir["CitrusGlaze.app/*"]
    end

    (bin/"citrusglaze-brew-cleanup").write <<~BASH
      #!/bin/bash
      if command -v citrusglaze &>/dev/null; then
        echo "yes" | citrusglaze uninstall
      else
        pkill -f citrusglazed 2>/dev/null || true
        for label in com.citrusglaze.daemon com.citrusglaze.orchestrator; do
          plist="$HOME/Library/LaunchAgents/${label}.plist"
          [ -f "$plist" ] && launchctl unload "$plist" 2>/dev/null && rm -f "$plist"
        done
      fi
      rm -f /Applications/CitrusGlaze.app 2>/dev/null || true
      echo "Cleanup complete. Now run: brew uninstall citrusglaze"
    BASH
    (bin/"citrusglaze-brew-cleanup").chmod 0755
  end

  def post_install
    (var/"log/citrusglaze").mkpath
    (var/"run/citrusglaze").mkpath

    # Copy the .app into /Applications so it shows up in Spotlight/Launchpad
    app_source = prefix/"CitrusGlaze.app"
    app_dest = Pathname.new("/Applications/CitrusGlaze.app")
    if app_source.exist?
      ohai "Installing CitrusGlaze.app to /Applications..."
      FileUtils.rm_rf(app_dest) if app_dest.exist?
      FileUtils.cp_r(app_source, app_dest)
      # Register with Launch Services so it appears in Spotlight immediately
      system "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister", "-f", app_dest.to_s
    end

    # Run setup interactively — generates CA, trusts it, starts daemon,
    # configures system proxy (Touch ID prompt), installs launchd agent.
    # Safe to re-run (idempotent — skips steps already done).
    ohai "Running CitrusGlaze setup..."
    ohai "You may see a Touch ID / password prompt to trust the CA certificate and set the system proxy."
    system bin/"citrusglaze", "setup"

    # Launch the desktop app (menu bar icon + dashboard)
    app_dest = Pathname.new("/Applications/CitrusGlaze.app")
    if app_dest.exist?
      ohai "Launching CitrusGlaze desktop app..."
      system "open", app_dest.to_s
    end
  end

  def caveats
    <<~EOS
      Setup complete! Verify with:
        citrusglaze status

      Desktop app installed to /Applications/CitrusGlaze.app
      Open it from Spotlight or Launchpad.

      If setup was interrupted or you skipped a prompt, re-run:
        citrusglaze setup

      Protect an AI tool:
        citrusglaze wrap claude
        citrusglaze wrap python my_agent.py

      Start on login:
        brew services start citrusglaze

      Search all AI conversations (add to .mcp.json):
        {"mcpServers":{"citrusglaze-recall":{"command":"citrusglaze","args":["mcp-server"]}}}

      Uninstall:
        citrusglaze-brew-cleanup && brew uninstall citrusglaze
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
