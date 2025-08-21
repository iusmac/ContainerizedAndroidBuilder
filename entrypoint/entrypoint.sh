#!/usr/bin/env bash

function main() {
    local query="$1"; shift
    case "$query" in
        'repo-init')
            local repo_url="${1?}"
            local repo_revision="${2?}"

            log 'Initializing repo...' \
                "- URL: $repo_url" \
                "- Revision: $repo_revision"

            yes | repo init \
                --depth=1 \
                --groups=default,-mips,-darwin \
                --manifest-url="$repo_url" \
                --manifest-branch="$repo_revision" \
                --git-lfs
            ;;
        'repo-sync')
            local jobs="${1?}"; shift
            local -a extra_args

            if [ $# -gt 0 ]; then
                log "Syncing sources ($jobs jobs):" "$@"
                extra_args+=('--no-manifest-update')
            else
                log "Syncing all sources ($jobs jobs)..."
            fi

            repo sync \
                --current-branch \
                --fail-fast \
                --force-sync \
                --no-clone-bundle \
                --no-tags \
                --optimized-fetch \
                --jobs="$jobs" "${extra_args[@]}" -- "$@"
            ;;
        'repo-local-list')
            local path list
            if ! list="$(repo list --path-only 2>&1)"; then
                printf "%s\n" "$list"
                return 1
            fi
            while read -r path; do
                if grep \
                    --recursive \
                    --quiet \
                    "<project.*path=\"$path\"" .repo/local_manifests/; then
                    printf -- "%s\n" "$path"
                fi
            done <<< "$list"
            ;;
        'build-rom'|'build-kernel'|'build-selinux')
            local lunch_system="${1?}" \
                lunch_device="${2?}" \
                lunch_flavor="${3?}" \
                build_metalava="${4?}" \
                jobs="${5?}"

            local lunch_release
            if isAtLeastU; then
                local build_id;
                if ! build_id="$(grep --max-count=1 'BUILD_ID=' build/core/build_id.mk)" ||
                    ! lunch_release="$(sed -n 's/BUILD_ID=\([^\.]\+\).*/\L\1/p' <<< "$build_id")" ||
                    [ -z "$lunch_release" ]; then
                    printf "Failed to parse release branch name for lunch command.\n" >&2
                    exit 1
                fi
            fi

            log 'Initializing build...' \
                "- Lunch system: $lunch_system" \
                "- Lunch device: $lunch_device" \
                "- Lunch release: $lunch_release" \
                "- Lunch flavor: $lunch_flavor" \
                "- Ccache enabled: $USE_CCACHE" \
                "- Ccache size: $CCACHE_SIZE" \
                "- Container timezone: $TZ" \

            if [ "${USE_CCACHE:-0}" = '1' ]; then
                ccache --max-size "$CCACHE_SIZE" &&
                ccache --set-config compression=true || exit $?
            fi

            log 'Running envsetup.sh...'
            # shellcheck disable=SC1091
            source build/envsetup.sh || exit $?

            local lunch_target="${lunch_system}_${lunch_device}"
            if [ -n "$lunch_release" ]; then
                lunch_target+="-$lunch_release"
            fi
            lunch_target+="-$lunch_flavor"
            log "Running lunch..."
            lunch "$lunch_target" || exit $?

            if [ "$build_metalava" = 'true' ]; then
                build_metalava "$jobs" || exit 1
            fi

            local task
            if [ "$query" = 'build-rom' ]; then
                log "Start building ROM ($jobs jobs)..."
                task='bacon'
            elif [ "$query" = 'build-kernel' ]; then
                log "Start building Kernel ($jobs jobs)..."
                task='bootimage'
            elif [ "$query" = 'build-selinux' ]; then
                log "Start building SELinux Policy ($jobs jobs)..."
                task='selinux_policy'
            else
                printf "This message should never be displayed!\n" >&2
                exit 1
            fi

            m $task -j"$jobs"; local code=$?
            if [ $code -eq 0 ]; then
                if [ "${MOVE_ZIPS:-0}" = '1' ]; then
                    local file_pattern
                    if [ "$query" = 'build-rom' ]; then
                        log 'Moving ZIPs to zips/ directory...'
                        file_pattern="*-*-$lunch_device-*.zip*"
                    elif [ "$query" = 'build-kernel' ]; then
                        log 'Moving boot.img to zips/ directory...'
                        file_pattern='boot.img'
                    fi

                    if [ -n "$file_pattern" ]; then
                        find "$OUT_DIR/target/product/$lunch_device" \
                            -maxdepth 1 \
                            -type f \
                            -name "$file_pattern" \
                            -exec mv --target-directory="$ZIP_DIR" {} + || exit $?
                    fi
                fi

                log 'Building done.'
            else
                log 'Building failed.'
            fi
            exit $code
            ;;
        *) printf "Unrecognized query command: %s\n" "$query"
            exit 1
    esac
}

function build_metalava() {
    case "$ANDROID_VERSION" in
        12|12.*|13|13.0|14|14.0|15|15.0|16|16.0)
            declare -a docs=(
                'test-api-stubs-docs-non-updatable'
                'api-stubs-docs-non-updatable'
                'services-non-updatable-stubs'
            ) ;;
        11|11.0)
            declare -a docs=(
                'api-stubs-docs'
                'module-lib-api-stubs-docs'
                'system-api-stubs-docs'
                'test-api-stubs-docs'
            ) ;;
        10|10.0)
            declare -a docs=(
                'api-stubs-docs'
                'hiddenapi-lists-docs'
                'system-api-stubs-docs '
                'test-api-stubs-docs'
            ) ;;
        *) printf "Metalava: Unsupported Android version: %s\n" "$ANDROID_VERSION"
            exit 1
    esac

    local doc i=0 jobs="${1?}" n_docs=${#docs[@]}

    log "Start building metalava docs ($jobs jobs)..."
    for doc in "${docs[@]}"; do
        i=$((i + 1))
        log "Building metalava doc [$i/$n_docs]: $doc"
        m "$doc" -j"$jobs" || exit $?
    done
    log "Building metalava docs done."
}

function log() {
    local log_file="$LOGS_DIR/progress.log"
    local date; date="$(date)"
    printf ">>[%s] %s\n" "$date" "${1?}" | tee -a "$log_file"

    if [ $# -gt 1 ]; then
        shift
        local n_spaces="$((${#date} + 5))"
        for line in "$@"; do
            printf "%${n_spaces}s%s\n" '' "$line" | tee -a "$log_file"
        done
    fi
}

function isAtLeastU() {
    [[ ${ANDROID_VERSION%%.*} -ge 14 ]]
}

main "$@"
