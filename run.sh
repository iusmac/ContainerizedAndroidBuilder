#!/usr/bin/env bash

readonly __VERSION__='1.5.0'
readonly __IMAGE_VERSION__='1.2'
__DIR__="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly __DIR__
readonly __CONTAINER_NAME__='containerized_android_builder'
readonly __REPOSITORY__="iusmac/$__CONTAINER_NAME__"
readonly __IMAGE_TAG__="$__REPOSITORY__:v$__IMAGE_VERSION__"
readonly __CACHE_DIR__='cache'
readonly __MISC_DIR__='misc'
readonly __HOME_DIR__="$__CACHE_DIR__/home"
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

source "$__DIR__"/boxlib/core.sh

config \
    headerTitle="ContainerizedAndroidBuilder v$__VERSION__ (using Docker image v$__IMAGE_VERSION__) / (c) 2022 iusmac" \
    changeToCallbackDir='false'

function main() {
    if [ $# -eq 0 ]; then
        printHelp
        exit 0
    fi
    if [ "${UID:-}" = '0' ] || [ "${__USER_IDS__['uid']}" = '0' ]; then
        printf "Do not execute this script using sudo.\n" >&2
        printf "You will get sudo prompt in case root privileges are needed.\n" >&2
        exit 1
    fi

    mkdir -p logs/ "$__CACHE_DIR__"/ "$__MISC_DIR__"/ \
        "${__ARGS__['src-dir']}"/.repo/local_manifests/ \
        "${__ARGS__['out-dir']}" \
        "${__ARGS__['zips-dir']}" \
        "${__ARGS__['ccache-dir']}"

    local arg param value
    while [ $# -gt 0 ]; do
        arg="$1"
        param="${1:2}"
        case "$param" in
            'version')
                printf -- "ContainerizedAndroidBuilder v%s (using Docker image v%s)\n" \
                    "$__VERSION__" "$__IMAGE_VERSION__"
                exit 0
                ;;
            'help')
                printHelp
                exit 0
                ;;
            'ccache-disabled')
                value=1
                shift
                ;;
            *=*) # equal sign as delim: param=value
                IFS='=' read -r param value <<< "$param"
                shift
                ;;
            *) # whitespace as delim: param value
                value="$2"
                shift 2 || true
        esac

        if [ -n "$param" ] && [ "${__ARGS__["$param"]+xyz}" ]; then
            __ARGS__["$param"]="$value"
        else
            printf -- "Unrecognized argument: %s\n" "$arg" >&2
            exit 1
        fi
    done

    local -n timezone=__ARGS__['timezone']
    if [ -z "$timezone" ]; then
        if ! timezone="$(timedatectl show -P 'Timezone' 2>/dev/null)" &&
            # Note: /etc/timezone can be a directory (seen on Ubuntu Server) or
            # absent (e.g., Manjaro)
            [ -f /etc/timezone ]; then
            timezone="$(cat /etc/timezone)"
        fi
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

    menu \
        title='Main menu' \
        text='Select an action' \
        cancelLabel='Exit' \
        abortOnCallbackFailure='true' \
        prefix='num' \
        loop='true' \
        [ title='Sources'            summary='Manage android source code'              callback="$__DIR__/boxes/sources-menu.sh" ] \
        [ title='Build'              summary='Start/stop or resume a build'            callback="$__DIR__/boxes/build-menu.sh" ] \
        [ title='Stop tasks'         summary='Stop gracefully running tasks'           callback="$__DIR__/boxes/stop-menu.sh" ] \
        [ title='Jump inside'        summary='Get into the Docker container shell'     callback='handle_jump_inside()' ] \
        [ title='Progress'           summary='Show current build state'                callback='show_build_progress()' ] \
        [ title='Logs'               summary='Show previous build logs'                callback='show_logs()' ] \
        [ title='Suspend/Hibernate'  summary='Suspend or hibernate this machine'       callback="$__DIR__/boxes/suspend-menu.sh" ] \
        [ title='Self-update'        summary='Get the latest version'                  callback="$__DIR__/boxes/self-update-menu.sh" ] \
        [ title='Self-destroy'       summary='Stop all tasks and remove Docker image'  callback="$__DIR__/boxes/self-destroy-menu.sh" ]

    menuDraw
}

function handle_jump_inside() {
    runInContainer /usr/bin/env SPLASH_SCREEN=1 /bin/bash
}

function show_build_progress() {
    local progress='logs/progress.log'
    until [ -f $progress ]; do
        pause \
            title="$1" \
            text='The build has not started yet. Retrying...' \
            seconds=3 || return 0
    done
    text file=$progress follow='true' width=90% height=90%
    return 0
}

