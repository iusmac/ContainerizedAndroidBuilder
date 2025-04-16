#!/usr/bin/env bash

config title="$1"

if ! confirm \
    text="$(cat << EOL
Are you sure you want to kill all running tasks and remove Docker image from disk?

NOTE: this won't remove sources or out files. You have to remove them manually.
EOL
)" \( --defaultno \); then
    return 0
fi

if isContainerRunning; then
    if [ "$PWD" != "$(getRunningContainerPWD)" ]; then
        anotherInstanceRunningConfirmDialog || return 0
    fi
    performGracefulStop || return $?
fi

img_list="$(getImageList)"
if [ -z "$img_list" ]; then
    echo 'No images to remove.'
else
    while IFS='=' read -r id tag; do
        if [ -n "$id" ] && [ -n "$tag" ]; then
            printf "Removing image with tag: %s\n" "$tag"
            sudo docker rmi "$id"
        fi
    done <<< "$img_list"
    echo 'Done.'
fi 2>&1 | program \
    text='Removing images...' \
    width=50% \
    height=50%
return 0
