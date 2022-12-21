#!/usr/bin/env bash

set -o errexit -o pipefail

readonly __VERSION__='1.0'
readonly __IMAGE_VERSION__='1.0'
__DIR__="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly __DIR__
readonly __CONTAINER_NAME__='containerized_android_builder'
readonly __REPOSITORY__="iusmac/$__CONTAINER_NAME__"
readonly __IMAGE_TAG__="$__REPOSITORY__:v$__IMAGE_VERSION__"
readonly __MENU_BACKTITLE__="ContainerizedAndroidBuilder v$__VERSION__ (using Docker image v$__IMAGE_VERSION__) | (c) 2022 iusmac"
declare -rA __USER_IDS__=(
    ['uid']="$(id --user "$USER")"
    ['gid']="$(id --group "$USER")"
)
declare -A __ARGS__=(
    ['android']=''
    ['email']='docker@localhost'
    ['repo-url']=''
    ['repo-revision']=''
    ['lunch-system']=''
    ['lunch-device']=''
    ['lunch-flavor']=''
    ['src-dir']="$PWD"/src
    ['out-dir']="$PWD"/out
    ['zips-dir']="$PWD"/zips
    ['move-zips']=0
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

    mkdir -p logs/ .home/ \
        "${__ARGS__['src-dir']}"/.repo/local_manifests/ \
        "${__ARGS__['out-dir']}" \
        "${__ARGS__['zips-dir']}" \
        "${__ARGS__['ccache-dir']}"

    local param value
    while [ $# -gt 0 ]; do
        param="${1:2}"; value="$2"

        if [ "$param" = 'version' ]; then
            printf -- "ContainerizedAndroidBuilder v%s (using Docker image v%s)\n" \
                "$__VERSION__" "$__IMAGE_VERSION__"
            exit 0
        fi

        if [ "$param" = 'help' ]; then
            printHelp
            exit 0
        fi

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

    for arg in \
        'android' \
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
            '3) Stop tasks' 'Stop gracefully running tasks' \
            '4) Jump inside' 'Get into the Docker container shell' \
            '5) Progress' 'Show current build state' \
            '6) Logs' 'Show previous build logs' \
            '7) Suspend/Hibernate' 'Suspend or hibernate this machine' \
            '8) Self-update' 'Get the latest version' \
            '9) Self-destroy' 'Stop all tasks and remove Docker image' \
            3>&1 1>&2 2>&3)"; then
            return 0
        fi

        case "$action" in
            1*) sourcesMenu;;
            2*) buildMenu;;
            3*) stopMenu;;
            4*) runInContainer /bin/bash;;
            5*) progressMenu;;
            6*) logsMenu;;
            7*) suspendMenu;;
            8*) selfUpdateMenu;;
            9*) selfDestroyMenu;;
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
            '2) Sync All' 'Sync all sources' \
            '3) Selective Sync' 'Selectively sync projects in "local_manifests/"' \
            '4) Selective Sync (cached)' 'Same as option n.3 but reuses a cached repo list' \
            3>&1 1>&2 2>&3)"; then
            return 0
        fi

        if [ -d local_manifests ]; then
            rsync --archive \
                --delete \
                --include '*/' \
                --include '*.xml' \
                --exclude '*' \
                local_manifests/ "${__ARGS__['src-dir']}"/.repo/local_manifests/
        fi

        case "$action" in
            1*) sourcesMenu__repoInit;;
            2*) sourcesMenu__repoSync;;
            3*) sourcesMenu__repoSyncLocalManifest;;
            4*) sourcesMenu__repoSyncLocalManifest \
                "$(cat .home/.repo-list.raw 2>/dev/null)";;
            *) printf "Undefined source menu action: %s\n" "$action" >&2
                exit 1
        esac
    done
}

function sourcesMenu__repoInit() {
    if ! containerQuery 'repo-init' \
        "${__ARGS__['repo-url']}" \
        "${__ARGS__['repo-revision']}"; then
            showLogs
    fi
}

function sourcesMenu__repoSync() {
    local jobs
    if ! jobs="$(insertJobNum)"; then
        return 0
    fi

    if containerQuery 'repo-sync' "$jobs" "$@"; then
        whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Success' \
            --msgbox 'The source code was successfully synced' \
            0 0
    else
        showLogs
    fi
}

