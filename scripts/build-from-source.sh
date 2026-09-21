#!/usr/bin/env bash
set -euo pipefail

# Build and test Ari IME from the current source tree on whatever distribution
# this is running on. The point is portability verification: Ari's behavior is
# the same everywhere, but the fcitx5 headers it compiles against and the
# libchewing that ranks its candidates are whatever the distribution ships, and
# those differ (see ISSUES.md). Run this on each target and compare the version
# banner it prints with the test result.
#
# Copy the tree to the machine first; this builds what is on disk, not a
# release tarball:
#   git archive --format=tar HEAD | ssh host 'mkdir -p ari && tar -x -C ari'
# or, to include uncommitted work:
#   rsync -a --exclude build --exclude .git ./ host:ari/

usage() {
    cat <<'EOF'
Usage: scripts/build-from-source.sh [options]

Configure, build and test Ari IME from this source tree.

Options:
  --deps          install the distribution's build dependencies first (sudo)
  --package       also build the native package (.deb via dpkg-buildpackage,
                  or .pkg.tar.zst via makepkg) instead of only a plain build
  --no-test       build only; do not run ctest
  --build-dir DIR use DIR instead of build-from-source
  --build-type T  CMake build type (default: Release)
  -h, --help      show this help

The package build is the stricter check on Debian and Ubuntu: debian/rules
configures with -DBUILD_TESTING=ON and debhelper runs ctest as part of it.

Exit status is non-zero if any step fails, so this is safe to use in a loop
across machines.
EOF
}

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

run() {
    printf '\n==> %s\n' "$*"
    "$@"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

install_deps=0
build_package=0
run_tests=1
build_dir="build-from-source"
build_type="Release"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --deps) install_deps=1 ;;
    --package) build_package=1 ;;
    --no-test) run_tests=0 ;;
    --build-dir)
        [[ $# -ge 2 ]] || die '--build-dir requires a directory'
        build_dir="$2"
        shift
        ;;
    --build-type)
        [[ $# -ge 2 ]] || die '--build-type requires a value'
        build_type="$2"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

[[ -f CMakeLists.txt && -d src ]] ||
    die 'run this from an Ari IME source tree'

# --- Which distribution family is this? -------------------------------------

distro_id=""
distro_like=""
distro_name="unknown"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro_id="${ID:-}"
    distro_like="${ID_LIKE:-}"
    distro_name="${PRETTY_NAME:-${NAME:-unknown}}"
fi

family=""
case " $distro_id $distro_like " in
*" debian "* | *" ubuntu "*) family="debian" ;;
*" arch "*) family="arch" ;;
*" fedora "* | *" rhel "*) family="fedora" ;;
esac
# ID alone covers distributions that set no ID_LIKE (Debian and Arch proper).
if [[ -z "$family" ]]; then
    case "$distro_id" in
    debian | ubuntu) family="debian" ;;
    arch) family="arch" ;;
    fedora) family="fedora" ;;
    esac
fi

sudo_cmd=()
if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 ||
        die 'this step needs root and sudo is not installed; re-run as root'
    sudo_cmd=(sudo)
fi

# --- Build dependencies ------------------------------------------------------

install_dependencies() {
    case "$family" in
    debian)
        # Mirrors debian/control Build-Depends plus what dpkg-buildpackage
        # itself needs. fcitx5 and hicolor-icon-theme are runtime deps, pulled
        # in so the install smoke check and a real try-out both work.
        local packages=(
            build-essential cmake extra-cmake-modules pkg-config
            libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev
            fcitx5-modules-dev libchewing3-dev
            fcitx5 hicolor-icon-theme
        )
        if [[ "$build_package" -eq 1 ]]; then
            packages+=(debhelper dpkg-dev fakeroot)
        fi
        run "${sudo_cmd[@]}" apt-get update
        run "${sudo_cmd[@]}" apt-get install -y --no-install-recommends \
            "${packages[@]}"
        ;;
    arch)
        local packages=(cmake extra-cmake-modules pkg-config fcitx5 libchewing
            hicolor-icon-theme)
        run "${sudo_cmd[@]}" pacman -S --needed --noconfirm "${packages[@]}"
        ;;
    fedora)
        local packages=(gcc-c++ cmake extra-cmake-modules pkgconf-pkg-config
            fcitx5-devel libchewing-devel hicolor-icon-theme)
        run "${sudo_cmd[@]}" dnf install -y "${packages[@]}"
        ;;
    *)
        die "Unsupported distribution for --deps: ${distro_name}.
Install the equivalents of: cmake, extra-cmake-modules, pkg-config, a C++20
compiler, the fcitx5 core/config/utils/module development headers and the
libchewing development headers, then re-run without --deps."
        ;;
    esac
}

# --- Version banner ----------------------------------------------------------
# Printed before anything is built so a failure downstream is still attributable
# to a specific toolchain and dependency set.

