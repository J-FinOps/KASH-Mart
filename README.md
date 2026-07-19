# H8S-DP: Hybrid Data Pipeline

> 쿠버네티스(K8s) + 외부 Docker Hadoop/YARN 하이브리드 데이터 파이프라인

회계 FDS(Fraud Detection System) 데이터 마트를 구축하는 단일 Docker Compose 기반 파이프라인을,
**KubernetesExecutor 기반 Airflow(K8s) + 외부 Docker Hadoop/YARN** 하이브리드 아키텍처로 고도화합니다.

---

## 아키텍처 개요

```
┌─────────────────────────────────────────────────┐
│              Kubernetes Cluster                  │
│  ┌───────────────────────────────────────────┐  │
│  │  Airflow (Helm)                           │  │
│  │  ┌───────────┐  ┌─────────────────────┐  │  │
│  │  │ Scheduler │  │    Webserver        │  │  │
│  │  └─────┬─────┘  └─────────────────────┘  │  │
│  │        │ KubernetesExecutor              │  │
│  │  ┌─────▼──────────────────────────────┐  │  │
│  │  │  Worker Pod (동적 생성/소멸)        │  │  │
│  │  │  • LivyOperator                    │  │  │
│  │  │  • Hadoop Conf (ConfigMap)         │  │  │
│  │  └──────────┬─────────────────────────┘  │  │
│  └─────────────┼────────────────────────────┘  │
└────────────────┼───────────────────────────────┘
                 │ REST API (Livy :8998)
                 │ HDFS RPC (:9820)
┌────────────────┼───────────────────────────────┐
│  Docker Host    │                                │
│  ┌──────────────▼────────────────────────────┐  │
│  │  Apache Livy Server                       │  │
│  └──────────────┬────────────────────────────┘  │
│  ┌──────────────▼────────────────────────────┐  │
│  │  YARN ResourceManager (:8088)             │  │
│  │  YARN NodeManager                         │  │
│  └──────────────┬────────────────────────────┘  │
│  ┌──────────────▼────────────────────────────┐  │
│  │  HDFS NameNode (:9820) + DataNode         │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## Quick Start

### 1. Hadoop/YARN 클러스터 시작 (Docker)

```bash
# 외부 클러스터만 실행 (Airflow 제외)
docker compose -f hadoop-cluster.yml up -d

# 상태 확인
docker compose -f hadoop-cluster.yml ps
```

### 2. 네트워크 설정

```bash
# Docker Host IP 감지 및 K8s ConfigMap 생성
bash helm/network-setup.sh
```

### 3. Airflow Helm 배포 (K8s)

```bash
# Helm repo 추가
helm repo add apache-airflow https://airflow.apache.org

# 네임스페이스 생성
kubectl create namespace airflow

# ConfigMap 및 Secret 배포
kubectl apply -f helm/airflow/templates/hadoop-configmap.yaml
kubectl apply -f helm/airflow/templates/external-db-secret.yaml

# Airflow 설치
helm upgrade --install airflow apache-airflow/airflow \
  -f helm/airflow/values.yaml \
  --namespace airflow
```

### 4. Spark Job 배포

```bash
# HDFS에 Spark Job 파일 업로드
bash dags/deploy_spark_jobs.sh
```

### 5. DAG 활성화 및 실행

```bash
# Airflow Webserver 포트포워드
kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow

# 브라우저에서 http://localhost:8080 접속 후 DAG 활성화
```

---

## 디렉토리 구조

```
.
├── hadoop-cluster.yml          # 독립 실행형 Hadoop/YARN/Livy 클러스터
├── docker-compose.yml          # (레거시) 전체 단일 호스트 구성
├── Dockerfile                   # Airflow용 Docker 이미지
├── Dockerfile.hadoop-java11     # Hadoop Java 11 패치
├── Dockerfile.livy              # Apache Livy 서버 이미지
├── dags/
│   ├── accounting_fds_pipeline.py      # (레거시) LocalExecutor DAG
│   ├── accounting_fds_pipeline_k8s.py  # ✅ K8s KubernetesExecutor DAG
│   ├── spark_jobs/
│   │   ├── accounting_fds_job.py       # (레거시) SparkSubmitOperator용
│   │   └── accounting_fds_job_k8s.py   # ✅ LivyOperator용 (argparse 지원)
│   ├── setup_hdfs.sh                   # HDFS 초기 디렉터리 설정
│   └── deploy_spark_jobs.sh            # Spark Job HDFS 배포 스크립트
├── helm/
│   ├── network-setup.sh                # K8s ↔ Docker 네트워크 설정
│   └── airflow/
│       ├── values.yaml                 # Airflow Helm Chart 설정
│       └── templates/
│           ├── hadoop-configmap.yaml    # Hadoop 설정 ConfigMap
│           └── external-db-secret.yaml  # 외부 DB 인증 Secret
├── hadoop-conf/
│   ├── core-site.xml
│   └── yarn-site.xml
├── livy-conf/
│   └── livy.conf                       # Livy 서버 설정
├── hadoop.env                           # Hadoop 환경 변수
└── transactions_10k.csv                 # 샘플 데이터
```

---

## 핵심 설계 원칙

| 원칙 | 설명 |
|------|------|
| **관심사 분리** | 제어부(Airflow/K8s) ↔ 데이터부(Hadoop/Spark) 완전 분리 |
| **무상태 워커** | Worker Pod는 작업 완료 즉시 소멸 (KubernetesExecutor) |
| **원격 연산 위임** | 모든 무거운 Spark 연산은 Livy → 외부 YARN으로 위임 |
| **변경 최소화** | 기존 Hadoop/YARN 설정은 그대로 유지 |
| **설정 모두 코드화** | 모든 K8s 매니페스트, Helm 값, 네트워크 설정을 코드로 관리 |

---

## 서비스 포트

| 서비스 | 컨테이너 | 포트 | 용도 |
|--------|---------|------|------|
| PostgreSQL | postgres | 5432 | Airflow 메타데이터 DB |
| HDFS NameNode WebUI | namenode | 9870 | HDFS 모니터링 |
| HDFS NameNode RPC | namenode | 9820 | HDFS 클라이언트 통신 |
| YARN ResourceManager | resourcemanager | 8088 | YARN 모니터링 |
| Livy REST API | livy-server | 8998 | 원격 Spark Job 제출 |

---

## 문제 해결

### Q: Worker Pod에서 Docker 호스트에 접근할 수 없음
```bash
# Docker bridge gateway IP 확인
docker network inspect finops-network | grep Gateway

# network-setup.sh 재실행
bash helm/network-setup.sh
```

### Q: Livy 세션이 YARN에 연결되지 않음
```bash
# Livy 로그 확인
docker compose -f hadoop-cluster.yml logs livy-server

# YARN RM 연결 확인
docker exec resourcemanager yarn application -list
```

### Q: Helm 배포 시 externalDatabase 연결 오류
```bash
# PostgreSQL 연결 확인
kubectl run -it --rm debug --image=busybox -n airflow \
  -- sh -c 'nc -zv <DOCKER_HOST_IP> 5432'

# Secret 확인
kubectl get secret airflow-external-db -n airflow -o yaml
```

---

## 라이선스

MIT
