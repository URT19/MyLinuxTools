#!/usr/bin/env bash
# =====================================================
#  hetzner_backup.sh
#  Full disk backup / restore / transfer for Hetzner Cloud
#
#  RULES:
#   - Run this from a DIFFERENT Linux server or from your own PC.
#   - Do NOT run backup/restore from the temporary server (rescue system).
#   - Login to Hetzner rescue: SSH key (recommended) or rescue password.
#
#  Needs: ssh, ssh-keygen, gzip, sha256sum, rsync, split   (openssl, sshpass optional)
# =====================================================

set -o pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'

BACKUP_DIR="$HOME/hetzner_backups"
KEY_PATH="$HOME/.ssh/id_ed25519"
AUTH="key"
SSH_OPTS=()
SSH_BASE=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30
          -o ControlMaster=auto -o "ControlPath=/tmp/hbk-%r@%h:%p" -o ControlPersist=20m)

ok()   { echo -e "${G}[OK] $*${N}"; }
warn() { echo -e "${Y}[!] $*${N}"; }
err()  { echo -e "${R}[X] $*${N}"; }
info() { echo -e "${C}>> $*${N}"; }
die()  { err "$1"; exit 1; }

hdr() {
  clear
  echo -e "${B}========================================${N}"
  echo -e "${W}  $*${N}"
  echo -e "${B}========================================${N}"
  echo
}

# yes/no: faghat y ya n ghabool mishe. Ghalat bezani script baste nemishe.
yn() {   # $1 = soal  -> return 0 baraye y, return 1 baraye n
  local a
  while true; do
    read -rp "$(echo -e "${Y}$1 [y/n]: ${N}")" a
    case "$a" in
      y|Y) return 0 ;;
      n|N) return 1 ;;
      *)   warn "Faghat y ya n bezan." ;;
    esac
  done
}

ask() {   # $1 = soal  $2 = pishfarz (ekhtiari)
  local v
  read -rp "$(echo -e "${Y}$1${2:+ [$2]}: ${N}")" v
  echo "${v:-$2}"
}

ask_req() {   # $1 = soal  -> ta vared nashode, dobare miporse
  local v=""
  while [[ -z "$v" ]]; do
    read -rp "$(echo -e "${Y}$1: ${N}")" v
    [[ -z "$v" ]] && warn "Chizi vared nakardi. Dobare vared kon."
  done
  echo "$v"
}

close_conn() {   # $1 = ip
  ssh -O exit -o "ControlPath=/tmp/hbk-%r@%h:%p" root@"$1" >/dev/null 2>&1
}

# ---------------- TOZIHAT ----------------
intro_backup() {
  hdr "Khosh amadi - Backup kamel Hetzner Cloud"
  echo -e "${W}Baraye gereftan backup, ba in marahel pish miravim:${N}"
  echo
  echo "  1) Az server asli, dar panel Hetzner yek SNAPSHOT begir."
  echo "  2) Snapshot ro ba yek SERVER MOVAGHAT bia bala (Create Server from snapshot)."
  echo "  3) Server movaghat ro dar RESCUE mode bebar (Enable Rescue, sepas Reboot)."
  echo "  4) Hetzner ye USER va PASSWORD ro be email mifreste (ma'mulan root + password)."
  echo "  5) Momkene bar avval az to bekhad password ro avaz koni. Yekbar ba SSH be server"
  echo "     vasl sho va password ro taghir bede."
  echo "  6) Ba server movaghat dar Rescue, in script ro az yek server LINUX DIGAR ejra kon"
  echo "     (na az khode server movaghat)."
  echo "  7) Script kol disk ro fesorde mikone va ruye system to save mikone."
  echo "  8) Bad az backup, server movaghat va snapshot ro hazf kon (hazine dare)."
  echo
  warn "Hazine: snapshot va server movaghat ta zamani ke hazf nashan hazine daran."
  warn "Zaman: vabaste be hajm disk va sorat internet (ma'mulan chand saat)."
  warn "Server asli dast nakhorde mimune."
  echo
  yn "Tayid mikoni ke in script ro az yek server LINUX DIGAR (ya system khodet) ejra mikoni va NA az khode server movaghat?" \
    || die "Lagv shod. Az server linuxi dige ejra kon."
  echo
  yn "Marahel bala ro khondi va mikhay edame bedi?" || die "Lagv shod."
}

