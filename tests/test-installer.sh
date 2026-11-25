#!/usr/bin/env bash
#
# Testbank voor ptp-grandmaster.sh en ptp-client.sh.
#
# Er is geen echte netwerkkaart met een PTP-klok nodig: de scripts kijken in
# PTP_SYSFS_NET, PTP_DEV_DIR en PTP_ETC, en die wijzen we hier naar een nepboom.
# id/systemctl/apt-get/timedatectl/pmc/journalctl staan als nepcommando op PATH,
# zodat de scripts denken dat ze root op een Proxmox-host zijn.
#
# Draaien:   bash tests/test-installer.sh
#
set -uo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HIER")"
WERK="$(mktemp -d)"
trap 'rm -rf "$WERK"' EXIT

GOED=0; FOUT=0
toets() {                       # toets <omschrijving> <commando...>
    local wat="$1"; shift
    if "$@" >/dev/null 2>&1; then printf '  \033[32mok\033[0m   %s\n' "$wat"; GOED=$((GOED+1))
    else printf '  \033[31mFOUT\033[0m %s\n' "$wat"; FOUT=$((FOUT+1)); fi
}
toets_bevat() {                 # toets_bevat <bestand> <patroon>
    local f="$1" p="$2"
    if grep -q -e "$p" "$f" 2>/dev/null; then printf '  \033[32mok\033[0m   %s bevat %s\n' "$(basename "$f")" "$p"; GOED=$((GOED+1))
    else printf '  \033[31mFOUT\033[0m %s bevat geen %s\n' "$(basename "$f")" "$p"; FOUT=$((FOUT+1)); fi
}
toets_bevat_niet() {
    local f="$1" p="$2"
    if grep -q -e "$p" "$f" 2>/dev/null; then printf '  \033[31mFOUT\033[0m %s bevat onverwacht %s\n' "$(basename "$f")" "$p"; FOUT=$((FOUT+1))
    else printf '  \033[32mok\033[0m   %s bevat geen %s\n' "$(basename "$f")" "$p"; GOED=$((GOED+1)); fi
}

# ----------------------------------------------------------- nep-omgeving

# Een netwerkkaart met een PTP-klok, eentje zonder, en een virtuele poort.
maak_nepboom() {
    local root="$1"
    rm -rf "$root"; mkdir -p "$root"/{net,dev,etc,systemd,sbin}
    for kaart in igb e1000e; do mkdir -p "$root/kart/$kaart"; done

    mkdir -p "$root/net/lo"
    mkdir -p "$root/net/eth0"                      # virtuele poort (geen PCI-apparaat)
    mkdir -p "$root/net/enp1s0f0/device"           # Intel I350, mét PTP-klok, in een bridge
    ln -s "$root/kart/igb" "$root/net/enp1s0f0/device/driver"
    mkdir -p "$root/net/enp1s0f0/device/ptp/ptp0"
    touch "$root/net/enp1s0f0/brport"
    mkdir -p "$root/net/enp1s0f1/device"           # tweede poort van dezelfde kaart, vrij
    ln -s "$root/kart/igb" "$root/net/enp1s0f1/device/driver"
    mkdir -p "$root/net/enp1s0f1/device/ptp/ptp0"
    mkdir -p "$root/net/enp2s0/device"             # onboard Intel, géén PTP-klok
    ln -s "$root/kart/e1000e" "$root/net/enp2s0/device/driver"

    touch "$root/dev/ptp0"
}

maak_nepcommando() {            # nepcommando's op PATH
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
echo 0
EOF
    cat > "$bin/systemctl" <<'EOF'
#!/bin/sh
# Alles lijkt actief/enabled; is-active --quiet vraagt om status 0.
case "$1" in
    is-active) exit 0 ;;
    is-enabled) echo enabled; exit 0 ;;
esac
echo "systemctl $*" >> "${NEP_LOG:-/dev/null}"
exit 0
EOF
    cat > "$bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "${NEP_LOG:-/dev/null}"
exit 0
EOF
    cat > "$bin/timedatectl" <<'EOF'
#!/bin/sh
echo yes
EOF
    cat > "$bin/pmc" <<'EOF'
#!/bin/sh
echo "grandmasterIdentity 001b21.fffe.112233"
echo "parentPortIdentity 001b21.fffe.112233-1"
EOF
    cat > "$bin/journalctl" <<'EOF'
