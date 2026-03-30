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

  def install
    bin.install "citrusglaze"
    bin.install "citrusglazed"

    # Download and extract the desktop app during install (not post_install)
    app_zip = "CitrusGlaze-v#{version}-darwin-arm64.app.zip"
    app_url = "https://github.com/citrusglaze/citrusglaze/releases/download/v#{version}/#{app_zip}"
    system "curl", "-fsSL", "-o", "#{buildpath}/#{app_zip}", app_url
    system "unzip", "-q", "#{buildpath}/#{app_zip}", "-d", "#{buildpath}/app"

    # Store the .app in the Cellar so post_install can copy to /Applications
    app_staged = buildpath/"app/CitrusGlaze.app"
    if app_staged.exist?
      (prefix/"CitrusGlaze.app").install Dir[app_staged/"*"]
    else
      # Fallback: zip extracted Contents/ directly
      contents_staged = buildpath/"app/Contents"
      if contents_staged.exist?
        (prefix/"CitrusGlaze.app/Contents").install Dir[contents_staged/"*"]
      else
        opoo "Could not find CitrusGlaze.app in archive"
      end
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
      rm -rf /Applications/CitrusGlaze.app 2>/dev/null || true
      echo "Cleanup complete. Now run: brew uninstall citrusglaze"
    BASH
    (bin/"citrusglaze-brew-cleanup").chmod 0755
  end

  def post_install
    (var/"log/citrusglaze").mkpath
    (var/"run/citrusglaze").mkpath

    # Copy .app from Cellar to /Applications
    app_source = prefix/"CitrusGlaze.app"
    app_dest = Pathname.new("/Applications/CitrusGlaze.app")

    if app_source.exist? && (app_source/"Contents/MacOS/citrusglaze-app").exist?
      FileUtils.rm_rf(app_dest) if app_dest.exist?
      ohai "Installing CitrusGlaze.app to /Applications..."
      FileUtils.cp_r(app_source, app_dest)

      # Register with Launch Services so it appears in Spotlight
      system "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister", "-f", app_dest.to_s
      ohai "Desktop app installed"
    else
      opoo "Desktop app not found in Cellar — download manually from:"
      opoo "  https://github.com/citrusglaze/citrusglaze/releases/latest"
    end

    # Run setup wizard (interactive — Touch ID prompts for CA + proxy)
    ohai "Running CitrusGlaze setup..."
    ohai "You may see a Touch ID / password prompt to trust the CA certificate and set the system proxy."
    system bin/"citrusglaze", "setup"

    # Launch the desktop app
    if app_dest.exist?
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
