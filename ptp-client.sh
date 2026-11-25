#!/usr/bin/env bash
#
# ptp-client — laat deze machine de tijd volgen van een PTP-grandmaster op het netwerk.
#
# Draai dit als root op de machine (of in de LXC) die moet meelopen:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/ptp-grandmaster/main/ptp-client.sh)
#
# Opties:
#   --check            alleen kijken wat deze machine kan (mag als gewone gebruiker)
#   --dev <poort>      netwerkpoort die naar de grootmeester luistert     (PTP_DEV)
#   --dry-run          alles doen behalve schrijven/installeren           (DROOG=1)
#   --uninstall        diensten en bestanden weghalen                     (VERWIJDER=1)
#   TRANSPORT=L2       moet gelijk zijn aan die van de grootmeester (L2 of UDPv4)
#   DOMAIN=0           idem
#   SOFTWARE=1         software-tijdstempels (in een container vaak de enige route)
#   OVERNAME=1         zet NTP (systemd-timesyncd/chrony) uit, anders vechten ze om de klok
#   UDS=/run/ptp4l-klant  stopcontact waarop pmc/ptp-status kunnen vragen hoe het staat
#
# Alle rechten voorbehouden.
#
set -uo pipefail

MARKER="PTP-CLIENT"
TRANSPORT="${TRANSPORT:-L2}"
DOMAIN="${DOMAIN:-0}"
SYNC_INTERVAL="${SYNC_INTERVAL:--3}"
PTP_DEV="${PTP_DEV:-}"
UDS="${UDS:-/run/ptp4l-klant}"
SOFTWARE="${SOFTWARE:-0}"
DROOG="${DROOG:-0}"
VERWIJDER="${VERWIJDER:-0}"
OVERNAME="${OVERNAME:-1}"
CHECK=0

PTP_ETC="${PTP_ETC:-/etc}"
PTP_SYSFS_NET="${PTP_SYSFS_NET:-/sys/class/net}"
PTP_SYSFS_CLASS="${PTP_SYSFS_CLASS:-/sys/class}"
PTP_DEV_DIR="${PTP_DEV_DIR:-/dev}"
PTP_SYSTEMD_DIR="${PTP_SYSTEMD_DIR:-/etc/systemd/system}"
PTP_APT="${PTP_APT:-apt-get}"
PTP_SYSTEMCTL="${PTP_SYSTEMCTL:-systemctl}"

CONF="$PTP_ETC/linuxptp/ptp4l-klant.conf"
UNIT_PTP="ptp4l-klant.service"
UNIT_PHC="phc2sys-klant.service"

FOUTEN=0
zeg()    { printf '%s\n' "$*"; }
stap()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()     { printf '  \033[32mok\033[0m   %s\n' "$*"; }
let_op() { printf '  \033[33mlet op\033[0m %s\n' "$*"; }
fout()   { printf '  \033[31m[fout]\033[0m %s\n' "$*"; FOUTEN=$((FOUTEN + 1)); }
doe()    { if [ "$DROOG" = "1" ]; then printf '  \033[36mdroog\033[0m %s\n' "$*"; else "$@"; fi; }

for arg in "$@"; do
    case "$arg" in
        --check)     CHECK=1 ;;
        --dry-run)   DROOG=1 ;;
        --uninstall) VERWIJDER=1 ;;
        --software)  SOFTWARE=1 ;;
        --dev=*)     PTP_DEV="${arg#--dev=}" ;;
        --help|-h)   sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           fout "onbekende optie: $arg"; exit 1 ;;
    esac
done

# Een client wil juist wél de kaartklok als bron: hardware-tijdstempels als de
# kaart ze heeft, anders software (minder nauwkeurig, maar het werkt wel).
phc_van() {
    local dev="$1"
    local pad="$PTP_SYSFS_NET/$dev" phc=""
    [ -d "$pad/device/ptp" ] || return 0
    phc="$(basename "$(ls -d "$pad/device/ptp/"ptp* 2>/dev/null | head -1)")"
    [ -e "$PTP_DEV_DIR/${phc:-geen}" ] || return 0
    printf '%s\n' "$phc"
}

