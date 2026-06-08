#!/usr/bin/env bash
#
# Sourced helper. Ensures Sparkle's command-line tools (generate_keys,
# sign_update, generate_appcast) are present under .sparkle/bin and exports
# SPARKLE_BIN. The tools come from the official Sparkle release tarball, PINNED to
# the same version as the embedded framework (project.yml → packages.Sparkle), and
# live in a gitignored folder so they never enter the repo.
#
# The pin matters: a newer generate_appcast/sign_update can emit appcast attributes
# or a signature format that the older embedded framework on already-installed
# clients mis-parses — silently stopping updates — and "always latest" makes builds
# non-reproducible across machines and time. Bump this in lockstep with project.yml.
SPARKLE_VERSION="2.6.0"

ensure_sparkle_tools() {
  local root="$1"
  local dir="$root/.sparkle"
  SPARKLE_BIN="$dir/bin"

  # Record which version is installed so a stale (wrong-version) checkout is replaced,
  # not silently reused, when SPARKLE_VERSION is bumped.
  local stamp="$dir/.version"
  if [ -x "$SPARKLE_BIN/generate_keys" ] \
     && [ -x "$SPARKLE_BIN/sign_update" ] \
     && [ -x "$SPARKLE_BIN/generate_appcast" ] \
     && [ "$(cat "$stamp" 2>/dev/null || true)" = "$SPARKLE_VERSION" ]; then
    return 0
  fi

  echo "==> Fetching Sparkle command-line tools (pinned $SPARKLE_VERSION)"
  rm -rf "$dir"
  mkdir -p "$dir"
  local url="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  if ! curl -fsSL "$url" -o "$dir/sparkle.tar.xz"; then
    echo "error: could not download pinned Sparkle tools from $url" >&2
    return 1
  fi
  tar -xf "$dir/sparkle.tar.xz" -C "$dir"
  if [ ! -x "$SPARKLE_BIN/generate_keys" ]; then
    echo "error: Sparkle tools not found after extracting $url" >&2
    return 1
  fi
  echo "$SPARKLE_VERSION" > "$stamp"
}
