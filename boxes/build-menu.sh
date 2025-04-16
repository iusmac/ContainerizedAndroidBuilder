#!/usr/bin/env bash

config title="$1"

function main() {
    declare -g -ix build_rc=0

    menu \
        text='Select an action' \
        prefix='num' \
        [ title='Build ROM'             summary='Start/resume a ROM build'                callback='build_rom()' ] \
        [ title='Build Kernel'          summary='Start/resume a Kernel build only'        callback='build_kernel()' ] \
        [ title='Build SELinux Policy'  summary='Start/resume SELinux Policy build only'  callback='build_selinux()' ]
    menuDraw

    # Unexport variable to prevent propagation to parent (main) menu
    declare -g +x build_rc

    return $build_rc
}

function build_rom() {
    build_target 'build-rom'
}

function build_kernel() {
    build_target 'build-kernel'
}

function build_selinux() {
    build_target 'build-selinux'
}

function build_target() {
    config hideBreadcrumb='true'

    local query="${1?}" build_metalava='false'
    if confirm \
        text="$(cat << EOL
Do you want to (re)build metalava doc packages before actually
initializing the build?

NOTE: building metalava doc packages separately allows to avoid
      huge compile times.
      Keep in mind, that you will need to rebuild metalava every
      time you make significant changes to the Android source code,
      e.g., after 'repo sync'.
EOL
    )"; then
        build_metalava='true'
    fi

    local jobs
    if ! jobs="$(insertJobNum)"; then
        return 1
    fi

    containerQuery "$query" \
        "${__ARGS__['lunch-system']}" \
        "${__ARGS__['lunch-device']}" \
        "${__ARGS__['lunch-flavor']}" \
        $build_metalava \
        "$jobs"; build_rc=$?
    return 0
}

main "$@"
