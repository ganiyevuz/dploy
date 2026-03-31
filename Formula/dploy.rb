class Dploy < Formula
  desc "Simple CLI to deploy frontend builds to remote servers"
  homepage "https://github.com/ganiyevuz/dploy"
  url "https://github.com/ganiyevuz/dploy/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "3dfaad220f44153f5da1e53634e32a02ed1e772bc4377dc55e5997de5843f3e4"
  license "MIT"

  def install
    bin.install "dploy.sh" => "dploy"
  end

  test do
    assert_match "dploy v1.1.0", shell_output("#{bin}/dploy --version")
  end
end