intro_restore() {
  hdr "Restore - bazgardani backup ruye server"
  echo -e "${W}Baraye bazgardani backup, ba in marahel pish miravim:${N}"
  echo
  echo "  1) Server maghsad ro dar panel Hetzner dar RESCUE mode bebar."
  echo "  2) Hetzner user va password ro be email mifreste. Password ro ba SSH avaz kon."
  echo "  3) Script fayl backup ro (kamel ya part-part) ruye disk server maghsad minevisad."
  echo "  4) Hameye etelaat ruye disk server maghsad pak mishe."
  echo "  5) Bad az restore, Rescue ro Disable kon va server ro Reboot kon."
  echo
  warn "In kar disk server maghsad ro kamel overwrite mikone."
  echo
  yn "Tayid mikoni ke server maghsad dar Rescue hast va mikhay edame bedi?" || die "Lagv shod."
}

intro_transfer() {
  hdr "Entegal - ferestadan backup be server digar"
  echo -e "${W}In bakhsh fayl backup ro az in system be server digar mifreste:${N}"
  echo
  echo "  1) Fayl backup ro entekhab mikoni (kamel ya part-part)."
  echo "  2) IP, port SSH, user, va kelid ya password server maghsad ro vared mikoni."
  echo "  3) Fayl ba rsync montaghel mishe (agar ghat shod, dobare ejra mishe va edame mide)."
  echo "  4) Hash fayl ruye server maghsad check mishe."
  echo
  yn "Edame bedam?" || die "Lagv shod."
}

# ---------------- ABZAR HA ----------------
precheck_tools() {
  hdr "Marhale 1: check abzar ha"
  local t
  for t in ssh ssh-keygen gzip sha256sum split; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "$t peyda shod"
    else
      err "$t nasb nist"
      if [[ "$t" == "ssh" || "$t" == "ssh-keygen" ]] && command -v apt >/dev/null 2>&1; then
        if yn "Nasb konam ba apt (openssh-client)?"; then
          sudo apt update && sudo apt install -y openssh-client || die "Nasb shekst khord."
          ok "openssh-client nasb shod"
        else
          die "Bedoon SSH edame nemishe."
        fi
      else
        die "$t ro nasb kon va dobare ejra kon."
      fi
    fi
  done
  echo
}

# ---------------- KELID / RAVESH VASL ----------------
ensure_key() {
  if [[ -f "$KEY_PATH" ]]; then
    ok "Kelid peyda shod: $KEY_PATH"
    return
  fi
  warn "Kelid SSH peyda nashod. Alan misazam."
  echo
  ssh-keygen -t ed25519 -C "hetzner-backup" -f "$KEY_PATH" || die "Sakhte kelid shekst khord."
  ok "Kelid sakhte shod"
  echo
  info "Kelid AAM (faghat in ro dar Hetzner estefade kon):"
  echo
  cat "$KEY_PATH.pub"
  echo
  warn "Marahel bad:"
  echo "  1) Dar panel Hetzner Cloud > Security > SSH Keys > Add SSH Key"
  echo "  2) Khat bala ro dar Public Key bechasban"
  echo "  3) Nam bedeh, mesle hetzner-backup, va Add bezan"
  echo
  yn "In kelid ro dar Hetzner ezafe kardi?" || die "Aval kelid ro ezafe kon, bad dobare ejra kon."
}

