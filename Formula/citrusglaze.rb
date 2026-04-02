class Citrusglaze < Formula
  desc "AI Security & Observability Platform — MITM proxy for AI API calls"
  homepage "https://citrusglaze.dev"
  version "0.1.12-beta"
  license "FSL-1.1-ALv2"

  if Hardware::CPU.arm?
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.12-beta/citrusglaze-v0.1.12-beta-darwin-arm64.tar.gz"
    sha256 "f1f3bc7642b7d93abe04a11d854cb69bf2468c5024376c80dfe15b9da431ce1b"
  else
    odie "CitrusGlaze currently only supports Apple Silicon (arm64)"
  end

  resource "desktop_app" do
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.12-beta/CitrusGlaze-v0.1.12-beta-darwin-arm64.app.zip"
    sha256 "db0c51a18177c4fd16354b39e3fd215c98c78ff9787d964f4d19abc68337b102"
  end

  resource "chrome_extension" do
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.12-beta/citrusglaze-extension-v0.1.2.4.zip"
    sha256 "3453e8b2068cde90151eb7d8882721abcd79081d0bde055fe8c42a009d90c928"
  end

  def install
    bin.install "citrusglaze"
    bin.install "citrusglazed"

    # Extract desktop app into Cellar so post_install can copy to /Applications.
    # Using resource blocks ensures Homebrew handles the download (not blocked by sandbox).
    resource("desktop_app").stage do
      app_staged = Pathname.pwd/"CitrusGlaze.app"
      if app_staged.exist?
        (prefix/"CitrusGlaze.app").install Dir[app_staged/"*"]
      else
        # Fallback: zip extracted Contents/ directly
        contents_staged = Pathname.pwd/"Contents"
        if contents_staged.exist?
          (prefix/"CitrusGlaze.app/Contents").install Dir[contents_staged/"*"]
        else
          opoo "Could not find CitrusGlaze.app in archive"
        end
      end
    end

    # Stage extension zip into Cellar; post_install copies to ~/.citrusglaze/
    resource("chrome_extension").stage do
      (prefix/"chrome-extension").install Dir["*"]
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

    # ── Copy .app from Cellar to /Applications ──
    app_source = prefix/"CitrusGlaze.app"
    app_dest = Pathname.new("/Applications/CitrusGlaze.app")

    if app_source.exist? && (app_source/"Contents/MacOS/citrusglaze-app").exist?
      ohai "Installing CitrusGlaze.app to /Applications..."
      system "rm", "-rf", app_dest.to_s
      system "cp", "-R", app_source.to_s, app_dest.to_s

      if app_dest.exist?
        # Strip quarantine flag so Gatekeeper doesn't block the unsigned app
        system "xattr", "-cr", app_dest.to_s
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

    # ── Copy Chrome extension from Cellar to ~/.citrusglaze/ ──
    ext_source = prefix/"chrome-extension"
    ext_dir = "#{Dir.home}/.citrusglaze/chrome-extension"
    # Migrate from old location if it exists
    old_ext_dir = "#{Dir.home}/Library/Application Support/citrusglaze/chrome-extension"
    if File.directory?(old_ext_dir) && !File.directory?(ext_dir)
      system "mkdir", "-p", "#{Dir.home}/.citrusglaze"
      system "mv", old_ext_dir, ext_dir
      ohai "Migrated extension from #{old_ext_dir} → #{ext_dir}"
    end
    if ext_source.exist?
      # Atomic swap so Chrome doesn't see a missing extension during reinstall
      ext_tmp = "#{ext_dir}.new"
      system "rm", "-rf", ext_tmp
      system "mkdir", "-p", ext_tmp
      system "cp", "-R", *Dir[ext_source/"*"], ext_tmp
      # If the zip contained a dist/ subfolder, flatten it
      if File.directory?("#{ext_tmp}/dist")
        system "cp", "-R", *Dir["#{ext_tmp}/dist/*"], ext_tmp
        system "rm", "-rf", "#{ext_tmp}/dist"
      end
      system "rm", "-rf", "#{ext_dir}.old"
      system "mv", ext_dir, "#{ext_dir}.old" if File.directory?(ext_dir)
      system "mv", ext_tmp, ext_dir
      system "rm", "-rf", "#{ext_dir}.old"
      ohai "Chrome extension installed to #{ext_dir}"
    else
      opoo "Chrome extension not found in Cellar"
      system "mkdir", "-p", ext_dir unless File.directory?(ext_dir)
    end

    # ── Schedule app launch + Finder open FIRST ──
    # Deferred background process fires after Homebrew finishes, even if later
    # steps (setup, CA install) fail or hang.
    deferred_cmds = []
    if app_dest.exist?
      deferred_cmds << "open '#{app_dest}'"
    end
    if File.directory?(ext_dir) && !Dir.empty?(ext_dir)
      ohai "In Chrome: Extensions → Load unpacked → select the highlighted folder"
      deferred_cmds << "open -R '#{ext_dir}'"
    end
    unless deferred_cmds.empty?
      ohai "Will launch app and open extension folder after install completes..."
      script = "(sleep 3 && #{deferred_cmds.join(' && ')}) &"
      system "bash", "-c", script
    end

    # ── Remove toxic HTTPS_PROXY/HTTP_PROXY from shell profiles ──
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
    system "launchctl", "unsetenv", "HTTPS_PROXY"
    system "launchctl", "unsetenv", "HTTP_PROXY"

    # ── Stop old daemon, run setup, install CA ──
    system "pkill", "-f", "citrusglazed"
    # Wait for daemon to fully exit (up to 5s) before starting a new one
    5.times do
      break unless quiet_system("pgrep", "-qf", "citrusglazed")
      sleep 1
    end

    ohai "Running CitrusGlaze setup..."
    system bin/"citrusglaze", "setup", "--headless", "--skip-trust"

    # Install CA to login keychain (no admin needed)
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

    # Configure PAC proxy (only AI traffic routed through CitrusGlaze).
    # Try direct first (no admin needed on some macOS versions).
    pac_url = "http://127.0.0.1:8888/proxy.pac"
    iface = `networksetup -listallnetworkservices 2>/dev/null`.lines
              .reject { |l| l.start_with?("An asterisk") || l.strip.empty? }
              .map(&:strip).first || "Wi-Fi"
    if system "networksetup", "-setautoproxyurl", iface, pac_url
      ohai "PAC proxy configured on #{iface} → #{pac_url}"
    else
      ohai "To complete setup (system proxy), run in a terminal:"
      ohai "  citrusglaze setup"
    end
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
