#!/bin/bash
# [0] 인자로 전달된 결과 디렉토리 확인
if [ $# -lt 1 ]; then
  echo "[!] 사용법: $0 <결과 디렉토리 경로>"
  exit 1
fi

BASE_DIR="$1" 

print_dependency_check() {
  local REQUIRED_TOOLS=(python3 pip3 jq curl lsof)
  local OPTIONAL_TOOLS=(virtualenv)

  local MISSING_REQUIRED=()
  local INSTALLED_OPTIONAL=()

  echo "🔍 [1] 필수 시스템 도구 점검 중..."

  for TOOL in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$TOOL" &>/dev/null; then
      MISSING_REQUIRED+=("$TOOL")
    fi
  done

  if [[ ${#MISSING_REQUIRED[@]} -eq 0 ]]; then
    echo "✅ 모든 필수 도구가 설치되어 있습니다."
  else
    echo "⚠️  누락된 필수 도구: ${MISSING_REQUIRED[*]}"
    while true; do
      read -rp "❓ 설치하시겠습니까? (yes/no): " CONFIRM
      case "$CONFIRM" in
        yes)
          echo "🔧 설치 중..."
          sudo apt update && sudo apt install -y "${MISSING_REQUIRED[@]}"
          break
          ;;
        no)
          echo "⛔ 설치를 건너뜁니다. 일부 기능이 작동하지 않을 수 있습니다."
          break
          ;;
        *)
          echo "⚠️ 'yes' 또는 'no'로 입력해주세요."
          ;;
      esac
    done
  fi

  echo ""
  echo "🛠️  [참고] 선택 도구 상태:"
  for TOOL in "${OPTIONAL_TOOLS[@]}"; do
    if command -v "$TOOL" &>/dev/null; then
      echo "   ✅ $TOOL"
    else
      echo "   ⛔ $TOOL (선택 사항, 필요 시 수동 설치)"
    fi
  done
  echo ""
}

check_python_dependencies() {
  echo "🐍 [2] Python 및 모듈 점검 중..."
  local REQUIRED_PKG=(python3 python3-pip jq lsof nohup)
  local PYTHON_MODULES=(requests flask)
  local MISSING_PKG=()
  local MISSING_PYMODULES=()

  for pkg in "${REQUIRED_PKG[@]}"; do
    if ! command -v "$pkg" &>/dev/null; then
      MISSING_PKG+=("$pkg")
    fi
  done

  for module in "${PYTHON_MODULES[@]}"; do
    python3 -c "import $module" 2>/dev/null || MISSING_PYMODULES+=("$module")
  done

  if [[ ${#MISSING_PKG[@]} -eq 0 ]]; then
    echo "✅ 모든 시스템 패키지 설치됨"
  else
    echo "⚠️  누락된 시스템 패키지: ${MISSING_PKG[*]}"
    while true; do
      read -rp "❓ 설치하시겠습니까? (yes/no): " CONFIRM
      case "$CONFIRM" in
        yes)
          sudo apt update && sudo apt install -y "${MISSING_PKG[@]}"
          break
          ;;
        no)
          echo "⛔ 설치를 건너뜁니다."
          break
          ;;
        *)
          echo "⚠️ 'yes' 또는 'no'로 입력해주세요."
          ;;
      esac
    done
  fi

  if [[ ${#MISSING_PYMODULES[@]} -eq 0 ]]; then
    echo "✅ 모든 Python 모듈 설치됨"
  else
    echo "⚠️  누락된 Python 모듈: ${MISSING_PYMODULES[*]}"
    while true; do
      read -rp "❓ pip로 설치하시겠습니까? (yes/no): " CONFIRM
      case "$CONFIRM" in
        yes)
          pip3 install "${MISSING_PYMODULES[@]}"
          break
          ;;
        no)
          echo "⛔ 설치를 건너뜁니다."
          break
          ;;
        *)
          echo "⚠️ 'yes' 또는 'no'로 입력해주세요."
          ;;
      esac
    done
  fi

  echo ""
}


verify_all_dependencies() {
  echo "======================================"
  echo "[🚀 의존성 점검 및 설치 여부 확인]"
  echo "======================================"
  print_dependency_check
  check_python_dependencies
  echo "✅ 의존성 점검 완료"
  echo ""
}

# ───── [환경변수 로딩: .env] ─────
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
else
  echo "[!] .env 파일이 존재하지 않습니다. 환경변수 GEMINI_API_KEY를 직접 export 했는지 확인하세요."
fi

verify_all_dependencies

API_KEY="${GEMINI_API_KEY:?환경변수 GEMINI_API_KEY가 설정되지 않았습니다}"
COMBINED_JSON="${BASE_DIR}/result_combined_logs.json"
LOG_DIR="auto_report/logs"
RESULT_DIR="auto_report/results"
PROMPT_DIR="auto_report/prompts"
FLASK_DIR="auto_report/security_flask_app"

mkdir -p "$LOG_DIR" "$RESULT_DIR"

echo "[1] 로그 분리 중..."
jq '.["kube-bench"]' "$COMBINED_JSON" > "$LOG_DIR/kube_bench_input.json"
jq '.["kubescape"]' "$COMBINED_JSON" > "$LOG_DIR/kubescape_input.json"
jq '.["grype"]' "$COMBINED_JSON" > "$LOG_DIR/grype_input.json"

echo "[2] Gemini 분석 시작..."

echo "  [2-1] kube-bench 분석 중..."
python3 auto_report/generate_report.py \
  --api_key "$API_KEY" \
  --json_file "$LOG_DIR/kube_bench_input.json" \
  --prompt_file "$PROMPT_DIR/kube_bench.txt" \
  --output_file "$RESULT_DIR/checklist_kubebench.json"

echo "  [2-2] kubescape 분석 중..."
python3 auto_report/generate_report.py \
  --api_key "$API_KEY" \
  --json_file "$LOG_DIR/kubescape_input.json" \
  --prompt_file "$PROMPT_DIR/kubescape.txt" \
  --output_file "$RESULT_DIR/checklist_kubescape.json"

echo "  [2-3] grype 분석 중..."
python3 auto_report/generate_report.py \
  --api_key "$API_KEY" \
  --json_file "$LOG_DIR/grype_input.json" \
  --prompt_file "$PROMPT_DIR/grype.txt" \
  --output_file "$RESULT_DIR/checklist_grype.json"

echo "  [2-4] ISMS-P 분석 중..."
python3 auto_report/generate_report.py \
  --api_key "$API_KEY" \
  --json_file "$COMBINED_JSON" \
  --prompt_file "$PROMPT_DIR/isms_p_prompt.txt" \
  --output_file "$RESULT_DIR/checklist_isms.json"

echo "  [2-5] CSAP 분석 중..."
python3 auto_report/generate_report.py \
  --api_key "$API_KEY" \
  --json_file "$COMBINED_JSON" \
  --prompt_file "$PROMPT_DIR/csap_prompt.txt" \
  --output_file "$RESULT_DIR/checklist_csap.json"

echo "[3] Flask 앱 상태 확인 중..."

# IP 유효성 검사 함수
is_valid_ip() {
  local ip=$1
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
      if ((octet < 0 || octet > 255)); then
        return 1
      fi
    done
    return 0
  else
    return 1
  fi
}

is_local_ip() {
  local ip=$1
  # 0.0.0.0은 모든 인터페이스 의미 → 예외적으로 허용
  if [[ "$ip" == "0.0.0.0" ]]; then
    return 0
  fi
  # 현재 서버가 가진 IP 중에 있는지 검사
  if hostname -I | tr ' ' '\n' | grep -Fxq "$ip"; then
    return 0
  else
    return 1
  fi
}


# 포트 유효성 검사 함수
is_valid_port() {
  local port=$1
  if [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)); then
    return 0
  else
    return 1
  fi
}

