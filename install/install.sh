#!/bin/sh
# Installs or updates CraftDepot for the current user:
#
#   curl -fsSL https://craftdepot.github.io/CraftDepot-App/install.sh | sh
#
# Downloads the latest release from https://github.com/CraftDepot/CraftDepot-App/releases, checks its
# SHA-256, installs it and opens it. Run it again to update.
#
#   macOS  ~/Applications/CraftDepot.app
#   Linux  ~/.local/bin/craftdepot, with a menu entry
#
#   CRAFTDEPOT_DIST       install a build from this folder or address instead (for testing)
#   CRAFTDEPOT_NO_LAUNCH  1: don't open CraftDepot afterwards

set -eu

REPO=CraftDepot/CraftDepot-App

say() { printf '%s\n' "$*"; }
fail() { printf 'craftdepot install: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "needs $1, which isn't installed"; }

fetch() { # fetch <file> <dest>
    case "$dist" in
    http://* | https://*) curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$dist/$1" || fail "couldn't download $dist/$1" ;;
    *) cp "$dist/$1" "$2" || fail "no $1 in $dist" ;;
    esac
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}

main() {
    need curl
    need tar

    case "$(uname -s)" in
    Darwin) os=macos package=craftdepot-macos-universal.tar.gz ;;
    Linux)
        os=linux
        case "$(uname -m)" in
        x86_64 | amd64) package=craftdepot-linux-x86_64.tar.gz ;;
        aarch64 | arm64) package=craftdepot-linux-aarch64.tar.gz ;;
        *) fail "there's no CraftDepot build for $(uname -m) yet" ;;
        esac
        ;;
    *) fail "this script is for macOS and Linux; on Windows run: irm https://craftdepot.github.io/CraftDepot-App/install.ps1 | iex" ;;
    esac

    dist=${CRAFTDEPOT_DIST:-}
    if [ -z "$dist" ]; then
        # github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>.
        latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
            fail "couldn't reach https://github.com/$REPO/releases"
        tag=${latest##*/tag/}
        [ "$tag" != "$latest" ] || fail "no CraftDepot release has been published yet"
        dist="https://github.com/$REPO/releases/download/$tag"
    fi

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    fetch "$package" "$tmp/$package"
    fetch SHA256SUMS "$tmp/SHA256SUMS"
    expected=$(awk -v f="$package" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || fail "SHA256SUMS has no entry for $package"
    actual=$(sha256 "$tmp/$package")
    [ "$actual" = "$expected" ] || fail "$package is damaged: its SHA-256 is $actual, not $expected. Nothing was installed."

    mkdir "$tmp/unpacked"
    tar -xzf "$tmp/$package" -C "$tmp/unpacked"

    if [ "$os" = macos ]; then
        apps="$HOME/Applications"
        app="$apps/CraftDepot.app"
        exe="$app/Contents/MacOS/craftdepot"
        # Close a running copy, so opening it afterwards starts the new version.
        if pkill -f "^$exe" 2>/dev/null; then sleep 1; fi
        mkdir -p "$apps"
        rm -rf "$app.new"
        mv "$tmp/unpacked/CraftDepot.app" "$app.new"
        rm -rf "$app"
        mv "$app.new" "$app"
    else
        bin="$HOME/.local/bin"
        exe="$bin/craftdepot"
        data=${XDG_DATA_HOME:-$HOME/.local/share}
        mkdir -p "$bin" "$data/applications" "$data/icons/hicolor/scalable/apps"
        if pkill -f "^$exe" 2>/dev/null; then sleep 1; fi
        # Replace by renaming, which works even while the old binary is running.
        install -m 755 "$tmp/unpacked/craftdepot" "$exe.new"
        mv -f "$exe.new" "$exe"
        install -m 644 "$tmp/unpacked/craftdepot.svg" "$data/icons/hicolor/scalable/apps/craftdepot.svg"
        cat >"$data/applications/craftdepot.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CraftDepot
Comment=Install, update and open software rewritten in Rust
Exec=$exe
Icon=craftdepot
Categories=Utility;
Terminal=false
EOF
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database -q "$data/applications" 2>/dev/null || true
        fi
    fi

    version=$("$exe" --version | sed 's/^craftdepot //') || fail "the installed CraftDepot doesn't run"

    if [ "$os" = macos ]; then
        say "CraftDepot $version is installed in $app."
        say "Open it from Launchpad or Spotlight. Run the same command again to update it."
        [ "${CRAFTDEPOT_NO_LAUNCH:-}" = 1 ] || open "$app"
    else
        say "CraftDepot $version is installed in $exe."
        say "Open it from your applications menu, or run craftdepot. Run the same command again to update it."
        case ":$PATH:" in
        *":$bin:"*) ;;
        *) say "Note: $bin isn't on your PATH, so the craftdepot command won't be found until you add it." ;;
        esac
        if [ "${CRAFTDEPOT_NO_LAUNCH:-}" != 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            nohup "$exe" >/dev/null 2>&1 &
        fi
    fi
}

# Everything runs from here, so a download cut off halfway can't run half a script.
main "$@"
