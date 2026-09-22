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
  --install       build the native package, install it through the system
                  package manager (sudo), then restart Fcitx5 and report what
                  the running daemon actually loaded. Implies --package.
  --no-restart    with --install, leave the running Fcitx5 alone
  --no-test       build only; do not run ctest
  --build-dir DIR use DIR instead of build-from-source
  --build-type T  CMake build type (default: Release)
  -h, --help      show this help

The package build is the stricter check on Debian and Ubuntu: debian/rules
configures with -DBUILD_TESTING=ON and debhelper runs ctest as part of it.

--install goes through the distribution's package manager rather than
installing files directly, so the result stays uninstallable and does not
fight dpkg or pacman. It then restarts Fcitx5, because Fcitx5 dlopen()s the
addon at startup: `fcitx5-remote -r` rereads configuration but never swaps a
shared library, so without a restart the daemon keeps running the previous
build from a now-deleted file.

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
install_package=0
restart_fcitx=1
run_tests=1
build_dir="build-from-source"
build_type="Release"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --deps) install_deps=1 ;;
    --package) build_package=1 ;;
    --install)
        build_package=1
        install_package=1
        ;;
    --no-restart) restart_fcitx=0 ;;
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

# Set by package_build() to the package --install should hand to the system
# package manager (the main one, never the -debug companion).
built_package=""

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
        # dpkg-buildpackage writes into the parent directory, which accumulates
        # artifacts from every previous build -- including older versions. Sort
        # by modification time and take the newest, so --install can never hand
        # a stale .deb to apt.
        local deb stamp
        while IFS= read -r stamp; do
            deb="${stamp#* }"
            printf '  %s\n' "$deb"
            # Skip the debug companion; it is not what gets installed.
            [[ "$deb" == *-dbgsym* || "$deb" == *-debug* ]] && continue
            [[ -n "$built_package" ]] && continue
            built_package="$(readlink -f "$deb")"
        done < <(find .. -maxdepth 1 -name 'fcitx5-ari-ime*.deb' \
            -printf '%T@ %p\n' | sort -rn)
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
            local landed="$repo_root/$(basename "$built")"
            printf '  %s\n' "$landed"
            [[ "$landed" == *-debug-* ]] && continue
            built_package="$landed"
        done < <(find "$work" -maxdepth 1 -name '*.pkg.tar.*' -print)
        ;;
    *)
        die "--package is not supported on ${distro_name}"
        ;;
    esac
}

install_built_package() {
    [[ -n "$built_package" && -f "$built_package" ]] ||
        die 'the package build produced nothing to install'
    case "$family" in
    debian)
        # apt-get, not dpkg -i, so runtime dependencies resolve.
        run "${sudo_cmd[@]}" apt-get install -y "$built_package"
        ;;
    arch)
        run "${sudo_cmd[@]}" pacman -U --noconfirm "$built_package"
        ;;
    *)
        die "--install is not supported on ${distro_name}"
        ;;
    esac
}

# Fcitx5 dlopen()s the addon once at startup. Reloading configuration does not
# swap the library, so an upgraded addon only takes effect after the daemon is
# restarted -- until then it keeps running the previous build out of a file that
# has already been replaced on disk.
restart_and_verify() {
    if ! command -v fcitx5 >/dev/null 2>&1; then
        printf '\n==> Fcitx5 is not installed; nothing to restart\n'
        return
    fi
    if [[ "$restart_fcitx" -eq 0 ]]; then
        printf '\n==> Skipping the Fcitx5 restart (--no-restart).\n'
        printf '    The addon stays on the previous build until you run: fcitx5 -r -d\n'
        return
    fi
    if ! pgrep -x fcitx5 >/dev/null 2>&1; then
        printf '\n==> Fcitx5 is not running; start it to pick the addon up\n'
        return
    fi

    local old_pid
    old_pid="$(pgrep -xo fcitx5 || true)"

    printf '\n==> Restarting Fcitx5 so it loads the new addon\n'
    # setsid + full redirection: fcitx5 -d daemonises but keeps the inherited
    # stdout open, which would otherwise hold this script (and any caller
    # capturing its output) open indefinitely.
    setsid fcitx5 -r -d </dev/null >/dev/null 2>&1 || true

    # Wait for a DIFFERENT pid, not merely for one to exist: the outgoing daemon
    # stays alive for a moment after its replacement starts, and `pgrep -xo`
    # reports the older of the two, so polling for "any fcitx5" hands back the
    # process we just asked to go away.
    local pid="" waited=0
    while [[ "$waited" -lt 100 ]]; do
        pid="$(pgrep -xo fcitx5 || true)"
        [[ -n "$pid" && "$pid" != "$old_pid" ]] && break
        sleep 0.1
        waited=$((waited + 1))
    done
    if [[ -z "$pid" || ! -r "/proc/$pid/maps" ]]; then
        printf '    Could not inspect the restarted Fcitx5\n'
        return
    fi

    # The addon is OnDemand: Fcitx5 only maps it once the input method is used.
    # Asking for its configuration over D-Bus forces it in, with retries because
    # the fresh daemon has to claim the bus name first.
    local mapped="" probe=0
    while [[ "$probe" -lt 30 ]]; do
        if command -v gdbus >/dev/null 2>&1; then
            gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
                --method org.fcitx.Fcitx.Controller1.GetConfig \
                "fcitx://config/inputmethod/ari-ime" >/dev/null 2>&1 || true
        fi
        mapped="$(grep -F 'ari-ime.so' "/proc/$pid/maps" 2>/dev/null |
            awk '{print $NF}' | sort -u | head -1)"
        [[ -n "$mapped" ]] && break
        sleep 0.2
        probe=$((probe + 1))
    done
    printf '    Fcitx5 pid %s\n' "$pid"
    if [[ -z "$mapped" ]]; then
        printf '    addon not loaded yet (it loads when Ari IME is selected)\n'
    elif [[ "$mapped" == *"(deleted)"* ]]; then
        printf '    STALE: still running a replaced file (%s)\n' "$mapped"
        printf '    Restart Fcitx5 again: fcitx5 -r -d\n'
    else
        printf '    loaded: %s\n' "$mapped"
    fi
}

report_installed() {
    printf '\n===== installed =====\n'
    case "$family" in
    debian) printf '%-22s %s\n' "package" \
        "$(dpkg-query -W -f='${Version}' fcitx5-ari-ime 2>/dev/null || echo 'not installed')" ;;
    arch) printf '%-22s %s\n' "package" \
        "$(pacman -Q fcitx5-ari-ime 2>/dev/null | awk '{print $2}' || echo 'not installed')" ;;
    esac
    # The package version does not move for a local rebuild, so also report the
    # source it was built from. This is what actually answers "is the thing I am
    # running the thing I just built?".
    if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
        local sha dirty=""
        sha="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
        git -C "$repo_root" diff --quiet 2>/dev/null || dirty=" (+uncommitted changes)"
        printf '%-22s %s\n' "built from" "$sha$dirty"
    fi
    printf '=====================\n'
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

if [[ "$install_package" -eq 1 ]]; then
    install_built_package
    report_installed
    restart_and_verify
fi

printf '\n==> OK on %s\n' "$distro_name"
