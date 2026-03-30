class Citrusglaze < Formula
  desc "AI Security & Observability Platform — MITM proxy for AI API calls"
  homepage "https://citrusglaze.dev"
  version "0.1.8-beta"
  license "FSL-1.1-ALv2"

  if Hardware::CPU.arm?
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.8-beta/citrusglaze-v0.1.8-beta-darwin-arm64.tar.gz"
    sha256 "a83556c0bd9a57130290aff0fcea419cff05ab49b290db28d30e0ddeb7258769"
  else
    odie "CitrusGlaze currently only supports Apple Silicon (arm64)"
  end

  # Desktop app (.app bundle) — downloaded separately and installed to /Applications
  resource "app" do
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.8-beta/CitrusGlaze-v0.1.8-beta-darwin-arm64.app.zip"
    sha256 "30e1f37ba03aeed06c9752fc152962c3cdbecefec82b05e6a288bbbd2ec29402"
  end

  def install
    bin.install "citrusglaze"
    bin.install "citrusglazed"

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
      rm -rf /Applications/CitrusGlaze.app 2>/dev/null || true
      echo "Cleanup complete. Now run: brew uninstall citrusglaze"
    BASH
    (bin/"citrusglaze-brew-cleanup").chmod 0755
  end

  def post_install
    (var/"log/citrusglaze").mkpath
    (var/"run/citrusglaze").mkpath

    # ── Install .app to /Applications ──
    app_dest = Pathname.new("/Applications/CitrusGlaze.app")
    FileUtils.rm_rf(app_dest) if app_dest.exist?

    # Download and extract the .app.zip resource
    resource("app").stage do
      staged_app = Pathname.pwd/"CitrusGlaze.app"
      if staged_app.exist?
        ohai "Installing CitrusGlaze.app to /Applications..."
        FileUtils.cp_r(staged_app, app_dest)
      else
        # The zip might extract without the .app wrapper — look for Contents/
        staged_contents = Pathname.pwd/"Contents"
        if staged_contents.exist?
          ohai "Installing CitrusGlaze.app to /Applications..."
          FileUtils.mkdir_p(app_dest)
          FileUtils.cp_r(staged_contents, app_dest/"Contents")
        else
          opoo "Could not find CitrusGlaze.app in downloaded archive. Contents: #{Dir.entries(Pathname.pwd).join(', ')}"
        end
      end
    end

    if app_dest.exist? && (app_dest/"Contents/MacOS/citrusglaze-app").exist?
      ohai "Desktop app installed successfully"
      # Register with Launch Services so it appears in Spotlight immediately
      system "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister", "-f", app_dest.to_s
    else
      opoo "Desktop app installation may have failed — check /Applications/CitrusGlaze.app"
      opoo "You can manually download from: https://github.com/citrusglaze/citrusglaze/releases"
    end

    # ── Run setup wizard ──
    ohai "Running CitrusGlaze setup..."
    ohai "You may see a Touch ID / password prompt to trust the CA certificate and set the system proxy."
    system bin/"citrusglaze", "setup"

    # ── Launch the desktop app ──
    if app_dest.exist? && (app_dest/"Contents/MacOS/citrusglaze-app").exist?
      ohai "Launching CitrusGlaze..."
      system "open", app_dest.to_s
    end
  end

  def caveats
    <<~EOS
      Setup complete! Verify with:
        citrusglaze status

      Desktop app installed to /Applications/CitrusGlaze.app
      Open it from Spotlight, Launchpad, or: open /Applications/CitrusGlaze.app

      If setup was interrupted or you skipped a prompt, re-run:
        citrusglaze setup

      Protect an AI tool:
        citrusglaze wrap claude
        citrusglaze wrap python my_agent.py

      Start daemon on login:
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
