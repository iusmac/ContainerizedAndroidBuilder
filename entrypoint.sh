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
                --manifest-branch="$repo_revision"
            ;;
        'repo-sync')
            local jobs="${1?}"; shift

            if [ $# -gt 0 ]; then
                log "Syncing sources ($jobs jobs):" "$@"
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
                --jobs="$jobs" -- "$@"
            ;;
        'repo-local-list')
            set -o pipefail

            local path
            repo list --path-only | while read -r path; do
                if grep \
                    --recursive \
                    --quiet \
                    "<project.*path=\"$path\"" .repo/local_manifests/; then
                    printf -- "%s\n" "$path"
                fi
            done
            ;;
        'build-rom'|'build-kernel')
            local lunch_system="${1?}" \
                lunch_device="${2?}" \
                lunch_flavor="${3?}" \
                jobs="${4?}"

            log 'Initializing build...' \
                "- Lunch system: $lunch_system" \
                "- Lunch device: $lunch_device" \
                "- Lunch flavor: $lunch_flavor" \
                "- Ccache enabled: $USE_CCACHE" \
                "- Ccache size: $CCACHE_SIZE" \
                "- Container timezone: $TZ" \

            if [ "${USE_CCACHE:-0}" = '1' ]; then
                ccache --max-size "$CCACHE_SIZE" &&
                ccache --set-config compression=true || exit $?
            fi

            # Forcefully point to out/ dir because we're mounting this
            # directory from the outside and somehow it changes to an absolute
            # path. This will force Soong to look for things in out/ dir using
            # the absolute path and fail if we will change the mount point for
            # some reason.
            export OUT_DIR=out

            log 'Running envsetup.sh...'
            # shellcheck disable=SC1091
            source build/envsetup.sh || exit $?

            log "Running lunch..."
            lunch "${lunch_system}_${lunch_device}-${lunch_flavor}" || exit $?

            local task
            if [ "$query" = 'build-rom' ]; then
                log "Start building ROM ($jobs jobs)..."
                task='bacon'
            elif [ "$query" = 'build-kernel' ]; then
                log "Start building Kernel ($jobs jobs)..."
                task='bootimage'
            else
                printf "This message should never be displayed!\n" >&2
                exit 1
            fi

            m $task -j"$jobs"; local code=$?
            if [ $code -eq 0 ]; then
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

main "$@"
