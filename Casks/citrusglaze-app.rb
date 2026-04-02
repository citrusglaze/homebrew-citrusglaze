cask "citrusglaze-app" do
  version "0.1.12-beta"
  sha256 "db0c51a18177c4fd16354b39e3fd215c98c78ff9787d964f4d19abc68337b102"

  url "https://github.com/citrusglaze/citrusglaze/releases/download/v#{version}/CitrusGlaze-v#{version}-darwin-arm64.app.zip"
  name "CitrusGlaze"
  desc "AI Security & Observability — desktop dashboard"
  homepage "https://citrusglaze.dev"

  depends_on formula: "citrusglaze/citrusglaze/citrusglaze"

  app "CitrusGlaze.app"

  postflight do
    # Copy Chrome extension from formula's Cellar to ~/.citrusglaze/
    ext_source = "#{HOMEBREW_PREFIX}/opt/citrusglaze/chrome-extension"
    ext_dir = "#{Dir.home}/.citrusglaze/chrome-extension"
    if File.directory?(ext_source)
      system_command "mkdir", args: ["-p", "#{Dir.home}/.citrusglaze"]
      system_command "rm", args: ["-rf", ext_dir]
      system_command "cp", args: ["-R", ext_source, ext_dir]
      # Flatten dist/ if present
      if File.directory?("#{ext_dir}/dist")
        Dir["#{ext_dir}/dist/*"].each do |f|
          system_command "cp", args: ["-R", f, ext_dir]
        end
        system_command "rm", args: ["-rf", "#{ext_dir}/dist"]
      end
    end

    # Strip quarantine so Gatekeeper doesn't block the unsigned app
    system_command "xattr", args: ["-cr", "/Applications/CitrusGlaze.app"]

    # Open the app
    system_command "open", args: ["/Applications/CitrusGlaze.app"]

    # Open Finder to extension folder
    if File.directory?(ext_dir)
      system_command "open", args: ["-R", ext_dir]
    end
  end

  uninstall quit: "com.citrusglaze.app"

  zap trash: [
    "~/.citrusglaze",
  ]

  caveats <<~EOS
    CitrusGlaze desktop app installed to /Applications.

    Chrome extension installed to:
      ~/.citrusglaze/chrome-extension
    Load it in Chrome: Extensions → Load unpacked → select that folder.
    On upgrades, click Refresh on the extension card.
  EOS
end
