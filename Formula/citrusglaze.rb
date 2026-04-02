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

  # Chrome extension staged in Cellar; cask or `citrusglaze setup` copies to ~/.citrusglaze/
  resource "chrome_extension" do
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.12-beta/citrusglaze-extension-v0.1.2.4.zip"
    sha256 "3453e8b2068cde90151eb7d8882721abcd79081d0bde055fe8c42a009d90c928"
  end

  def install
    bin.install "citrusglaze"
    bin.install "citrusglazed"

    # Stage extension in Cellar so the cask's postflight or `citrusglaze setup` can copy it
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

    # ── Stop any old daemon before starting the service ──
    system "pkill", "-f", "citrusglazed"
    5.times do
      break unless quiet_system("pgrep", "-qf", "citrusglazed")
      sleep 1
    end

    # ── Generate CA + config (don't start daemon — brew services handles that) ──
    # Run setup in headless mode, skip trust (we handle CA below), skip daemon start.
    # Setup creates dirs, generates CA, writes config, copies policies.
    ohai "Running CitrusGlaze setup..."
    system bin/"citrusglaze", "setup", "--headless", "--skip-trust"
    # Setup may fail to start daemon inside sandbox — that's expected.
    # brew services will start it properly below.

    # Install CA to login keychain (no admin needed, not sandboxed)
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

    # ── Start daemon via brew services (proper launchd, survives post_install sandbox) ──
    ohai "Starting CitrusGlaze daemon..."
    system "brew", "services", "start", "citrusglaze/citrusglaze/citrusglaze"

    # Wait for daemon to be ready
    ready = false
    10.times do
      sleep 1
      if File.exist?("/tmp/citrusglaze/daemon.sock")
        ready = true
        break
      end
    end

    if ready
      ohai "Daemon started successfully"

      # Configure PAC proxy now that daemon is listening
      pac_url = "http://127.0.0.1:8888/proxy.pac"
      iface = `networksetup -listallnetworkservices 2>/dev/null`.lines
                .reject { |l| l.start_with?("An asterisk") || l.strip.empty? }
                .map(&:strip).first || "Wi-Fi"
      if system "networksetup", "-setautoproxyurl", iface, pac_url
        ohai "PAC proxy configured on #{iface} → #{pac_url}"
      else
        ohai "To configure system proxy, run: citrusglaze setup"
      end
    else
      opoo "Daemon did not start in time. Start manually:"
      opoo "  brew services start citrusglaze"
    end
  end

  def caveats
    <<~EOS
      CLI + daemon installed. To add the desktop app and Chrome extension:
        brew install --cask citrusglaze-app

      Verify setup:
        citrusglaze status

      Protect an AI tool:
        citrusglaze wrap claude
        citrusglaze wrap python my_agent.py

      If setup was interrupted or you skipped a prompt, re-run:
        citrusglaze setup

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
