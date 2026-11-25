#!/usr/bin/env bash
#
# ptp-grandmaster — maak van je Proxmox-host (of elke Debian-machine) een
# PTP-grandmaster (IEEE 1588) die op je eigen netwerk de tijd uitgeeft.
#
# Draai dit als root op de host:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/ptp-grandmaster/main/ptp-grandmaster.sh)
#
# Kijken wat er is, zónder iets te veranderen (mag als gewone gebruiker):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/ptp-grandmaster/main/ptp-grandmaster.sh) --check
#
# Opties (argument of omgevingsvariabele):
#   --check            alleen kijken: welke poort kan het, wat loopt er al (niets aanmaken)
#   --dev <poort>      netwerkpoort waarop de klok wordt uitgezonden (PTP_DEV)
#   --dry-run          alles doen behalve schrijven/installeren        (DROOG=1)
#   --uninstall        diensten stoppen en bestanden weghalen          (VERWIJDER=1)
#   --help             deze uitleg
#
# Instellingen:
#   DOMAIN=0           PTP-domein (moet aan de client-kant gelijk zijn)
#   PRIORITY=64        lagere waarde wint de grootmeesterverkiezing (standaard in PTP is 128)
#   TRANSPORT=L2       L2 (ruw Ethernet, standaard bij audio/video) of UDPv4 (makkelijker over routers)
#   SYNC_INTERVAL=-3   sync-berichten per 2^N seconde (-3 = 8 per seconde, media-standaard; 0 = 1/s)
#   CLOCK_CLASS=248    kwaliteit die we claimen (248 = niet traceerbaar, prima voor een NTP-bron)
#   UTC_OFFSET=0       0 = onze klok loopt in UTC (NTP-bron); 37 = strikte TAI-tijdschaal
#   SOFTWARE=1         software-tijdstempels in plaats van de klok van de netwerkkaart
#   UDS=/run/ptp4l     stopcontact waarop pmc/ptp-status kunnen vragen hoe het staat
#
# Deze omgevingsvariabelen zijn er om te kunnen testen zonder echte host
# (zo hoort het script ook op een andere machine te kunnen worden nagelopen):
#   PTP_ETC, PTP_SYSFS_NET, PTP_CLASS, PTP_DEV_DIR, PTP_SYSTEMD_DIR, PTP_SBIN_DIR,
#   PTP_STATE_DIR, PTP_APT, PTP_SYSTEMCTL
#
# Alle rechten voorbehouden.
#
set -uo pipefail

MARKER="PTP-GRANDMASTER"          # aanwezigheid van dit bestand bewijst dat de kit compleet is

DOMAIN="${DOMAIN:-0}"
PRIORITY="${PRIORITY:-64}"
TRANSPORT="${TRANSPORT:-L2}"
SYNC_INTERVAL="${SYNC_INTERVAL:--3}"
CLOCK_CLASS="${CLOCK_CLASS:-248}"
UTC_OFFSET="${UTC_OFFSET:-0}"
PTP_DEV="${PTP_DEV:-}"
UDS="${UDS:-/run/ptp4l}"
SOFTWARE="${SOFTWARE:-0}"
DROOG="${DROOG:-0}"
VERWIJDER="${VERWIJDER:-0}"
CHECK=0

# Paden; allemaal overschrijfbaar zodat het script buiten een echte host te toetsen is.
PTP_ETC="${PTP_ETC:-/etc}"
PTP_SYSFS_NET="${PTP_SYSFS_NET:-/sys/class/net}"
PTP_SYSFS_CLASS="${PTP_SYSFS_CLASS:-/sys/class}"
PTP_DEV_DIR="${PTP_DEV_DIR:-/dev}"
PTP_SYSTEMD_DIR="${PTP_SYSTEMD_DIR:-/etc/systemd/system}"
PTP_SBIN_DIR="${PTP_SBIN_DIR:-/usr/local/sbin}"
PTP_STATE_DIR="${PTP_STATE_DIR:-/var/lib/ptp-grandmaster}"
PTP_APT="${PTP_APT:-apt-get}"
PTP_SYSTEMCTL="${PTP_SYSTEMCTL:-systemctl}"

CONF="$PTP_ETC/linuxptp/ptp4l-gm.conf"
UNIT_PTP="ptp4l-gm.service"
UNIT_PHC="phc2sys-gm.service"
SERVICE_TAG="ptp-grandmaster"