function show_logs() {
    local log_file="${__ARGS__['out-dir']}/verbose.log.gz" err
    if ! err="$(gzip --test "$log_file" 2>&1)"; then
        text title="$1" text="$(cat << EOL
Failed to read logs.
Hint: If the build is currently running, try again after the build will terminate.

$err
EOL
        )"
        return 0
    fi

    gzip --stdout --decompress "$log_file" | less -R || return 0
}

function containerQuery() {
    local query="${1?}"; shift
    runInContainer /bin/bash -i +o histexpand /mnt/entrypoint/entrypoint.sh "$query" "$@"
}

function buildImageIfNone() {
    if ! sudo docker inspect --type image "$__IMAGE_TAG__" &> /dev/null; then
        if isContainerRunning; then
            if [ "$PWD" != "$(getRunningContainerPWD)" ]; then
                anotherInstanceRunningConfirmDialog || return 0
            fi
            sudo docker container stop "$__CONTAINER_NAME__" || return $?
        fi
        local id tag
        while IFS='=' read -r id tag; do
            if [ -n "$id" ] && [ -n "$tag" ] && [ "$tag" != "$__IMAGE_VERSION__" ]; then
                printf "Removing unused image with tag: %s\n" "$tag"
                sudo docker rmi "$id"
            fi
        done <<< "$(getImageList)"

        if [ "${DOCKER_BUILD_IMAGE:-0}" = '1' ]; then
            printf "Note: Unable to find '%s' image. Start building...\n" "$__IMAGE_TAG__"
            printf "This may take a while...\n\n"
            sudo docker build \
                --no-cache \
                --build-arg EMAIL="${__ARGS__['email']}" \
                --build-arg UID="${__USER_IDS__['uid']}" \
                --build-arg GID="${__USER_IDS__['gid']}" \
                --tag "$__IMAGE_TAG__" \
                "${DOCKER_BUILD_PATH:-"$__DIR__"/Dockerfile/}" || return $?
        else
            printf "Note: Unable to find '%s' image. Pulling from repository...\n" "$__IMAGE_TAG__"
            sudo docker pull "$__IMAGE_TAG__" || return $?
        fi
    fi

    copyFilesToHost
}

function copyFilesToHost() {
    # Example: ['SRC_PATH/.'='DEST_PATH']
    # NB.: if DEST_PATH is a directory and
    # ├── SRC_PATH does not end with /. (that is: slash followed by dot)
    # │   └── the source directory is copied into this directory
    # │ 
    # └── SRC_PATH does end with /. (that is: slash followed by dot)
    #     └── the content of the source directory is copied into this directory
    declare -A flist=(
        ['/home/android/.']="$__HOME_DIR__"
        ['/etc/passwd']="$__CACHE_DIR__/passwd.orig"
        ['/etc/group']="$__CACHE_DIR__/group.orig"
    )

    local source_ target running=0
    for source_ in "${!flist[@]}"; do
        target="${flist["$source_"]}"

        if [ -e "$target" ]; then
            continue
        fi

        printf "Copying missing target to host: %s\n" "$target"
        if [ $running -eq 0 ]; then
            if isContainerRunning; then
                printf "Found a running container, stopping...\n"
                sudo docker container stop "$__CONTAINER_NAME__" >/dev/null || return $?
            fi
            sudo docker run \
                --interactive \
                --rm \
                --name "$__CONTAINER_NAME__" \
                --detach=true \
                "$__IMAGE_TAG__" || return $?
            running=1
        fi

        sudo docker container cp \
            --archive \
            "$__CONTAINER_NAME__":"$source_" "$target" || return $?
    done

    if [ $running -eq 1 ]; then
        printf "Finishing...\n"
        # TODO: this is a workaround because '--archive' argument for 'docker
        # container cp' command is broken. Check from time to time if it has
        # been fixed.
        sudo chown \
            --silent \
            --recursive \
            "${__USER_IDS__['uid']}":"${__USER_IDS__['gid']}" \
            "${flist[@]}" &&

        sudo docker container stop "$__CONTAINER_NAME__" >/dev/null || return $?
    fi
    return 0
}

function setUpUser() {
    local uid="${1?}" gid="${2?}" home="${3?}"
    {
        # NOTE: keep user on top to ensure it's picked up regardless of
        # duplicates
        printf "android:x:%d:%d::%s:/bin/bash\n" "$uid" "$gid" "$home"
        cat "$__CACHE_DIR__"/passwd.orig
    } > "$__CACHE_DIR__"/passwd || return $?

    {
        # NOTE: keep group on top to ensure it's picked up regardless of
        # duplicates
        printf "android:x:%d\n" "$gid"
        cat "$__CACHE_DIR__"/group.orig
    } > "$__CACHE_DIR__"/group || return $?
}

