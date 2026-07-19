#!/usr/bin/env bash
# ============================================================
# H8S-DP: 네트워크 연동 설정 스크립트
# K8s Namespace ↔ Docker Bridge Network 통신 구성
# - Docker Host IP 동적 감지
# - Hadoop ConfigMap 생성
# - DAG ConfigMap 생성
# - values.yaml / Secrets IP 치환
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "============================================"
echo " H8S-DP Network Setup Script"
echo "============================================"

# -------------------------------------------------------------------
# 1. Docker Host IP 감지
# -------------------------------------------------------------------
echo ""
echo "[Step 1] Detecting Docker Host IP..."

DOCKER_HOST_IP=""

if command -v docker &> /dev/null; then
    if docker network inspect kind &>/dev/null; then
        DOCKER_HOST_IP=$(docker network inspect kind \
            | jq -r '.[0].IPAM.Config[] | select(.Gateway != null) | .Gateway' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
    fi

    if [ -z "$DOCKER_HOST_IP" ]; then
        DOCKER_HOST_IP=$(docker network inspect finops-network 2>/dev/null \
            | grep -m1 '"Gateway"' | awk -F'"' '{print $4}' || true)
    fi

    if [ -z "$DOCKER_HOST_IP" ]; then
        DOCKER_HOST_IP=$(ip addr show docker0 2>/dev/null \
            | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 || true)
    fi

    if [ -z "$DOCKER_HOST_IP" ]; then
        if ping -c1 host.docker.internal &>/dev/null; then
            DOCKER_HOST_IP="host.docker.internal"
        fi
    fi
else
    DOCKER_HOST_IP="host.docker.internal"
fi

if [ -z "$DOCKER_HOST_IP" ]; then
    echo "ERROR: Cannot determine Docker Host IP. Please set DOCKER_HOST_IP manually."
    exit 1
fi

echo "  → Docker Host IP: ${DOCKER_HOST_IP}"

# -------------------------------------------------------------------
# 2. Hadoop ConfigMap 생성
# -------------------------------------------------------------------
echo ""
echo "[Step 2] Generating Hadoop ConfigMap..."

CONFIGMAP_YAML="${PROJECT_ROOT}/helm/airflow/templates/hadoop-configmap-generated.yaml"

kubectl create configmap hadoop-config \
    --from-file=core-site.xml=<(sed "s/namenode/${DOCKER_HOST_IP}/g; s/host\.docker\.internal/${DOCKER_HOST_IP}/g" \
        "${PROJECT_ROOT}/hadoop-conf/core-site.xml") \
    --from-file=hdfs-site.xml=<(sed "s/host\.docker\.internal/${DOCKER_HOST_IP}/g" \
        "${PROJECT_ROOT}/hadoop-conf/hdfs-site.xml") \
    --from-file=yarn-site.xml=<(sed "s/resourcemanager/${DOCKER_HOST_IP}/g; s/host\.docker\.internal/${DOCKER_HOST_IP}/g" \
        "${PROJECT_ROOT}/hadoop-conf/yarn-site.xml") \
    --from-file=spark-defaults.conf=<(sed "s/host\.docker\.internal/${DOCKER_HOST_IP}/g; s/namenode/${DOCKER_HOST_IP}/g; s/resourcemanager/${DOCKER_HOST_IP}/g" \
        "${PROJECT_ROOT}/hadoop-conf/spark-defaults.conf") \
    --namespace airflow \
    --dry-run=client -o yaml > "${CONFIGMAP_YAML}"

echo "  → Hadoop ConfigMap saved to: ${CONFIGMAP_YAML}"

# -------------------------------------------------------------------
# 3. DAG ConfigMap 생성
# -------------------------------------------------------------------
echo ""
echo "[Step 3] Generating DAG ConfigMap..."

DAG_CONFIGMAP_YAML="${PROJECT_ROOT}/helm/airflow/templates/dags-configmap-generated.yaml"

kubectl create configmap airflow-dags \
    --from-file="${PROJECT_ROOT}/dags/__init__.py" \
    --from-file="${PROJECT_ROOT}/dags/accounting_fds_pipeline_k8s.py" \
    --from-file="${PROJECT_ROOT}/dags/.airflowignore" \
    --namespace airflow \
    --dry-run=client -o yaml > "${DAG_CONFIGMAP_YAML}"

echo "  → DAG ConfigMap saved to: ${DAG_CONFIGMAP_YAML}"

# -------------------------------------------------------------------
# 4. Airflow Connections Secret 생성
# -------------------------------------------------------------------
echo ""
echo "[Step 4] Generating Airflow Connections Secret..."

CONNECTIONS_YAML="${PROJECT_ROOT}/helm/airflow/templates/airflow-connections-generated.yaml"

sed -e "s/host\.docker\.internal/${DOCKER_HOST_IP}/g" \
    "${PROJECT_ROOT}/helm/airflow/templates/airflow-connections.yaml" \
    > "${CONNECTIONS_YAML}"

echo "  → Connections Secret saved to: ${CONNECTIONS_YAML}"

# -------------------------------------------------------------------
# 5. values.yaml 호스트 주소 업데이트
# -------------------------------------------------------------------
echo ""
echo "[Step 5] Updating values.yaml with actual Docker Host IP..."

VALUES_FILE="${PROJECT_ROOT}/helm/airflow/values.yaml"
if [ -f "$VALUES_FILE" ]; then
    cp "$VALUES_FILE" "${VALUES_FILE}.bak"
    sed -i "s/host\.docker\.internal/${DOCKER_HOST_IP}/g" "$VALUES_FILE"
    echo "  → Updated ${VALUES_FILE} (backup: ${VALUES_FILE}.bak)"
fi

# -------------------------------------------------------------------
# 6. K8s 리소스 적용
# -------------------------------------------------------------------
echo ""
echo "[Step 6] Applying K8s resources..."

apply_resource() {
    local file="$1"
    local name="$2"
    if [ -f "$file" ] && kubectl cluster-info &>/dev/null; then
        kubectl apply -f "$file" && echo "  ✅ Applied: ${name}" || echo "  ⚠️  Failed: ${name}"
    else
        echo "  ⚠️  Skipped: ${name} (kubectl not connected or file missing)"
    fi
}

apply_resource "${CONFIGMAP_YAML}" "hadoop-config ConfigMap"
apply_resource "${DAG_CONFIGMAP_YAML}" "airflow-dags ConfigMap"
apply_resource "${CONNECTIONS_YAML}" "airflow-connections Secret"

kubectl cluster-info &>/dev/null && \
    kubectl get secret airflow-external-db -n airflow &>/dev/null && \
    echo "  ✅ airflow-external-db Secret exists" || \
    echo "  ⚠️  Apply airflow-external-db Secret first: kubectl apply -f helm/airflow/templates/external-db-secret.yaml"

# -------------------------------------------------------------------
# 7. 포트 연결성 검증
# -------------------------------------------------------------------
echo ""
echo "[Step 7] Verifying port connectivity..."

declare -A PORTS=(
    ["PostgreSQL"]="5432"
    ["HDFS NameNode RPC"]="9820"
    ["HDFS NameNode WebUI"]="9870"
    ["YARN ResourceManager WebUI"]="8088"
    ["Livy REST API"]="8998"
)

for SERVICE in "${!PORTS[@]}"; do
    PORT=${PORTS[$SERVICE]}
    if nc -z -w3 "${DOCKER_HOST_IP}" "${PORT}" 2>/dev/null; then
        echo "  ✅ ${SERVICE} (${PORT}): OPEN"
    else
        echo "  ⚠️  ${SERVICE} (${PORT}): NOT REACHABLE (Docker Compose 실행 중인지 확인)"
    fi
done

# -------------------------------------------------------------------
# 8. 최종 요약
# -------------------------------------------------------------------
echo ""
echo "============================================"
echo " Network Setup Complete!"
echo "============================================"
echo ""
echo "  Docker Host IP : ${DOCKER_HOST_IP}"
echo ""
echo "  Generated Resources:"
echo "    - ${CONFIGMAP_YAML}"
echo "    - ${DAG_CONFIGMAP_YAML}"
echo "    - ${CONNECTIONS_YAML}"
echo ""
echo "  Next Steps:"
echo "    1. Build custom Airflow image:"
echo "       docker build -t airflow-h8sdp:3.2.2 -f helm/airflow/Dockerfile ."
echo "       kind load docker-image airflow-h8sdp:3.2.2 --name airflow-cluster"
echo ""
echo "    2. Deploy Airflow via Helm:"
echo "       helm upgrade --install airflow apache-airflow/airflow \\"
echo "         -f helm/airflow/values.yaml \\"
echo "         --namespace airflow --create-namespace"
echo ""
echo "    3. Verify deployment:"
echo "       bash verify-deployment.sh"
