#!/usr/bin/env bash
# Build codex the way the official release pipeline does, and strip the
# binary down to its shipped size (~280M instead of ~1.2G).
#
# Mirrors .github/scripts/archive-release-symbols-and-strip-binaries.sh but
# is self-contained: runs `cargo build --release` and then performs the
# objcopy/strip/objcopy dance on the resulting binaries, archiving the
# extracted debug symbols next to them.
#
# Usage:
#   scripts/build-release.sh              # builds codex + bwrap, strips both
#   scripts/build-release.sh --no-build   # skip cargo, only strip existing
#   scripts/build-release.sh --tag rust-v0.142.5
#   scripts/build-release.sh --binaries "codex bwrap"
#   scripts/build-release.sh --archive-dir /tmp/symbols
#
# Run from the repo root (the directory containing codex-rs/).

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: build-release.sh [OPTIONS]

Options:
  --no-build           Skip `cargo build`; only strip existing binaries.
  --tag <tag>          Fetch <tag> from upstream, merge it into the current
                       branch, then push the branch and tag to origin after a
                       successful build/package step.
  --binaries "<names>" Space-delimited binary basenames to strip.
                       Default: "codex bwrap"
  --release-dir <dir>  Directory containing the release binaries.
                       Default: codex-rs/target/release
  --archive-dir <dir>  Where to write the symbols tarball.
                       Default: <release-dir>/symbols
  --package <name>     Crate passed to `cargo build -p <name>`.
                       Default: codex-cli
  --upstream <name>    Remote used to fetch tags. Default: upstream
  --fork <name>        Remote pushed after a successful tagged build.
                       Default: origin
  -h, --help           Show this help.
EOF
}

do_build=1
tag=""
binaries="codex bwrap"
release_dir=""
archive_dir=""
package="codex-cli"
upstream_remote="upstream"
fork_remote="origin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)    do_build=0; shift ;;
    --tag)         tag="${2:?--tag requires a value}"; shift 2 ;;
    --binaries)    binaries="${2:?--binaries requires a value}"; shift 2 ;;
    --release-dir) release_dir="${2:?--release-dir requires a value}"; shift 2 ;;
    --archive-dir) archive_dir="${2:?--archive-dir requires a value}"; shift 2 ;;
    --package)     package="${2:?--package requires a value}"; shift 2 ;;
    --upstream)    upstream_remote="${2:?--upstream requires a value}"; shift 2 ;;
    --fork)        fork_remote="${2:?--fork requires a value}"; shift 2 ;;
    -h|--help)     print_usage; exit 0 ;;
    *) echo "Unexpected argument: $1" >&2; print_usage >&2; exit 1 ;;
  esac
done

# Locate the repo root (directory containing codex-rs/).
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -d "$repo_root/codex-rs" ]]; then
  echo "Could not find codex-rs/ relative to $repo_root" >&2
  exit 1
fi

release_dir="${release_dir:-$repo_root/codex-rs/target/release}"
archive_dir="${archive_dir:-$release_dir/symbols}"

rust_target="$(rustc -vV 2>/dev/null | awk '/^host:/ {print $2}')"
if [[ -z "$rust_target" ]]; then
  echo "Could not determine rustc host target" >&2
  exit 1
fi

read -r -a binary_names <<< "$binaries"

current_branch=""
if [[ -n "$tag" ]]; then
  current_branch="$(git -C "$repo_root" branch --show-current)"
  if [[ -z "$current_branch" ]]; then
    echo "--tag requires a checked out branch" >&2
    exit 1
  fi

  if ! git -C "$repo_root" diff --quiet --ignore-submodules --exit-code; then
    echo "Refusing to merge with tracked worktree changes present." >&2
    echo "Commit or stash tracked changes first, then retry." >&2
    exit 1
  fi

  if ! git -C "$repo_root" diff --cached --quiet --ignore-submodules --exit-code; then
    echo "Refusing to merge with staged changes present." >&2
    exit 1
  fi
fi

echo "==> Repo root:    $repo_root"
echo "==> Release dir:  $release_dir"
echo "==> Archive dir:  $archive_dir"
echo "==> Rust target:  $rust_target"
echo "==> Binaries:     $binaries"
if [[ -n "$tag" ]]; then
  echo "==> Upstream tag:  $tag"
  echo "==> Upstream:      $upstream_remote"
  echo "==> Fork:          $fork_remote"
  echo "==> Branch:        $current_branch"
fi
echo

