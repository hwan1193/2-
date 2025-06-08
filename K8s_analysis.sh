#!/bin/bash
set -euo pipefail

# --------- [권한 체크 및 환경 점검] ---------
if [[ $EUID -ne 0 ]]; then
   echo "============================================="
   echo "[!] 이 스크립트는 root (sudo) 권한이 필요합니다."
   echo "[!] 관리자 계정으로 다음과 같이 실행하세요:"
   echo ""
   echo "    sudo $0"
   echo ""
   echo "실행을 중단합니다."
   echo "============================================="
   exit 1
fi

echo "============================================="
echo "[!] 이 스크립트는 root (sudo) 권한이 필요합니다."
echo "[!] 관리자 계정으로 다음과 같이 실행하세요:"
echo "[✓] root 권한 확인 완료 (UID: $EUID)"

if ! command -v kubectl &> /dev/null; then
    echo "[!] kubectl 명령어가 시스템에 설치되어 있지 않습니다."
    echo "[!] 설치 후 다시 시도하세요."
    exit 1
fi

echo "---------------------------------------------"
echo "[+] 실행 사용자: $(whoami)"
echo "[+] 호스트 이름: $(hostname)"
echo "[+] 실행 시각 : $(date)"
echo "============================================="
echo ""

# --------- [결과 저장 경로 설정] ---------
BASE_DIR="$(pwd)"
FINAL_DIR="${BASE_DIR}/k8s_analysis"

echo ""
echo "[+] 현재 디렉토리: $BASE_DIR"
echo "[+] 결과 저장 디렉토리: $FINAL_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="${FINAL_DIR}/analysis_$TIMESTAMP"
SYFT_DIR="${RESULT_DIR}/syft"
GRYPE_DIR="${RESULT_DIR}/grype"
KUBESCAPE_DIR="${RESULT_DIR}/kubescape"
KUBEBENCH_DIR="${RESULT_DIR}/kube-bench"
SUMMARY_FILE="${GRYPE_DIR}/grype_summary_$TIMESTAMP.txt"

mkdir -p "$RESULT_DIR"

sanitize_filename() {
  echo "$1" | sed -E 's/[^a-zA-Z0-9._-]/_/g'
}