function runInContainer() {
    local uid="${__USER_IDS__['uid']}" \
        gid="${__USER_IDS__['gid']}" \
        home='/home/android' \
        use_ccache=${__ARGS__['ccache-disabled']}
    use_ccache=$((use_ccache ^= 1))

    buildImageIfNone >&2 &&
    setUpUser "$uid" "$gid" "$home" >&2 || return $?

    touch "$__MISC_DIR__"/.bash_profile

    if ! isContainerRunning; then
        sudo docker run \
            --detach \
            --interactive \
            --rm \
            --network host \
            --name "$__CONTAINER_NAME__" \
            --tmpfs /tmp:rw,exec,nosuid,nodev,uid="$uid",gid="$gid" \
            --privileged \
            --user "$uid":"$gid" \
            --env IMAGE_VERSION="$__IMAGE_VERSION__" \
            --label PWD="$PWD" \
            --label lunch_system="${__ARGS__['lunch-system']}" \
            --label lunch_device="${__ARGS__['lunch-device']}" \
            --label lunch_flavor="${__ARGS__['lunch-flavor']}" \
            --volume "$PWD/$__CACHE_DIR__"/passwd:/etc/passwd:ro \
            --volume "$PWD/$__CACHE_DIR__"/group:/etc/group:ro \
            --volume /etc/localtime:/etc/localtime:ro \
            --volume "$__DIR__"/.bashrc_extra:/mnt/.bashrc_extra \
            --volume "$__DIR__"/entrypoint:/mnt/entrypoint \
            --volume "${__ARGS__['out-dir']}":/mnt/out \
            --volume "${__ARGS__['ccache-dir']}":/mnt/ccache \
            --volume "${__ARGS__['src-dir']}":/mnt/src \
            --volume "${__ARGS__['zips-dir']}":/mnt/zips \
            --volume "$PWD"/logs:/mnt/logs \
            --volume "$PWD/$__HOME_DIR__":"$home" \
            --volume "$PWD/$__MISC_DIR__":/mnt/misc \
            "$__IMAGE_TAG__" >&2 || return $?
    elif [ "$PWD" != "$(getRunningContainerPWD)" ]; then
        text text="$(cat << EOL
Another instance of the builder is already running for the project at
$(getRunningContainerPWD)

Use the "Stop tasks" option in the main menu to stop all running tasks.
EOL
        )"
        return 0
    fi

    sudo docker container exec \
        --interactive \
        --tty \
        --privileged \
        --env ANDROID_VERSION="${__ARGS__['android']}" \
        --env LUNCH_SYSTEM="${__ARGS__['lunch-system']}" \
        --env LUNCH_DEVICE="${__ARGS__['lunch-device']}" \
        --env LUNCH_FLAVOR="${__ARGS__['lunch-flavor']}" \
        --env TZ="${__ARGS__['timezone']}" \
        --env USE_CCACHE="$use_ccache" \
        --env MOVE_ZIPS="${__ARGS__['move-zips']}" \
        --env CCACHE_SIZE="${__ARGS__['ccache-size']}" \
        --env APP_VERSION="$__VERSION__" \
        --env __REPO_URL__="${__ARGS__['repo-url']}" \
        --env __REPO_REVISION__="${__ARGS__['repo-revision']}" \
        "$__CONTAINER_NAME__" "$@" || return $?
}

function getImageList() {
    sudo docker images --format '{{.ID}}={{.Tag}}' "$__REPOSITORY__"
}

function insertJobNum() {
    local cpus; cpus="$(nproc --all)" || cpus=8
    range text="$(cat << EOL
Insert how many jobs you want run in parallel?

NOTE: this number, N, is the same as the one you normally use while
      running 'make -jN' or 'repo sync -jN'.
EOL
    )" min=1 default="$cpus" max=$((cpus ** 2))
}

function performGracefulStop() {
    if ! sudo docker container stop "$__CONTAINER_NAME__" >/dev/null 2> >(program \
        text='Found a running container, stopping...' \
        hideOk='true' \
        width=50% \
        height=50%); then
        return 1
    fi
    return 0
}

function isContainerRunning() {
    local id
    id="$(sudo docker container ls \
        --filter name="$__CONTAINER_NAME__" \
        --filter status=running \
        --quiet)"

    test -n "$id"
}

function getRunningContainerPWD() {
    sudo docker inspect --format '{{ .Config.Labels.PWD }}' "$__CONTAINER_NAME__"
}

function anotherInstanceRunningConfirmDialog() {
    confirm text="$(cat << EOL
This operation requires the Docker container to be stopped, but another instance
of the builder is already running for the project at $(getRunningContainerPWD)

Are you sure you want to continue?
EOL
    )" \( --defaultno \)
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
