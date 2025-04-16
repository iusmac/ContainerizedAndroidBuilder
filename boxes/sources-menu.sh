#!/usr/bin/env bash

config title="$1"

function main() {
    if [ -d local_manifests ]; then
        rsync --archive \
            --delete \
            --include '*/' \
            --include '*.xml' \
            --exclude '*' \
            local_manifests/ "${__ARGS__['src-dir']}"/.repo/local_manifests/
    fi

    menu \
        text='Select an action' \
        cancelLabel='Return' \
        prefix='num' \
        loop='true' \
        [ title='Init'                     summary='Set repo URL to an android project'                callback='handle_repo_init()' ] \
        [ title='Sync All'                 summary='Sync all sources'                                  callback='handle_repo_sync()' ] \
        [ title='Selective Sync'           summary='Selectively sync projects in "local_manifests/"'   callback='handle_repo_sync_local_manifest()' ] \
        [ title='Selective Sync (cached)'  summary='Same as option n.3 but reuses a cached repo list'  callback='handle_repo_sync_local_manifest_cached()' ]
    menuDraw
    return 0
}

function handle_repo_init() {
    if ! containerQuery 'repo-init' "${__ARGS__['repo-url']}" "${__ARGS__['repo-revision']}"; then
        showLogs
    fi
}

function handle_repo_sync() {
    config title="$1"
    # shellcheck disable=2119
    repo_sync
}

# shellcheck disable=2120
function repo_sync() {
    local jobs
    if ! jobs="$(insertJobNum)"; then
        return 0
    fi

    if containerQuery 'repo-sync' "$jobs" "$@"; then
        text summary='The source code was successfully synced'
    else
        showLogs
    fi
    return 0
}

function handle_repo_sync_local_manifest() {
    config title="$1"
    repo_sync_projects
}

function handle_repo_sync_local_manifest_cached() {
    config title="$1"
    repo_sync_projects "$(cat "$__HOME_DIR__"/.repo-list.raw 2>/dev/null)"
}

function repo_sync_projects() {
    local repo_list_raw="${1:-}"
    if [ -z "$repo_list_raw" ]; then
        info text='Generating project list...'
        if ! repo_list_raw="$(containerQuery 'repo-local-list')"; then
            printf -- "%s\n" "$repo_list_raw" >&2
            showLogs
            return 0
        fi
        echo "$repo_list_raw" > "$__HOME_DIR__"/.repo-list.raw
        clear
    fi

    list \
        text='Select projects to sync\nHint: use space bar to select' \
        callback='repo_sync()'

    local path total=0
    while IFS=$'\n\r' read -r path; do
        if [ -n "$path" ]; then
            listEntry title="$path"
            total=$((total+1))
        fi
    done <<< "$repo_list_raw"

    if [ $total -gt 0 ]; then
        listDraw
    else
        text text='No projects found in your local_manifests/ or a full sync was never executed.'
    fi
    return 0
}

main "$@"