print_dependency_check() {
  local REQUIRED_TOOLS=(kubectl jq curl)
  local OPTIONAL_AUTO_TOOLS=(kubescape syft grype)
  local INSTALLED_REQUIRED=()
  local MISSING_REQUIRED=()
  local INSTALLED_OPTIONAL=()

  echo "🔍 [의존성 확인] 필수 도구 목록: ${REQUIRED_TOOLS[*]}"
  echo ""

  for TOOL in "${REQUIRED_TOOLS[@]}"; do
    if command -v "$TOOL" &>/dev/null; then
      INSTALLED_REQUIRED+=("$TOOL")
    else
      MISSING_REQUIRED+=("$TOOL")
    fi
  done

  if [[ ${#MISSING_REQUIRED[@]} -eq 0 ]]; then
    echo "✅ 모든 필수 도구가 설치되어 있습니다."
    echo "   - ${INSTALLED_REQUIRED[*]}"
    echo "👉 스크립트를 바로 실행할 수 있습니다."
  else
    echo "⚠️  다음 필수 도구가 설치되어 있지 않습니다:"
    for TOOL in "${MISSING_REQUIRED[@]}"; do
      echo "   - $TOOL"
    done
    echo ""
    echo "❗ 일부 기능이 작동하지 않을 수 있습니다."
    echo "   다음 명령어로 수동 설치하세요:"
    echo "   sudo apt update && sudo apt install -y ${MISSING_REQUIRED[*]}"
  fi

  echo ""
  echo "🛠️  [스크립트에서 자동 설치 가능한 도구 목록]"
  for TOOL in "${OPTIONAL_AUTO_TOOLS[@]}"; do
    if command -v "$TOOL" &>/dev/null; then
      INSTALLED_OPTIONAL+=("$TOOL")
    fi
    echo "   - $TOOL"
  done

  echo ""
}

check_and_install_tool() {
  local TOOL=$1
  local URL=$2
  if ! command -v "$TOOL" &> /dev/null; then
    echo "[+] $TOOL 설치 중..."
    curl -sSfL "$URL" | sh -s -- -b /usr/local/bin
    echo "[✓] $TOOL 설치 완료"
  else
    echo "[✓] $TOOL 이미 설치됨"
  fi
}

run_kubebench() {
  mkdir -p "$KUBEBENCH_DIR"
  echo "[+] kube-bench DaemonSet을 배포할 네임스페이스를 입력하세요 (기본값: kube-system)"
  read -rp "[?] 네임스페이스 입력: " NAMESPACE
  NAMESPACE="${NAMESPACE:-kube-system}"
  echo "[+] 사용된 네임스페이스: $NAMESPACE"

  KUBEBENCH_YAML="${RESULT_DIR}/kube-bench-daemonset.yaml"
cat <<EOF > "$KUBEBENCH_YAML"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-bench
  namespace: $NAMESPACE
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-bench
  namespace: $NAMESPACE
  labels:
    app: kube-bench
spec:
  selector:
    matchLabels:
      app: kube-bench
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      serviceAccountName: kube-bench
      tolerations:
        - operator: Exists
      hostPID: true
      restartPolicy: Always
      containers:
      - name: kube-bench
        image: aquasec/kube-bench:latest
        command:
          - /bin/bash
          - -c
          - |
            ROLE=""
            if [ ! -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
              ROLE="node"
            else
              ROLE="master"
            fi
            export KUBEBENCH_NODE_ROLE="\$ROLE"
            kube-bench run
        securityContext:
          privileged: true
        volumeMounts:
          - name: etc-kubernetes
            mountPath: /etc/kubernetes
            readOnly: true
          - name: var-lib-etcd
            mountPath: /var/lib/etcd
            readOnly: true
          - name: etc-systemd
            mountPath: /etc/systemd
            readOnly: true
          - name: var-lib-kubelet
            mountPath: /var/lib/kubelet
            readOnly: true
          - name: usr-bin
            mountPath: /usr/local/mount-from-host/bin
            readOnly: true
          - name: etc-containerd
            mountPath: /etc/containerd
            readOnly: true
      volumes:
        - name: etc-kubernetes
          hostPath: { path: /etc/kubernetes }
        - name: var-lib-etcd
          hostPath: { path: /var/lib/etcd }
        - name: etc-systemd
          hostPath: { path: /etc/systemd }
        - name: var-lib-kubelet
          hostPath: { path: /var/lib/kubelet }
        - name: usr-bin
          hostPath: { path: /usr/local/bin }
        - name: etc-containerd
          hostPath: { path: /etc/containerd }
EOF

  echo "[+] kube-bench DaemonSet 배포 중..."
  kubectl apply -f "$KUBEBENCH_YAML"
  sleep 20

  PODS=$(kubectl get pods -n "$NAMESPACE" -l app=kube-bench -o jsonpath='{.items[*].metadata.name}')
  for POD in $PODS; do
    NODE=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
    if [[ -z "$NODE" ]]; then
      echo "[!] 노드 이름 확인 실패. Pod 이름으로 로그 저장: $POD"
      NODE="$POD"
    fi

    LOG_FILE="$KUBEBENCH_DIR/${NODE}.log"
    echo "[+] 로그 저장: $LOG_FILE"
    kubectl logs -n "$NAMESPACE" "$POD" > "$LOG_FILE"
  done

  kubectl delete -f "$KUBEBENCH_YAML"
  echo "[✓] kube-bench 결과 저장 완료"
}

run_kubescape() {
  mkdir -p "$KUBESCAPE_DIR"

  if ! command -v kubescape &> /dev/null; then
    echo "[+] kubescape 설치 중..."
    curl -s https://raw.githubusercontent.com/armosec/kubescape/master/install.sh | /bin/bash
    echo "[✓] kubescape 설치 완료"
  fi

  if ! command -v jq &> /dev/null; then
    echo "[!] jq가 설치되어 있지 않습니다."
    read -rp "[?] jq를 설치하시겠습니까? (yes/no): " INSTALL_JQ
    if [[ "$INSTALL_JQ" == "yes" ]]; then
      apt update && apt install -y jq
      if ! command -v jq &> /dev/null; then
        echo "[✗] jq 설치 실패. 수동 설치 후 다시 실행하세요."
        exit 1
      fi
      echo "[✓] jq 설치 완료"
    else
      echo "[!] jq가 없으면 Kubescape 결과를 포맷할 수 없습니다. 실행을 중단합니다."
      exit 1
    fi
  fi

  echo "[+] Kubescape 실행 중..."
  if kubescape scan --format json --output "$KUBESCAPE_DIR/kubescape_result.json"; then
    echo "[✓] Kubescape JSON 결과 저장 완료"
    jq . "$KUBESCAPE_DIR/kubescape_result.json" > "$KUBESCAPE_DIR/kubescape_result_pretty.json"
    echo "[✓] 포맷된 결과 저장 완료: $KUBESCAPE_DIR/kubescape_result_pretty.json"
  else
    echo "[!] Kubescape 실행 실패" | tee -a "$RESULT_DIR/error.log"
  fi
}



run_grype() {
  mkdir -p "$SYFT_DIR" "$GRYPE_DIR"
  check_and_install_tool syft https://raw.githubusercontent.com/anchore/syft/main/install.sh
  check_and_install_tool grype https://raw.githubusercontent.com/anchore/grype/main/install.sh

  echo "[+] Syft + Grype 이미지 목록 수집 중..."
  IMAGES=$(kubectl get pods --all-namespaces -o jsonpath='{..image}' | tr ' ' '\n' | sort | uniq)
  TOTAL=$(echo "$IMAGES" | wc -l)
  echo "[+] $TOTAL개 이미지 발견됨"
  echo ""

  i=0
  for IMAGE in $IMAGES; do
    i=$((i+1))
    SAFE_NAME=$(sanitize_filename "$IMAGE")
    echo "[${i}/${TOTAL}] 이미지 분석: $IMAGE"

    echo "  [>] Syft 분석..."
    if timeout 180 syft "$IMAGE" -o table > "$SYFT_DIR/$SAFE_NAME.txt" 2>/dev/null; then
      echo "    [✓] Syft 완료"
    else
      echo "    [!] Syft 실패: $IMAGE" | tee -a "$RESULT_DIR/error.log"
    fi

    echo "  [>] Grype 분석..."
    if timeout 300 grype "$IMAGE" -o table > "$GRYPE_DIR/$SAFE_NAME.txt" 2>/dev/null; then
      echo "    [✓] Grype 완료"
    else
      echo "    [!] Grype 실패: $IMAGE" | tee -a "$RESULT_DIR/error.log"
    fi

    CRITICAL=$(grep -c " Critical" "$GRYPE_DIR/$SAFE_NAME.txt" || true)
    HIGH=$(grep -c " High" "$GRYPE_DIR/$SAFE_NAME.txt" || true)
    MEDIUM=$(grep -c " Medium" "$GRYPE_DIR/$SAFE_NAME.txt" || true)
    LOW=$(grep -c " Low" "$GRYPE_DIR/$SAFE_NAME.txt" || true)
    NEGLIGIBLE=$(grep -c " Negligible" "$GRYPE_DIR/$SAFE_NAME.txt" || true)
    TOTAL_VULN=$((CRITICAL + HIGH + MEDIUM + LOW + NEGLIGIBLE))
    echo "    요약: 총 $TOTAL_VULN (Critical: $CRITICAL, High: $HIGH, Medium: $MEDIUM, Low: $LOW, Negligible: $NEGLIGIBLE)"
    echo ""
  done

  echo "====== Grype 분석 요약 ======" > "$SUMMARY_FILE"
  echo "대상 디렉토리: $GRYPE_DIR" >> "$SUMMARY_FILE"
  echo "" >> "$SUMMARY_FILE"

  for FILE in "$GRYPE_DIR"/*.txt; do
    IMG_NAME=$(basename "$FILE" .txt)
    CRITICAL=$(grep -c " Critical" "$FILE" || true)
    HIGH=$(grep -c " High" "$FILE" || true)
    MEDIUM=$(grep -c " Medium" "$FILE" || true)
    LOW=$(grep -c " Low" "$FILE" || true)
    NEGLIGIBLE=$(grep -c " Negligible" "$FILE" || true)
    TOTAL=$((CRITICAL + HIGH + MEDIUM + LOW + NEGLIGIBLE))

    echo "이미지: $IMG_NAME" >> "$SUMMARY_FILE"
    echo "  - 총 취약점: $TOTAL (Critical: $CRITICAL, High: $HIGH, Medium: $MEDIUM, Low: $LOW, Negligible: $NEGLIGIBLE)" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
  done

  echo "[✓] Grype 요약 저장 완료: $SUMMARY_FILE"
}

generate_combined_logs_json() {
  while read -r -t 0; do read -r; done
  local OUTFILE="${RESULT_DIR}/result_combined_logs.json"
  local TMPFILE="${RESULT_DIR}/_tmp_combined_raw.json"
  echo "{}" > "$TMPFILE"

  # timestamp 삽입
  jq --arg ts "$TIMESTAMP" '. + {timestamp: $ts}' "$TMPFILE" > "$TMPFILE.new" && mv "$TMPFILE.new" "$TMPFILE"

  # kube-bench 로그 추가 (rawfile)
  for FILE in "$KUBEBENCH_DIR"/*.log; do
  NODE=$(basename "$FILE" .log)
  CONTENTS=$(jq -R -s 'split("\n") | map(select(length > 0))' "$FILE")
  jq --arg node "$NODE" --argjson lines "$CONTENTS" \
    '.["kube-bench"] += {($node): $lines}' "$TMPFILE" > "$TMPFILE.new" && mv "$TMPFILE.new" "$TMPFILE"
  done


  # kubescape는 이미 JSON 구조 → 안전하게 병합
  if [[ -f "$KUBESCAPE_DIR/kubescape_result.json" ]]; then
    jq --slurpfile kube "$KUBESCAPE_DIR/kubescape_result.json" \
      '. + {kubescape: $kube[0]}' "$TMPFILE" > "$TMPFILE.new" && mv "$TMPFILE.new" "$TMPFILE"
  fi

  # grype 로그 추가 (rawfile, summary 제외)
  for FILE in "$GRYPE_DIR"/*.txt; do
    [[ "$FILE" == *"summary"* ]] && continue
    IMG=$(basename "$FILE" .txt)
    SAFE_IMG=$(sanitize_filename "$IMG")
    jq --arg img "$SAFE_IMG" --rawfile content "$FILE" \
      '.["grype"] += {($img): $content}' "$TMPFILE" > "$TMPFILE.new" && mv "$TMPFILE.new" "$TMPFILE"
  done

  mv "$TMPFILE" "$OUTFILE"
  echo "[✓] 전체 로그 통합 JSON 저장 완료: $OUTFILE"
}
# --------- [명령줄 옵션 파싱] ---------
AUTO_YES="no"
for arg in "$@"; do
  case "$arg" in
    --yes|-y)
      AUTO_YES="yes"
      ;;
  esac
done

# --------- [분석 모드 선택] ---------
main() {
  echo ""
  echo "🔍 실행할 보안 분석 항목을 선택하세요:"
  echo ""
  echo "  [1] kube-bench       - 노드 및 클러스터 설정이 CIS Benchmark 기준에 부합하는지 점검합니다."
  echo "  [2] Kubescape        - 네임스페이스, RBAC, 보안컨텍스트 등 리소스 구성의 정책 적합성 분석합니다."
  echo "  [3] Syft + Grype     - 컨테이너 이미지 내부 구성 및 취약점 스캔합니다."
  echo "  [4] 전체 실행        - 1 → 2 → 3 순서로 모든 분석 수행합니다."
  echo "                       - 4번 실행 시 전체 분석이 끝난 후 전체 로그를 하나의 JSON 파일로 저장할 수 있습니다."
  echo "                       - 또한 전체 로그파일을 기반으로 Gemini API를 기반으로 보고서 작성이 가능합니다."
  echo ""
  read -rp "번호 입력 [1|2|3|4]: " SELECTED
  echo ""


  case "$SELECTED" in
    1) run_kubebench ;;
    2) run_kubescape ;;
    3) run_grype ;;
    4)
      echo "========== [1번 실행 중] =========="; run_kubebench
      echo "========== [2번 실행 중] =========="; run_kubescape
      echo "========== [3번 실행 중] =========="; run_grype
      echo ""

      if [[ "$AUTO_YES" == "yes" ]]; then
        echo "[+] --yes 플래그 감지됨: 자동으로 통합 JSON 생성"
        generate_combined_logs_json
      else
        while read -r -t 0; do read -r; done
        read -rp "[?] 모든 로그를 하나의 JSON 파일로 합치시겠습니까? (yes/no): " COMBINE
        if [[ "$COMBINE" == "yes" ]]; then
          generate_combined_logs_json
        else
          echo "[!] 통합 JSON 파일 생성을 건너뜁니다."
        fi
      fi

      # LLM 기반 분석 여부 확인
      while read -r -t 0; do read -r; done
      echo ""
      read -rp "[?] Gemini 기반 자동 분석 리포트를 생성하시겠습니까? (yes/no): " RUN_LLM
      if [[ "$RUN_LLM" == "yes" ]]; then
        echo "[+] Gemini 분석 스크립트를 실행합니다..."
        bash auto_report.sh "$RESULT_DIR"
      else
        echo "[!] Gemini 분석을 생략합니다."
      fi

      ;;
    *) echo "[!] 잘못된 입력입니다." && exit 1 ;;
  esac

  echo ""
  echo "[+] 완료 - 결과 디렉토리: $RESULT_DIR"
  [[ -f "$RESULT_DIR/error.log" ]] && echo "[!] 오류 발생: $RESULT_DIR/error.log"
}

print_dependency_check
main "$@"

