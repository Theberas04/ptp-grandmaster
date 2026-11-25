#!/usr/bin/env bash
#
# Proef op de som: laat twee ptp4l-processen écht synchroniseren.
#
# Dit bouwt eerst met ptp-grandmaster.sh en ptp-client.sh de configuraties die
# een host en een client zouden krijgen (met SOFTWARE=1, want in een testomgeving
# is er geen netwerkkaart met een PTP-klok). Daarna worden die twee
# configuraties gebruikt in een eigen netwerknaamruimte met een veth-paar: de
# grootmeester zendt uit, de client moet vergrendelen en kleine afwijkingen
# rapporteren.
#
# Zo bewijs je dat de configuraties kloppen — een testbank met nepcommando's
# bewijst alleen dat het script schrijft wat je denkt.
#
# Draaien:   bash tests/test-lock.sh [--streng]
#            --streng  ook falen als de omgeving geen naamruimte toestaat
#
set -uo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HIER")"
STRENG=0
[ "${1:-}" = "--streng" ] && STRENG=1

WERK="$(mktemp -d)"
trap 'rm -rf "$WERK"' EXIT

GOED=0; FOUT=0
toets() {
    local wat="$1"; shift
    if "$@" >/dev/null 2>&1; then printf '  \033[32mok\033[0m   %s\n' "$wat"; GOED=$((GOED+1))
    else printf '  \033[31mFOUT\033[0m %s\n' "$wat"; FOUT=$((FOUT+1)); fi
}

overslaan() {
    printf '  \033[33movergeslagen\033[0m %s\n' "$1"
    if [ "$STRENG" = "1" ]; then exit 1; fi
    exit 0
}

# ---------------------------------------------------------------- ptp4l vinden
PTP4L="${PTP4L:-$(command -v ptp4l || true)}"
if [ -z "$PTP4L" ]; then
    printf '  ptp4l is niet geïnstalleerd; ik haal het pakket op om het uit te pakken.\n'
    cd "$WERK" || exit 1
    if command -v apt-get >/dev/null 2>&1 && apt-get download linuxptp >/dev/null 2>&1; then
        dpkg-deb -x linuxptp_*.deb "$WERK/pakket"
    else
        VERSIE="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-trixie}")"
        curl -fsSL "http://deb.debian.org/debian/pool/main/l/linuxptp/" \
            | grep -oE 'linuxptp_[^"]*_amd64\.deb' | sort -V | tail -1 > "$WERK/naam"
        NAAM="$(cat "$WERK/naam")"
        [ -n "$NAAM" ] || overslaan "kon linuxptp niet ophalen (geen netwerk of geen dpkg)"
        curl -fsSL -o "$WERK/linuxptp.deb" "http://deb.debian.org/debian/pool/main/l/linuxptp/$NAAM" \
            || overslaan "kon $NAAM niet downloaden"
        dpkg-deb -x "$WERK/linuxptp.deb" "$WERK/pakket" 2>/dev/null || overslaan "kon het pakket niet uitpakken"
    fi
    PTP4L="$WERK/pakket/usr/sbin/ptp4l"
    [ -x "$PTP4L" ] || overslaan "geen ptp4l-binary gevonden na uitpakken"
fi
printf '  ptp4l: %s (%s)\n' "$PTP4L" "$("$PTP4L" -v 2>&1 | head -1)"

