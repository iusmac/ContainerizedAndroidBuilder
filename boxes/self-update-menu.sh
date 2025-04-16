#!/usr/bin/env bash

config title="$1"

if [ ! -d .git ]; then
    err='Error: cannot find .git/ directory. Please, follow the installation guide '
    err+='and make sure the directory structure complies with the requirements.'
    text text="$err"
    return 1 # exit app
fi

if isContainerRunning; then
    if [ "$PWD" != "$(getRunningContainerPWD)" ]; then
        anotherInstanceRunningConfirmDialog || return 0
    fi
    performGracefulStop || return $?
fi

if git pull --rebase && (
    cd "$__DIR__" &&
    git pull --recurse-submodules --force --rebase origin master
); then
    text text="You've successfully upgraded. Run the builder again when you wish it ;)"
fi
return 1 # exit app