# ----------------------------------------------------------------------------
# 1. Fetch + merge tag (optional)
# ----------------------------------------------------------------------------
if [[ -n "$tag" ]]; then
  echo "==> git fetch $upstream_remote refs/tags/$tag"
  git -C "$repo_root" fetch "$upstream_remote" "refs/tags/$tag:refs/tags/$tag"

  if git -C "$repo_root" merge-base --is-ancestor "$tag" HEAD; then
    echo "==> Tag $tag is already merged into $current_branch"
  else
    echo "==> git merge --no-ff $tag"
    git -C "$repo_root" merge --no-ff "$tag" -m "Merge tag '$tag' into $current_branch"
  fi
  echo
fi

# ----------------------------------------------------------------------------
# 2. Build (optional)
# ----------------------------------------------------------------------------
if [[ "$do_build" -eq 1 ]]; then
  build_cmd=(cargo build --release -p "$package")
  if [[ "$rust_target" == *linux* ]]; then
    for binary in "${binary_names[@]}"; do
      if [[ "$binary" == "bwrap" && "$package" != "codex-bwrap" ]]; then
        build_cmd+=(-p codex-bwrap)
        break
      fi
    done
  fi

  echo "==> ${build_cmd[*]}"
  ( cd "$repo_root/codex-rs" && "${build_cmd[@]}" )
  echo
fi

# ----------------------------------------------------------------------------
# 3. Locate toolchain
# ----------------------------------------------------------------------------
objcopy_bin="${OBJCOPY:-objcopy}"
strip_bin="${STRIP:-strip}"
command -v "$objcopy_bin" >/dev/null || { echo "Missing: $objcopy_bin" >&2; exit 1; }
command -v "$strip_bin"    >/dev/null || { echo "Missing: $strip_bin"    >&2; exit 1; }

# ----------------------------------------------------------------------------
# 4. Strip + archive symbols, matching the official flow per target triple.
# ----------------------------------------------------------------------------
artifact_name="codex-${rust_target}"
symbols_root="$(mktemp -d -t codex-symbols-XXXXXX)"
symbols_dir="$symbols_root/codex-symbols-$artifact_name"
mkdir -p "$symbols_dir" "$archive_dir"
archive_path="$archive_dir/codex-symbols-$artifact_name.tar.gz"

case "$rust_target" in
  *apple-darwin)
    for binary in "${binary_names[@]}"; do
      binary_path="$release_dir/$binary"
      dsym_path="${binary_path}.dSYM"
      [[ -f "$binary_path" ]] || { echo "Binary not found: $binary_path" >&2; exit 1; }
      [[ -d "$dsym_path"   ]] || { echo "dSYM not found: $dsym_path"    >&2; exit 1; }
      cp -RL "$dsym_path" "$symbols_dir/${binary}.dSYM"
      strip -S -x "$binary_path"
    done
    ;;
  *linux*)
    for binary in "${binary_names[@]}"; do
      binary_path="$release_dir/$binary"
      debug_path="$symbols_dir/${binary}.debug"
      [[ -f "$binary_path" ]] || { echo "Binary not found: $binary_path" >&2; exit 1; }

      "$objcopy_bin" --only-keep-debug "$binary_path" "$debug_path"
      "$strip_bin"   --strip-debug --strip-unneeded "$binary_path"
      "$objcopy_bin" --add-gnu-debuglink="$debug_path" "$binary_path"
    done
    ;;
  *windows*)
    for binary in "${binary_names[@]}"; do
      pdb_path="$release_dir/${binary}.pdb"
      [[ -f "$pdb_path" ]] || { echo "PDB not found: $pdb_path" >&2; exit 1; }
      cp "$pdb_path" "$symbols_dir/${binary}.pdb"
    done
    ;;
  *)
    echo "No symbols packaging support for target: $rust_target" >&2
    exit 1
    ;;
esac

# ----------------------------------------------------------------------------
# 5. Tar up the symbols sidecar.
# ----------------------------------------------------------------------------
rm -f "$archive_path"
tar -C "$symbols_root" -czf "$archive_path" "codex-symbols-$artifact_name"
rm -rf "$symbols_root"

# ----------------------------------------------------------------------------
# 6. Push merged branch + tag to fork (optional).
# ----------------------------------------------------------------------------
if [[ -n "$tag" ]]; then
  echo "==> git push $fork_remote HEAD:$current_branch refs/tags/$tag"
  git -C "$repo_root" push "$fork_remote" "HEAD:$current_branch" "refs/tags/$tag"
  echo
fi

# ----------------------------------------------------------------------------
# 7. Report.
# ----------------------------------------------------------------------------
echo "==> Done."
echo
echo "Stripped binaries:"
for binary in "${binary_names[@]}"; do
  if [[ -f "$release_dir/$binary" ]]; then
    size="$(du -h "$release_dir/$binary" | awk '{print $1}')"
    printf '  %-12s %s\n' "$binary" "$size"
  fi
done
echo
echo "Symbols archive:"
printf '  %s (%s)\n' "$archive_path" "$(du -h "$archive_path" | awk '{print $1}')"