#!/bin/sh
echo "ptp4l[1.1]: port 1 (enp1s0f1): assuming the grand master role"
EOF
    cat > "$bin/ptp4l" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-v" ] && { echo "4.2"; exit 0; }
exit 0
EOF
    cat > "$bin/phc2sys" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$bin"/*
}

NEP="$WERK/nep"
maak_nepcommando "$NEP"
export PATH="$NEP:$PATH"
export NEP_LOG="$WERK/nep.log"
: > "$NEP_LOG"

# --------------------------------------------------------------- scenario's

omgeving_voor_run() {           # zet de variabelen voor één run
    local root="$1"
    maak_nepboom "$root"
    export PTP_ETC="$root/etc"
    export PTP_SYSFS_NET="$root/net"
    export PTP_SYSFS_CLASS="$root/class"
    export PTP_DEV_DIR="$root/dev"
    export PTP_SYSTEMD_DIR="$root/systemd"
    export PTP_SBIN_DIR="$root/sbin"
    export PTP_STATE_DIR="$root/state"
    mkdir -p "$root/class"
}

printf '\n\033[1m== 1. kijken welke poort geschikt is\033[0m\n'
R1="$WERK/run1"; omgeving_voor_run "$R1"
UIT="$(bash "$REPO/ptp-grandmaster.sh" --check 2>&1)"
printf '%s\n' "$UIT" | sed 's/^/    /'
printf '%s\n' "$UIT" | grep -q "gekozen poort: enp1s0f1" \
    && { printf '  \033[32mok\033[0m   kiest de vrije poort met PTP-klok (enp1s0f1), niet de bridged poort\n'; GOED=$((GOED+1)); } \
    || { printf '  \033[31mFOUT\033[0m kiest niet enp1s0f1\n'; FOUT=$((FOUT+1)); }
printf '%s\n' "$UIT" | grep -q "enp2s0.*hardware: nee (kaart heeft geen PTP-klok)" \
    && { printf '  \033[32mok\033[0m   herkent de kaart zonder PTP-klok\n'; GOED=$((GOED+1)); } \
    || { printf '  \033[31mFOUT\033[0m herkent enp2s0 niet als kaart zonder PTP-klok\n'; FOUT=$((FOUT+1)); }
toets "--check verandert niets (geen config geschreven)" test ! -f "$R1/etc/linuxptp/ptp4l-gm.conf"

printf '\n\033[1m== 2. installeren op een host met een PTP-kaart\033[0m\n'
R2="$WERK/run2"; omgeving_voor_run "$R2"
UIT="$(bash "$REPO/ptp-grandmaster.sh" 2>&1)"; STATUS=$?
printf '%s\n' "$UIT" | tail -25 | sed 's/^/    /'
toets "installatie eindigt met status 0 (nu: $STATUS)" test "$STATUS" -eq 0
toets_bevat "$R2/etc/linuxptp/ptp4l-gm.conf" '^priority1 *64$'
toets_bevat "$R2/etc/linuxptp/ptp4l-gm.conf" '^serverOnly *1$'
toets_bevat "$R2/etc/linuxptp/ptp4l-gm.conf" '^network_transport *L2$'
toets_bevat "$R2/etc/linuxptp/ptp4l-gm.conf" '^time_stamping *hardware$'
toets_bevat "$R2/etc/linuxptp/ptp4l-gm.conf" '^utc_offset *0$'
toets_bevat "$R2/systemd/ptp4l-gm.service" '-i enp1s0f1'
toets_bevat "$R2/systemd/phc2sys-gm.service" '-s CLOCK_REALTIME -c enp1s0f1'
toets "phc2sys-gm heeft een Restart (dus herstelt na een fout)" \
    grep -q 'Restart=always' "$R2/systemd/phc2sys-gm.service"

# De eenheden die het script schrijft moeten gelijk zijn aan de kopieën in
# systemd/ (met de paden van deze run erin). Anders lopen de twee uit elkaar en
# klopt de documentatie niet meer met wat er geïnstalleerd wordt.
for u in ptp4l-gm phc2sys-gm; do
    sed -e "s|$R2/etc/linuxptp|/etc/linuxptp|g" -e 's|enp1s0f1|__DEV__|g' \
        "$R2/systemd/$u.service" > "$WERK/$u.norm"
    toets "$u.service is identiek aan het origineel in systemd/" \
        diff -q "$WERK/$u.norm" "$REPO/systemd/$u.service"
