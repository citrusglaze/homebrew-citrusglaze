class Citrusglaze < Formula
  desc "AI Security & Observability Platform — MITM proxy for AI API calls"
  homepage "https://github.com/citrusglaze/citrusglaze"
  version "0.1.7-beta"
  license "FSL-1.1-ALv2"

  if Hardware::CPU.arm?
    url "https://github.com/citrusglaze/citrusglaze/releases/download/v0.1.7-beta/citrusglaze-v0.1.7-beta-darwin-arm64.tar.gz"
    sha256 "4861f271659903297e18ebd7073bcb7d961239c4272d96264c7ed2fd099dbc2e"
  else
    odie "CitrusGlaze currently only supports Apple Silicon (arm64)"
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
      echo "Cleanup complete. Now run: brew uninstall citrusglaze"
    BASH
    (bin/"citrusglaze-brew-cleanup").chmod 0755
  end

  def post_install
    (var/"log/citrusglaze").mkpath
    (var/"run/citrusglaze").mkpath

    # Auto-run setup: dirs, CA cert, config, policies, daemon, proxy.
    # Fully non-interactive. Idempotent (safe to re-run).
    # --headless skips osascript admin prompts and CA trust installation.
    ohai "Running CitrusGlaze setup..."
    system bin/"citrusglaze", "setup", "--headless"

    # Install CA to login keychain (no admin password needed).
    # May fail silently in headless/CI environments — user can run manually.
    ca_pem = "#{Dir.home}/Library/Application Support/citrusglaze/ca.pem"
    alt_ca = "#{Dir.home}/.local/share/citrusglaze/ca.pem"
    cert = File.exist?(ca_pem) ? ca_pem : (File.exist?(alt_ca) ? alt_ca : nil)
    if cert
      ohai "Installing CA to login keychain..."
      begin
        system "security", "add-trusted-cert", "-r", "trustRoot",
               "-k", "#{Dir.home}/Library/Keychains/login.keychain-db", cert
      rescue
        opoo "CA certificate installation skipped (run manually: security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db '#{cert}')"
      end
    end
  end

  def caveats
    <<~EOS
      CitrusGlaze is installed and running!

      Verify:
        citrusglaze status

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
