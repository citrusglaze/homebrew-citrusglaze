class CitrusglazeScan < Formula
  include Language::Python::Virtualenv

  desc "Scan AI chat histories for leaked secrets"
  homepage "https://citrusglaze.dev"
  url "https://files.pythonhosted.org/packages/source/c/citrusglaze-scan/citrusglaze_scan-0.1.0.tar.gz"
  license "MIT"
  depends_on "python@3.12"

  def install
    virtualenv_install_with_resources
  end

  test do
    assert_match "CitrusGlaze", shell_output("#{bin}/citrusglaze-scan --help 2>&1")
  end
end
