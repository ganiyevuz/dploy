class Dploy < Formula
  desc "Simple CLI to deploy frontend builds to remote servers"
  homepage "https://github.com/ganiyevuz/dploy"
  url "https://github.com/ganiyevuz/dploy/archive/refs/tags/v1.2.1.tar.gz"
  sha256 "b1aebbc20471fc00d25e1ec119fd2c8bfc53c08fe75f7747ecd5027f3d8f2744"
  license "MIT"

  def install
    bin.install "dploy.sh" => "dploy"
  end

  test do
    assert_match "dploy v1.2.1", shell_output("#{bin}/dploy --version")
  end
end