FOUTEN=0
zeg()    { printf '%s\n' "$*"; }
stap()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()     { printf '  \033[32mok\033[0m   %s\n' "$*"; }
let_op() { printf '  \033[33mlet op\033[0m %s\n' "$*"; }
fout()   { printf '  \033[31m[fout]\033[0m %s\n' "$*"; FOUTEN=$((FOUTEN + 1)); }
doe()    { if [ "$DROOG" = "1" ]; then printf '  \033[36mdroog\033[0m %s\n' "$*"; else "$@"; fi; }

gebruik() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --check)     CHECK=1 ;;
        --dry-run)   DROOG=1 ;;
        --uninstall) VERWIJDER=1 ;;
        --software)  SOFTWARE=1 ;;
        --dev)       fout "--dev heeft een poortnaam nodig: --dev eth0"; gebruik; exit 1 ;;
        --dev=*)     PTP_DEV="${arg#--dev=}" ;;
        --help|-h)   gebruik; exit 0 ;;
        *)           fout "onbekende optie: $arg"; gebruik; exit 1 ;;
    esac
done

# ------------------------------------------------------------------ kijken

# Is dit een poort die de klok van een netwerkkaart kan gebruiken?
# Print per poort:  <naam>|<stuurprogramma>|<phc-apparaat>|<hardware ja/nee[,-reden]>|<in-bridge ja/nee>
poort_regel() {
    local dev="$1"
    local pad="$PTP_SYSFS_NET/$dev" drv="" phc="" hw="nee" bridge="nee" reden=""
    [ -e "$pad" ] || return 0
    [ "$dev" = "lo" ] && return 0
    case "$dev" in veth*|docker*|br-*|virbr*|tap*|tun*|fw*|wg*|zt*|tailscale*) return 0 ;; esac

    if [ -e "$pad/device/driver" ]; then
        drv="$(basename "$(readlink -f "$pad/device/driver")")"
    fi
    [ -n "$drv" ] || reden="geen netwerkkaart (virtuele poort)"

    if [ -d "$pad/device/ptp" ]; then
        phc="$(basename "$(ls -d "$pad/device/ptp/"ptp* 2>/dev/null | head -1)")"
    fi
    if [ -z "$phc" ]; then
        for p in "$PTP_SYSFS_CLASS/ptp/"ptp*; do
            [ -e "$p" ] || continue
            if [ "$(readlink -f "$p/device/net" 2>/dev/null)" = "$(readlink -f "$pad")" ]; then
                phc="$(basename "$p")"
                break
            fi
        done
    fi

    if [ -n "$phc" ] && [ -e "$PTP_DEV_DIR/$phc" ]; then
        if [ "$SOFTWARE" = "1" ]; then
            hw="nee (-SOFTWARE=1: we gebruiken software-tijdstempels)"
        else
            hw="ja"
        fi
    elif [ "$SOFTWARE" = "1" ]; then
        hw="nee (-SOFTWARE=1)"
    elif [ -n "$reden" ]; then
        hw="nee ($reden)"
    else
        hw="nee (kaart heeft geen PTP-klok; alleen software-tijdstempels mogelijk)"
    fi

    if [ -e "$pad/brport" ] || [ -n "$(ls -d "$PTP_SYSFS_NET/$dev/upper/"* 2>/dev/null)" ]; then
        bridge="ja"
    fi
    printf '%s|%s|%s|%s|%s\n' "$dev" "${drv:--}" "${phc:--}" "$hw" "$bridge"
}

# Kiest de poort die het beste is: hardware-klok, en niet in een bridge.
kies_poort() {
    local regel dev hw bridge eerste_hw=""
    while IFS='|' read -r dev drv phc hw bridge; do
        [ -n "$dev" ] || continue
        case "$hw" in ja*) ;; *) continue ;; esac
        [ -n "$eerste_hw" ] || eerste_hw="$dev"
        if [ "$bridge" = "nee" ]; then printf '%s\n' "$dev"; return 0; fi
    done <<< "$(poort_regels)"
    printf '%s\n' "$eerste_hw"
}