# 사용자 IP 입력
while true; do
  while read -r -t 0; do read -r; done
  echo "[?] Flask 앱을 어떤 IP 주소에 바인딩할까요?"
  echo "    - 예: 127.0.0.1 (로컬에서만 접속 허용)"
  echo "    - 예: 0.0.0.0 (외부 접속 허용, 방화벽 설정 필요)"
  echo "    - ⚠️ 반드시 이 서버가 실제 가지고 있는 IP만 입력하세요."
  read -rp ">> 입력 (기본: 0.0.0.0): " FLASK_HOST
  FLASK_HOST="${FLASK_HOST:-0.0.0.0}"

  if is_valid_ip "$FLASK_HOST" && is_local_ip "$FLASK_HOST"; then
    echo "[Flask] 입력된 IP: $FLASK_HOST"
    break
  else
    echo "⚠️ 유효하지 않은 IP 형식입니다. 다시 입력해주세요."
  fi
done

# 사용자 포트 입력 (중복 체크 포함)
while true; do
  while read -r -t 0; do read -r; done
  read -rp "[?] 사용할 포트 번호를 입력하세요 (1~65535, 기본값: 5000): " FLASK_PORT
  FLASK_PORT="${FLASK_PORT:-5000}"

  if ! is_valid_port "$FLASK_PORT"; then
    echo "⚠️ 유효하지 않거나, 이 서버에 존재하지 않는 IP입니다. 다시 입력해주세요."
    continue
  fi

  if lsof -i TCP:"$FLASK_PORT" -sTCP:LISTEN -t >/dev/null; then
    echo "⚠️ 포트 $FLASK_PORT 는 이미 사용 중입니다. 다른 포트를 입력해주세요."
    continue
  fi

  echo "[Flask] 사용할 포트: $FLASK_PORT"
  break
done

cd "$FLASK_DIR"
echo "[Flask] 서버 실행 중... (Ctrl+C로 종료)"
flask run --host="$FLASK_HOST" --port="$FLASK_PORT"

