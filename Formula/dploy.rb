class Dploy < Formula
  desc "Simple CLI to deploy frontend builds to remote servers"
  homepage "https://github.com/ganiyevuz/dploy"
  url "https://github.com/ganiyevuz/dploy/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "62751482728514effbd22206bb878c6ec23f86897f8dc10cbcab016d8c3851be"
  license "MIT"

  def install
    bin.install "dploy.sh" => "dploy"
  end

  test do
    assert_match "dploy v1.0.0", shell_output("#{bin}/dploy --version")
  end
end