setup_auth() {
  hdr "Marhale 2: ravesh vasl be server Rescue"
  echo -e "  ${G}1)${N} Kelid SSH (tavsiye mishe)"
  echo -e "  ${G}2)${N} Password (password Rescue ke Hetzner be email ferestade)"
  echo
  local m
  m=$(ask "Entekhab" "1")
  if [[ "$m" == "2" ]]; then
    AUTH="password"
    SSH_OPTS=("${SSH_BASE[@]}")
    warn "Password ro moghe soal vared kon. Dar hengam vasl, faghat yek bar miporse."
  else
    AUTH="key"
    ensure_key
    SSH_OPTS=("${SSH_BASE[@]}" -i "$KEY_PATH" -o BatchMode=yes)
  fi
  echo
}

check_conn() {   # $1 = ip
  ssh-keygen -R "$1" >/dev/null 2>&1
  info "Dar hale ettesal be $1 ..."
  if ssh "${SSH_OPTS[@]}" root@"$1" true; then
    ok "Vasl shod"
  else
    die "Vasl nashod. Check kon: server Rescue bashe, IP dorost bashe, kelid ya password dorost bashe."
  fi
}

# ---------------- TAGHSIM BE PART ----------------
split_backup() {   # $1 = masir fayl kamel
  local f="$1" dir base size
  dir=$(dirname "$f")
  base=$(basename "$f")
  echo
  info "Taghsim fayl be part-ha (mesle WinRAR, bedoon fesharde o bedoon ramz)."
  info "Har part ro jodagane dar IDM download kon, bad dar Windows be ham vasl kon."
  echo
  size=$(ask "Andaze har part (mesle 500M, 1G, 2G)" "1G")
  info "Dar hale taghsim..."
  (cd "$dir" && split -b "$size" -d -a 2 "$base" "$base.part") || die "Taghsim shekst khord."
  (cd "$dir" && sha256sum "$base" > "$base.full.sha256" && sha256sum "$base".part[0-9]* > "$base.parts.sha256") \
    || die "Sakhte hash shekst khord."
  ok "Partha sakhte shodand:"
  ls -lh "$dir/$base".part[0-9]*
  echo
  ok "Hash fayl kamel: $dir/$base.full.sha256"
  ok "Hash har part:   $dir/$base.parts.sha256"
  echo
  if yn "Fayl kamel ro hazf konam? (faghat partha bemanand)"; then
    rm -f "$f" && ok "Fayl kamel hazf shod"
  else
    info "Fayl kamel negah dashte shod."
  fi
}

