#!/usr/bin/env bash

cd "$(dirname "$0")"

set -eux

ZLIB_SOURCE_DIR="zlib-ng"

top="$(pwd)"
stage="$top"/stage

# load autobuild provided shell functions and variables
case "$AUTOBUILD_PLATFORM" in
    windows*)
        autobuild="$(cygpath -u "$AUTOBUILD")"
    ;;
    *)
        autobuild="$AUTOBUILD"
    ;;
esac
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

# remove_cxxstd
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

pushd "$ZLIB_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        # ------------------------ windows, windows64 ------------------------
        windows*)
            load_vsvars

            # zlib-ng already has a win32 folder and win32 build will fail
            mkdir -p "WIN"
            pushd "WIN"

            case "$AUTOBUILD_ADDRSIZE" in
                32)
                    cmake_arch="Win32"
                    ;;
                64)
                    cmake_arch="x64"
                    ;;
            esac

            cmake -G "$AUTOBUILD_WIN_CMAKE_GEN" -A "$cmake_arch" .. -DBUILD_SHARED_LIBS=OFF -DZLIB_COMPAT:BOOL=ON

            #build_sln "zlib.sln" "Release|$AUTOBUILD_WIN_VSPLATFORM" "zlib"
            cmake --build . --config Release

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Release
            fi

            mkdir -p "$stage/lib/release"
            cp -a "Release/zlibstatic.lib" "$stage/lib/release/zlib.lib"

            mkdir -p "$stage/include/zlib-ng"
            cp -a zconf.h "$stage/include/zlib-ng"

            # zlib-ng includes minigzip, but only in executable form

            # WIN
            popd

            cp -a zlib.h "$stage/include/zlib-ng"
        ;;

        # ------------------------- darwin, darwin64 -------------------------
        darwin*)

            case "$AUTOBUILD_ADDRSIZE" in
                32)
                    cfg_sw=
                    ;;
                64)
                    cfg_sw="--64"
                    ;;
            esac

            # Install name for dylibs
            # We copy libz.a for package, not dylibs
            install_name="@executable_path/../Resources/libz.1.dylib"

            export MAKEFLAGS="-j${AUTOBUILD_CPU_COUNT:-2}"

            for arch in x86_64 arm64 ; do
                ARCH_ARGS="-arch $arch"
                cc_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $cc_opts)"
                ld_opts="$ARCH_ARGS -Wl,-install_name,\"${install_name}\" -Wl,-headerpad_max_install_names"
                export CC=clang

                # release
                CFLAGS="$cc_opts" \
                LDFLAGS="$ld_opts" \
                ARCH="$arch" \
                    ./configure $cfg_sw --prefix="$stage" --includedir="$stage/include/zlib-ng" --libdir="$stage/lib/release/$arch" --zlib-compat --static
                make
                make install

                # conditionally run unit tests only on native host architecture
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" -a "$arch" = "$(uname -m)" ]; then
                    # Build a Resources directory as a peer to the test executable directory
                    # and fill it with symlinks to the dylibs.  This replicates the target
                    # environment of the viewer.
                    mkdir -p ../Resources
                    ln -sf "${stage}"/lib/release/$arch/*.dylib ../Resources

                    make test

                    # And wipe it
                    rm -rf ../Resources
                fi

                make distclean
            done

            lipo -create -output "$stage/lib/release/libz.a" "$stage/lib/release/x86_64/libz.a" "$stage/lib/release/arm64/libz.a" 
        ;;            

        # -------------------------- linux, linux64 --------------------------
        linux*)

            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CC CXX CFLAGS CPPFLAGS CXXFLAGS

            # Prefer gcc-4.6 if available.
            if [[ -x /usr/bin/gcc-4.6 && -x /usr/bin/g++-4.6 ]]; then
                export CC=/usr/bin/gcc-4.6
                export CXX=/usr/bin/g++-4.6
            fi

            # Default target per autobuild build --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"

            # Handle any deliberate platform targeting
            if [ ! "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Release
            CFLAGS="$(remove_cxxstd $opts)" CXXFLAGS="$opts" \
                ./configure --prefix="$stage" --includedir="$stage/include/zlib-ng" --libdir="$stage/lib/release" --zlib-compat
            make
            make install

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                make test
            fi

            # clean the build artifacts
            make distclean
        ;;
    esac

    mkdir -p "$stage/LICENSES"
    cp LICENSE.md "$stage/LICENSES/zlib-ng.txt"
popd

mkdir -p "$stage"/docs/zlib-ng/
