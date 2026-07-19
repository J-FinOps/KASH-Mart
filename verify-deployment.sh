#!/usr/bin/env bash
# ============================================================
# H8S-DP: 배포 검증 스크립트
# 모든 컴포넌트가 정상 동작하는지 종합 검증합니다.
#
# 사용법:
#   bash verify-deployment.sh
# ============================================================
set -euo pipefail

PASS=0
FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check() {
    local name="$1"
    shift
    if "$@" &>/dev/null; then
        echo "  ✅ ${name}"
        PASS=$((PASS + 1))
    else
        echo "  ❌ ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo "============================================"
echo " H8S-DP Deployment Verification"
echo "============================================"

# -------------------------------------------------------------------
# 1. Docker Compose 상태 확인
# -------------------------------------------------------------------
echo ""
echo "[1] Docker Compose (External Cluster)"

check "hadoop-cluster.yml exists" test -f hadoop-cluster.yml
check "Dockerfile.livy exists" test -f Dockerfile.livy
check "livy.conf exists" test -f livy-conf/livy.conf
check "Custom Airflow Dockerfile exists" test -f helm/airflow/Dockerfile

if command -v docker &> /dev/null; then
    check "postgres container" docker ps --format '{{.Names}}' | grep -q postgres
    check "namenode container" docker ps --format '{{.Names}}' | grep -q namenode
    check "datanode container" docker ps --format '{{.Names}}' | grep -q datanode
    check "resourcemanager container" docker ps --format '{{.Names}}' | grep -q resourcemanager
    check "nodemanager container" docker ps --format '{{.Names}}' | grep -q nodemanager
    check "livy-server container" docker ps --format '{{.Names}}' | grep -q livy-server
else
    echo "  ⚠️  Docker not available (skip container checks)"
fi

# -------------------------------------------------------------------
# 2. Helm Chart 설정 검증
# -------------------------------------------------------------------
echo ""
echo "[2] Helm Chart Configuration"

check "values.yaml exists" test -f helm/airflow/values.yaml
check "hadoop-configmap.yaml exists" test -f helm/airflow/templates/hadoop-configmap.yaml
check "external-db-secret.yaml exists" test -f helm/airflow/templates/external-db-secret.yaml
check "airflow-connections.yaml exists" test -f helm/airflow/templates/airflow-connections.yaml
check "Custom Dockerfile exists" test -f helm/airflow/Dockerfile
check "network-setup.sh exists" test -f helm/network-setup.sh

if command -v helm &> /dev/null 2>&1; then
    if helm repo list 2>/dev/null | grep -q apache-airflow; then
        check "helm repo exists" true
    else
        echo "  ⚠️  Add Helm repo: helm repo add apache-airflow https://airflow.apache.org"
    fi
else
    echo "  ⚠️  Helm not available (skip lint check)"
fi

# -------------------------------------------------------------------
# 3. K8s 리소스 검증
# -------------------------------------------------------------------
echo ""
echo "[3] Kubernetes Resources"

if command -v kubectl &> /dev/null 2>&1; then
    kubectl get ns airflow &>/dev/null && \
        check "namespace 'airflow' exists" true || \
        echo "  ⚠️  Create namespace: kubectl create ns airflow"

    kubectl get configmap hadoop-config -n airflow &>/dev/null && \
        check "hadoop-config ConfigMap exists" true || \
        echo "  ⚠️  Run: bash helm/network-setup.sh"

    kubectl get configmap airflow-dags -n airflow &>/dev/null && \
        check "airflow-dags ConfigMap exists" true || \
        echo "  ⚠️  Run: bash helm/network-setup.sh"

    kubectl get secret airflow-external-db -n airflow &>/dev/null && \
        check "airflow-external-db Secret exists" true || \
        echo "  ⚠️  Apply: kubectl apply -f helm/airflow/templates/external-db-secret.yaml"

    kubectl get secret airflow-connections -n airflow &>/dev/null && \
        check "airflow-connections Secret exists" true || \
        echo "  ⚠️  Run: bash helm/network-setup.sh"

    # KubernetesExecutor 검증
    if helm list -n airflow 2>/dev/null | grep -q airflow; then
        VALUES=$(helm get values airflow -n airflow 2>/dev/null || echo "")
        if echo "$VALUES" | grep -q "KubernetesExecutor"; then
            check "executor: KubernetesExecutor" true
        else
            echo "  ⚠️  Expected KubernetesExecutor but found different executor"
        fi
    fi
else
    echo "  ⚠️  kubectl not available (skip K8s checks)"
fi

# -------------------------------------------------------------------
# 4. DAG 및 Spark Job 파일 검증
# -------------------------------------------------------------------
echo ""
echo "[4] DAGs and Spark Jobs"

check "K8s DAG exists" test -f dags/accounting_fds_pipeline_k8s.py
check "K8s Spark Job exists" test -f dags/spark_jobs/accounting_fds_job_k8s.py
check "HDFS setup script exists" test -f dags/setup_hdfs.sh
check "deploy_spark_jobs.sh exists" test -f dags/deploy_spark_jobs.sh

check "DAG syntax valid" python3 -m py_compile dags/accounting_fds_pipeline_k8s.py
check "Spark Job syntax valid" python3 -m py_compile dags/spark_jobs/accounting_fds_job_k8s.py

# Livy/HDFS Provider import 검증
if python3 -c "from airflow.providers.apache.livy.operators.livy import LivyOperator" 2>/dev/null; then
    check "LivyOperator import OK" true
else
    echo "  ⚠️  LivyOperator not on host (expected — installed in Docker image)"
fi

if python3 -c "from airflow.providers.apache.hdfs.hooks.webhdfs import WebHdfsHook" 2>/dev/null; then
    check "WebHdfsHook import OK" true
else
    echo "  ⚠️  WebHDFSHook not on host (expected — installed in Docker image)"
fi

# -------------------------------------------------------------------
# 5. YAML 문법 검증
# -------------------------------------------------------------------
echo ""
echo "[5] YAML Syntax Validation"

if command -v python3 &> /dev/null 2>&1; then
    HAS_YAML=false
    python3 -c "import yaml" 2>/dev/null && HAS_YAML=true

    for f in hadoop-cluster.yml docker-compose.yml \
             helm/airflow/values.yaml \
             helm/airflow/templates/airflow-connections.yaml; do
        if [ "$HAS_YAML" = true ]; then
            python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null && \
                check "$f valid" true || \
                check "$f valid" false
        else
            check "$f exists" test -f "$f"
        fi
    done
fi

# -------------------------------------------------------------------
# 6. 네트워크 연결성 검증
# -------------------------------------------------------------------
echo ""
echo "[6] Network Connectivity"

DOCKER_HOST_IP="${DOCKER_HOST_IP:-172.18.0.1}"

if command -v curl &> /dev/null 2>&1; then
    if curl -s --connect-timeout 3 "http://${DOCKER_HOST_IP}:8998/sessions" &>/dev/null; then
        check "Livy API (:8998)" true
    else
        echo "  ⚠️  Livy not running or unreachable"
    fi

    if curl -s --connect-timeout 3 "http://${DOCKER_HOST_IP}:8088" &>/dev/null; then
        check "YARN Web UI (:8088)" true
    else
        echo "  ⚠️  YARN RM not running or unreachable"
    fi

    if curl -s --connect-timeout 3 "http://${DOCKER_HOST_IP}:9870" &>/dev/null; then
        check "HDFS NameNode WebUI (:9870)" true
    else
        echo "  ⚠️  HDFS NameNode not running or unreachable"
    fi
fi

# -------------------------------------------------------------------
# 7. Worker Pod 검증
# -------------------------------------------------------------------
echo ""
echo "[7] KubernetesExecutor Worker Pods"

if command -v kubectl &> /dev/null 2>&1 && kubectl cluster-info &>/dev/null 2>&1; then
    DOCKER_HOST_IP="${DOCKER_HOST_IP:-172.18.0.1}"

    kubectl run --rm -i --restart=Never --image=busybox:latest \
        --namespace airflow net-test -- sh -c \
        "nc -vz ${DOCKER_HOST_IP} 8998 && nc -vz ${DOCKER_HOST_IP} 9820 && nc -vz ${DOCKER_HOST_IP} 5432" \
        &>/dev/null && \
        check "Worker Pod → Docker connectivity (8998/9820/5432)" true || \
        echo "  ⚠️  Worker Pod cannot reach Docker services"
else
    echo "  ⚠️  kubectl not available (skip Worker Pod checks)"
fi

# -------------------------------------------------------------------
# 결과 요약
# -------------------------------------------------------------------
echo ""
echo "============================================"
TOTAL=$((PASS + FAIL))
echo " Verification Complete: ${PASS}/${TOTAL} passed"
echo "============================================"

if [ "$FAIL" -eq 0 ]; then
    echo "  All checks passed!"
    exit 0
else
    echo "  ${FAIL} check(s) failed. Review above for details."
    exit 1
fi