# ---------------- BACKUP ----------------
run_backup() {
  intro_backup
  setup_auth
  hdr "Backup - Marhale 3: etelaat server"
  info "Server movaghat bayad dar Rescue bashe."
  echo
  local IP DISK NAME OUT REMOTE_GZ
  IP=$(ask_req "IP server movaghat (Rescue)")
  check_conn "$IP"
  echo
  info "Etelaat server:"
  ssh "${SSH_OPTS[@]}" root@"$IP" "uname -n; lsblk -dn -o NAME,SIZE,TYPE"
  echo
  yn "Server dar Rescue hast va edame bedam?" || die "Lagv shod."

  hdr "Backup - Marhale 4: entekhab disk"
  DISK=$(ask "Esm disk asli" "sda")
  ssh "${SSH_OPTS[@]}" root@"$IP" "test -b /dev/$DISK" || die "Disk /dev/$DISK peyda nashod."
  ok "Disk /dev/$DISK peyda shod"
  echo

  NAME=$(ask "Esm fayl backup (bedoon pasvand)" "server-$(date +%F_%H%M)")
  OUT="$BACKUP_DIR/$NAME.img.gz"
  mkdir -p "$BACKUP_DIR"
  info "Fayl khoroji: $OUT"
  info "Fazaye khali:"
  df -h "$BACKUP_DIR" | tail -1
  echo
  yn "Dump shoroo beshe?" || die "Lagv shod."

  hdr "Backup - Marhale 5: dump kol disk"
  info "Dar hale dump... (ta tamoom shodan ghat nakon)"
  REMOTE_GZ=$(ssh "${SSH_OPTS[@]}" root@"$IP" "command -v pigz >/dev/null && echo pigz || echo gzip")
  ssh "${SSH_OPTS[@]}" root@"$IP" \
    "set -o pipefail; dd if=/dev/$DISK bs=32M status=progress | $REMOTE_GZ -c" > "$OUT"
  local rc=$?
  if (( rc != 0 )); then
    rm -f "$OUT"
    die "Dump shekst khord (kod $rc)."
  fi
  echo
  ok "Dump tamoom shod: $(du -h "$OUT" | cut -f1)"
  echo
  yn "Marhale 5 tamoom shod. Edame bedam be check sahih budan?" || die "Lagv shod. Fayl dar $OUT hast."

  hdr "Backup - Marhale 6: check sahih budan"
  warn "In marhale mumkene chand daghighe tool bekeshe."
  warn "Agar ertebat ghat shod, fayl bakhtesh khoobe. Bad dobare ejra kon ya dasti check kon:"
  echo "    gzip -t \"$OUT\" && echo OK"
  echo "  Baraye ejra dakhel tmux (bara ghat nashodan):"
  echo "    tmux new -s check"
  echo "    gzip -t \"$OUT\" && echo OK"
  echo "    tmux attach -t check   (bad az ghat shodan)"
  echo
  yn "Ahan check konam?" || die "Lagv shod. Fayl dar $OUT hast."
  gzip -t "$OUT" || die "Fayl khrab ast. Dobare backup begir."
  ok "Fayl gzip salem ast"
  sha256sum "$OUT" | tee "$OUT.sha256"
  ok "Checksum zakhire shod"
  echo
  if yn "Dump-e dovom baraye moghayese (tavsiye mishe)?"; then
    local OUT2="${OUT%.img.gz}-copy2.img.gz"
    info "Dump dovom dar hale anjam..."
    ssh "${SSH_OPTS[@]}" root@"$IP" \
      "set -o pipefail; dd if=/dev/$DISK bs=32M status=progress | $REMOTE_GZ -c" > "$OUT2"
    if (( $? != 0 )); then
      rm -f "$OUT2"; err "Dump dovom shekst khord."
    else
      local h1 h2
      h1=$(gunzip -c "$OUT"  | sha256sum | cut -d' ' -f1)
      h2=$(gunzip -c "$OUT2" | sha256sum | cut -d' ' -f1)
      if [[ "$h1" == "$h2" ]]; then
        ok "Har do dump yeksan hastand"
        rm -f "$OUT2"
      else
        err "Hash ha yeksan nistand! Backup ro dobare begir."
      fi
    fi
  fi

  hdr "Backup - Marhale 7: ramzgozari (ekhtiari)"
  warn "Fayl shamel kelid, ramz va etelaat karbar ast. Ramzgozari tavsiye mishe."
  echo
  if yn "Ba ramz (AES-256) ramzgozari kon?"; then
    if openssl enc -aes-256-cbc -pbkdf2 -salt -in "$OUT" -out "$OUT.enc"; then
      if openssl enc -d -aes-256-cbc -pbkdf2 -in "$OUT.enc" | gzip -t 2>/dev/null; then
        ok "Ramzgozari anjam shod va test shod"
        rm -f "$OUT"
        OUT="$OUT.enc"
      else
        err "Test ramz shekst khord. Fayl asli negah dashte shod."
        rm -f "$OUT.enc"
      fi
    else
      err "Ramzgozari shekst khord."
    fi
  fi

  hdr "Backup - Marhale 8: taghsim be part (ekhtiari)"
  if yn "Fayl ro be part-ha taghsim konam (baraye danlod ba IDM)?"; then
    split_backup "$OUT"
  fi

  close_conn "$IP"
  hdr "Tamoom shod"
  ok "Fayl backup: $OUT"
  echo
  info "Kar ba server Rescue tamoom shod."
  echo "  Mitooni Rescue ro Disable kon, ya server movaghat ro khamoosh ya pak kon."
  echo "  Dige kari be server nadarim."
  echo
  echo "  Fayl backup ro jaye aman negah dar."
  echo
}

