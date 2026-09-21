#!/usr/bin/env bash
#
# CloudShift Hardware Certification Tool
# v1.1.1 - adds dependency auto-install, threshold enforcement (no MinIO)
#
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='1.1.1'
BASE='/var/log/cloudshift-test'
HOST=$(hostname -s)
RUN=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$BASE/$HOST/$RUN"
RAW="$OUT/raw"

# ---------- threshold defaults (override via /etc/cloudshift/thresholds.env) ----------
TEMP_MAX_C=90
SMART_REQUIRED=1
FIO_MIN_IOPS=200
SYBENCH_MIN_EVENTS=500
STRESS_MINUTES=30
JOURNAL_MAX_ERRORS=50
# ------------------------------------------------------------------------------------

mkdir -p "$RAW"
chmod 700 "$OUT"

[[ $EUID -eq 0 ]] || { echo 'Run: sudo cloudshift-test'; exit 1; }

log(){ echo "[$(date -u +%FT%TZ)] $*" | tee -a "$OUT/run.log"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- optional config ----------
[[ -r /etc/cloudshift/thresholds.env ]] && { set -a; . /etc/cloudshift/thresholds.env; set +a; }

# ---------- dependency installation ----------
TOOLS=(lshw dmidecode smartctl stress-ng sysbench fio iperf3 sensors jq ethtool curl)
MISSING=()
for t in "${TOOLS[@]}"; do have "$t" || MISSING+=("$t"); done

install_deps(){
  local pkgs=()
  for t in "${MISSING[@]}"; do
    case "$t" in
      smartctl)  pkgs+=(smartmontools) ;;
      stress-ng) pkgs+=(stress-ng) ;;
      sysbench)  pkgs+=(sysbench) ;;
      fio)       pkgs+=(fio) ;;
      iperf3)    pkgs+=(iperf3) ;;
      sensors)   pkgs+=(lm-sensors) ;;
      lshw)      pkgs+=(lshw) ;;
      dmidecode) pkgs+=(dmidecode) ;;
      jq)        pkgs+=(jq) ;;
      ethtool)   pkgs+=(ethtool) ;;
      curl)      pkgs+=(curl) ;;
      *)         pkgs+=("$t") ;;
    esac
  done
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  log "Installing missing dependencies: ${pkgs[*]}"
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || true
    apt-get install -y -qq "${pkgs[@]}" || { log "WARN: apt install failed"; return 1; }
  elif have dnf; then
    dnf install -y "${pkgs[@]}" || { log "WARN: dnf install failed"; return 1; }
  elif have yum; then
    yum install -y "${pkgs[@]}" || { log "WARN: yum install failed"; return 1; }
  else
    log "WARN: no known package manager; install manually: ${pkgs[*]}"
    return 1
  fi
  MISSING=()
  for t in "${TOOLS[@]}"; do have "$t" || MISSING+=("$t"); done
}

