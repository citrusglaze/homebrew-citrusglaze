class Citrusglaze < Formula
  desc "AI Security & Observability Platform — MITM proxy for AI API calls"
  homepage "https://citrusglaze.dev"
  version "0.2.5-experimental"
  license "FSL-1.1-ALv2"

  if Hardware::CPU.arm?
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.2.5-experimental/citrusglaze-v0.2.5-experimental-darwin-arm64.tar.gz"
    sha256 "ce9a2682a5b3d594c208fe2ed6c4217e2b24da90b7af24ed9cf00816954acca0"
  else
    odie "CitrusGlaze currently only supports Apple Silicon (arm64)"
  end

  # Chrome extension staged in Cellar; cask or `citrusglaze setup` copies to ~/.citrusglaze/
  resource "chrome_extension" do
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.2.5-experimental/citrusglaze-extension-v0.1.2.4.zip"
    sha256 "3d6233d6f8371109bc0c527021a7f553d50935745dbada70eaf101ef2491fc64"
  end

  def install
    bin.install "citrusglaze"
    bin.install "cg"
    bin.install "citrusglazed"
    bin.install "citrusglaze-pf-helper"

    # Ship the LaunchDaemon plist so setup.rs can find and install it
    (share/"citrusglaze").install "com.citrusglaze.pf-helper.plist"

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
    quiet_system "launchctl", "unsetenv", "HTTPS_PROXY"
    quiet_system "launchctl", "unsetenv", "HTTP_PROXY"

    # ── Generate CA + config (no daemon start — sandbox kills processes) ──
    # Setup creates dirs, generates CA, writes config, copies policies.
    # Daemon start + PF helper install are handled by the cask's postflight (not sandboxed).
    quiet_system "pkill", "-f", "citrusglazed"
    ohai "Running CitrusGlaze setup (directories, CA, config, policies)..."
    quiet_system bin/"citrusglaze", "setup", "--headless", "--skip-trust"

    # Install CA to login keychain (no admin needed)
    ca_pem = "#{Dir.home}/Library/Application Support/citrusglaze/ca.pem"
    alt_ca = "#{Dir.home}/.local/share/citrusglaze/ca.pem"
    cert = File.exist?(ca_pem) ? ca_pem : (File.exist?(alt_ca) ? alt_ca : nil)
    if cert
      ohai "Installing CA certificate to login keychain..."
      if quiet_system "security", "add-trusted-cert", "-r", "trustRoot",
                      "-k", "#{Dir.home}/Library/Keychains/login.keychain-db", cert
        ohai "CA certificate installed successfully"
      else
        opoo "CA certificate installation failed. Run: citrusglaze setup"
      end
    else
      opoo "CA certificate not found — run `citrusglaze setup` to generate and install it"
    end

    # NOTE: Daemon is NOT started here — post_install is sandboxed and kills processes on exit.
    # The cask postflight starts the daemon, or user runs: brew services start citrusglaze
  end

  def caveats
    <<~EOS
      CLI + daemon installed. To add the desktop app and Chrome extension:
        brew install --cask citrusglaze-app

      First-time setup (installs CA, PF helper, starts daemon):
        citrusglaze setup

      The setup wizard will prompt once for your admin password to install the
      kernel-level network security helper. This helper intercepts AI traffic
      at the OS level — no proxy env vars needed, works with any app.

      Verify setup:
        citrusglaze status

      Protect an AI tool with full sandboxing:
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