# ---------------- RESTORE ----------------
stream_backup() {   # $1 = esm asli (baraye tashkhis .enc)  $2.. = fayl ha beraye cat
  local name="$1"; shift
  if [[ "$name" == *.enc ]]; then
    cat "$@" | openssl enc -d -aes-256-cbc -pbkdf2
  else
    cat "$@"
  fi
}

run_restore() {
  intro_restore
  setup_auth
  hdr "Restore - Marhale 3: entekhab fayl backup"
  [[ -d "$BACKUP_DIR" ]] && { info "Fayl haye mojood:"; ls -1 "$BACKUP_DIR"; echo; }
  local FILE BASE IP DISK c
  local -a SRC
  FILE=$(ask_req "Masir yek fayl backup (kamel ya har part ke dashti)")
  BASE="${FILE%.part[0-9]*}"

  if [[ ! -f "$BASE" ]] && compgen -G "${BASE}.part[0-9]*" >/dev/null; then
    SRC=("${BASE}".part[0-9]*)
    ok "Part-ha peyda shodand: ${#SRC[@]} ta"
    if [[ -f "$BASE.parts.sha256" ]]; then
      info "Check hash partha..."
      ( cd "$(dirname "$BASE")" && sha256sum -c "$(basename "$BASE").parts.sha256" ) \
        || die "Hash yek part ya bishtar ghalat ast. Dobare download kon."
      ok "Hash partha dorost ast"
    else
      warn "Fayl hash partha peyda nashod. Check nemishe."
    fi
  else
    [[ -f "$FILE" ]] || die "Fayl peyda nashod."
    BASE="$FILE"
    SRC=("$FILE")
    ok "Fayl kamel entekhab shod"
  fi
  echo
  yn "Edame bedam?" || die "Lagv shod."

  hdr "Restore - Marhale 4: server maghsad"
  warn "Server maghsad bayad dar Rescue bashe. Hameye disk-esh pak mishe!"
  echo
  IP=$(ask_req "IP server maghsad")
  check_conn "$IP"
  echo
  ssh "${SSH_OPTS[@]}" root@"$IP" "uname -n; lsblk -dn -o NAME,SIZE,TYPE"
  echo
  DISK=$(ask "Disk maghsad" "sda")
  ssh "${SSH_OPTS[@]}" root@"$IP" "test -b /dev/$DISK" || die "Disk /dev/$DISK peyda nashod."
  echo
  yn "Edame bedam?" || die "Lagv shod."

  hdr "Restore - Marhale 5: tayid nahaii"
  err "Hameye /dev/$DISK ruye $IP overwrite mishe!"
  echo
  yn "Mutmaeni ke mikhay ruye $IP restore koni?" || die "Lagv shod."

  hdr "Restore - Marhale 6: dar hale restore"
  info "Restore dar hale anjam... (progress ro bebin)"
  stream_backup "$BASE" "${SRC[@]}" | gunzip -c | \
    ssh "${SSH_OPTS[@]}" root@"$IP" \
      "set -o pipefail; dd of=/dev/$DISK bs=32M conv=fsync status=progress"
  local -a RC=("${PIPESTATUS[@]}")
  echo

  close_conn "$IP"
  if (( RC[0] == 0 && RC[1] == 0 && RC[2] == 0 )); then
    hdr "Restore tamoom shod"
    ok "Disk baazgari shod"
    echo
    info "Marhale aakhar (dar panel Hetzner):"
    echo "  1) Rescue ro Disable kon"
    echo "  2) Server ro Reboot kon"
    echo
    warn "Agar boot nashod, GRUB ro dar rescue dorost kon."
    echo
    info "Kar ba server Rescue tamoom shod. Dige kari be server nadarim."
  else
    err "Restore khata dad (kod ha: ${RC[*]})."
  fi
  echo
}

