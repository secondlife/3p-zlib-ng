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

# remove_cxxstd apply_patch
source "$(dirname "$AUTOBUILD_VARIABLES_FILE")/functions"

apply_patch "$top/patches/fix-macos-arm64-and-win-build.patch" "$ZLIB_SOURCE_DIR"

pushd "$ZLIB_SOURCE_DIR"
    case "$AUTOBUILD_PLATFORM" in

        # ------------------------ windows, windows64 ------------------------
        windows*)
            load_vsvars

            # zlib-ng already has a win32 folder and win32 build will fail
            mkdir -p "WIN"
            pushd "WIN"

            opts="$(replace_switch /Zi /Z7 $LL_BUILD_RELEASE)"
            plainopts="$(remove_switch /GR $(remove_cxxstd $opts))"

            cmake -G "Ninja Multi-Config" .. -DBUILD_SHARED_LIBS=OFF -DZLIB_COMPAT:BOOL=ON \
                    -DCMAKE_C_FLAGS="$plainopts" \
                    -DCMAKE_CXX_FLAGS="$opts /EHsc" \
                    -DCMAKE_INSTALL_PREFIX="$(cygpath -m $stage)" \
                    -DCMAKE_INSTALL_LIBDIR="$(cygpath -m "$stage/lib/release")" \
                    -DCMAKE_INSTALL_INCLUDEDIR="$(cygpath -m "$stage/include/zlib-ng")"

            cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
            cmake --install . --config Release

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
            fi

            mv "$stage/lib/release/zlibstatic.lib" "$stage/lib/release/zlib.lib"

            # WIN
            popd
        ;;

        # ------------------------- darwin, darwin64 -------------------------
        darwin*)
            export MACOSX_DEPLOYMENT_TARGET="$LL_BUILD_DARWIN_DEPLOY_TARGET"

            for arch in x86_64 arm64 ; do
                ARCH_ARGS="-arch $arch"
                cc_opts="${TARGET_OPTS:-$ARCH_ARGS $LL_BUILD_RELEASE}"
                cc_opts="$(remove_cxxstd $cc_opts)"
                ld_opts="$ARCH_ARGS"

                mkdir -p "build_$arch"
                pushd "build_$arch"
                    CFLAGS="$cc_opts" \
                    LDFLAGS="$ld_opts" \
                    cmake .. -G "Ninja Multi-Config" -DBUILD_SHARED_LIBS:BOOL=OFF -DZLIB_COMPAT:BOOL=ON \
                        -DCMAKE_BUILD_TYPE="Release" \
                        -DCMAKE_C_FLAGS="$cc_opts" \
                        -DCMAKE_CXX_FLAGS="$cc_opts" \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DCMAKE_INSTALL_LIBDIR="$stage/lib/release/$arch" \
                        -DCMAKE_INSTALL_INCLUDEDIR="$stage/include/zlib-ng" \
                        -DCMAKE_OSX_ARCHITECTURES="$arch" \
                        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}

                    cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT
                    cmake --install . --config Release

                    # conditionally run unit tests
                    if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                        ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                    fi
                popd
            done

            lipo -create -output "$stage/lib/release/libz.a" "$stage/lib/release/x86_64/libz.a" "$stage/lib/release/arm64/libz.a"
        ;;

        # -------------------------- linux, linux64 --------------------------
        linux*)
            # Default target per autobuild build --address-size
            opts="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE}"

            # Release
            mkdir -p "build"
            pushd "build"
                cmake .. -GNinja -DBUILD_SHARED_LIBS:BOOL=OFF -DZLIB_COMPAT:BOOL=ON \
                    -DCMAKE_BUILD_TYPE="Release" \
                    -DCMAKE_C_FLAGS="$(remove_cxxstd $opts)" \
                    -DCMAKE_CXX_FLAGS="$opts" \
                    -DCMAKE_INSTALL_PREFIX="$stage" \
                    -DCMAKE_INSTALL_LIBDIR="$stage/lib/release" \
                    -DCMAKE_INSTALL_INCLUDEDIR="$stage/include/zlib-ng"

                cmake --build . --config Release
                cmake --install . --config Release

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release --parallel $AUTOBUILD_CPU_COUNT
                fi
            popd
        ;;
    esac

    mkdir -p "$stage/LICENSES"
    cp LICENSE.md "$stage/LICENSES/zlib-ng.txt"
popd

mkdir -p "$stage"/docs/zlib-ng/