done

printf '\n\033[1m== 3. tweede run is idempotent\033[0m\n'
UIT2="$(bash "$REPO/ptp-grandmaster.sh" 2>&1)"
printf '%s\n' "$UIT2" | grep -q "is al gelijk" \
    && { printf '  \033[32mok\033[0m   herkent de bestaande configuratie\n'; GOED=$((GOED+1)); } \
    || { printf '  \033[31mFOUT\033[0m schrijft opnieuw zonder te melden dat het al gelijk was\n'; FOUT=$((FOUT+1)); }
toets "geen backup gemaakt bij een ongewijzigde tweede run" \
    bash -c "ls $R2/etc/linuxptp/ptp4l-gm.conf.bak.* >/dev/null 2>&1 && exit 1 || exit 0"

printf '\n\033[1m== 4. software-tijdstempels als er geen PTP-klok is\033[0m\n'
R4="$WERK/run4"; omgeving_voor_run "$R4"
UIT="$(SOFTWARE=1 PTP_DEV=enp2s0 bash "$REPO/ptp-grandmaster.sh" 2>&1)"
toets_bevat "$R4/etc/linuxptp/ptp4l-gm.conf" '^time_stamping *software$'
toets_bevat "$R4/systemd/ptp4l-gm.service" '-i enp2s0'

printf '\n\033[1m== 5. instellingen via de omgeving\033[0m\n'
R5="$WERK/run5"; omgeving_voor_run "$R5"
UIT="$(DOMAIN=24 PRIORITY=32 TRANSPORT=UDPv4 SYNC_INTERVAL=0 CLOCK_CLASS=248 UTC_OFFSET=37 bash "$REPO/ptp-grandmaster.sh" 2>&1)"
toets_bevat "$R5/etc/linuxptp/ptp4l-gm.conf" '^domainNumber *24$'
toets_bevat "$R5/etc/linuxptp/ptp4l-gm.conf" '^priority1 *32$'
toets_bevat "$R5/etc/linuxptp/ptp4l-gm.conf" '^network_transport *UDPv4$'
toets_bevat "$R5/etc/linuxptp/ptp4l-gm.conf" '^logSyncInterval *0$'
toets_bevat "$R5/etc/linuxptp/ptp4l-gm.conf" '^utc_offset *37$'

printf '\n\033[1m== 6. een bestaande configuratie wordt bewaard\033[0m\n'
R6="$WERK/run6"; omgeving_voor_run "$R6"
mkdir -p "$R6/etc/linuxptp"; echo "# oude inhoud" > "$R6/etc/linuxptp/ptp4l-gm.conf"
bash "$REPO/ptp-grandmaster.sh" >/dev/null 2>&1
toets "backup van de oude configuratie" bash -c "cs=($R6/etc/linuxptp/ptp4l-gm.conf.bak.*); grep -q 'oude inhoud' \"\${cs[0]}\""

printf '\n\033[1m== 7. opruimen\033[0m\n'
R7="$WERK/run7"; omgeving_voor_run "$R7"
bash "$REPO/ptp-grandmaster.sh" >/dev/null 2>&1
bash "$REPO/ptp-grandmaster.sh" --uninstall >/dev/null 2>&1
toets "eenheden weg na --uninstall" test ! -f "$R7/systemd/ptp4l-gm.service"
toets "configuratie blijft staan na --uninstall" test -f "$R7/etc/linuxptp/ptp4l-gm.conf"

