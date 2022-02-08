#!/usr/bin/env bash

function main() {
    local query="$1"; shift
    case "$query" in
        'repo-init')
            local repo_url="${1?}"
            local repo_revision="${2?}"
            yes | repo init --depth=1 -u "$repo_url" -b "$repo_revision"
            ;;
        'repo-sync')
            local jobs="${1?}"
            repo sync -c \
                --fail-fast \
                --force-sync \
                --no-clone-bundle \
                --no-tags \
                --optimized-fetch \
                --prune \
                -j"$jobs"
            ;;
        'build-rom'|'build-kernel')
            local lunch_system="${1?}" \
                lunch_device="${2?}" \
                lunch_flavor="${3?}" \
                build_metalava="${4?}" \
                jobs="${5?}"

            if [ "${USE_CCACHE:-0}" = '1' ]; then
                ccache -M "$CCACHE_SIZE" || exit $?
            fi

            log 'Running envsetup.sh...'
            # shellcheck disable=SC1091
            source build/envsetup.sh || exit $?

            log 'Preparing build...'
            lunch "$lunch_system"_"$lunch_device"-"$lunch_flavor" || exit $?

            if [ "$build_metalava" = 'true' ]; then
                build_metalava "$jobs" || exit 1
            fi

            if [ "$query" = 'bulid-rom' ]; then
                log 'Building ROM...'
                mka bacon -j"$jobs"
            else
                log 'Building Kernel...'
                mka bootimage -j"$jobs"
            fi
            ;;
        *) printf "Unrecognized query command: %s\n" "$query"
            exit 1
    esac
}

function build_metalava() {
    declare -a docs=(
        'api-stubs-docs'
        'module-lib-api-stubs-docs'
        'system-api-stubs-docs'
        'test-api-stubs-docs'
    )

    local doc i=0 jobs="${1?}"
    for doc in "${docs[@]}"; do
        i=$((i + 1))
        log "Building metalava ($doc) [$i/${#docs[@]}]..."
        mka "$doc" -j"$jobs" || exit $?
    done
}

function log() {
    printf ">>[%s] %s\n" "$(date)" "${1?}" | tee -a "$LOGS_DIR/progress.log"
}

main "$@"