function sourcesMenu__repoSyncLocalManifest() {
    local repo_list_raw="${1:-}"
    if [ -z "$repo_list_raw" ]; then
        printf "Generating project list...\n"
        if ! repo_list_raw="$(containerQuery 'repo-local-list')"; then
            printf -- "%s\n" "$repo_list_raw" >&2
            showLogs
            return 0
        fi
        echo "$repo_list_raw" > .home/.repo-list.raw
    fi

    declare -a repo_list=()
    local path
    while IFS=$'\n\r' read -r path; do
        if [ -z "$path" ]; then
            continue
        fi

        repo_list+=("$path" '' 'OFF')
    done <<< "$repo_list_raw"

    if [ ${#repo_list[@]} -eq 0 ]; then
        local msg
        msg="$(cat << EOL
No projects found in your local_manifests/ or a
full sync was never executed.
EOL
        )"
        whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Error' \
            --msgbox "$msg" \
            0 0

        return 0
    fi

    local choices
    if ! choices="$(whiptail \
        --backtitle "$__MENU_BACKTITLE__" \
        --title 'Project list' \
        --checklist \
        --separate-output \
        "Select projects to sync\nHint: use space bar to select" 0 0 0 \
        "${repo_list[@]}" \
        3>&1 1>&2 2>&3)"; then
        return 0
    fi

    declare -a repo_list_choices=()
    while read -r path; do
        if [ -z "$path" ]; then
            continue
        fi

        repo_list_choices+=("$path")
    done <<< "$choices"

    if [ ${#repo_list_choices[@]} -eq 0 ]; then
        return 0
    fi

    sourcesMenu__repoSync "${repo_list_choices[@]}"
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
            '3) Build SELinux Policy' 'Start/resume SELinux Policy build only' \
            3>&1 1>&2 2>&3)"; then
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
            3*) query='build-selinux';;
            *) printf "Undefined build menu action: %s\n" "$action" >&2
                exit 1
        esac

        containerQuery "$query" \
            "${__ARGS__['lunch-system']}" \
            "${__ARGS__['lunch-device']}" \
            "${__ARGS__['lunch-flavor']}" \
            $build_metalava \
            "$jobs"

        exit $?
    done
}

function stopMenu() {
    local msg
    msg="$(cat << EOL
Are you sure you want to stop whatever is running in container
(ROM/Kernel/SELinux building or source tree syncing)?
EOL
)"
    if ! whiptail \
        --title 'Graceful stop' \
        --yesno "$msg" \
        --defaultno \
        0 0 \
        3>&1 1>&2 2>&3; then
        return 0
    fi

    if ! assertIsRunningContainer; then
        whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Error' \
            --msgbox "No tasks are currently running." \
            0 0

        return 0
    fi

    coproc { sudo docker container stop "$__CONTAINER_NAME__"; }
    local pid="$COPROC_PID"

    printf "Attempt to gracefully stop all tasks...\n"
    if wait "$pid"; then
        whiptail \
            --backtitle "$__MENU_BACKTITLE__" \
            --title 'Success' \
            --msgbox "All tasks were successfully stopped." \
            0 0
    else
        showLogs
    fi
}

function suspendMenu() {
    local action
    if ! action="$(whiptail \
        --backtitle "$__MENU_BACKTITLE__" \
        --title 'Suspend/Hibernate' \
        --menu 'Select power-off type' 0 0 0 \
        --cancel-button 'Return' \
        '1) Suspend' 'Save the session to RAM and put the PC in low power consumption mode' \
        '2) Hibernate' 'Save the session to disk and completely power off the PC' \
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

    case "$action" in
        1*) systemctl suspend;;
        2*) systemctl hibernate;;
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

function selfUpdateMenu() {
    if [ ! -d .git ]; then
        printf "Cannot find '.git' directory. Please, follow the installation\n" >&2
        printf "guide and make sure the directory structure complies with\n" >&2
        printf "the requirements.\n" >&2
        exit 1
    fi

    if assertIsRunningContainer; then
        printf "Found a running container, stopping...\n" >&2
        sudo docker container stop $__CONTAINER_NAME__ || exit $?
    fi

    git pull --recurse-submodules --force --rebase || exit $?

    printf "You've successfully upgraded. Run the builder again when you wish it ;)\n"
    exit 0
}

function selfDestroyMenu() {
    local msg; msg="$(cat << EOL
Are you sure you want to kill all running tasks and remove Docker image from disk?

NOTE: this won't remove sources or out files. You have to remove
      them manually.
EOL
    )"
    if ! whiptail \
        --title 'Self-destroy' \
        --yesno "$msg" \
        --defaultno \
        0 0 \
        3>&1 1>&2 2>&3; then
        return 0
    fi

    if assertIsRunningContainer; then
        printf "Found a running container, stopping...\n" >&2
        sudo docker container stop $__CONTAINER_NAME__ || exit $?
    fi

    local img_list id tag
    printf "Retrieving image list...\n" >&2
    img_list="$(getImageList)"

    while IFS='=' read -r id tag; do
        if [ -n "$id" ] && [ -n "$tag" ]; then
            printf "Removing image with tag: %s\n" "$tag" >&2
            sudo docker rmi "$id"
        fi
    done <<< "$img_list"

    if [ -z "$img_list" ]; then
        printf "No images to remove.\n" >&2
    fi
}

function containerQuery() {
    local query="${1?}"; shift
    runInContainer /mnt/entrypoint/entrypoint.sh "$query" "$@"
}

