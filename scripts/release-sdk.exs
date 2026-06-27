# Interactive release assistant for the Elixir SDK packages. Run from the repo
# root via the justfile:
#
#     just release-core      # sdk/elixir       -> dustlayer
#     just release-ecto      # sdk/elixir_ecto  -> dustlayer_ecto
#
# or directly:  elixir scripts/release-sdk.exs sdk/elixir
#
# Shows the current and published versions, asks for a patch/minor/major bump,
# rolls the package CHANGELOG, then (with your confirmation) commits, tags, and
# pushes — which starts .github/workflows/sdk-release.yml. The Hex publish still
# waits for your approval on the `hex` GitHub environment.
#
# Monorepo-aware: tags are prefixed `<app>-v<version>` (e.g. dustlayer-v0.1.1)
# and the dirty-tree check is scoped to the package subdir, since the monorepo
# routinely carries unrelated changes elsewhere. Publish `dustlayer` before
# `dustlayer_ecto` — the ecto package depends on `{:dustlayer, "~> 0.1"}`.
#
# Standalone Elixir — no mix compilation, just file edits + git.

defmodule Release do
  def run([dir]) do
    dir = String.trim_trailing(dir, "/")
    mix_path = Path.join(dir, "mix.exs")
    unless File.exists?(mix_path), do: die("no mix.exs at #{mix_path}")

    {app, current} = read_mix(mix_path)
    branch = trimmed(git!(["rev-parse", "--abbrev-ref", "HEAD"]))

    info("package", app)
    info("directory", dir)
    info("current (mix.exs)", current)
    if v = published(app), do: info("latest on Hex", v)
    info("branch", branch)

    ensure_subdir_clean!(dir)
    confirm_branch!(branch)

    {maj, min, pat} = parse(current)

    choices = %{
      "1" => {"patch", "#{maj}.#{min}.#{pat + 1}", "bug fixes"},
      "2" => {"minor", "#{maj}.#{min + 1}.0", "new features, backwards-compatible"},
      "3" => {"major", "#{maj + 1}.0.0", "breaking changes"}
    }

    IO.puts("\nselect the release type:")

    for k <- ["1", "2", "3"] do
      {name, ver, note} = choices[k]
      IO.puts("  #{k}) #{name} → #{ver}\t(#{note})")
    end

    {_, new, _} = choices[prompt("choice [1-3]: ")] || abort()
    unless yes?("bump #{app} #{current} → #{new} ?"), do: abort()

    changelog_path = Path.join(dir, "CHANGELOG.md")
    bump_mix!(mix_path, current, new)
    roll_changelog!(changelog_path, new)

    tag = "#{app}-v#{new}"
    files = [mix_path, changelog_path] |> Enum.filter(&File.exists?/1)

    IO.puts("\nchanges:")
    IO.puts(git!(["--no-pager", "diff", "--" | files]))

    unless yes?("commit, tag #{tag}, and push? (this starts the release workflow)") do
      IO.puts("""
      Edits left in place, uncommitted.
      Run `git checkout -- #{Enum.join(files, " ")}` to discard them.
      """)

      System.halt(0)
    end

    git!(["add" | files])
    git!(["commit", "-m", "Release #{app} #{new}"])
    git!(["tag", "-a", tag, "-m", tag])
    git!(["push", "origin", branch])
    git!(["push", "origin", tag])

    IO.puts("""

    ✅ pushed #{tag} — the release workflow is running.
       Final step: approve the `hex` deployment to publish:
       #{actions_url()}
    """)
  end

  def run(_), do: die("usage: elixir scripts/release-sdk.exs <package-dir>")

  # ── mix.exs ────────────────────────────────────────────────────────────────
  defp read_mix(path) do
    src = File.read!(path)
    [_, version] = Regex.run(~r/@version "([^"]+)"/, src) || die("no @version in #{path}")
    [_, app] = Regex.run(~r/app:\s*:([a-z0-9_]+)/, src) || die("no `app:` in #{path}")
    {app, version}
  end

  defp parse(version) do
    [maj, min, pat] =
      version
      |> String.split("-")
      |> hd()
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)

    {maj, min, pat}
  end

  defp bump_mix!(path, old, new) do
    src = File.read!(path)
    File.write!(path, String.replace(src, ~s(@version "#{old}"), ~s(@version "#{new}")))
  end

  # ── CHANGELOG ──────────────────────────────────────────────────────────────
  defp roll_changelog!(path, new) do
    with true <- File.exists?(path),
         src = File.read!(path),
         true <- String.contains?(src, "## [Unreleased]") do
      today = Date.to_iso8601(Date.utc_today())
      heading = "## [Unreleased]\n\n## #{new} - #{today}"
      File.write!(path, String.replace(src, "## [Unreleased]", heading, global: false))
    else
      _ -> :ok
    end
  end

  # ── Hex (best-effort, no rescue) ───────────────────────────────────────────
  defp published(app) do
    if System.find_executable("mix") do
      case System.cmd("mix", ["hex.info", app], stderr_to_stdout: true) do
        {out, 0} -> Regex.run(~r/[0-9]+\.[0-9]+\.[0-9]+/, out) |> then(&(&1 && hd(&1)))
        _ -> nil
      end
    end
  end

  # ── git ────────────────────────────────────────────────────────────────────
  defp ensure_subdir_clean!(dir) do
    case trimmed(git!(["status", "--porcelain", "--", dir])) do
      "" -> :ok
      _ -> die("#{dir} has uncommitted changes — commit or stash them first.")
    end
  end

  defp confirm_branch!(b) when b in ["master", "main"], do: :ok

  defp confirm_branch!(b) do
    unless yes?("⚠  not on master/main (on '#{b}'). release from here anyway?"), do: abort()
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> die("git #{Enum.join(args, " ")} failed (#{code}):\n#{out}")
    end
  end

  defp actions_url do
    case System.cmd("git", ["config", "--get", "remote.origin.url"]) do
      {url, 0} ->
        slug =
          url
          |> String.trim()
          |> String.replace(~r/\.git$/, "")
          |> String.replace(~r{^git@github\.com:}, "")
          |> String.replace(~r{^https://github\.com/}, "")

        "https://github.com/#{slug}/actions"

      _ ->
        "your repo's Actions tab"
    end
  end

  # ── IO ─────────────────────────────────────────────────────────────────────
  defp info(label, value), do: IO.puts(String.pad_trailing("#{label}:", 19) <> value)
  defp prompt(label), do: IO.gets(label) |> to_string() |> String.trim()
  defp yes?(question), do: prompt("#{question} [y/N] ") =~ ~r/^[Yy]/
  defp trimmed(s), do: String.trim(s)
  defp abort, do: die("aborted.")

  defp die(msg) do
    IO.puts(:stderr, "✗ #{msg}")
    System.halt(1)
  end
end

Release.run(System.argv())
