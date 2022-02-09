#!/usr/bin/env bash

function main() {
    local query="$1"; shift
    case "$query" in
        'repo-init')
            local repo_url="${1?}"
            local repo_revision="${2?}"

            log "Initializing repo '$repo_url' on revision '$repo_revision'..."
            yes | repo init \
                --depth=1 \
                --groups=default,-mips,-darwin \
                --manifest-url="$repo_url" \
                --manifest-branch="$repo_revision"
            ;;
        'repo-sync')
            local jobs="${1?}"

            log "Syncing sources ($jobs jobs)..."
            repo sync \
                --current-branch \
                --fail-fast \
                --force-sync \
                --no-clone-bundle \
                --no-tags \
                --optimized-fetch \
                --jobs="$jobs"
            ;;
        'build-rom'|'build-kernel')
            local lunch_system="${1?}" \
                lunch_device="${2?}" \
                lunch_flavor="${3?}" \
                build_metalava="${4?}" \
                jobs="${5?}"

            if [ "${USE_CCACHE:-0}" = '1' ]; then
                ccache --max-size "$CCACHE_SIZE" || exit $?
            fi

            log 'Running envsetup.sh...'
            # shellcheck disable=SC1091
            source build/envsetup.sh || exit $?

            log "Preparing $lunch_system build for $lunch_device ($lunch_flavor)..."
            lunch "$lunch_system"_"$lunch_device"-"$lunch_flavor" || exit $?

            if [ "$build_metalava" = 'true' ]; then
                build_metalava "$jobs" || exit 1
            fi

            local task
            if [ "$query" = 'build-rom' ]; then
                log 'Start building ROM...'
                task='bacon'
            elif [ "$query" = 'build-kernel' ]; then
                log 'Start building Kernel...'
                task='bootimage'
            else
                printf "This message should never be displayed!\n" >&2
                exit 1
            fi

            mka $task -j"$jobs"
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
