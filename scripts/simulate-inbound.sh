#!/usr/bin/env bash
# Эмуляция входящего звонка на FreePBX через AMI (без Novofon/PSTN).
#
# Local/{ext}@from-did-direct + внешний CallerID → коннектор видит inbound → CRM.
#
# Примеры:
#   ./scripts/simulate-inbound.sh
#   ./scripts/simulate-inbound.sh --caller 79001112233
#   ./scripts/simulate-inbound.sh --caller 79991234567          # номер из CRM-контакта
#   ./scripts/simulate-inbound.sh --caller 79009998877 --mode miss
#   ./scripts/simulate-inbound.sh --ext 228 --wait 60
#   ./scripts/simulate-inbound.sh --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

AMI_HOST="${AMI_HOST:-127.0.0.1}"
AMI_PORT="${ASTERISK_AMI_PORT:-5038}"
AMI_USER="${ASTERISK_AMI_USER:-admin}"
AMI_SECRET="${ASTERISK_AMI_PASSWORD:-}"

CALLER="79001234567"
DID="0126650"
EXT="228"
WAIT_SEC=45
MODE="ring"   # ring | miss | answer
DRY_RUN=0

usage() {
  cat <<EOF
Эмуляция входящего через AMI → Local/{ext}@from-did-direct

  --caller NUM   CallerID «клиента» (для CRM), default: $CALLER
  --ext EXT      внутренний (228), default: $EXT
  --did DID      пишется в канал как __FROM_DID, default: $DID
  --wait SEC     длительность после ответа / таймаут кольца, default: $WAIT_SEC
  --mode MODE    ring  — звонит на EXT, подними трубку
                 miss  — кольцо ~5с и сброс (пропущенный)
                 answer — Playback без трубки (smoke)
  --host HOST    AMI host, default: $AMI_HOST
  --dry-run      показать AMI-пакет
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller) CALLER="$2"; shift 2 ;;
    --ext) EXT="$2"; shift 2 ;;
    --did) DID="$2"; shift 2 ;;
    --wait) WAIT_SEC="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --host) AMI_HOST="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$AMI_SECRET" ]]; then
  echo "ASTERISK_AMI_PASSWORD пуст — проверь $ROOT/.env" >&2
  exit 1
fi

CALLER="${CALLER//[^0-9+]/}"
DID="${DID//[^0-9]/}"
EXT="${EXT//[^0-9]/}"
CHANNEL="Local/${EXT}@from-did-direct/n"

case "$MODE" in
  ring)
    APP="Wait"
    DATA="$WAIT_SEC"
    TIMEOUT_MS=$(( (WAIT_SEC + 20) * 1000 ))
    ;;
  miss)
    APP="Wait"
    DATA="1"
    TIMEOUT_MS=5000
    ;;
  answer)
    APP="Playback"
    DATA="hello-world"
    TIMEOUT_MS=30000
    ;;
  *)
    echo "mode: ring|miss|answer" >&2
    exit 1
    ;;
esac

ACTION_ID="sim-in-$(date +%s)-$$"
AMI_PACKET=$(cat <<EOF
Action: Login
Username: ${AMI_USER}
Secret: ${AMI_SECRET}
Events: off

Action: Originate
ActionID: ${ACTION_ID}
Channel: ${CHANNEL}
CallerID: "Test CRM" <${CALLER}>
Application: ${APP}
Data: ${DATA}
Timeout: ${TIMEOUT_MS}
Async: true
Variable: SIMULATED_INBOUND=1
Variable: __FROM_DID=${DID}

Action: Logoff

EOF
)

echo "==> Simulate inbound"
echo "    caller:  ${CALLER}"
echo "    ext:     ${EXT}"
echo "    did var: ${DID}"
echo "    mode:    ${MODE}  (${APP} ${DATA})"
echo "    channel: ${CHANNEL}"
echo "    ami:     ${AMI_HOST}:${AMI_PORT}"
echo
if [[ "$MODE" == "ring" ]]; then
  echo "Подними трубку на ${EXT}. Логи: docker logs -f bitrix24-asterisk-connector-worker-ami-1"
elif [[ "$MODE" == "miss" ]]; then
  echo "Не поднимай трубку — через ~5с будет пропущенный."
fi
echo

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "$AMI_PACKET"
  exit 0
fi

python3 - "$AMI_HOST" "$AMI_PORT" "$AMI_PACKET" <<'PY'
import socket, sys, time
host, port, packet = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with socket.create_connection((host, port), timeout=5) as sock:
    print(sock.recv(256).decode(errors="replace").strip())
    sock.sendall(packet.replace("\n", "\r\n").encode())
    deadline = time.time() + 3
    chunks = []
    sock.settimeout(0.4)
    while time.time() < deadline:
        try:
            data = sock.recv(4096)
            if not data:
                break
            chunks.append(data)
        except socket.timeout:
            if chunks:
                break
    text = b"".join(chunks).decode(errors="replace")
    print(text.strip())
    if "Response: Error" in text:
        raise SystemExit(2)
print("OK: originate отправлен")
PY