poort_regels() {
    local dev
    for dev in "$PTP_SYSFS_NET"/*; do
        [ -e "$dev" ] || continue
        poort_regel "$(basename "$dev")"
    done
}

stap "Wat deze machine kan"

if [ "$(id -u)" -eq 0 ]; then ok "root"; else
    if [ "$CHECK" = "1" ] || [ "$DROOG" = "1" ]; then
        let_op "geen root: kijken mag, installeren niet"
    else
        fout "dit script moet als root draaien om linuxptp te installeren en diensten te starten."
        zeg  "     Alleen kijken kan zonder root:  ... --check"
        exit 1
    fi
fi

[ -d "$PTP_ETC/linuxptp" ] && ok "$PTP_ETC/linuxptp bestaat al" || ok "linuxptp is nog niet geïnstalleerd"

if command -v ptp4l >/dev/null 2>&1; then
    ok "ptp4l aanwezig: $(ptp4l -v 2>&1 | head -1)"
else
    let_op "ptp4l (pakket linuxptp) is nog niet geïnstalleerd"
fi

zeg ""
zeg "  netwerkpoorten:"
POORTEN="$(poort_regels)"
if [ -z "$POORTEN" ]; then
    let_op "geen fysieke netwerkpoort gevonden onder $PTP_SYSFS_NET"
else
    while IFS='|' read -r dev drv phc hw bridge; do
        [ -n "$dev" ] || continue
        zeg "    $(printf '%-12s' "$dev") kaart: $(printf '%-10s' "$drv") PTP-klok: $(printf '%-7s' "$phc") hardware-tijdstempels: $(printf '%-6s' "$hw") in bridge: $bridge"
    done <<< "$POORTEN"
fi

zeg ""
if [ -z "$PTP_DEV" ]; then
    PTP_DEV="$(kies_poort)"
fi
if [ -n "$PTP_DEV" ]; then
    ok "gekozen poort: $PTP_DEV"
    if [ -e "$PTP_SYSFS_NET/$PTP_DEV/brport" ]; then
        let_op "$PTP_DEV zit in een bridge (bijvoorbeeld vmbr0). Dat werkt, want de tijdstempels"
        let_op "  komen uit de kaart zelf — maar een eigen poort die nergens in hangt geeft de"
        let_op "  mooiste cijfers. Gebruik dan: --dev <poort>."
    fi
else
    let_op "geen poort met een PTP-klok gevonden."
    let_op "  Dit kan op drie manieren: (1) je netwerkkaart heeft geen PTP-hardware —"
    let_op "  installeer dan met SOFTWARE=1 (tijdstempels in de kernel, nauwkeurigheid ~ms);"
    let_op "  (2) de poort zit in een bridge die het apparaat verbergt — kies een losse poort;"
    let_op "  (3) er is geen fysieke kaart in deze machine (container!)."
fi

# Tijdbron: de klok die wij uitdelen is de systeemklok. Loopt die niet goed,
# dan delen we een verkeerde tijd netjes synchroon uit.
zeg ""
TIJD="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo onbekend)"
case "$TIJD" in
    yes) ok "systeemklok is gesynchroniseerd (NTP)" ;;
    onbekend) let_op "kon de NTP-status niet lezen; controleer: timedatectl" ;;
    *) let_op "systeemklok is NIET gesynchroniseerd (NTPSynchronized=$TIJD)."
       let_op "  Zet eerst de tijd goed: timedatectl set-ntp true (of gebruik chrony)." ;;
esac

if [ "$CHECK" = "1" ]; then
    zeg ""
    zeg "  --check: er is niets veranderd."
    exit "$FOUTEN"
fi

# ------------------------------------------------------------ installeren

if [ "$VERWIJDER" = "1" ]; then
    stap "Wegwezen"
    doe "$PTP_SYSTEMCTL" disable --now "$UNIT_PTP" "$UNIT_PHC" 2>/dev/null
    doe rm -f "$PTP_SYSTEMD_DIR/$UNIT_PTP" "$PTP_SYSTEMD_DIR/$UNIT_PHC"
    doe rm -f "$PTP_SBIN_DIR/ptp-status"
    doe "$PTP_SYSTEMCTL" daemon-reload
    zeg "  De configuratie in $CONF is bewaard. Wegwezen kan ook met: rm $CONF"
    zeg "  Het pakket linuxptp is niet verwijderd: apt-get remove linuxptp"
    exit "$FOUTEN"
fi

stap "linuxptp installeren"
if command -v ptp4l >/dev/null 2>&1; then
    ok "linuxptp is er al"
else
    # De enterprise-repo van Proxmox staat zonder abonnement op 401; dat mag de
    # installatie niet tegenhouden, dus de uitkomst van apt-get update negeren en
    # daarna op het echte feit controleren (is ptp4l er nu?).
    doe "$PTP_APT" update -qq || true
    doe "$PTP_APT" install -y -qq linuxptp || fout "kon linuxptp niet installeren (apt-get)"
    if [ "$DROOG" = "1" ]; then
        ok "droog: linuxptp zou nu geïnstalleerd zijn"
    elif command -v ptp4l >/dev/null 2>&1; then
        ok "$(ptp4l -v 2>&1 | head -1)"
    else
        fout "ptp4l is er nog steeds niet; kijk met: apt-get install linuxptp"
    fi
fi

stap "Configuratie schrijven"
TIJDSTEMPEL="hardware"
[ "$SOFTWARE" = "1" ] && TIJDSTEMPEL="software"
[ -n "${PTP_DEV:-}" ] || fout "geen netwerkpoort gekozen; geef er één met --dev <poort> of SOFTWARE=1"
[ "$FOUTEN" -eq 0 ] || exit 1

NIEUW_CONF="$(mktemp)"
cat > "$NIEUW_CONF" <<EOF
# $MARKER — aangemaakt door ptp-grandmaster.sh
#
# Deze machine zendt de tijd uit. De klok die we uitdelen is de systeemklok
# (die op tijd wordt gehouden door NTP/chrony); phc2sys kopieert hem naar de
# klok van de netwerkkaart, en ptp4l maakt daar PTP-berichten van.
[global]
domainNumber            $DOMAIN
priority1               $PRIORITY
priority2               $PRIORITY
clockClass              $CLOCK_CLASS
clockAccuracy           0xFE
offsetScaledLogVariance 0xFFFF
twoStepFlag             1
serverOnly              1
time_stamping           $TIJDSTEMPEL
network_transport       $TRANSPORT
delay_mechanism         E2E
logSyncInterval         $SYNC_INTERVAL
logAnnounceInterval     1
logMinDelayReqInterval  0
announceReceiptTimeout  3
uds_address             $UDS
# utc_offset: hoeveel seconden PTP-tijd (TAI) voorloopt op UTC. Onze bron is
# UTC, dus 0 houdt de tijd die clients overnemen exact gelijk aan de onze.
# Voor de strikte standaardtijdschaal: UTC_OFFSET=37.
utc_offset              $UTC_OFFSET
tx_timestamp_timeout    10
summary_interval        0
logging_level           6
EOF

if [ -f "$CONF" ] && cmp -s "$NIEUW_CONF" "$CONF"; then
    ok "$CONF is al gelijk"
elif [ -f "$CONF" ]; then
    doe cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"
    doe install -m 0644 "$NIEUW_CONF" "$CONF"
    let_op "bestaande config bewaard als $CONF.bak.*"
else
    doe install -d -m 0755 "$(dirname "$CONF")"
    doe install -m 0644 "$NIEUW_CONF" "$CONF"
    ok "$CONF"
fi
rm -f "$NIEUW_CONF"

stap "Diensten aanmaken"
mkdir -p "$PTP_SYSTEMD_DIR" "$(dirname "$PTP_STATE_DIR")" 2>/dev/null

GEN_PTP="$(mktemp)"; GEN_PHC="$(mktemp)"
cat > "$GEN_PTP" <<EOF
# $MARKER — aangemaakt door ptp-grandmaster.sh
[Unit]
Description=PTP grandmaster op __DEV__ (ptp4l)
Documentation=man:ptp4l(8)
After=network-online.target sys-subsystem-net-devices-__DEV__.device
Wants=sys-subsystem-net-devices-__DEV__.device
Before=time-sync.target

[Service]
Type=simple
ExecStart=/usr/sbin/ptp4l -f $CONF -i __DEV__ -m
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
EOF

cat > "$GEN_PHC" <<EOF
# $MARKER — aangemaakt door ptp-grandmaster.sh
[Unit]
Description=Klok van de netwerkkaart volgt de systeemklok (phc2sys, __DEV__)
Documentation=man:phc2sys(8)
PartOf=ptp4l-gm.service
After=ptp4l-gm.service sys-subsystem-net-devices-__DEV__.device

[Service]
Type=simple
# -s CLOCK_REALTIME -c __DEV__ : de systeemklok is de bron, de kaartklok het doel
# (bij een client is het precies andersom: daar is de kaartklok de bron).
ExecStart=/usr/sbin/phc2sys -s CLOCK_REALTIME -c __DEV__ -m
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sed -i "s/__DEV__/$PTP_DEV/g" "$GEN_PTP" "$GEN_PHC"

for paar in "$GEN_PTP:$UNIT_PTP" "$GEN_PHC:$UNIT_PHC"; do
    bron="${paar%%:*}"; doel="$PTP_SYSTEMD_DIR/${paar##*:}"
    if [ -f "$doel" ] && cmp -s "$bron" "$doel"; then
        ok "$(basename "$doel") is al gelijk"
    else
        doe install -m 0644 "$bron" "$doel"
        ok "$(basename "$doel") geschreven"
    fi
done
rm -f "$GEN_PTP" "$GEN_PHC"

stap "Diensten starten"
doe "$PTP_SYSTEMCTL" daemon-reload
doe "$PTP_SYSTEMCTL" enable --now "$UNIT_PTP" "$UNIT_PHC"
doe install -m 0755 "$(dirname "${BASH_SOURCE[0]}")/ptp-status.sh" "$PTP_SBIN_DIR/ptp-status" 2>/dev/null \
    || printf '#!/bin/sh\necho "ptp-status: haal het bestand ptp-status.sh uit de repo"\n' > "$PTP_SBIN_DIR/ptp-status" 2>/dev/null
doe mkdir -p "$PTP_STATE_DIR"
doe sh -c "printf 'dev=%s\ntransport=%s\ndomain=%s\npriority=%s\n' '$PTP_DEV' '$TRANSPORT' '$DOMAIN' '$PRIORITY' > '$PTP_STATE_DIR/installatie.env'" 2>/dev/null

if [ "$DROOG" = "1" ]; then
    zeg ""
    zeg "  --dry-run: er is niets geschreven of gestart."
    exit 0
fi

# ------------------------------------------------------------------ bewijs

stap "Bewijs dat het draait"
timeout 20 sh -c "while [ ! -S /run/ptp4l ]; do sleep 0.5; done" 2>/dev/null
sleep 3

if [ -x /usr/sbin/pmc ]; then
    OUDER="/usr/sbin/pmc -u -b 0 -i "$PTP_DEV" 'GET PARENT_DATA_SET' 2>/dev/null"
    UIT="$(eval "$OUDER")"
    if [ -n "$UIT" ]; then
        zeg "$UIT" | sed 's/^/    /'
        if printf '%s' "$UIT" | grep -qi "grandmasterIdentity"; then
            ok "de poort is grootmeester en zendt de tijd uit"
        fi
    else
        let_op "pmc kreeg geen antwoord; kijk in: journalctl -u $UNIT_PTP -n 30"
    fi
fi

if "$PTP_SYSTEMCTL" is-active --quiet "$UNIT_PTP" 2>/dev/null; then
    ok "$UNIT_PTP draait"
else
    fout "$UNIT_PTP draait niet: journalctl -u $UNIT_PTP -n 30"
fi
if "$PTP_SYSTEMCTL" is-active --quiet "$UNIT_PHC" 2>/dev/null; then
    ok "$UNIT_PHC draait"
else
    let_op "$UNIT_PHC draait niet: journalctl -u $UNIT_PHC -n 30"
fi

GRANDMASTER="$(journalctl -u "$UNIT_PTP" --no-pager -n 200 2>/dev/null | grep -c 'assuming the grand master role' || true)"
if [ "${GRANDMASTER:-0}" -gt 0 ]; then
    ok "in het log staat 'assuming the grand master role'"
else
    let_op "nog geen 'assuming the grand master role' in het log."
    let_op "  Zit er soms een ándere PTP-grootmeester op dit netwerk? Die wint dan."
fi

stap "Klaar"
zeg "  Poort        : $PTP_DEV"
zeg "  Transport    : $TRANSPORT (domein $DOMAIN, prioriteit $PRIORITY)"
zeg "  Tijdstempels : $TIJDSTEMPEL"
zeg "  Configuratie : $CONF"
zeg "  Status       : ptp-status"
zeg ""
zeg "  Een Linux-client laat je meekijken met (op die machine, als root):"
zeg "    bash <(curl -fsSL https://raw.githubusercontent.com/Theberas04/ptp-grandmaster/main/ptp-client.sh)"
zeg "  Media-apparatuur (Dante/AES67): domein $DOMAIN, $TRANSPORT, sync-interval $SYNC_INTERVAL."
exit "$FOUTEN"