kies_poort() {
    local dev pad
    for dev in "$PTP_SYSFS_NET"/*; do
        [ -e "$dev" ] || continue
        dev="$(basename "$dev")"
        case "$dev" in lo|veth*|docker*|br-*|virbr*|tap*|tun*|fw*|wg*|zt*) continue ;; esac
        pad="$PTP_SYSFS_NET/$dev"
        [ -e "$pad/device/driver" ] || continue
        printf '%s\n' "$dev"
        return 0
    done
}

stap "Wat deze machine kan"
if [ "$(id -u)" -eq 0 ]; then ok "root"; else
    if [ "$CHECK" = "1" ] || [ "$DROOG" = "1" ]; then let_op "geen root: kijken mag, installeren niet"
    else fout "dit script moet als root draaien om linuxptp te installeren en diensten te starten."; exit 1; fi
fi

[ -n "$PTP_DEV" ] || PTP_DEV="$(kies_poort)"
if [ -z "$PTP_DEV" ]; then
    fout "geen netwerkpoort gevonden; geef er één met --dev <poort>"
    exit 1
fi
ok "poort: $PTP_DEV"

PHC="$(phc_van "$PTP_DEV")"
if [ -n "$PHC" ] && [ "$SOFTWARE" != "1" ]; then
    ok "deze kaart heeft een PTP-klok: $PHC (hardware-tijdstempels)"
    TIJDSTEMPEL="hardware"
elif [ "$SOFTWARE" = "1" ]; then
    let_op "SOFTWARE=1: tijdstempels in de kernel (nauwkeurigheid milliseconden)"
    TIJDSTEMPEL="software"
else
    let_op "geen PTP-klok op $PTP_DEV (virtuele poort of kaart zonder klok): software-tijdstempels"
    TIJDSTEMPEL="software"
fi

NTP_ACTIEF=""
"$PTP_SYSTEMCTL" is-active --quiet systemd-timesyncd 2>/dev/null && NTP_ACTIEF="systemd-timesyncd"
"$PTP_SYSTEMCTL" is-active --quiet chrony 2>/dev/null && NTP_ACTIEF="$NTP_ACTIEF chrony"
if [ -n "$NTP_ACTIEF" ] && [ "$OVERNAME" = "1" ]; then
    let_op "NTP draait ($NTP_ACTIEF); die zet ik uit, anders vechten NTP en PTP om de klok"
elif [ -n "$NTP_ACTIEF" ]; then
    let_op "NTP draait ($NTP_ACTIEF) en mag blijven (OVERNAME=0) — verwacht dat ze om de klok vechten"
fi

if [ "$CHECK" = "1" ]; then
    zeg ""
    zeg "  --check: er is niets veranderd."
    exit "$FOUTEN"
fi

if [ "$VERWIJDER" = "1" ]; then
    stap "Wegwezen"
    doe "$PTP_SYSTEMCTL" disable --now "$UNIT_PTP" "$UNIT_PHC" 2>/dev/null
    doe rm -f "$PTP_SYSTEMD_DIR/$UNIT_PTP" "$PTP_SYSTEMD_DIR/$UNIT_PHC"
    doe "$PTP_SYSTEMCTL" daemon-reload
    [ "$OVERNAME" = "1" ] && doe "$PTP_SYSTEMCTL" enable --now systemd-timesyncd 2>/dev/null
    zeg "  Configuratie bewaard in $CONF"
    exit "$FOUTEN"
fi

stap "linuxptp installeren"
if command -v ptp4l >/dev/null 2>&1; then ok "linuxptp is er al"
else
    doe "$PTP_APT" update -qq || true
    doe "$PTP_APT" install -y -qq linuxptp || fout "kon linuxptp niet installeren (apt-get)"
    if [ "$DROOG" != "1" ]; then
        if command -v ptp4l >/dev/null 2>&1; then ok "$(ptp4l -v 2>&1 | head -1)"
        else fout "ptp4l is er nog steeds niet; kijk met: apt-get install linuxptp"; fi
    fi
fi

stap "Configuratie schrijven"
NIEUW_CONF="$(mktemp)"
cat > "$NIEUW_CONF" <<EOF
# $MARKER — aangemaakt door ptp-client.sh
# Deze machine volgt de grootmeester op het netwerk.
[global]
domainNumber            $DOMAIN
clientOnly              1
time_stamping           $TIJDSTEMPEL
network_transport       $TRANSPORT
delay_mechanism         E2E
logSyncInterval         $SYNC_INTERVAL
logAnnounceInterval     1
announceReceiptTimeout  3
clock_class_threshold   248
tx_timestamp_timeout    10
uds_address             $UDS
logging_level           6
EOF

if [ -f "$CONF" ] && cmp -s "$NIEUW_CONF" "$CONF"; then ok "$CONF is al gelijk"
else
    doe install -d -m 0755 "$(dirname "$CONF")"
    doe install -m 0644 "$NIEUW_CONF" "$CONF"
    ok "$CONF"
fi
rm -f "$NIEUW_CONF"

stap "Diensten aanmaken"
GEN_PTP="$(mktemp)"; GEN_PHC="$(mktemp)"
cat > "$GEN_PTP" <<EOF
# $MARKER — aangemaakt door ptp-client.sh
[Unit]
Description=PTP-client op __DEV__: volgt de grootmeester (ptp4l)
Documentation=man:ptp4l(8)
After=network-online.target sys-subsystem-net-devices-__DEV__.device
Wants=sys-subsystem-net-devices-__DEV__.device

[Service]
Type=simple
ExecStart=/usr/sbin/ptp4l -f $CONF -i __DEV__ -m -s
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > "$GEN_PHC" <<EOF
# $MARKER — aangemaakt door ptp-client.sh
[Unit]
Description=Klok van de netwerkkaart naar de systeemklok (phc2sys, __DEV__)
Documentation=man:phc2sys(8)
PartOf=ptp4l-klant.service
After=ptp4l-klant.service sys-subsystem-net-devices-__DEV__.device

[Service]
Type=simple
# Bij een client is de kaartklok de bron (-s __DEV__) en de systeemklok het doel.
# -w wacht tot ptp4l op de grootmeester vergrendeld is.
ExecStart=/usr/sbin/phc2sys -s __DEV__ -c CLOCK_REALTIME -w -m
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sed -i "s/__DEV__/$PTP_DEV/g" "$GEN_PTP" "$GEN_PHC"

for paar in "$GEN_PTP:$UNIT_PTP" "$GEN_PHC:$UNIT_PHC"; do
    bron="${paar%%:*}"; doel="$PTP_SYSTEMD_DIR/${paar##*:}"
    if [ -f "$doel" ] && cmp -s "$bron" "$doel"; then ok "$(basename "$doel") is al gelijk"
    else doe install -m 0644 "$bron" "$doel"; ok "$(basename "$doel") geschreven"; fi
done
rm -f "$GEN_PTP" "$GEN_PHC"

stap "NTP loskoppelen en starten"
if [ "$OVERNAME" = "1" ]; then
    [ -n "$NTP_ACTIEF" ] && doe "$PTP_SYSTEMCTL" disable --now $NTP_ACTIEF 2>/dev/null
fi
doe "$PTP_SYSTEMCTL" daemon-reload
doe "$PTP_SYSTEMCTL" enable --now "$UNIT_PTP"
sleep 4
doe "$PTP_SYSTEMCTL" enable --now "$UNIT_PHC"

if [ "$DROOG" = "1" ]; then zeg ""; zeg "  --dry-run: er is niets geschreven of gestart."; exit 0; fi

stap "Bewijs dat de klok meeloopt"
sleep 6
if [ -x /usr/sbin/pmc ]; then
    UIT="$(/usr/sbin/pmc -u -b 0 -i "$PTP_DEV" 'GET TIME_STATUS_NP' 2>/dev/null)"
    if [ -n "$UIT" ]; then
        zeg "$UIT" | sed 's/^/    /'
        AFWIJKING="$(printf '%s' "$UIT" | awk '/offsetFromMaster/ {print $2}')"
        if [ -n "$AFWIJKING" ]; then
            if awk -v d="$AFWIJKING" 'BEGIN { exit (d < 0 ? -d : d) > 100000 ? 1 : 0 }'; then
                ok "de klok loopt mee (afwijking ${AFWIJKING} ns van de grootmeester)"
            else
                let_op "nog aan het bijtrekken: afwijking ${AFWIJKING} ns. Kijk over een halve minuut opnieuw."
            fi
        fi
    else
        let_op "geen antwoord van ptp4l; kijk in: journalctl -u $UNIT_PTP -n 30"
    fi
fi

REGEL="$(journalctl -u "$UNIT_PTP" --no-pager -n 100 2>/dev/null | grep -E 'rms|master offset' | tail -1)"
if [ -n "$REGEL" ]; then ok "metingen: $REGEL"
else
    let_op "nog geen meetregels in het log. Staat er een grootmeester op dit netwerk?"
fi

VOLLEDIG="$("$PTP_SYSTEMCTL" is-active "$UNIT_PTP" 2>/dev/null)"
zeg "  Dienst           : $UNIT_PTP is $VOLLEDIG"
zeg "  Tijdstempels     : $TIJDSTEMPEL"
zeg "  Transport/domein : $TRANSPORT / $DOMAIN"
zeg "  Klok             : $(date '+%H:%M:%S.%N') (systeemklok, nu door PTP gestuurd)"
exit "$FOUTEN"