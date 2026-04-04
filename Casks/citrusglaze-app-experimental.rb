cask "citrusglaze-app-experimental" do
  version "0.1.15-beta"
  sha256 "b8dde9c4dab8a7911fc5dc9afd97166332a14bfa658bd442813d51c916e262c2"

  url "https://github.com/citrusglaze/citrusglaze/releases/download/v#{version}/CitrusGlaze-v#{version}-darwin-arm64.app.zip"
  name "CitrusGlaze (Experimental)"
  desc "AI Security & Observability — experimental desktop dashboard"
  homepage "https://citrusglaze.dev"

  depends_on formula: "citrusglaze/citrusglaze/citrusglaze-experimental"

  conflicts_with cask: "citrusglaze-app"

  app "CitrusGlaze.app"

  postflight do
    # Copy Chrome extension from formula's Cellar
    ext_source = "#{HOMEBREW_PREFIX}/opt/citrusglaze-experimental/chrome-extension"
    ext_dir = "#{Dir.home}/.citrusglaze/chrome-extension"
    if File.directory?(ext_source)
      system_command "mkdir", args: ["-p", "#{Dir.home}/.citrusglaze"]
      system_command "rm", args: ["-rf", ext_dir]
      system_command "cp", args: ["-R", ext_source, ext_dir]
      if File.directory?("#{ext_dir}/dist")
        Dir["#{ext_dir}/dist/*"].each do |f|
          system_command "cp", args: ["-R", f, ext_dir]
        end
        system_command "rm", args: ["-rf", "#{ext_dir}/dist"]
      end
    end

    system_command "xattr", args: ["-cr", "/Applications/CitrusGlaze.app"]

    brew = "#{HOMEBREW_PREFIX}/bin/brew"
    system_command brew, args: ["services", "start", "citrusglaze/citrusglaze/citrusglaze-experimental"]

    citrusglaze = "#{HOMEBREW_PREFIX}/bin/citrusglaze"
    ready = false
    15.times do
      sleep 2
      if File.exist?("/tmp/citrusglaze/daemon.sock")
        result = system_command citrusglaze, args: ["start"], print_stderr: false, must_succeed: false
        if result.exit_status == 0
          ready = true
          break
        end
      end
    end

    if ready
      pac_url = "http://127.0.0.1:8888/proxy.pac"
      iface = `networksetup -listallnetworkservices 2>/dev/null`.lines
                .reject { |l| l.start_with?("An asterisk") || l.strip.empty? }
                .map(&:strip).first || "Wi-Fi"
      system_command "networksetup", args: ["-setautoproxyurl", iface, pac_url], must_succeed: false
    end

    system_command "open", args: ["/Applications/CitrusGlaze.app"]
    if File.directory?(ext_dir)
      system_command "open", args: ["-R", ext_dir]
    end
  end

  uninstall quit: "com.citrusglaze.app"

  zap trash: [
    "~/.citrusglaze",
  ]

  caveats <<~EOS
    EXPERIMENTAL CitrusGlaze desktop app installed.

    Switch to stable:
      brew uninstall --cask citrusglaze-app-experimental
      brew install --cask citrusglaze-app

    Verify: citrusglaze status
  EOS
end
