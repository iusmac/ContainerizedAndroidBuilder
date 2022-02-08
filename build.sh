#!/usr/bin/env bash

set -o errexit -o pipefail

__DIR__="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly __DIR__
readonly __IMAGE_TAG__='iusmac/containerized_android_builder_v1.0'
readonly __CONTAINER_NAME__='containerized_android_builder_v1.0'
readonly __MENU_BACKTITLE__='Android OS Builder v1.0 | (c) 2022 iusmac'
declare -rA __USER_IDS__=(
    ['name']="$USER"
    ['uid']="$(id --user "$USER")"
    ['gid']="$(id --group "$USER")"
)
declare -A __ARGS__=(
    ['email']=''
    ['repo-url']=''
    ['repo-revision']=''
    ['lunch-system']=''
    ['lunch-device']=''
    ['lunch-flavor']=''
    ['src-dir']="$PWD"/src
    ['out-dir']="$PWD"/src/out
    ['ccache-dir']="$PWD"/ccache
    ['ccache-disabled']=0
    ['ccache-size']='30GB'
    ['timezone']="${TZ:-}"
)

function main() {
    if [ "${UID:-}" = '0' ] || [ "${__USER_IDS__['uid']}" = '0' ]; then
        printf "Do not execute this script using sudo.\n" >&2
        printf "You will get sudo prompt in case root privileges are needed.\n" >&2
        exit 1
    fi

    mkdir -p logs/ \
        "${__ARGS__['src-dir']}"/.repo/local_manifests/ \
        "${__ARGS__['out-dir']}" \
        "${__ARGS__['ccache-dir']}"

    local param value
    while [ $# -gt 0 ]; do
        param="${1:2}"; value="$2"

        if [ "$param" = 'ccache-disabled' ]; then
            __ARGS__['ccache-disabled']=1
            shift
        elif [ "${__ARGS__["$param"]+xyz}" ]; then
            __ARGS__["$param"]="$value"
            shift 2
        else
            printf -- "Unrecognized argument: --%s\n" "$param" >&2
            exit 1
        fi
    done

    if [ -z "${__ARGS__['timezone']}" ]; then
        local timezone
        if ! timezone="$(timedatectl | awk '/Time zone:/ { print $3 }')"; then
            timezone="$(curl --fail-early --silent 'http://ip-api.com/line?fields=timezone')"
        fi
        __ARGS__['timezone']="$timezone"
    fi

    for arg in 'email' \
        'repo-url' \
        'repo-revision' \
        'lunch-system' \
        'lunch-device' \
        'lunch-flavor'; do
        if [ -z "${__ARGS__[$arg]}" ]; then
            printf -- "Missing required argument: --%s\n" "$arg" >&2
            exit 1
        fi
    done

    local action
    while true; do
        if ! action="$(whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Main menu'  \
            --cancel-button 'Exit' \
            --menu 'Select an action' 0 0 0 \
            '1) Sources' 'Manage android source code' \
            '2) Build' 'Start/stop or resume a build' \
            '3) Progress' 'Show current build state' \
            '4) Logs' 'Show previous build logs' \
            '5) Suspend/Hibernate' 'Suspend or hibernate this machine' \
            3>&1 1>&2 2>&3)"; then
            return 0
        fi

        case "$action" in
            1*) sourcesMenu;;
            2*) buildMenu;;
            3*) progressMenu;;
            4*) logsMenu;;
            5*) suspendMenu;;
            *) printf "Unrecognized main menu action: %s\n" "$action" >&2
                exit 1
        esac
    done
}

function sourcesMenu() {
    local action jobs
    while true; do
        if ! action="$(whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Sources' \
            --cancel-button 'Return' \
            --menu 'Select an action' 0 0 0 \
            '1) Init' 'Set repo URL to an android project' \
            '2) Sync' 'Sync all sources' \
            3>&1 1>&2 2>&3)"; then
            return 0
        fi

        rsync --archive \
            --delete \
            --include '*.xml' \
            --exclude '*' \
            local_manifests/ "${__ARGS__['src-dir']}"/.repo/local_manifests/

        case "$action" in
            1*) containerQuery 'repo-init' "${__ARGS__['repo-url']}" "${__ARGS__['repo-revision']}";;
            2*) if ! jobs="$(insertJobNum)"; then
                    continue
                fi
                containerQuery 'repo-sync' "$jobs";;
            *) printf "Undefined source menu action: %s\n" "$action" >&2
                exit 1
        esac
    done
}

function buildMenu() {
    local action build_metalava=false metalava_msg jobs query
    while true; do
        if ! action="$(whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Build' \
            --cancel-button 'Return' \
            --menu 'Select an action' 0 0 0 \
            '1) Build ROM' 'Start/resume a ROM build' \
            '2) Build Kernel' 'Start/resume a Kernel build only' \
            '3) Build Stop' 'Stop gracefully the current build' \
            3>&1 1>&2 2>&3)"; then
            return 0
        fi

        if [[ "$action" =~ ^3 ]]; then
            build__stop
            return 0
        fi

        metalava_msg="$(cat << EOL
Do you want to (re)build metalava doc packages before actually
initializing the build?

NOTE: building metalava doc packages separately allows to avoid
      huge compile times.
      Keep in mind, that you will need to rebuild metalava every
      time you make significant changes to the Android source code,
      ex. after 'repo sync'.
EOL
    )"
        if whiptail \
            --title 'Build metalava doc packages' \
            --yesno "$metalava_msg" \
            --defaultno 0 0 3>&1 1>&2 2>&3; then
            build_metalava=true
        fi

        if ! jobs="$(insertJobNum)"; then
            continue
        fi

        case "$action" in
            1*) query='build-rom';;
            2*) query='build-kernel';;
            *) printf "Undefined build menu action: %s\n" "$action" >&2
                exit 1
        esac

        containerQuery "$query" \
            "${__ARGS__['lunch-system']}" \
            "${__ARGS__['lunch-device']}" \
            "${__ARGS__['lunch-flavor']}" \
            $build_metalava \
            "$jobs"
    done
}

