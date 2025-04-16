#!/usr/bin/env bash

config title="$1"

if ! confirm \
    text="$(cat << EOL
Are you sure you want to stop whatever is running in container
(ROM/Kernel/SELinux building or source tree syncing)?
EOL
)" \( --defaultno \); then
    return 0
fi

if ! isContainerRunning; then
    text text='No tasks are currently running.'
    return 0
fi

if [ "$PWD" != "$(getRunningContainerPWD)" ]; then
    anotherInstanceRunningConfirmDialog || return 0
fi

if performGracefulStop; then
    text text='All tasks were successfully stopped.'
    return 0
fi
return 1 # Exit app
