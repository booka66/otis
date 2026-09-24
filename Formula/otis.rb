# otis through Homebrew, from GitHub:
#
#   brew tap booka66/otis https://github.com/booka66/otis
#   brew trust --formula booka66/otis/otis booka66/seam/seam
#   brew install booka66/otis/otis
#   otis-setup
#
# Homebrew 7 loads formulae from taps outside its own only once trusted.
# Installing one by its full name trusts it, but not seam, which comes in
# as a dependency from its own tap, so both are trusted first.
#
# A release: bump version and tag below, commit, then tag that commit the same.
class Otis < Formula
  desc "Git and GitLab from the terminal: a dashboard and pickers drawn in the terminal"
  homepage "https://github.com/booka66/otis"
  url "https://github.com/booka66/otis.git", using: :git, tag: "v0.7.6"
  version "0.7.6"
  head "https://github.com/booka66/otis.git", using: :git, branch: "main"

  depends_on "ast-grep"
  depends_on "bat"
  depends_on "booka66/seam/seam"
  depends_on "git"
  depends_on "git-delta"
  depends_on "glab"
  depends_on "glow"
  depends_on "jq"
  uses_from_macos "curl"
  uses_from_macos "perl"
  uses_from_macos "zsh"

  def install
    libexec.install Dir["*"] - ["Formula"]
    # Only otis-setup goes on PATH here: the commands (gb, gd, ...) come with
    # the line it adds to your shell, so nothing named like them lands in
    # Homebrew's bin. Through opt, so that line survives an upgrade.
    bin.write_exec_script opt_libexec/"bin/otis-setup"
  end

  def caveats
    <<~EOS
      otis installs with curl now, and this formula goes in a later release:
        brew uninstall otis
        curl -fsSL https://raw.githubusercontent.com/booka66/otis/main/install.sh | sh
      Staying on this one for now? Finish with: otis-setup
    EOS
  end

  test do
    assert_match "terminal", shell_output("#{libexec}/bin/otis-theme --list")
  end
end