printf '\n\033[1m== 8. zonder geschikte poort stopt het script met uitleg\033[0m\n'
R8="$WERK/run8"
rm -rf "$R8"; mkdir -p "$R8"/{net,dev,etc}
mkdir -p "$R8/net/lo"; mkdir -p "$R8/net/eth0"
export PTP_ETC="$R8/etc"; export PTP_SYSFS_NET="$R8/net"; export PTP_DEV_DIR="$R8/dev"
export PTP_SYSTEMD_DIR="$R8/systemd"; export PTP_SBIN_DIR="$R8/sbin"; export PTP_STATE_DIR="$R8/state"
UIT="$(bash "$REPO/ptp-grandmaster.sh" 2>&1)"; STATUS=$?
printf '%s\n' "$UIT" | tail -8 | sed 's/^/    /'
toets "stopt met status 1 zonder poort en zonder SOFTWARE=1 (nu: $STATUS)" test "$STATUS" -eq 1
printf '%s\n' "$UIT" | grep -q 'SOFTWARE=1' \
    && { printf '  \033[32mok\033[0m   legt de uitweg SOFTWARE=1 uit\n'; GOED=$((GOED+1)); } \
    || { printf '  \033[31mFOUT\033[0m legt SOFTWARE=1 niet uit\n'; FOUT=$((FOUT+1)); }

printf '\n\033[1m== 9. dry-run raakt niets aan\033[0m\n'
R9="$WERK/run9"; omgeving_voor_run "$R9"
UIT="$(DROOG=1 bash "$REPO/ptp-grandmaster.sh" 2>&1)"
printf '%s\n' "$UIT" | grep -q 'niets geschreven of gestart' \
    && { printf '  \033[32mok\033[0m   meldt dat er niets is veranderd\n'; GOED=$((GOED+1)); } \
    || { printf '  \033[31mFOUT\033[0m meldt de dry-run niet\n'; FOUT=$((FOUT+1)); }
toets "dry-run schrijft geen configuratie" test ! -f "$R9/etc/linuxptp/ptp4l-gm.conf"
toets "dry-run schrijft geen eenheden" test ! -f "$R9/systemd/ptp4l-gm.service"

printf '\n\033[1m== 10. de client volgt de grootmeester\033[0m\n'
R10="$WERK/run10"; omgeving_voor_run "$R10"
UIT="$(bash "$REPO/ptp-client.sh" 2>&1)"; STATUS=$?
printf '%s\n' "$UIT" | tail -15 | sed 's/^/    /'
toets "client-installatie eindigt met status 0 (nu: $STATUS)" test "$STATUS" -eq 0
toets_bevat "$R10/etc/linuxptp/ptp4l-klant.conf" '^clientOnly *1$'
toets_bevat "$R10/etc/linuxptp/ptp4l-klant.conf" '^network_transport *L2$'
toets_bevat "$R10/systemd/ptp4l-klant.service" '-i enp1s0f0 -m -s'
toets_bevat "$R10/systemd/phc2sys-klant.service" '-s enp1s0f0 -c CLOCK_REALTIME -w'
for u in ptp4l-klant phc2sys-klant; do
    sed -e "s|$R10/etc/linuxptp|/etc/linuxptp|g" -e 's|enp1s0f0|__DEV__|g' \
        "$R10/systemd/$u.service" > "$WERK/$u.norm"
    toets "$u.service is identiek aan het origineel in systemd/" \
        diff -q "$WERK/$u.norm" "$REPO/systemd/$u.service"
done
toets_bevat "$NEP_LOG" 'disable --now systemd-timesyncd'
toets "client kiest hardware-tijdstempels als de kaart er een heeft" \
    grep -q '^time_stamping *hardware$' "$R10/etc/linuxptp/ptp4l-klant.conf"

printf '\n\033[1m== 11. de client in een container (software-tijdstempels)\033[0m\n'
R11="$WERK/run11"; omgeving_voor_run "$R11"
rm -rf "$R11/net/enp1s0f0/device/ptp" "$R11/net/enp1s0f1/device/ptp"
UIT="$(bash "$REPO/ptp-client.sh" 2>&1)"
toets_bevat "$R11/etc/linuxptp/ptp4l-klant.conf" '^time_stamping *software$'
printf '%s\n' "$UIT" | grep -q 'geen PTP-klok' \
    && { printf '  \033[32mok\033[0m   zegt eerlijk dat het om software-tijdstempels gaat\n'; GOED=$((GOED+1)); } \
    || { printf '  \033[31mFOUT\033[0m meldt de beperking niet\n'; FOUT=$((FOUT+1)); }

printf '\n\033[1m== resultaat\033[0m\n'
printf '  %d goed, %d fout\n' "$GOED" "$FOUT"
[ "$FOUT" -eq 0 ] || exit 1