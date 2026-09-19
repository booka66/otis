# otis through Homebrew, from GitHub:
#
#   brew tap booka66/otis https://github.com/booka66/otis
#   brew install booka66/otis/otis
#   otis-setup
#
# A release: bump version and tag below, commit, then tag that commit the same.
class Otis < Formula
  desc "Git and GitLab from the terminal: a dashboard and fzf pickers"
  homepage "https://github.com/booka66/otis"
  url "https://github.com/booka66/otis.git", using: :git, tag: "v0.1.0"
  version "0.1.0"
  head "https://github.com/booka66/otis.git", using: :git, branch: "main"

  depends_on "ast-grep"
  depends_on "bat"
  depends_on "booka66/seam/seam"
  depends_on "fzf"
  depends_on "git"
  depends_on "git-delta"
  depends_on "glab"
  depends_on "glow"
  depends_on "jq"
  depends_on "neovim"
  uses_from_macos "curl"
  uses_from_macos "perl"
  uses_from_macos "zsh"

  def install
    libexec.install Dir["*"] - ["Formula"]
    # Only otis-setup goes on PATH here: the commands (gb, gd, ...) come with
    # the line it adds to your shell, so nothing named like them lands in
    # Homebrew's bin. Through opt, so that line survives an upgrade.
    (bin/"otis-setup").write_exec_script opt_libexec/"bin/otis-setup"
  end

  def caveats
    <<~EOS
      Finish with:
        otis-setup
      It logs you in to GitLab, adds otis to your shell, and offers the font.
    EOS
  end

  test do
    assert_match "terminal", shell_output("#{libexec}/bin/otis-theme --list")
  end
end