# ------------------------------------------------- configuraties van de kit maken
NEP="$WERK/nep"; mkdir -p "$NEP"
cat > "$NEP/id" <<'EOF'
#!/bin/sh
echo 0
EOF
cat > "$NEP/systemctl" <<'EOF'
#!/bin/sh
case "$1" in is-active) exit 0 ;; is-enabled) echo enabled; exit 0 ;; esac
exit 0
EOF
cat > "$NEP/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$NEP/timedatectl" <<'EOF'
#!/bin/sh
echo yes
EOF
cat > "$NEP/journalctl" <<'EOF'
#!/bin/sh
echo "ptp4l[1]: port 1 (veth0): assuming the grand master role"
EOF
cat > "$NEP/ptp4l" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-v" ] && { echo "4.2"; exit 0; }
exit 0
EOF
chmod +x "$NEP"/*

K="$WERK/omgeving"; mkdir -p "$K"/{net/veth0,net/veth1,dev,etc,systemd,sbin,class}
touch "$K/dev/ptp0"     # alleen zodat het script een PTP-klok ziet; ptp4l gebruikt software-tijdstempels
export PATH="$NEP:$PATH"
export PTP_ETC="$K/etc" PTP_SYSFS_NET="$K/net" PTP_SYSFS_CLASS="$K/class" PTP_DEV_DIR="$K/dev"
export PTP_SYSTEMD_DIR="$K/systemd" PTP_SBIN_DIR="$K/sbin" PTP_STATE_DIR="$K/state"

printf '\n\033[1m== Configuraties maken zoals de kit ze schrijft\033[0m\n'
SOFTWARE=1 PTP_DEV=veth0 UDS="$WERK/math.sock" bash "$REPO/ptp-grandmaster.sh" > "$WERK/gm.out" 2>&1
SOFTWARE=1 PTP_DEV=veth1 UDS="$WERK/klant.sock" bash "$REPO/ptp-client.sh"  > "$WERK/klant.out" 2>&1
GM_CONF="$K/etc/linuxptp/ptp4l-gm.conf"
KLANT_CONF="$K/etc/linuxptp/ptp4l-klant.conf"
toets "de grootmeesterconfiguratie is geschreven" test -s "$GM_CONF"
toets "de clientconfiguratie is geschreven" test -s "$KLANT_CONF"
chmod -R a+rX "$WERK" 2>/dev/null   # ook leesbaar voor een proces met een andere uid
toets "grootmeester gebruikt L2 en software-tijdstempels" grep -qE '^network_transport *L2$' "$GM_CONF"
toets "client zet clientOnly" grep -qE '^clientOnly *1$' "$KLANT_CONF"

# --------------------------------------------------------------- echt meten
printf '\n\033[1m== Twee ptp4l-processen op een veth-paar\033[0m\n'
TESTSCRIPT="$WERK/lock.sh"
cat > "$TESTSCRIPT" <<EOF
#!/bin/bash
set -u
ip link set lo up
ip link add veth0 type veth peer name veth1 || { echo "GEEN-VETH"; exit 3; }
ip link set veth0 up; ip link set veth1 up
"$PTP4L" -f "$GM_CONF"    -i veth0 -m -l 6 > "$WERK/math.log" 2>&1 &
M=\$!
sleep 3
"$PTP4L" -f "$KLANT_CONF" -i veth1 -m -l 6 -s > "$WERK/klant.log" 2>&1 &
K=\$!
sleep 28
kill \$M \$K 2>/dev/null
exit 0
EOF
chmod +x "$TESTSCRIPT"

# Let op: hierboven staat een nep-"id" op PATH, dus vraag het echte id.
if [ "$(command -p id -u)" -eq 0 ]; then NS="unshare -n"; else NS="unshare -Urn"; fi
UIT="$($NS "$TESTSCRIPT" 2>&1)"
if printf '%s' "$UIT" | grep -q 'GEEN-VETH'; then
    overslaan "deze kernel laat geen veth-paar in een naamruimte toe (run: unshare -Urn ip link add ...)"
fi
if printf '%s' "$UIT" | grep -qE 'Operation not permitted|unshare failed'; then
    overslaan "geen eigen netwerknaamruimte mogelijk: $(printf '%s' "$UIT" | head -1)"
fi

if grep -q 'failed to open configuration file' "$WERK/math.log" "$WERK/klant.log" 2>/dev/null; then
    printf '\n  --- diagnose: ptp4l kan de configuratie niet lezen ---\n'
    cat > "$WERK/diagnose.sh" <<EOF
echo "wie: \$(id -u) \$(id -un 2>/dev/null), caps: \$(grep -E '^CapEff' /proc/self/status)"
ls -ld "$WERK" "$K/etc/linuxptp"; ls -l "$GM_CONF"
echo "leesproef: \$(head -c 30 "$GM_CONF" | tr '\n' ' ')"
echo "bestandsrechten van ptp4l: \$(ls -l "$PTP4L" 2>/dev/null)"
command -v getcap >/dev/null && getcap "$PTP4L" 2>&1
echo "apparmor: \$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null), \$(cat /proc/self/attr/current 2>/dev/null)"
echo "--- poging 1: met de configuratie uit de kit:"
timeout 5 "$PTP4L" -f "$GM_CONF" -i lo -S -m -l 6 2>&1 | head -3
cp "$GM_CONF" /tmp/ptp-proef.conf; chmod 666 /tmp/ptp-proef.conf
echo "--- poging 2: met een kopie in /tmp:"
timeout 5 "$PTP4L" -f /tmp/ptp-proef.conf -i lo -S -m -l 6 2>&1 | head -3
cp "$PTP4L" /tmp/mijn-ptp4l 2>/dev/null && chmod +x /tmp/mijn-ptp4l
echo "--- poging 2b: met een kopie van ptp4l (zonder bestandsrechten):"
timeout 5 /tmp/mijn-ptp4l -f /tmp/ptp-proef.conf -i lo -S -m -l 6 2>&1 | head -3
echo "--- poging 3: zonder configuratiebestand, opties op de opdrachtregel:"
timeout 5 "$PTP4L" -i lo -S -m -l 6 --serverOnly 1 --priority1 64 --network_transport L2 --uds_address /tmp/proef.sock 2>&1 | head -3
EOF
    $NS bash "$WERK/diagnose.sh" 2>&1 | sed 's/^/    /'
fi

printf '\n  --- grootmeester ---\n'
sed 's/^/    /' "$WERK/math.log" | tail -8
printf '\n  --- client ---\n'
sed 's/^/    /' "$WERK/klant.log" | tail -8
printf '\n'

toets "de grootmeester neemt de grootmeesterrol aan" \
    grep -q 'assuming the grand master role' "$WERK/math.log"
toets "de client vergrendelt op de grootmeester" \
    grep -q 'UNCALIBRATED on RS_SLAVE' "$WERK/klant.log"
toets "de client meet de afwijking (rms-regels)" \
    bash -c "grep -c 'rms' '$WERK/klant.log' | grep -qE '^[1-9][0-9]*$'"

RMS="$(awk '/rms/ {for (i=1;i<=NF;i++) if ($i=="rms") print $(i+1)}' "$WERK/klant.log" | sort -n)"
AANTAL="$(printf '%s\n' "$RMS" | grep -c . || true)"
if [ "${AANTAL:-0}" -gt 0 ]; then
    MIDDEN="$(printf '%s\n' "$RMS" | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')"
    HOOGSTE="$(printf '%s\n' "$RMS" | tail -1)"
    printf '  %s metingen: mediaan %s ns, hoogste %s ns (software-tijdstempels op een virtuele kabel)\n' \
        "$AANTAL" "$MIDDEN" "$HOOGSTE"
    if [ "$MIDDEN" -lt 100000 ]; then
        printf '  \033[32mok\033[0m   de client loopt binnen 100 µs mee — de configuraties werken\n'
        GOED=$((GOED+1))
    else
        printf '  \033[31mFOUT\033[0m mediaan %s ns is te groot voor software-tijdstempels\n' "$MIDDEN"
        FOUT=$((FOUT+1))
    fi
else
    printf '  \033[31mFOUT\033[0m geen metingen gevonden\n'; FOUT=$((FOUT+1))
fi

printf '\n\033[1m== resultaat\033[0m\n  %d goed, %d fout\n' "$GOED" "$FOUT"
[ "$FOUT" -eq 0 ] || exit 1