report_versions() {
    printf '\n===== environment =====\n'
    printf '%-22s %s\n' "distribution" "$distro_name"
    printf '%-22s %s\n' "family" "${family:-unknown}"
    printf '%-22s %s\n' "kernel" "$(uname -sr)"
    printf '%-22s %s\n' "architecture" "$(uname -m)"
    printf '%-22s %s\n' "Ari IME" \
        "$(sed -n 's/^project(ari-ime VERSION \([^ ]*\).*/\1/p' CMakeLists.txt)"
    if command -v cmake >/dev/null 2>&1; then
        printf '%-22s %s\n' "cmake" \
            "$(cmake --version | sed -n '1s/^cmake version //p')"
    fi
    printf '%-22s %s\n' "c++" \
        "$("${CXX:-c++}" --version 2>/dev/null | sed -n '1p' || echo 'not found')"
    if command -v pkg-config >/dev/null 2>&1; then
        printf '%-22s %s\n' "libchewing" \
            "$(pkg-config --modversion chewing 2>/dev/null || echo 'not found')"
        printf '%-22s %s\n' "Fcitx5Core" \
            "$(pkg-config --modversion Fcitx5Core 2>/dev/null ||
                echo 'no .pc (CMake config only)')"
    fi
    # Fcitx5 ships its version through CMake rather than pkg-config on most
    # distributions, so read it from the package manager as a fallback.
    local fcitx_pkg=""
    case "$family" in
    debian) fcitx_pkg="$(dpkg-query -W -f='${Version}' fcitx5 2>/dev/null || true)" ;;
    arch) fcitx_pkg="$(pacman -Q fcitx5 2>/dev/null | awk '{print $2}' || true)" ;;
    fedora) fcitx_pkg="$(rpm -q --qf '%{VERSION}-%{RELEASE}' fcitx5 2>/dev/null || true)" ;;
    esac
    [[ -n "$fcitx_pkg" ]] && printf '%-22s %s\n' "fcitx5 (package)" "$fcitx_pkg"
    printf '=======================\n'
}

# --- Steps -------------------------------------------------------------------

plain_build() {
    local testing=ON
    [[ "$run_tests" -eq 1 ]] || testing=OFF
    run cmake -S . -B "$build_dir" \
        -DCMAKE_BUILD_TYPE="$build_type" \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_TESTING="$testing"
    run cmake --build "$build_dir" -j"$(nproc 2>/dev/null || echo 2)"

    # Install into a throwaway prefix: catches a broken install() rule without
    # touching the system, and proves the addon/inputmethod descriptors land.
    local staging
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' RETURN
    run cmake --install "$build_dir" --prefix "$staging/usr" >/dev/null
    local module
    module="$(find "$staging" -type f -name 'ari-ime.so' -print -quit)"
    [[ -n "$module" && -s "$module" ]] ||
        die 'install produced no ari-ime.so'
    printf '  installed module: %s (%s bytes)\n' \
        "${module#"$staging"}" "$(stat -c %s "$module")"

    if [[ "$run_tests" -eq 1 ]]; then
        run ctest --test-dir "$build_dir" --output-on-failure
    else
        printf '\n==> tests skipped (--no-test)\n'
    fi
}

package_build() {
    case "$family" in
    debian)
        command -v dpkg-buildpackage >/dev/null 2>&1 ||
            die 'dpkg-buildpackage not found; re-run with --deps'
        # debian/rules configures with -DBUILD_TESTING=ON and debhelper runs
        # ctest for the cmake buildsystem, so this covers the suite too.
        run dpkg-buildpackage -us -uc -b
        # dpkg-buildpackage writes its artifacts into the parent directory.
        printf '\n==> packages written next to the source tree:\n'
        find .. -maxdepth 1 -name 'fcitx5-ari-ime*.deb' -printf '  %p\n' |
            sort || true
        ;;
    arch)
        command -v makepkg >/dev/null 2>&1 ||
            die 'makepkg not found'
        # The shipped PKGBUILD downloads the released tarball from GitHub and
        # uses $startdir/src as its build directory -- which is this repo's
        # actual source directory. Build from a copy so neither happens here.
        local work
        work="$(mktemp -d)"
        trap 'rm -rf "$work"' RETURN
        mkdir -p "$work/tree"
        local item
        for item in CMakeLists.txt LICENSE README.md data scripts src test; do
            [[ -e "$item" ]] && cp -a "$item" "$work/tree/"
        done
        rm -rf "$work/tree/src/build"
        sed -e 's|^source=.*|source=()|' \
            -e 's|^sha256sums=.*|sha256sums=()|' \
            -e "s|-S \"\$srcdir/\$_srcdir\"|-S \"\$startdir/tree\"|" \
            -e 's|-DBUILD_TESTING=OFF|-DBUILD_TESTING=ON|' \
            PKGBUILD >"$work/PKGBUILD"
        run env -C "$work" makepkg -f
        # The work directory is temporary, so hand the artifacts back here
        # before the RETURN trap removes it.
        printf '\n==> packages written next to the source tree:\n'
        local built
        while IFS= read -r built; do
            cp -f "$built" "$repo_root/"
            printf '  %s\n' "$repo_root/$(basename "$built")"
        done < <(find "$work" -maxdepth 1 -name '*.pkg.tar.*' -print)
        ;;
    *)
        die "--package is not supported on ${distro_name}"
        ;;
    esac
}

# --- Main --------------------------------------------------------------------

if [[ "$install_deps" -eq 1 ]]; then
    [[ -n "$family" ]] ||
        die "Cannot install dependencies: unrecognised distribution ${distro_name}"
    install_dependencies
fi

report_versions

command -v cmake >/dev/null 2>&1 ||
    die 'cmake not found; re-run with --deps'

if [[ "$build_package" -eq 1 ]]; then
    package_build
else
    plain_build
fi

printf '\n==> OK on %s\n' "$distro_name"