if [[ ${#MISSING[@]} -gt 0 ]]; then
  log "Missing tools: ${MISSING[*]}"
  install_deps || true
fi

# sensors module load (best-effort)
if have sensors && ! sensors 2>/dev/null | grep -q 'Adapter:'; then
  have sensors-detect && sensors-detect --auto >/dev/null 2>&1 || true
fi

# ---------- inventory ----------
MANUFACTURER=$(dmidecode -s system-manufacturer 2>/dev/null || true)
PRODUCT=$(dmidecode -s system-product-name 2>/dev/null || true)
SERIAL=$(dmidecode -s system-serial-number 2>/dev/null || true)
CPU=$(awk -F: '/model name/{gsub(/^ /,"",$2);print $2;exit}' /proc/cpuinfo)
CORES=$(nproc)
RAM_GB=$(awk '/MemTotal/{printf "%.2f",$2/1024/1024}' /proc/meminfo)
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
KERNEL=$(uname -r)
VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)

log "CloudShift Hardware Certification v$VERSION"
log "Output: $OUT"
log "Host: $HOST  Virt: $VIRT  Cores: $CORES  RAM: ${RAM_GB}GB"

lshw -json > "$RAW/lshw.json" 2>&1 || true
lsblk -J -o NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,FSTYPE,MOUNTPOINTS > "$RAW/lsblk.json" 2>&1 || true
dmidecode > "$RAW/dmidecode.txt" 2>&1 || true
ip -j addr > "$RAW/ip-address.json" 2>&1 || true
df -hT > "$RAW/df.txt" 2>&1 || true
free -h > "$RAW/free.txt" 2>&1 || true
uptime > "$RAW/uptime.txt" 2>&1 || true
journalctl -p 0..3 -b --no-pager > "$RAW/journal-errors.txt" 2>&1 || true

DISK=$(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print "/dev/"$1;exit}')
[[ -n "${DISK:-}" ]] || DISK='none'

PASS=0; WARN=0; FAIL=0
add_pass(){ PASS=$((PASS+1)); }
add_warn(){ WARN=$((WARN+1)); }
add_fail(){ FAIL=$((FAIL+1)); }

# ---------- sysbench ----------
SYSCPU='SKIPPED'; SYSMEM='SKIPPED'
if have sysbench; then
  if sysbench cpu --threads="$CORES" --time=30 run > "$RAW/sysbench-cpu.txt" 2>&1; then
    EVENTS=$(grep -Eo 'events per second: *[0-9.]+' "$RAW/sysbench-cpu.txt" | awk '{print $4}' | tail -1 || true)
    SYSCPU="PASSED (${EVENTS:-?} ev/s)"
    if [[ -n "$EVENTS" ]] && awk "BEGIN{exit !($EVENTS >= $SYBENCH_MIN_EVENTS)}"; then add_pass; else add_warn; SYSCPU="$SYSCPU [below ${SYBENCH_MIN_EVENTS}]"; fi
  else
    SYSCPU='FAILED'; add_fail
  fi
  if sysbench memory --threads="$CORES" --time=30 run > "$RAW/sysbench-memory.txt" 2>&1; then
    SYSMEM='PASSED'; add_pass
  else
    SYSMEM='FAILED'; add_fail
  fi
else
  add_warn
fi

# ---------- temperature ----------
TEMP_MAX=null
if have sensors; then
  sensors > "$RAW/temperature.txt" 2>&1 || true
  T=$(grep -Eo '[+-]?[0-9]+(\.[0-9]+)?°C' "$RAW/temperature.txt" 2>/dev/null | sed 's/°C//' | sort -n | tail -1 || true)
  [[ -n "${T:-}" ]] && TEMP_MAX="$T"
else
  add_warn
fi

# ---------- stress-ng ----------
STRESS='SKIPPED'
if have stress-ng; then
  if stress-ng --cpu "$CORES" --vm 2 --vm-bytes 70% --verify --metrics-brief \
       --timeout "${STRESS_MINUTES}m" > "$RAW/stress-ng.txt" 2>&1; then
    STRESS='PASSED'; add_pass
  else
    STRESS='FAILED'; add_fail
  fi
else
  add_warn
fi

# re-read temp after stress (peak)
if have sensors && [[ -f "$RAW/temperature.txt" ]]; then
  sensors > "$RAW/temperature-after.txt" 2>&1 || true
  T2=$(grep -Eo '[+-]?[0-9]+(\.[0-9]+)?°C' "$RAW/temperature-after.txt" 2>/dev/null | sed 's/°C//' | sort -n | tail -1 || true)
  if [[ -n "${T2:-}" ]]; then
    if [[ "$TEMP_MAX" == "null" ]] || awk "BEGIN{exit !($T2 > $TEMP_MAX)}"; then TEMP_MAX="$T2"; fi
  fi
fi

# ---------- SMART ----------
SMART='UNAVAILABLE'
if [[ -b "$DISK" ]] && have smartctl; then
  smartctl -a "$DISK" > "$RAW/smartctl.txt" 2>&1 || true
  if smartctl -H "$DISK" 2>&1 | grep -qi PASSED; then
    SMART='PASSED'; add_pass
  else
    SMART='CHECK'; add_warn
  fi
fi

# ---------- fio ----------
FIO='SKIPPED'
if have fio && [[ $(df -Pk /var/tmp | awk 'NR==2{print $4}') -gt 2097152 ]]; then
  mkdir -p /var/tmp/cloudshift-test
  if fio --name=cloudshift --filename=/var/tmp/cloudshift-test/testfile \
        --size=512M --rw=readwrite --rwmixread=70 --bs=1M --iodepth=8 \
        --runtime=60 --time_based=1 --group_reporting > "$RAW/fio.txt" 2>&1; then
    IOPS=$(grep -Eo 'iops=[0-9.]+' "$RAW/fio.txt" | head -1 | cut -d= -f2 || true)
    FIO="PASSED (${IOPS:-?} iops)"
    if [[ -n "$IOPS" ]] && awk "BEGIN{exit !($IOPS >= $FIO_MIN_IOPS)}"; then add_pass; else add_warn; FIO="$FIO [below ${FIO_MIN_IOPS}]"; fi
  else
    FIO='FAILED'; add_fail
  fi
  rm -f /var/tmp/cloudshift-test/testfile
else
  add_warn
fi

# ---------- network ----------
NET='SKIPPED'
if have iperf3; then
  echo 'No iperf3 server supplied; run separately with --iperf-server in a later version.' > "$RAW/network.txt"
  add_warn
fi

# ---------- docker ----------
DOCKER='NOT_INSTALLED'
if have docker; then
  docker info > "$RAW/docker-info.txt" 2>&1 && DOCKER='RUNNING' || DOCKER='INSTALLED'
fi

# ---------- journal error count ----------
JERR=$(wc -l < "$RAW/journal-errors.txt" 2>/dev/null || echo 0)

# ---------- threshold verdicts ----------
declare -a REASONS=()
if [[ "$FAIL" -gt 0 ]]; then
  REASONS+=("hard test failure(s): $FAIL")
fi
if [[ "$TEMP_MAX" != "null" ]] && awk "BEGIN{exit !($TEMP_MAX > $TEMP_MAX_C)}"; then
  REASONS+=("temperature ${TEMP_MAX}C exceeds ${TEMP_MAX_C}C")
fi
if [[ "$SMART_REQUIRED" -eq 1 && "$SMART" != "PASSED" && "$SMART" != "UNAVAILABLE" ]]; then
  REASONS+=("SMART health: $SMART")
fi
if [[ "$JERR" -gt "$JOURNAL_MAX_ERRORS" ]]; then
  REASONS+=("kernel errors $JERR > $JOURNAL_MAX_ERRORS")
fi

STATUS='PASS'
if [[ ${#REASONS[@]} -gt 0 ]]; then
  if [[ "$FAIL" -gt 0 ]]; then STATUS='FAIL'
  else STATUS='PASS_WITH_WARNINGS'
  fi
elif [[ "$WARN" -gt 0 ]]; then
  STATUS='PASS_WITH_WARNINGS'
fi

# ---------- JSON report ----------
MISSING_JSON=$(printf '%s\n' "${MISSING[@]:-}" | jq -R 'select(length>0)' | jq -s .)
REASONS_JSON=$(printf '%s\n' "${REASONS[@]:-}" | jq -R 'select(length>0)' | jq -s .)
TEMP_JSON=null
[[ "$TEMP_MAX" != "null" ]] && TEMP_JSON="$TEMP_MAX"

jq -n \
  --arg tool "$VERSION" \
  --arg generated "$(date -u +%FT%TZ)" \
  --arg host "$HOST" \
  --arg virt "$VIRT" \
  --arg manufacturer "$MANUFACTURER" \
  --arg product "$PRODUCT" \
  --arg serial "$SERIAL" \
  --arg cpu "$CPU" \
  --arg os "$OS" \
  --arg kernel "$KERNEL" \
  --argjson cores "$CORES" \
  --argjson ram "$RAM_GB" \
  --arg disk "$DISK" \
  --arg smart "$SMART" \
  --arg fio "$FIO" \
  --arg syscpu "$SYSCPU" \
  --arg sysmem "$SYSMEM" \
  --arg stress "$STRESS" \
  --arg docker "$DOCKER" \
  --argjson temp "$TEMP_JSON" \
  --argjson jerr "$JERR" \
  --argjson pass "$PASS" \
  --argjson warnings "$WARN" \
  --argjson failures "$FAIL" \
  --arg status "$STATUS" \
  --argjson missing "$MISSING_JSON" \
  --argjson reasons "$REASONS_JSON" \
  --arg out "$OUT" \
  '{
    schema_version:"1.1",
    tool:{name:"CloudShift Hardware Certification",version:$tool},
    generated_utc:$generated,
    system:{
      hostname:$host, virt:$virt,
      manufacturer:$manufacturer, product:$product, serial:$serial,
      cpu:$cpu, cpu_cores:$cores, ram_gb:$ram,
      os:$os, kernel:$kernel
    },
    tests:{
      cpu_benchmark:$syscpu,
      memory_benchmark:$sysmem,
      stress:$stress,
      temperature_max_c:$temp,
      kernel_errors:$jerr,
      storage:{device:$disk, smart_health:$smart, fio:$fio},
      docker:$docker
    },
    missing_tools:$missing,
    result:{
      pass_count:$pass, warning_count:$warnings, failure_count:$failures,
      status:$status, reasons:$reasons
    },
    artifacts:{directory:$out}
  }' > "$OUT/report.json"

# ---------- summary ----------
{
  echo 'CloudShift Hardware Certification'
  echo '==============================='
  echo "Machine: $MANUFACTURER $PRODUCT"
  echo "Virt: $VIRT"
  echo "CPU: $CPU ($CORES cores)"
  echo "RAM: $RAM_GB GB"
  echo "OS: $OS"
  echo "Kernel: $KERNEL"
  echo "Disk: $DISK"
  echo "SMART: $SMART"
  echo "sysbench CPU: $SYSCPU"
  echo "sysbench MEM: $SYSMEM"
  echo "stress-ng: $STRESS"
  echo "FIO: $FIO"
  echo "Temp max: ${TEMP_MAX}C"
  echo "Kernel errors: $JERR"
  echo "Docker: $DOCKER"
  echo "Pass: $PASS  Warn: $WARN  Fail: $FAIL"
  echo "RESULT: $STATUS"
  [[ ${#REASONS[@]} -gt 0 ]] && printf 'Reason: %s\n' "${REASONS[@]}"
  echo "JSON: $OUT/report.json"
} > "$OUT/summary.txt"

log "JSON report: $OUT/report.json"
log "Summary: $OUT/summary.txt"
log "RESULT: $STATUS"

[[ $FAIL -eq 0 && "$STATUS" != "FAIL" ]]
