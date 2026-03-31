class Dploy < Formula
  desc "Simple CLI to deploy frontend builds to remote servers"
  homepage "https://github.com/ganiyevuz/dploy"
  url "https://github.com/ganiyevuz/dploy/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "92e3212a8ef7fc3e75a9ea4f1b3744efdbeae846fe1bee850893324960e3004e"
  license "MIT"

  def install
    bin.install "dploy.sh" => "dploy"
  end

  test do
    assert_match "dploy v1.2.0", shell_output("#{bin}/dploy --version")
  end
end