function build__stop() {
    if ! whiptail \
        --title 'Build stop' \
        --yesno "Are you sure you want to stop the build?" \
        --defaultno \
        0 0 \
        3>&1 1>&2 2>&3; then
        return 0
    fi

    if ! assertIsRunningContainer; then
        whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Error' \
            --msgbox "The build is not running on container: $__CONTAINER_NAME__" \
            0 0

        return 0
    fi

    coproc { sudo docker container stop "$__CONTAINER_NAME__"; }
    local pid="$COPROC_PID"

    while kill -0 "$pid"; do
        TERM=ansi whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Build stop' \
            --infobox "Trying to stop the build gracefully..." \
            0 0
        sleep 1
    done

    if wait "$pid"; then
        whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Success' \
            --msgbox "The build was successfully stopped." \
            0 0
    else
        showLogs
    fi
}

function suspendMenu() {
    local choice
    if ! choice="$(whiptail \
        --backtitle "$__MENU_BACKTITLE__" \
        --title 'Suspend/Hibernate' \
        --radiolist 'Select power-off type' 0 0 0 \
        --cancel-button 'Return' \
        '1) Suspend' 'Save the session to RAM and put the PC in low power consumption mode' ON \
        '2) Hibernate' 'Save the session to disk and completely power off the PC' OFF \
        3>&1 1>&2 2>&3
    )"; then
        return 0
    fi

    if ! whiptail \
        --title 'Suspend/Hibernate' \
        --yesno "Are you sure you want to suspend/hibernate the machine?" \
        --defaultno \
        0 0 \
        3>&1 1>&2 2>&3; then
        return 0
    fi

    case "$choice" in
        1*) systemctl hibernate;;
        2*) systemctl suspend;;
        *) printf "Undefined suspend menu action: %s\n" "$action" >&2
            exit 1
    esac
}

function progressMenu() {
    until tail --follow logs/progress.log 2>/dev/null; do
        printf "The build has not started yet. Retrying...\n" >&2
        sleep 2
    done
}

function logsMenu() {
    local log_file="${__ARGS__['out-dir']}/verbose.log.gz"
    if ! gzip --test "$log_file"; then
        printf "Failed to read logs.\n" >&2
        printf "Hint: If the build is currently running, try again\n" >&2
        printf "after the build will terminate.\n\n" >&2
        showLogs
        return 0
    fi

    gzip --stdout --decompress "$log_file" | less -R
}

function containerQuery() {
    # Build image if does not exist
    if ! sudo docker inspect --type image "$__IMAGE_TAG__" &> /dev/null; then
        sudo DOCKER_BUILDKIT=1 docker build \
            --no-cache \
            --build-arg USER="${__USER_IDS__['name']}" \
            --build-arg EMAIL="${__ARGS__['email']}" \
            --build-arg UID="${__USER_IDS__['uid']}" \
            --build-arg GID="${__USER_IDS__['gid']}" \
            --tag "$__IMAGE_TAG__" "$__DIR__"/Dockerfile/ || exit $?
    fi

    local home="/home/${__USER_IDS__['name']}"
    local query="${1?}"; shift
    local entrypoint="$home"/entrypoint.sh
    if ! sudo docker run \
        --tty \
        --rm \
        --name "$__CONTAINER_NAME__" \
        --tmpfs /tmp:rw,exec,nosuid,nodev,uid="${__USER_IDS__['uid']}",gid="${__USER_IDS__['gid']}" \
        --privileged \
        --env TZ="${__ARGS__['timezone']}" \
        --env USE_CCACHE="$((__ARGS__['ccache-disabled'] ^= 1))" \
        --env CCACHE_SIZE="${__ARGS__['ccache-size']}" \
        --volume /etc/timezone:/etc/timezone:ro \
        --volume /etc/localtime:/etc/localtime:ro \
        --volume "$__DIR__"/entrypoint.sh:"$entrypoint" \
        --volume "${__ARGS__['out-dir']}":"$home"/src/out \
        --volume "${__ARGS__['ccache-dir']}":"$home"/ccache \
        --volume "${__ARGS__['src-dir']}":"$home"/src \
        --volume "$PWD"/logs:"$home"/logs \
        "$__IMAGE_TAG__" \
        "$entrypoint" "$query" "$@"; then
        showLogs
    else
        whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Success' \
            --msgbox 'The build was successfully terminated' \
            0 0
    fi
}

function insertJobNum() {
    local jobs msg
    msg="$(cat << EOL
Insert how many jobs you want run in parallel?

NOTE: this number, N, is the same as the one you normally use while
      running 'make -jN' or 'repo sync -jN'.
EOL
    )"
whiptail \
    --backtitle "$__MENU_BACKTITLE__" \
    --title 'Job number' \
    --inputbox "$msg" \
    0 0 "$(nproc --all)" \
    3>&1 1>&2 2>&3
}

function assertIsRunningContainer() {
    local id
    id="$(sudo docker container ls \
        --filter name=$__CONTAINER_NAME__ \
        --filter status=running \
        --quiet)"

    test -n "$id"
}

function clearLine() {
    tput cr; tput el
}

function showLogs() {
    read -n1 -rsp 'Press any key to return...'
    clearLine
}

function trapCallback() {
    # Fix cursor on exit if docker container is running using TTY.
    tput cnorm
}

trap trapCallback EXIT

main "$@"