function buildImageIfNone() {
    local home="/home/android"
    if ! sudo docker inspect --type image "$__IMAGE_TAG__" &> /dev/null; then
        local id tag
        while IFS='=' read -r id tag; do
            if [ -n "$id" ] && [ -n "$tag" ] && [ "$tag" != $__IMAGE_VERSION__ ]; then
                printf "Removing unused image with tag: %s\n" "$tag" >&2
                sudo docker rmi "$id"
            fi
        done <<< "$(getImageList)"

        printf "Note: Unable to find '%s' image. Start building...\n" "$__IMAGE_TAG__" >&2
        printf "This may take a while...\n\n" >&2
        sudo DOCKER_BUILDKIT=1 docker build \
            --no-cache \
            --build-arg EMAIL="${__ARGS__['email']}" \
            --build-arg UID="${__USER_IDS__['uid']}" \
            --build-arg GID="${__USER_IDS__['gid']}" \
            --tag "$__IMAGE_TAG__" "$__DIR__"/Dockerfile/ || exit $?
    fi

    if [ ! -d .home ]; then
        printf "Extracting .home directory...\n" >&2
        sudo docker run \
            --interactive \
            --rm \
            --name "$__CONTAINER_NAME__" \
            --detach=true \
            "$__IMAGE_TAG__" >&2 &&

        sudo docker container cp \
            --archive \
            "$__CONTAINER_NAME__":"$home"/. .home &&

        # TODO: this is a workaround because '--archive' argument for 'docker
        # container cp' command is broken. Check from time to time if it has
        # been fixed.
        sudo find .home -exec chown \
            --silent \
            --recursive \
            "${__USER_IDS__['uid']}":"${__USER_IDS__['gid']}" \
            {} \+

        printf "Finishing...\n" >&2
        sudo docker container stop "$__CONTAINER_NAME__" >/dev/null || exit $?
    fi
}

function runInContainer() {
    local home="/home/android"
    local use_ccache=${__ARGS__['ccache-disabled']}
    use_ccache=$((use_ccache ^= 1))

    buildImageIfNone

    if ! assertIsRunningContainer; then
        sudo docker run \
            --detach \
            --interactive \
            --rm \
            --name "$__CONTAINER_NAME__" \
            --tmpfs /tmp:rw,exec,nosuid,nodev,uid="${__USER_IDS__['uid']}",gid="${__USER_IDS__['gid']}" \
            --privileged \
            --env ANDROID_VERSION="${__ARGS__['android']}" \
            --env TZ="${__ARGS__['timezone']}" \
            --env USE_CCACHE="$use_ccache" \
            --env MOVE_ZIPS="${__ARGS__['move-zips']}" \
            --env CCACHE_SIZE="${__ARGS__['ccache-size']}" \
            --volume /etc/timezone:/etc/timezone:ro \
            --volume /etc/localtime:/etc/localtime:ro \
            --volume "$__DIR__"/entrypoint:/mnt/entrypoint \
            --volume "${__ARGS__['out-dir']}":/mnt/out \
            --volume "${__ARGS__['ccache-dir']}":/mnt/ccache \
            --volume "${__ARGS__['src-dir']}":/mnt/src \
            --volume "${__ARGS__['zips-dir']}":/mnt/zips \
            --volume "$PWD"/logs:/mnt/logs \
            --volume "$PWD"/.home:"$home" \
            "$__IMAGE_TAG__" >&2 || exit $?
    fi

    sudo docker container exec \
        --interactive \
        --tty \
        --privileged \
        --env ANDROID_VERSION="${__ARGS__['android']}" \
        --env TZ="${__ARGS__['timezone']}" \
        --env USE_CCACHE="$use_ccache" \
        --env MOVE_ZIPS="${__ARGS__['move-zips']}" \
        --env CCACHE_SIZE="${__ARGS__['ccache-size']}" \
        $__CONTAINER_NAME__ "$@" || exit $?
}

function getImageList() {
    sudo docker images --format '{{.ID}}={{.Tag}}' $__REPOSITORY__
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

function printHelp() {
    printf -- "%s\n" "$(cat << EOL
Usage: ./${BASH_SOURCE[0]}
    --android ANDROID
    --repo-url REPO_URL
    --repo-revision REPO_REVISION
    --lunch-system LUNCH_SYSTEM
    --lunch-device LUNCH_DEVICE
    --lunch-flavor LUNCH_FLAVOR
    [--email EMAIL]
    [--src-dir SRC_DIR]
    [--out-dir OUT_DIR]
    [--zips-dir ZIPS_DIR]
    [--move-zips MOVE_ZIPS]
    [--ccache-dir CCACHE_DIR]
    [--ccache-disabled]
    [--ccache-size CCACHE_SIZE]
    [--timezone TIMEZONE]
    [--help] [--version]
EOL
    )"
}

function trapCallback() {
    # Fix cursor on exit if docker container is running using TTY.
    tput cnorm
}

trap trapCallback EXIT

main "$@"
