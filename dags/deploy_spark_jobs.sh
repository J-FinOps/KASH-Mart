#!/usr/bin/env bash
# ============================================================
# H8S-DP: Spark Job 파일 HDFS 배포 스크립트
# ============================================================
# DAG에서 LivyOperator가 HDFS 경로의 Spark Job을 참조하므로
# Spark Job 파일을 HDFS에 먼저 배포해야 합니다.
#
# 사용법:
#   bash dags/deploy_spark_jobs.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

HDFS_JOBS_DIR="/user/airflow/spark_jobs"
NAMENODE_CONTAINER="${NAMENODE_CONTAINER:-namenode}"

echo "[H8S-DP] Deploying Spark Jobs to HDFS..."
echo "  Container: ${NAMENODE_CONTAINER}"

# Spark Job 파일 리스트
JOBS=(
    "dags/spark_jobs/accounting_fds_job.py"
    "dags/spark_jobs/accounting_fds_job_k8s.py"
)

# namenode 컨테이너 실행 확인
if ! docker ps --format '{{.Names}}' | grep -q "${NAMENODE_CONTAINER}"; then
    echo "ERROR: Container '${NAMENODE_CONTAINER}' is not running"
    exit 1
fi

# HDFS 디렉토리 생성
docker exec "${NAMENODE_CONTAINER}" hdfs dfs -mkdir -p "${HDFS_JOBS_DIR}" 2>/dev/null || true

# 각 Job 파일 업로드
for job in "${JOBS[@]}"; do
    job_path="${PROJECT_ROOT}/${job}"
    job_name="$(basename $job)"
    if [ -f "$job_path" ]; then
        echo "  Uploading: ${job} → ${HDFS_JOBS_DIR}/${job_name}"
        docker cp "${job_path}" "${NAMENODE_CONTAINER}:/tmp/${job_name}"
        docker exec "${NAMENODE_CONTAINER}" hdfs dfs -put -f "/tmp/${job_name}" "${HDFS_JOBS_DIR}/${job_name}"
        docker exec "${NAMENODE_CONTAINER}" rm -f "/tmp/${job_name}"
        echo "    ✅ Done"
    else
        echo "  ⚠️  File not found: ${job_path}"
    fi
done

# 권한 설정
docker exec "${NAMENODE_CONTAINER}" hdfs dfs -chown -R airflow:supergroup "${HDFS_JOBS_DIR}" 2>/dev/null || true
docker exec "${NAMENODE_CONTAINER}" hdfs dfs -chmod -R 755 "${HDFS_JOBS_DIR}" 2>/dev/null || true

echo ""
echo "[H8S-DP] Spark Job deployment complete!"
echo "  Verify: docker exec ${NAMENODE_CONTAINER} hdfs dfs -ls ${HDFS_JOBS_DIR}"
