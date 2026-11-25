#!/usr/bin/env bash
#
# ptp-status — laat zien wat de PTP-diensten op deze machine doen.
# Werkt zowel op de grootmeester (host) als op een client.
#
#   ptp-status            samenvatting
#   ptp-status --log      ook de laatste logregels
#
set -uo pipefail

PTP_DEV="${PTP_DEV:-}"
[ -n "$PTP_DEV" ] || PTP_DEV="$(find /sys/class/net -maxdepth 3 -type d -name 'ptp*' -printf '%h\n' 2>/dev/null \
    | sed 's#/sys/class/net/##; s#/device/ptp$##' | head -1)"
[ -n "$PTP_DEV" ] || PTP_DEV="$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|veth|docker|br-|virbr|tap|tun|fw)' | head -1)"

printf '\033[1mKlok van deze machine\033[0m\n'
printf '  systeemklok : %s\n' "$(date '+%Y-%m-%d %H:%M:%S.%N %Z')"

if [ -n "$PTP_DEV" ]; then
    printf '  poort       : %s\n' "$PTP_DEV"
    PHC="$(basename "$(ls -d /sys/class/net/"$PTP_DEV"/device/ptp/ptp* 2>/dev/null | head -1)" 2>/dev/null)"
    if [ -n "$PHC" ] && [ -e /dev/"$PHC" ]; then
        printf '  kaartklok   : /dev/%s\n' "$PHC"
        printf '  kaarttijd   : %s\n' "$(phc_ctl /dev/"$PHC" get 2>/dev/null | tr -d '\n' || echo 'niet te lezen')"
    else
        printf '  kaartklok   : geen PTP-klok op deze poort (software-tijdstempels)\n'
    fi
fi

printf '\n\033[1mDiensten\033[0m\n'
for u in ptp4l-gm ptp4l-klant phc2sys-gm phc2sys-klant; do
    if systemctl list-unit-files "$u.service" >/dev/null 2>&1 && [ -f "/etc/systemd/system/$u.service" ]; then
        printf '  %-14s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null)/$(systemctl is-enabled "$u" 2>/dev/null)"
    fi
done

if [ -S /run/ptp4l ] || [ -S /run/ptp4l-klant ]; then
    UDS=/run/ptp4l; [ -S /run/ptp4l-klant ] && UDS=/run/ptp4l-klant
    printf '\n\033[1mWat ptp4l vindt\033[0m\n'
    for vraag in 'GET PARENT_DATA_SET' 'GET TIME_STATUS_NP'; do
        UIT="$(pmc -u -b 0 -i "$UDS" "$vraag" 2>/dev/null)"
        [ -n "$UIT" ] && printf '%s\n' "$UIT" | sed 's/^/  /'
    done
else
    printf '\n  ptp4l draait hier niet (geen luisterend stopcontact op /run/ptp4l)\n'
fi

printf '\n\033[1mLaatste metingen\033[0m\n'
REGELS="$(journalctl -u ptp4l-gm -u ptp4l-klant --no-pager -n 400 2>/dev/null | grep -E 'rms|master offset|assuming the grand master role|selected best master' | tail -5)"
[ -n "$REGELS" ] && printf '%s\n' "$REGELS" | sed 's/^/  /' || printf '  (nog niets)\n'

if [ "${1:-}" = "--log" ]; then
    printf '\n\033[1mLog\033[0m\n'
    journalctl -u ptp4l-gm -u ptp4l-klant -u phc2sys-gm -u phc2sys-klant --no-pager -n 40 2>/dev/null | sed 's/^/  /'
fi
