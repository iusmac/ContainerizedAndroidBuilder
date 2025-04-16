#!/usr/bin/env bash

config title="$1"

menu \
    text='Select power-off type' \
    cancelLabel='Return' \
    prefix='num' \
    [ title='Suspend'    summary='Save the session to RAM and put the PC in low power consumption mode' ] \
    [ title='Hibernate'  summary='Save the session to disk and completely power off the PC'             ]
if ! type="$(menuDraw)" || ! confirm \
    text="Are you sure you want to suspend/hibernate the machine?" \
    \( --defaultno \); then
    return 0
fi
systemctl "${type,}"
