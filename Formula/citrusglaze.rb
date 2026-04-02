class Citrusglaze < Formula
  desc "AI Security & Observability Platform — MITM proxy for AI API calls"
  homepage "https://citrusglaze.dev"
  version "0.1.10-beta"
  license "FSL-1.1-ALv2"

  if Hardware::CPU.arm?
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.10-beta/citrusglaze-v0.1.10-beta-darwin-arm64.tar.gz"
    sha256 "b4168b6eae38e0c6ed9d362f1a25a7b2e9637c086624254344d2ba901e41d5a8"
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
    if File.exist?("#{buildpath}/#{app_zip}")
      system "unzip", "-q", "#{buildpath}/#{app_zip}", "-d", "#{buildpath}/app"
    else
      opoo "Failed to download desktop app — it can be installed later via `citrusglaze setup`"
    end

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

    # Download and extract Chrome extension to ~/.citrusglaze/chrome-extension/
    # Dotfile convention — predictable path, easy to find.
    # Users "Load unpacked" once, then just hit Refresh on upgrades.
    ext_zip = "citrusglaze-extension-v0.1.2.4.zip"
    ext_url = "https://github.com/citrusglaze/citrusglaze/releases/download/v#{version}/#{ext_zip}"
    ext_dir = "#{Dir.home}/.citrusglaze/chrome-extension"
    # Migrate from old location if it exists
    old_ext_dir = "#{Dir.home}/Library/Application Support/citrusglaze/chrome-extension"
    if File.directory?(old_ext_dir) && !File.directory?(ext_dir)
      system "mkdir", "-p", "#{Dir.home}/.citrusglaze"
      system "mv", old_ext_dir, ext_dir
      ohai "Migrated extension from #{old_ext_dir} → #{ext_dir}"
    end
    system "curl", "-fsSL", "-o", "#{buildpath}/#{ext_zip}", ext_url
    if File.exist?("#{buildpath}/#{ext_zip}")
      system "rm", "-rf", ext_dir
      system "mkdir", "-p", ext_dir
      system "unzip", "-q", "-o", "#{buildpath}/#{ext_zip}", "-d", ext_dir
    else
      opoo "Failed to download Chrome extension — skipping"
      system "mkdir", "-p", ext_dir unless File.directory?(ext_dir)
    end
    # If the zip contains a dist/ subfolder, flatten it
    if File.directory?("#{ext_dir}/dist")
      system "cp", "-R", *Dir["#{ext_dir}/dist/*"], ext_dir
      system "rm", "-rf", "#{ext_dir}/dist"
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
      ohai "Installing CitrusGlaze.app to /Applications..."
      system "rm", "-rf", app_dest.to_s
      system "cp", "-R", app_source.to_s, app_dest.to_s

      if app_dest.exist?
        # Register with Launch Services so it appears in Spotlight
        system "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister", "-f", app_dest.to_s
        ohai "Desktop app installed to /Applications"
      else
        opoo "Failed to copy app to /Applications. Run manually:"
        opoo "  cp -R #{app_source} /Applications/"
      end
    else
      opoo "Desktop app not found in Cellar — download manually from:"
      opoo "  https://github.com/citrusglaze/citrusglaze/releases/latest"
    end

    # ── Schedule app launch + Finder open FIRST ──
    # These run in a deferred background process (sleep 3) so they fire after
    # Homebrew finishes. Scheduled early so they happen even if later steps
    # (setup, CA install) fail or hang.
    deferred_cmds = []
    if app_dest.exist?
      deferred_cmds << "open '#{app_dest}'"
    end
    ext_dir = "#{Dir.home}/.citrusglaze/chrome-extension"
    if File.directory?(ext_dir)
      ohai "In Chrome: Extensions → Load unpacked → select the highlighted folder"
      deferred_cmds << "open -R '#{ext_dir}'"
    end
    unless deferred_cmds.empty?
      ohai "Will launch app and open extension folder after install completes..."
      script = "(sleep 3 && #{deferred_cmds.join(' && ')}) &"
      system "bash", "-c", script
    end

    # ── Remove toxic HTTPS_PROXY/HTTP_PROXY from shell profiles ──
    # Old versions of citrusglaze setup injected these, which breaks Claude Code.
    # Do this in the formula directly so it happens even if setup errors out.
    for profile in [
      "#{Dir.home}/.zshrc",
      "#{Dir.home}/.bashrc",
      "#{Dir.home}/.bash_profile",
    ]
      next unless File.exist?(profile)
      content = File.read(profile)
      next unless content.include?("CitrusGlaze: HTTPS_PROXY") || content.include?("CitrusGlaze: HTTP_PROXY")
      ohai "Removing stale HTTPS_PROXY/HTTP_PROXY from #{profile}..."
      cleaned = content.lines.reject { |l|
        l.include?("CitrusGlaze: HTTPS_PROXY") ||
        l.include?("CitrusGlaze: HTTP_PROXY") ||
        (l.strip.start_with?("export HTTPS_PROXY=") && content.include?("CitrusGlaze: HTTPS_PROXY")) ||
        (l.strip.start_with?("export HTTP_PROXY=") && content.include?("CitrusGlaze: HTTP_PROXY"))
      }.join
      File.write(profile, cleaned)
    end
    # Also clear from current session's launchctl
    system "launchctl", "unsetenv", "HTTPS_PROXY"
    system "launchctl", "unsetenv", "HTTP_PROXY"

    # Stop any running daemon so it picks up the new binary on restart.
    # Harmless on fresh install (nothing to stop).
    system "pkill", "-f", "citrusglazed"
    sleep 1

    # Run setup wizard in headless mode (dirs, CA gen, config, policies, daemon, proxy).
    # --skip-trust: osascript can't show GUI dialogs inside brew post_install, so we
    # handle CA installation ourselves below via `security add-trusted-cert`.
    ohai "Running CitrusGlaze setup..."
    system bin/"citrusglaze", "setup", "--headless", "--skip-trust"

    # Install CA to login keychain (no admin password needed — works non-interactively)
    ca_pem = "#{Dir.home}/Library/Application Support/citrusglaze/ca.pem"
    alt_ca = "#{Dir.home}/.local/share/citrusglaze/ca.pem"
    cert = File.exist?(ca_pem) ? ca_pem : (File.exist?(alt_ca) ? alt_ca : nil)
    if cert
      ohai "Installing CA certificate to login keychain..."
      if system "security", "add-trusted-cert", "-r", "trustRoot",
                "-k", "#{Dir.home}/Library/Keychains/login.keychain-db", cert
        ohai "CA certificate installed successfully"
      else
        opoo "CA certificate installation failed. Run manually:"
        opoo "  citrusglaze setup"
      end
    else
      opoo "CA certificate not found — run `citrusglaze setup` to generate and install it"
    end

    # Set system proxy (PAC) — needs interactive admin dialog
    ohai "To complete setup (system proxy + System Keychain CA), run in a terminal:"
    ohai "  citrusglaze setup"
  end

  def caveats
    <<~EOS
      Setup complete! Verify with:
        citrusglaze status

      Desktop app installed to /Applications/CitrusGlaze.app
      Open it from Spotlight, Launchpad, or: open /Applications/CitrusGlaze.app

      Chrome extension extracted to:
        ~/.citrusglaze/chrome-extension
      Load it once: Chrome → Extensions → Load unpacked → select that folder
      (Finder opened automatically after install)
      On upgrades, just click Refresh on the extension card.

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