# ---------------- ENTEGAL BE SERVER DIGAR ----------------
dest_ssh() {   # ejra dastur ruye server maghsad
  if [[ "$DEST_AUTH" == "password" ]]; then
    SSHPASS="$DEST_PASS" sshpass -e ssh "${DEST_OPTS[@]}" "$DEST_USER@$DEST_IP" "$@"
  else
    ssh "${DEST_OPTS[@]}" "$DEST_USER@$DEST_IP" "$@"
  fi
}

run_transfer() {
  intro_transfer
  hdr "Entegal - Marhale 1: entekhab fayl"
  mkdir -p "$BACKUP_DIR"
  info "Fayl haye backup:"
  ls -1 "$BACKUP_DIR" 2>/dev/null || warn "Hich fayli peyda nashod."
  echo
  local FILE BASE DEST_IP DEST_PORT DEST_USER DEST_DIR KEYD m MODE
  local -a FILES
  FILE=$(ask_req "Masir yek fayl backup (kamel ya har part)")
  BASE="${FILE%.part[0-9]*}"

  if [[ ! -f "$BASE" ]] && compgen -G "${BASE}.part[0-9]*" >/dev/null; then
    MODE="parts"
    FILES=("${BASE}".part[0-9]*)
    [[ -f "$BASE.parts.sha256" ]] && FILES+=("$BASE.parts.sha256")
    [[ -f "$BASE.full.sha256" ]]  && FILES+=("$BASE.full.sha256")
    ok "Part-ha entekhab shodand: ${#FILES[@]} fayl"
  else
    [[ -f "$FILE" ]] || die "Fayl peyda nashod."
    MODE="single"
    FILES=("$FILE")
    ok "Fayl kamel entekhab shod"
  fi
  echo
  yn "Edame bedam?" || die "Lagv shod."

  hdr "Entegal - Marhale 2: etelaat server maghsad"
  DEST_IP=$(ask_req "IP server maghsad")
  DEST_PORT=$(ask "Port SSH server maghsad" "22")
  DEST_USER=$(ask "User server maghsad" "root")
  echo
  echo -e "  ${G}1)${N} Kelid SSH"
  echo -e "  ${G}2)${N} Password"
  echo
  m=$(ask "Entekhab" "1")
  DEST_OPTS=(-p "$DEST_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=30)
  if [[ "$m" == "2" ]]; then
    DEST_AUTH="password"
    read -rsp "$(echo -e "${Y}Password server maghsad: ${N}")" DEST_PASS
    echo
    [[ -z "$DEST_PASS" ]] && die "Password khali ast."
    if ! command -v sshpass >/dev/null 2>&1; then
      warn "sshpass nasb nist. Baraye vared kardan password lazem ast."
      if command -v apt >/dev/null 2>&1 && yn "Nasb konam ba apt (sshpass)?"; then
        sudo apt update && sudo apt install -y sshpass || die "Nasb sshpass shekst khord."
      else
        die "Bedoon sshpass edame nemishe."
      fi
    fi
  else
    DEST_AUTH="key"
    KEYD=$(ask "Masir kelid SSH" "$KEY_PATH")
    [[ -f "$KEYD" ]] || die "Kelid '$KEYD' peyda nashod."
    DEST_OPTS+=(-i "$KEYD" -o BatchMode=yes)
  fi
  DEST_DIR=$(ask "Masir maghsad dar server" "/root/backups")
  echo
  info "Kholase:"
  echo "  Fayl(ha): ${FILES[*]}"
  echo "  Server:   $DEST_USER@$DEST_IP  (port $DEST_PORT)"
  echo "  Masir:    $DEST_DIR"
  echo
  yn "Ferestadan shoroo beshe?" || die "Lagv shod."

  hdr "Entegal - Marhale 3: ferestadan"
  if ! command -v rsync >/dev/null 2>&1; then
    warn "rsync nasb nist."
    if command -v apt >/dev/null 2>&1 && yn "Nasb konam ba apt (rsync)?"; then
      sudo apt update && sudo apt install -y rsync || die "Nasb rsync shekst khord."
    else
      die "Bedoon rsync edame nemishe."
    fi
  fi

  dest_ssh "mkdir -p '$DEST_DIR'" || die "Sakhte masir ruye server maghsad shekst khord."
  ok "Masir ruye server maghsad amade ast"
  echo
  info "Dar hale ferestadan... (agar ghat shod, dobare ejra kon, az jaee edame mide)"
  if [[ "$DEST_AUTH" == "password" ]]; then
    SSHPASS="$DEST_PASS" rsync -avP --partial \
      -e "sshpass -e ssh -p $DEST_PORT -o StrictHostKeyChecking=accept-new" \
      "${FILES[@]}" "$DEST_USER@$DEST_IP:$DEST_DIR/"
  else
    rsync -avP --partial \
      -e "ssh -p $DEST_PORT -i $KEYD -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
      "${FILES[@]}" "$DEST_USER@$DEST_IP:$DEST_DIR/"
  fi
  if (( $? != 0 )); then
    err "Ferestadan kamel nashod. Dobare ejra kon, az jaee edame mide."
    return 1
  fi
  echo

  hdr "Entegal - Marhale 4: check hash ruye server maghsad"
  local NAME LOCAL_H REMOTE_H
  if [[ "$MODE" == "parts" ]]; then
    local BNAME; BNAME=$(basename "$BASE")
    if dest_ssh "cd '$DEST_DIR' && sha256sum -c '$BNAME.parts.sha256'"; then
      hdr "Entegal tamoom shod"
      ok "Hame partha ba mosharakat ferestade shodand va hash dorost ast"
      echo
      info "Masir ruye server maghsad: $DEST_DIR"
    else
      err "Hash yek part ya bishtar dorost nist. Dobare ejra kon ta dorost montaghel beshe."
    fi
  else
    NAME=$(basename "$FILE")
    LOCAL_H=$(sha256sum "$FILE" | cut -d' ' -f1)
    REMOTE_H=$(dest_ssh "sha256sum '$DEST_DIR/$NAME'" | cut -d' ' -f1)
    echo "  Hash mahalli:  $LOCAL_H"
    echo "  Hash maghsad:  $REMOTE_H"
    echo
    if [[ -n "$REMOTE_H" && "$LOCAL_H" == "$REMOTE_H" ]]; then
      hdr "Entegal tamoom shod"
      ok "Fayl ba mosharakat ferestade shod va hash yeksan ast"
      echo
      info "Fayl ruye server maghsad: $DEST_DIR/$NAME"
    else
      err "Hash yeksan nist. Dobare ejra kon ta fayl dorost montaghel beshe."
    fi
  fi
  echo
}

# ---------------- MENU ----------------
mkdir -p "$BACKUP_DIR"
precheck_tools
hdr "Entekhab"
echo -e "  ${G}1)${N} Backup kamel (server movaghat Rescue -> in system)"
echo -e "  ${G}2)${N} Restore (fayl backup -> server Rescue)"
echo -e "  ${G}3)${N} Entegal fayl backup be server digar"
echo -e "  ${G}0)${N} Khorooj"
echo
case "$(ask 'Entekhab')" in
  1) run_backup ;;
  2) run_restore ;;
  3) run_transfer ;;
  *) exit 0 ;;
esac
