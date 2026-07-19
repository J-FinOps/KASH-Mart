#!/usr/bin/env bash
# reconstruct_history.sh
# Git history reconstruction script
set -euo pipefail

VERSION_A_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_B_DIR="${VERSION_A_DIR}/01_B/build_data_mart_with_airflow_B"

echo "===== Git History Reconstruction Script ====="
echo "Version A: ${VERSION_A_DIR}"
echo "Version B: ${VERSION_B_DIR}"

cleanup() {
    echo "[ERROR] Script failed. Current branch: $(git branch --show-current 2>/dev/null || echo unknown)"
    git status 2>/dev/null || true
}
trap cleanup ERR

git config core.quotepath false
export LANG=C.UTF-8 2>/dev/null || export LANG=C
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=C

# ─── Detect base branch ─────────────────────────
if git rev-parse --verify master >/dev/null 2>&1; then
    BASE_BRANCH="master"
elif git rev-parse --verify main >/dev/null 2>&1; then
    BASE_BRANCH="main"
else
    BASE_BRANCH="$(git branch --show-current)"
    echo "WARNING: Using current branch '${BASE_BRANCH}' as base"
fi
echo "Using base branch: ${BASE_BRANCH}"

# Switch to base branch and ensure clean state
git checkout "${BASE_BRANCH}" 2>/dev/null || true

echo "[STEP 1] Initial commit: Version A baseline"

cat << 'GITIGNORE' > .gitignore
01_B/
logs/
.env
hadoop.env

.DS_Store
.idea/
.vscode/
*.txt
*.csv
__pycache__/
exported_data/
db/*.db
*.tgz
*.zip
*.log
*.pyc
GITIGNORE

cat << 'GITATTR' > .gitattributes
dags/setup_hdfs.sh text eol=lf
GITATTR

git add -A
git commit --allow-empty -m 'chore: 버전 A 베이스라인 스냅샷 초기화

Docker Compose based Airflow 2.7.1 + Hadoop + Postgres all-in-one stack. LocalExecutor with SparkSubmitOperator.'

echo "[STEP 2] feat/docker-hadoop branch"
git checkout -b feat/docker-hadoop "${BASE_BRANCH}"

echo "  [C1] feat(build): add Airflow 2.7.1 Dockerfile"
cat << 'EOF' > Dockerfile
FROM apache/airflow:2.7.1-python3.9

USER root
# PySpark with Java 11
RUN apt-get update && apt-get install -y openjdk-11-jre-headless && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set JAVA_HOME for Java 11
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV PATH=$PATH:$JAVA_HOME/bin

USER airflow
# Install dependencies with constraints to match Airflow 2.7.1 and Python 3.9
RUN pip install --no-cache-dir \
    "pyspark==3.4.1" \
    "apache-airflow-providers-apache-spark" \
    "apache-airflow-providers-postgres" \
    "psycopg2-binary" \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-2.7.1/constraints-3.9.txt"
EOF

git add Dockerfile
git commit --allow-empty -m 'feat(build): Airflow 2.7.1 Dockerfile 추가 (Java 11 + PySpark 3.4.1)'

echo "  [C2] build(docker): add Dockerfile.hadoop-java11"
cat << 'EOF' > Dockerfile.hadoop-java11
ARG BASE_IMAGE=bde2020/hadoop-base:2.0.0-hadoop3.2.1-java8
FROM $BASE_IMAGE

USER root

# Update APT sources to point to archive.debian.org as Debian 9 Stretch is EOL
# and install openjdk-11-jre-headless from stretch-backports
RUN sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
    sed -i 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list && \
    sed -i '/stretch-updates/d' /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian stretch-backports main" > /etc/apt/sources.list.d/backports.list && \
    apt-get update -o Acquire::Check-Valid-Until=false && \
    apt-get install -y -o Acquire::Check-Valid-Until=false -t stretch-backports openjdk-11-jre-headless && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Override JAVA_HOME to use Java 11
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

# Download JAXB and JavaBeans Activation Framework JARs because Java 11
# removed EE modules, causing ClassNotFoundException: javax.activation.DataSource in YARN
RUN curl -sSLo /opt/hadoop-3.2.1/share/hadoop/common/lib/javax.activation-api-1.2.0.jar https://repo1.maven.org/maven2/javax/activation/javax.activation-api/1.2.0/javax.activation-api-1.2.0.jar && \
    curl -sSLo /opt/hadoop-3.2.1/share/hadoop/common/lib/jaxb-api-2.3.1.jar https://repo1.maven.org/maven2/javax/xml/bind/jaxb-api/2.3.1/jaxb-api-2.3.1.jar && \
    curl -sSLo /opt/hadoop-3.2.1/share/hadoop/common/lib/jaxb-core-2.3.0.1.jar https://repo1.maven.org/maven2/com/sun/xml/bind/jaxb-core/2.3.0.1/jaxb-core-2.3.0.1.jar && \
    curl -sSLo /opt/hadoop-3.2.1/share/hadoop/common/lib/jaxb-impl-2.3.1.jar https://repo1.maven.org/maven2/com/sun/xml/bind/jaxb-impl/2.3.1/jaxb-impl-2.3.1.jar && \
    curl -sSLo /opt/hadoop-3.2.1/share/hadoop/common/lib/activation-1.1.1.jar https://repo1.maven.org/maven2/javax/activation/activation/1.1.1/activation-1.1.1.jar
EOF

git add Dockerfile.hadoop-java11
git commit --allow-empty -m 'build(docker): Dockerfile.hadoop-java11 추가 (Hadoop Java 8→11 업그레이드)'

echo "  [C3] feat(infra): add all-in-one docker-compose.yml"
cat << 'EOF' > docker-compose.yml
networks:
  finops-network:
    driver: bridge

volumes:
  hadoop_namenode:
  hadoop_datanode:
  postgres_data: 

services:
  # 0. PostgreSQL Metadata Database
  postgres:
    image: postgres:13
    container_name: postgres
    restart: always
    environment:
      - POSTGRES_USER=airflow
      - POSTGRES_PASSWORD=airflow
      - POSTGRES_DB=airflow
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - finops-network

  # 1. HDFS
  namenode:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11
    container_name: namenode
    restart: always
    ports:
      - "9870:9870"
      - "9820:9820"
    volumes:
      - hadoop_namenode:/hadoop/dfs/name
    environment:
      - CLUSTER_NAME=finops_cluster
    env_file:
      - ./hadoop.env
    networks:
      - finops-network

  datanode:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java11
    container_name: datanode
    restart: always
    ports:
      - "9864:9864"
    volumes:
      - hadoop_datanode:/hadoop/dfs/data
    environment:
      - SERVICE_PRECONDITION=namenode:9820
    env_file:
      - ./hadoop.env
    depends_on:
      - namenode
    networks:
      - finops-network

  # YARN Resource Manager
  resourcemanager:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java11
    container_name: resourcemanager
    restart: always
    ports:
      - "8088:8088"
    environment:
      - SERVICE_PRECONDITION=namenode:9820 datanode:9864
      - YARN_CONF_yarn_resourcemanager_scheduler_class=org.apache.hadoop.yarn.server.resourcemanager.scheduler.fifo.FifoScheduler
      - YARN_CONF_yarn_scheduler_minimum___allocation___mb=1024
      - YARN_CONF_yarn_scheduler_maximum___allocation___mb=4096
    env_file:
      - ./hadoop.env
    networks:
      - finops-network

  # YARN Node Manager
  nodemanager:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-nodemanager:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-nodemanager:2.0.0-hadoop3.2.1-java11
    container_name: nodemanager
    restart: always
    ports:
      - "8042:8042"
    environment:
      - SERVICE_PRECONDITION=namenode:9820 datanode:9864 resourcemanager:8088
      - YARN_CONF_yarn_nodemanager_resource_memory___mb=4096
      - YARN_CONF_yarn_scheduler_minimum___allocation___mb=1024
      - YARN_CONF_yarn_scheduler_maximum___allocation___mb=4096
    env_file:
      - ./hadoop.env
    depends_on:
      - resourcemanager
    networks:
      - finops-network

  # 2. HDFS Directory Setup
  hdfs-directory-setup:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11
    container_name: hdfs-directory-setup
    depends_on:
      - namenode
    networks:
      - finops-network
    env_file:
      - ./hadoop.env
    volumes:
      - ./dags/setup_hdfs.sh:/setup_hdfs.sh
      - ./transactions_10k.csv:/transactions_10k.csv
    command: ["/bin/bash", "/setup_hdfs.sh"]

  # 3. Airflow DB 초기화
  airflow-init:
    build: .
    container_name: airflow-init
    depends_on:
      postgres:
        condition: service_started
      hdfs-directory-setup:
        condition: service_completed_successfully
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./db:/opt/airflow/db
      - ./hadoop-conf:/opt/hadoop/conf
      - ./exported_data:/opt/airflow/exported_data
    environment:
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - HADOOP_CONF_DIR=/opt/hadoop/conf
    entrypoint: [ "/entrypoint" ]
    command: >
      bash -c "until nc -z postgres 5432; do echo 'waiting for postgres...'; sleep 3; done &&
               airflow db init &&
               airflow users create --username admin --password admin --firstname Anonymous --lastname Admin --role Admin --email admin@example.com"
    networks:
      - finops-network

  # 4. Apache Airflow Webserver
  airflow-webserver:
    build: .
    container_name: airflow-webserver
    ports:
      - "8080:8080"
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./db:/opt/airflow/db
      - ./hadoop-conf:/opt/hadoop/conf
      - ./exported_data:/opt/airflow/exported_data
    environment:
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CORE__EXECUTOR=LocalExecutor
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - HADOOP_CONF_DIR=/opt/hadoop/conf
    entrypoint: [ "/entrypoint" ]
    command: webserver
    depends_on:
      postgres:
        condition: service_started
      airflow-init:
        condition: service_completed_successfully
    networks:
      - finops-network

  # 5. Apache Airflow Scheduler
  airflow-scheduler:
    build: .
    container_name: airflow-scheduler
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./db:/opt/airflow/db
      - ./hadoop-conf:/opt/hadoop/conf
      - ./exported_data:/opt/airflow/exported_data
    environment:
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CORE__EXECUTOR=LocalExecutor
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - HADOOP_CONF_DIR=/opt/hadoop/conf
    entrypoint: [ "/entrypoint" ]
    command: scheduler
    depends_on:
      postgres:
        condition: service_started
      airflow-init:
        condition: service_completed_successfully
    networks:
      - finops-network
EOF

git add docker-compose.yml
git commit --allow-empty -m 'feat(infra): docker-compose.yml 추가 (LocalExecutor + Hadoop 올인원)'

echo "  [C4] feat(dag): add v1 DAG with SparkSubmitOperator"
mkdir -p dags/spark_jobs
cat << 'EOF' > dags/accounting_fds_pipeline.py
from datetime import datetime, timedelta
from airflow.decorators import dag, task
from airflow.operators.bash import BashOperator
from airflow.providers.apache.spark.operators.spark_submit import SparkSubmitOperator

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 1,
    'retry_delay': timedelta(minutes=5),
}

@dag(
    dag_id='accounting_anomaly_detection_v1',
    default_args=default_args,
    description='Hadoop YARN 리소스 매니저 연동형 HDFS 분산 회계 FDS 파이프라인',
    start_date=datetime(2026, 7, 1),
    schedule_interval='@daily',
    catchup=False
)
def accounting_fds_dag():

    # 1. 인프라 검증 태스크
    check_hdfs_storage = BashOperator(
        task_id='check_hdfs_storage',
        bash_command='airflow connections get HDFS_DEFAULT || true', 
    )

    # 2. SparkSubmitOperator로 분리된 스크립트 실행 위임 (YARN)
    execute_fds_logic = SparkSubmitOperator(
        task_id='execute_fds_logic',
        application='/opt/airflow/dags/spark_jobs/accounting_fds_job.py', # 마운트된 볼륨 내 경로
        conn_id='spark_default', # Airflow Spark Connection ID
        name='accounting_fds_job_on_yarn',
        verbose=True,
        # 도커 소형 가상환경 자원 절약을 위한 Spark 메모리 슬림 튜닝
        driver_memory='1024m',
        executor_memory='1024m',
        conf={
            'spark.submit.deployMode': 'client', # 로컬 드라이버 실행(컨테이너 기반 제출에 안전)
            'spark.yarn.am.memory': '1024m',
            'spark.yarn.queue': 'default'        # YARN 리소스 큐 설정
        },
        # Spark Submit 시 YARN 및 하둡 환경변수 주입을 위한 옵션 설정
        env_vars={
            'HADOOP_CONF_DIR': '/opt/hadoop/conf',
            'JAVA_HOME': '/usr/lib/jvm/java-11-openjdk-amd64'
        }
    )

    # 3. HDFS 결과를 로컬 호스트 마운트 폴더로 복사 위임 태스크 (PySpark Local Mode)
    @task
    def export_to_local():
        import os
        import shutil
        from pyspark.sql import SparkSession
        
        # 로컬 쓰기이므로 YARN이 아닌 local[*] 모드로 드라이버 내에서 가동
        spark = SparkSession.builder \
            .appName("ExportHDFSToLocal") \
            .master("local[*]") \
            .getOrCreate()
            
        hdfs_path = "hdfs://namenode:9820/user/airflow/warehouse/fact_accounting"
        local_path = "file:///opt/airflow/exported_data/fact_accounting"
        clean_path = "/opt/airflow/exported_data/fact_accounting"
        
        # 기존 로컬 디렉토리가 있다면 안전하게 비워 전처리 진행
        if os.path.exists(clean_path):
            try:
                shutil.rmtree(clean_path)
            except Exception as e:
                print(f"Error cleaning directory: {e}")
                
        # HDFS Parquet 데이터를 읽어서 로컬 호스트 볼륨에 '거래일자' 기준 파티션 쓰기
        print("Reading Parquet from HDFS and writing to local volume...")
        df = spark.read.parquet(hdfs_path)
        df.write.mode("overwrite").partitionBy("거래일자").parquet(local_path)
        
        print("Successfully exported HDFS parquet files to local host directory!")
        spark.stop()

    check_hdfs_storage >> execute_fds_logic >> export_to_local()

accounting_pipeline = accounting_fds_dag()
EOF

git add dags/accounting_fds_pipeline.py
git commit --allow-empty -m 'feat(dag): v1 DAG 추가 (SparkSubmitOperator 기반 FDS 파이프라인)'

echo "  [C5] feat(spark): add v1 Spark job"
cat << 'EOF' > dags/spark_jobs/accounting_fds_job.py
from pyspark.sql import SparkSession
from pyspark.sql.functions import col
from pyspark.sql.types import StructType, StructField, StringType, LongType, DateType

def run_fds_job():
    spark = SparkSession.builder \
        .appName("AccountingFDSProcessingYARN") \
        .getOrCreate()
    
    print("Spark Session 성공적으로 연결 완료 (YARN Client Mode)")

    schema = StructType([
        StructField("거래번호", StringType(), False),
        StructField("거래일자", StringType(), False),
        StructField("계정과목", StringType(), True),
        StructField("거래처", StringType(), True),
        StructField("금액", LongType(), True),
        StructField("적요", StringType(), True),
        StructField("담당자", StringType(), True),
        StructField("승인자", StringType(), True),
        StructField("이상여부", LongType(), True),
        StructField("이상유형", StringType(), True)
    ])

    input_path = "hdfs://namenode:9820/user/hive/warehouse/raw_accounting"
    raw_df = spark.read.csv(input_path, schema=schema, header=True)

    cleaned_df = raw_df.withColumn("거래일자", col("거래일자").cast(DateType())) \
                       .fillna({"금액": 0, "이상여부": 0})

    output_path = "hdfs://namenode:9820/user/airflow/warehouse/fact_accounting"
    
    cleaned_df.write \
        .mode("overwrite") \
        .partitionBy("거래일자") \
        .parquet(output_path)

    print("PySpark FDS 연산 및 HDFS Parquet 파티셔닝 적재 프로세스 정상 종료 (YARN)")
    spark.stop()

if __name__ == "__main__":
    run_fds_job()
EOF

git add dags/spark_jobs/accounting_fds_job.py
git commit --allow-empty -m 'feat(spark): v1 Spark Job 추가 (HDFS CSV→Parquet 변환)'

echo "  [C6] feat(config): add Hadoop configs"
mkdir -p hadoop-conf
cat << 'EOF' > hadoop-conf/core-site.xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://namenode:9820</value>
    </property>
</configuration>
EOF

cat << 'EOF' > hadoop-conf/yarn-site.xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>yarn.resourcemanager.hostname</name>
        <value>resourcemanager</value>
    </property>
    <property>
        <name>yarn.resourcemanager.address</name>
        <value>resourcemanager:8032</value>
    </property>
    <property>
        <name>yarn.resourcemanager.scheduler.address</name>
        <value>resourcemanager:8030</value>
    </property>
    <property>
        <name>yarn.resourcemanager.resource-tracker.address</name>
        <value>resourcemanager:8031</value>
    </property>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
    <property>
        <name>yarn.nodemanager.env-whitelist</name>
        <value>JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_MAPRED_HOME</value>
    </property>
    <property>
        <name>yarn.nodemanager.pmem-check-enabled</name>
        <value>false</value>
    </property>
    <property>
        <name>yarn.nodemanager.vmem-check-enabled</name>
        <value>false</value>
    </property>

    <property>
        <name>yarn.resourcemanager.scheduler.class</name>
        <value>org.apache.hadoop.yarn.server.resourcemanager.scheduler.fifo.FifoScheduler</value>
    </property>
</configuration>
EOF

git add hadoop-conf/core-site.xml
git add hadoop-conf/yarn-site.xml
git commit --allow-empty -m 'feat(config): Hadoop core-site.xml, yarn-site.xml 설정 추가'

echo "  [C7] feat(scripts): add HDFS setup script"
cat << 'EOF' > dags/setup_hdfs.sh
#!/bin/bash
echo "Waiting for HDFS NameNode to leave safe mode..."
until hdfs dfsadmin -safemode get | grep "Safe mode is OFF"; do
  sleep 5
done
echo "HDFS is ready. Creating directories..."
hdfs dfs -mkdir -p /user/airflow/warehouse
hdfs dfs -mkdir -p /user/hive/warehouse
hdfs dfs -mkdir -p /user/hive/warehouse/raw_accounting

if [ -f /transactions_10k.csv ]; then
  echo "Uploading transactions_10k.csv to HDFS..."
  hdfs dfs -put -f /transactions_10k.csv /user/hive/warehouse/raw_accounting/transactions_10k.csv
fi

hdfs dfs -chown -R airflow:supergroup /user/airflow
hdfs dfs -chown -R airflow:supergroup /user/hive
EOF

git add dags/setup_hdfs.sh
git add .gitattributes
git commit --allow-empty -m 'feat(scripts): HDFS setup 스크립트 및 .gitattributes 추가'

echo "  [C8] chore(git): update .gitignore"
cat << 'GITIGNORE' > .gitignore
logs/
.env
hadoop.env

.DS_Store
.idea/
.vscode/
*.txt
*.csv
__pycache__/
exported_data/
db/*.db
*.tgz
*.zip
*.log
*.pyc
GITIGNORE

git add .gitignore
git commit --allow-empty -m 'chore(git): .gitignore 업데이트 (CSV 및 바이너리 제외)'

echo "[STEP 3] try/docker-build branch (K8s Airflow Dockerfile experiment)"
git checkout -b try/docker-build feat/docker-hadoop
mkdir -p helm/airflow/templates

echo "  [C9] build(docker): attempt K8s Dockerfile with Java 11 (FAIL)"
cat << 'EOF' > helm/airflow/Dockerfile
# ============================================================
# Custom Airflow Image (Attempt — Java 11, WILL FAIL)
# ============================================================
ARG AIRFLOW_VERSION=3.2.2
FROM apache/airflow:${AIRFLOW_VERSION}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-11-jre-headless && apt-get clean && rm -rf /var/lib/apt/lists/*
USER airflow
RUN pip install --no-cache-dir apache-airflow-providers-apache-livy apache-airflow-providers-apache-hdfs requests
ENV JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
ENV HADOOP_CONF_DIR=/opt/hadoop/conf
EOF

git add helm/airflow/Dockerfile
git commit --allow-empty -m 'build(docker): K8s Airflow 3.2.2 Dockerfile 시도 (Java 11, 실패)

[에러 현상] Package openjdk-11-jre-headless has no installation candidate
[원인 가설] Debian Bookworm default JDK is 17
[해결 방향] Switch to Java 17 JRE, add gssapi build deps'

echo "  [C10] fix(build): switch to Java 17 JRE + gssapi deps"
cat << 'EOF' > helm/airflow/Dockerfile
# ============================================================
# H8S-DP: Custom Airflow Image with Livy/HDFS Providers
# ============================================================
ARG AIRFLOW_VERSION=3.2.2

FROM apache/airflow:${AIRFLOW_VERSION}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openjdk-17-jre-headless \
        libkrb5-dev \
        libsasl2-dev \
        gcc \
        python3-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER airflow

RUN pip install --no-cache-dir \
    apache-airflow-providers-apache-livy \
    apache-airflow-providers-apache-hdfs \
    requests

USER root

RUN apt-get remove -y --purge \
        gcc \
        python3-dev \
        libkrb5-dev \
        libsasl2-dev \
    && apt-get autoremove -y \
    && apt-get clean

USER airflow

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV HADOOP_CONF_DIR=/opt/hadoop/conf
EOF

git add helm/airflow/Dockerfile
git commit --allow-empty -m 'fix(build): Java 17 JRE로 전환 및 gssapi 빌드 의존성 추가

[에러 현상] Failed to build gssapi when getting requirements to build wheel
[원인 가설] Bookworm missing openjdk-11-jre-headless; gssapi needs libkrb5-dev, libsasl2-dev, gcc, python3-dev
[해결 방향] Java 11 -> 17, build deps install -> pip -> build deps remove, USER airflow for pip'

git checkout feat/docker-hadoop
git merge try/docker-build --no-ff -m 'merge: try/docker-build 병합'
echo "[STEP 3b] Merging feat/docker-hadoop -> ${BASE_BRANCH}"
git checkout "${BASE_BRANCH}"
git merge feat/docker-hadoop --no-ff -m 'merge: feat/docker-hadoop 병합'
echo "[STEP 4] feat/k8s-airflow branch"
git checkout -b feat/k8s-airflow "${BASE_BRANCH}"

echo "  [C11] feat(k8s): add Airflow 3.2.2 Dockerfile"
cat << 'EOF' > helm/airflow/Dockerfile
# ============================================================
# H8S-DP: Custom Airflow Image with Livy/HDFS Providers
# ============================================================
ARG AIRFLOW_VERSION=3.2.2

FROM apache/airflow:${AIRFLOW_VERSION}

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openjdk-17-jre-headless \
        libkrb5-dev \
        libsasl2-dev \
        gcc \
        python3-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER airflow

RUN pip install --no-cache-dir \
    apache-airflow-providers-apache-livy \
    apache-airflow-providers-apache-hdfs \
    requests

USER root

RUN apt-get remove -y --purge \
        gcc \
        python3-dev \
        libkrb5-dev \
        libsasl2-dev \
    && apt-get autoremove -y \
    && apt-get clean

USER airflow

ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV HADOOP_CONF_DIR=/opt/hadoop/conf
EOF

git add helm/airflow/Dockerfile
git commit --allow-empty -m 'feat(k8s): Airflow 3.2.2 Dockerfile 추가 (Kubernetes 배포용)'

echo "  [C12] feat(k8s): add Helm values.yaml"
cat << 'EOF' > helm/airflow/values.yaml
# ============================================================
# H8S-DP: Airflow Helm Chart Values
# KubernetesExecutor 기반, 외부 Docker Hadoop/YARN 연동
# ============================================================

executor: "KubernetesExecutor"

# Static API secret key — prevents token invalidation on pod restarts
apiSecretKey: "h8sdp-static-api-key-2026"
webserverSecretKey: "h8sdp-static-ws-key-2026"

# -------------------------------------------------------------------
# Custom Airflow Image (모든 컴포넌트에 Livy/HDFS Provider 포함)
# -------------------------------------------------------------------
images:
  airflow:
    repository: airflow-h8sdp
    tag: "3.2.2"
    pullPolicy: IfNotPresent

# -------------------------------------------------------------------
# Airflow Config
# -------------------------------------------------------------------
config:
  core:
    load_examples: "False"
    dags_are_paused_at_creation: "True"
    dag_discovery_safe_mode: "True"
  kubernetes:
    delete_worker_pods: "False"
    worker_container_repository: "airflow-h8sdp"
    worker_container_tag: "3.2.2"
    namespace: "airflow"
    run_as_user: "50000"
    dags_in_image: "False"

# -------------------------------------------------------------------
# External PostgreSQL Database (Docker 호스트에서 실행 중)
# -------------------------------------------------------------------
postgresql:
  enabled: false

data:
  metadataConnection:
    user: airflow
    pass: airflow
    protocol: postgresql
    host: 172.18.0.1
    port: 5432
    db: airflow
    sslmode: disable

# -------------------------------------------------------------------
# API Server (Web UI + REST API, NodePort로 외부 접근)
# -------------------------------------------------------------------
apiServer:
  service:
    type: NodePort
    ports:
      - name: airflow-ui
        port: 8080
        nodePort: 30080
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "1000m"
      memory: "2Gi"

# -------------------------------------------------------------------
# Scheduler
# -------------------------------------------------------------------
scheduler:
  replicas: 1
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "1000m"
      memory: "2Gi"

# -------------------------------------------------------------------
# DAG 배포 방식 (GitSync 비활성화, ConfigMap 기반)
# -------------------------------------------------------------------
dags:
  gitSync:
    enabled: false
  persistence:
    enabled: false

# -------------------------------------------------------------------
# Logs
# -------------------------------------------------------------------
logs:
  persistence:
    enabled: false

# -------------------------------------------------------------------
# 공통 환경 변수 (Scheduler, Webserver, Worker Pods)
# -------------------------------------------------------------------
env:
  # Livy / WebHDFS Connections (Airflow가 자동 인식)
  - name: AIRFLOW_CONN_LIVY_DEFAULT
    value: "http://@172.18.0.1:8998"
  - name: AIRFLOW_CONN_WEBHDFS_DEFAULT
    value: "http://@172.18.0.1:9870"
  # Hadoop/YARN/Livy 연동
  - name: DOCKER_HOST_IP
    value: "172.18.0.1"
  - name: HADOOP_CONF_DIR
    value: "/opt/hadoop/conf"
  - name: JAVA_HOME
    value: "/usr/lib/jvm/java-17-openjdk-amd64"

# -------------------------------------------------------------------
# Extra Volume Mounts (Hadoop Config + DAGs via ConfigMap)
# -------------------------------------------------------------------
volumes:
  - name: hadoop-conf
    configMap:
      name: hadoop-config
  - name: dags
    configMap:
      name: airflow-dags
  - name: exported-data
    hostPath:
      path: /opt/airflow-exported
      type: DirectoryOrCreate

volumeMounts:
  - name: hadoop-conf
    mountPath: /opt/hadoop/conf
    readOnly: true
  - name: dags
    mountPath: /opt/airflow/dags
    readOnly: true
  - name: exported-data
    mountPath: /opt/airflow/exported_data
EOF

git add helm/airflow/values.yaml
git commit --allow-empty -m 'feat(k8s): Helm values.yaml 추가 (KubernetesExecutor 설정)'

echo "  [C13] feat(k8s): add Helm templates"
cat << 'EOF' > helm/airflow/templates/airflow-connections.yaml
# ============================================================
# H8S-DP: Airflow Connections Secret
# LivyOperator + WebHdfsHook 연결 정보
# ============================================================
apiVersion: v1
kind: Secret
metadata:
  name: airflow-connections
  namespace: airflow
  labels:
    app: airflow
    component: connections
type: Opaque
stringData:
  AIRFLOW_CONN_LIVY_DEFAULT: "http://@host.docker.internal:8998"
  AIRFLOW_CONN_WEBHDFS_DEFAULT: "http://@host.docker.internal:9870"
EOF

cat << 'EOF' > helm/airflow/templates/hadoop-configmap-generated.yaml
# ============================================================
# Hadoop Configuration ConfigMap for Worker Pods
# ============================================================
# 이 ConfigMap은 HDFS/HAAdoop 설정 파일을 K8s Worker Pod에 주입하여,
# Pod에서 외부 Docker Hadoop 클러스터에 접근할 수 있도록 합니다.
apiVersion: v1
kind: ConfigMap
metadata:
  name: hadoop-config
  namespace: airflow
  labels:
    app: airflow
    component: hadoop-client
data:
  core-site.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
    <configuration>
        <property>
            <name>fs.defaultFS</name>
            <value>hdfs://172.17.0.1:9820</value>
        </property>
    </configuration>

  hdfs-site.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
    <configuration>
        <property>
            <name>dfs.client.use.datanode.hostname</name>
            <value>true</value>
        </property>
        <property>
            <name>dfs.replication</name>
            <value>1</value>
        </property>
    </configuration>

  yarn-site.xml: |
    <?xml version="1.0" encoding="UTF-8"?>
    <?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
    <configuration>
        <property>
            <name>yarn.resourcemanager.hostname</name>
            <value>172.17.0.1</value>
        </property>
        <property>
            <name>yarn.resourcemanager.address</name>
            <value>172.17.0.1:8032</value>
        </property>
        <property>
            <name>yarn.resourcemanager.scheduler.address</name>
            <value>172.17.0.1:8030</value>
        </property>
        <property>
            <name>yarn.resourcemanager.resource-tracker.address</name>
            <value>172.17.0.1:8031</value>
        </property>
        <property>
            <name>yarn.nodemanager.aux-services</name>
            <value>mapreduce_shuffle</value>
        </property>
    </configuration>

  spark-defaults.conf: |
    spark.master                 yarn
    spark.submit.deployMode      client
    spark.yarn.queue             default
    spark.driver.memory          1g
    spark.executor.memory        1g
    spark.dynamicAllocation.enabled true
    spark.hadoop.fs.defaultFS    hdfs://172.17.0.1:9820
EOF

cat << 'EOF' > helm/airflow/templates/external-db-secret.yaml
# ============================================================
# External Database Secret for Airflow Metadata DB
# ============================================================
# Docker 호스트의 PostgreSQL에 연결하기 위한 인증 정보
#
# 생성 방법:
#   kubectl create secret generic airflow-external-db \
#     --from-literal=password=airflow \
#     -n airflow
# ============================================================
apiVersion: v1
kind: Secret
metadata:
  name: airflow-external-db
  namespace: airflow
  labels:
    app: airflow
type: Opaque
stringData:
  password: "airflow"  # 외부 PostgreSQL 비밀번호 (실제 배포 시 별도 관리)
EOF

git add helm/airflow/templates/airflow-connections.yaml
git add helm/airflow/templates/hadoop-configmap-generated.yaml
git add helm/airflow/templates/external-db-secret.yaml
git commit --allow-empty -m 'feat(k8s): Helm 템플릿 추가 (connections, hadoop configmap, db secret)'

echo "  [C14] feat(network): add network-setup.sh"
cat << 'EOF' > helm/network-setup.sh
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
EOF

git add helm/network-setup.sh
git commit --allow-empty -m 'feat(network): network-setup.sh 추가 (K8s-Docker 브릿지 설정)'

git checkout "${BASE_BRANCH}"
git merge feat/k8s-airflow --no-ff -m 'merge: feat/k8s-airflow 병합'
echo "[STEP 5] feat/livy-server branch"
git checkout -b feat/livy-server "${BASE_BRANCH}"

echo "  [C15] feat(livy): add Livy server Dockerfile"
cat << 'EOF' > Dockerfile.livy
# Apache Livy Server for Hybrid Data Pipeline (H8S-DP)
# Bridge between K8s Airflow and external Docker YARN/HDFS cluster

FROM bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11 AS base

USER root

# Fix APT sources — Debian 9 Stretch is EOL
RUN sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
    sed -i 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list && \
    sed -i '/stretch-updates/d' /etc/apt/sources.list

# Install Python 3.5 system packages
RUN apt-get update -o Acquire::Check-Valid-Until=false && \
    apt-get install -y -o Acquire::Check-Valid-Until=false \
    python3 python3-pip curl unzip wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    ln -s /usr/bin/python3 /usr/bin/python

# -------------------------------------------------------------------
# Install Python 3.9 via Miniconda (for PySpark 3.4.1 compatibility)
# -------------------------------------------------------------------
ENV PYTHON39_PREFIX=/opt/conda

RUN wget -q https://repo.anaconda.com/miniconda/Miniconda3-py39_24.1.2-0-Linux-x86_64.sh && \
    bash Miniconda3-py39_24.1.2-0-Linux-x86_64.sh -b -p ${PYTHON39_PREFIX} && \
    rm Miniconda3-py39_24.1.2-0-Linux-x86_64.sh && \
    echo "Python 3.9 installed: $(${PYTHON39_PREFIX}/bin/python3.9 --version)"

# -------------------------------------------------------------------
# Stage 1: Install Apache Spark 3.4.1 (matching Airflow's PySpark)
# -------------------------------------------------------------------
ENV SPARK_VERSION=3.4.1
ENV HADOOP_VERSION=3
ENV SPARK_HOME=/opt/spark

COPY spark-3.4.1-bin-hadoop3.tgz /tmp/

RUN tar -xz -C /opt/ -f /tmp/spark-3.4.1-bin-hadoop3.tgz && \
    mv /opt/spark-3.4.1-bin-hadoop3 ${SPARK_HOME} && \
    rm /tmp/spark-3.4.1-bin-hadoop3.tgz

# -------------------------------------------------------------------
# Stage 2: Install Apache Livy 0.7.1 (local archive)
# -------------------------------------------------------------------
ENV LIVY_VERSION=0.7.1-incubating
ENV LIVY_HOME=/opt/livy

COPY apache-livy-0.7.1-incubating-bin.zip /tmp/

RUN unzip -q /tmp/apache-livy-${LIVY_VERSION}-bin.zip -d /opt/ && \
    mv /opt/apache-livy-${LIVY_VERSION}-bin ${LIVY_HOME} && \
    rm /tmp/apache-livy-${LIVY_VERSION}-bin.zip

# -------------------------------------------------------------------
# Stage 3: Configure Livy
# -------------------------------------------------------------------
# Copy Hadoop configuration so Livy can talk to YARN/HDFS
COPY hadoop-conf/core-site.xml ${LIVY_HOME}/conf/
COPY hadoop-conf/hdfs-site.xml ${LIVY_HOME}/conf/
COPY hadoop-conf/yarn-site.xml ${LIVY_HOME}/conf/
COPY livy-conf/livy.conf ${LIVY_HOME}/conf/livy.conf

# Copy Spark configuration for YARN
RUN cp ${SPARK_HOME}/conf/spark-defaults.conf.template ${SPARK_HOME}/conf/spark-defaults.conf && \
    echo "spark.master yarn" >> ${SPARK_HOME}/conf/spark-defaults.conf && \
    echo "spark.submit.deployMode client" >> ${SPARK_HOME}/conf/spark-defaults.conf

# Create Livy log directory
RUN mkdir -p ${LIVY_HOME}/logs

# Environment variables
ENV PYSPARK_PYTHON=/opt/conda/bin/python3.9
ENV SPARK_HOME=/opt/spark
ENV HADOOP_CONF_DIR=/opt/livy/conf
ENV LIVY_CONF_DIR=${LIVY_HOME}/conf
ENV PATH=$PATH:${SPARK_HOME}/bin:${LIVY_HOME}/bin:/opt/conda/bin

WORKDIR ${LIVY_HOME}

EXPOSE 8998

CMD ["bin/livy-server"]
EOF

git add Dockerfile.livy
git commit --allow-empty -m 'feat(livy): Livy 서버 Dockerfile 추가 (Miniconda Python 3.9)'

echo "  [C16] feat(livy): add livy.conf, hadoop-cluster.yml, spark-defaults.conf, hadoop.env"
mkdir -p livy-conf
cat << 'EOF' > livy-conf/livy.conf
# ============================================================
# Apache Livy Configuration for H8S-DP
# Bridge between K8s Airflow and external Docker YARN/HDFS
# ============================================================

# Livy server host and port
livy.server.host = 0.0.0.0
livy.server.port = 8998

# Spark master - connect to Docker-based YARN Resource Manager
livy.spark.master = yarn
livy.spark.deploy-mode = client

# Spark home directory inside Livy container
# (set via SPARK_HOME env var in Dockerfile, but also configured here)

# Session timeout (1 hour)
livy.server.session.timeout = 1h

# Maximum number of sessions
livy.server.session.max-creation = 100

# Enable YARN application logging
livy.spark.applog.path = hdfs://namenode:9820/user/livy/app-logs

# RSC (Remote Spark Context) configuration
# Run Spark driver in YARN cluster for production
livy.spark.yarn.submit.waitAppCompletion = false

# Resource limits for Spark sessions
livy.spark.driver.cores = 1
livy.spark.driver.memory = 1g
livy.spark.executor.cores = 2
livy.spark.executor.memory = 2g
livy.spark.executor.instances = 2
livy.spark.dynamicAllocation.enabled = true

# Recover sessions on restart
livy.server.recovery.mode = recovery
livy.server.recovery.state-store = filesystem
livy.server.recovery.state-store.url = file:///opt/livy/session-state

# Superuser can manage all sessions
livy.superusers = livy,airflow

# RPC settings
livy.rsc.rpc.server.address = 0.0.0.0
livy.rsc.rpc.max.size = 1073741824

# Access control - allow all for development
livy.server.access-control.enabled = false

# File system
livy.file.local-dir-whitelist = /opt/livy/sessions/

# YARN authentication
livy.spark.yarn.security.credentials.hadoopfs.enabled = false

# PySpark Python interpreter (Python 3.9 for PySpark 3.4.1 compatibility)
livy.spark.pyspark.python = /opt/conda/bin/python3.9
EOF

cat << 'EOF' > hadoop-conf/spark-defaults.conf
spark.master                 yarn
spark.submit.deployMode      client
spark.yarn.queue             default
spark.driver.memory          1g
spark.executor.memory        1g
spark.dynamicAllocation.enabled true
spark.hadoop.fs.defaultFS    hdfs://namenode:9820
EOF

cat << 'EOF' > hadoop-cluster.yml
# ============================================================
# H8S-DP: Hadoop/YARN 독립 실행형 클러스터 (External Cluster)
# ============================================================
# 이 파일은 스토리지/연산 레이어만 포함하며,
# 오케스트레이션(Airflow)은 Kubernetes에 별도 배포됩니다.
#
# 사용법:
#   docker compose -f hadoop-cluster.yml up -d
# ============================================================

networks:
  finops-network:
    driver: bridge

volumes:
  hadoop_namenode:
  hadoop_datanode:
  postgres_data: 

services:
  # 0. PostgreSQL Metadata Database (Airflow 메타데이터 DB)
  #    K8s의 Airflow가 원격으로 이 DB에 연결합니다.
  postgres:
    image: postgres:13
    container_name: postgres
    restart: always
    environment:
      - POSTGRES_USER=airflow
      - POSTGRES_PASSWORD=airflow
      - POSTGRES_DB=airflow
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - finops-network

  # 1. HDFS NameNode
  namenode:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11
    container_name: namenode
    restart: always
    ports:
      - "9870:9870"
      - "9820:9820"
    volumes:
      - hadoop_namenode:/hadoop/dfs/name
    environment:
      - CLUSTER_NAME=finops_cluster
    env_file:
      - ./hadoop.env
    networks:
      - finops-network

  datanode:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java11
    container_name: datanode
    restart: always
    ports:
      - "9864:9864"
    volumes:
      - hadoop_datanode:/hadoop/dfs/data
    environment:
      - SERVICE_PRECONDITION=namenode:9820
    env_file:
      - ./hadoop.env
    depends_on:
      - namenode
    networks:
      - finops-network

  # YARN Resource Manager
  resourcemanager:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java11
    container_name: resourcemanager
    restart: always
    ports:
      - "8088:8088"
    environment:
      - SERVICE_PRECONDITION=namenode:9820 datanode:9864
      - YARN_CONF_yarn_resourcemanager_scheduler_class=org.apache.hadoop.yarn.server.resourcemanager.scheduler.fifo.FifoScheduler
      - YARN_CONF_yarn_scheduler_minimum___allocation___mb=1024
      - YARN_CONF_yarn_scheduler_maximum___allocation___mb=4096
    env_file:
      - ./hadoop.env
    networks:
      - finops-network

  # YARN Node Manager
  nodemanager:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-nodemanager:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-nodemanager:2.0.0-hadoop3.2.1-java11
    container_name: nodemanager
    restart: always
    ports:
      - "8042:8042"
    environment:
      - SERVICE_PRECONDITION=namenode:9820 datanode:9864 resourcemanager:8088
      - YARN_CONF_yarn_nodemanager_resource_memory___mb=4096
      - YARN_CONF_yarn_scheduler_minimum___allocation___mb=1024
      - YARN_CONF_yarn_scheduler_maximum___allocation___mb=4096
    env_file:
      - ./hadoop.env
    depends_on:
      - resourcemanager
    networks:
      - finops-network

  # 2. HDFS Directory Setup
  hdfs-directory-setup:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11
    container_name: hdfs-directory-setup
    depends_on:
      - namenode
    networks:
      - finops-network
    env_file:
      - ./hadoop.env
    volumes:
      - ./dags/setup_hdfs.sh:/setup_hdfs.sh
      - ./transactions_10k.csv:/transactions_10k.csv
    command: ["/bin/bash", "/setup_hdfs.sh"]

  # 3. Apache Livy Server (K8s Airflow ↔ YARN 원격 Spark Job 제출 브릿지)
  livy-server:
    build:
      context: .
      dockerfile: Dockerfile.livy
    image: livy-server:0.7.1-hdp
    container_name: livy-server
    restart: always
    ports:
      - "8998:8998"   # Livy REST API (K8s에서 접근)
    environment:
      - SPARK_HOME=/opt/spark
      - HADOOP_CONF_DIR=/opt/livy/conf
      - LIVY_CONF_DIR=/opt/livy/conf
      - SERVICE_PRECONDITION=namenode:9820 resourcemanager:8088
    env_file:
      - ./hadoop.env
    depends_on:
      - resourcemanager
      - namenode
    networks:
      - finops-network
    volumes:
      - ./livy-conf/livy.conf:/opt/livy/conf/livy.conf
      - ./hadoop-conf/core-site.xml:/opt/livy/conf/core-site.xml
      - ./hadoop-conf/hdfs-site.xml:/opt/livy/conf/hdfs-site.xml
      - ./hadoop-conf/yarn-site.xml:/opt/livy/conf/yarn-site.xml
EOF

cat << 'EOF' > hadoop.env
CORE_CONF_fs_defaultFS=hdfs://namenode:9820
HDFS_CONF_dfs_namenode_datanode_registration_ip__hostname__check=false
YARN_CONF_yarn_resourcemanager_hostname=resourcemanager
YARN_CONF_yarn_nodemanager_disk_health_checker_enable=false
YARN_CONF_yarn_nodemanager_resource_memory__mb=4096
YARN_CONF_yarn_scheduler_maximum__allocation__mb=4096
EOF

git add livy-conf/livy.conf
git add hadoop-conf/spark-defaults.conf
git add hadoop-cluster.yml
git add -f hadoop.env
git commit --allow-empty -m 'feat(livy): livy.conf, spark-defaults.conf, hadoop-cluster.yml, hadoop.env 추가'

git checkout "${BASE_BRANCH}"
git merge feat/livy-server --no-ff -m 'merge: feat/livy-server 병합'
echo "[STEP 6] feat/k8s-dag branch"
git checkout -b feat/k8s-dag "${BASE_BRANCH}"

echo "  [C17] feat(dag): K8s DAG 추가 (LivyOperator, polling_interval=0 초기값)"
cat << 'EOF' > dags/accounting_fds_pipeline_k8s.py
"""
H8S-DP: K8s KubernetesExecutor 기반 회계 FDS 파이프라인
========================================================
LivyOperator (polling) + WebHDFS 검증 기반
"""
from datetime import datetime, timedelta
import os

import requests

from airflow.decorators import dag, task
from airflow.providers.apache.livy.operators.livy import LivyOperator

LIVY_CONN_ID = "livy_default"

DOCKER_HOST_IP = os.environ.get("DOCKER_HOST_IP", "172.18.0.1")
WEBHDFS_BASE = f"http://{DOCKER_HOST_IP}:9870/webhdfs/v1"

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}


@dag(
    dag_id='accounting_anomaly_detection_v2_k8s',
    default_args=default_args,
    description='H8S-DP',
    start_date=datetime(2026, 7, 1),
    schedule='@daily',
    catchup=False,
    tags=['h8s-dp'],
)
def accounting_fds_hybrid_dag():

    submit_batch = LivyOperator(
        task_id='submit_fds_batch',
        livy_conn_id=LIVY_CONN_ID,
        file=(
            "hdfs://" + DOCKER_HOST_IP
            + ":9820/user/airflow/spark_jobs/accounting_fds_job_k8s.py"
        ),
        args=[
            "--input",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/hive/warehouse/raw_accounting",
            "--output",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/airflow/warehouse/fact_accounting",
            "--date",
            "{{ ds }}",
        ],
        conf={
            "spark.executor.memory": "1024m",
            "spark.driver.memory": "1024m",
        },
        name="fds_{{ ds_nodash }}",
        polling_interval=0,
    )

    @task(task_id='verify_fds_output')
    def verify_output(**context):
        url = f"{WEBHDFS_BASE}/user/airflow/warehouse/fact_accounting?op=LISTSTATUS"
        resp = requests.get(url, allow_redirects=True, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        dirs = data.get("FileStatuses", {}).get("FileStatus", [])
        count = len(dirs)
        print(f"{count} partitions found")
        if count == 0:
            raise ValueError("No output partitions found")
        return count

    verify = verify_output()

    @task(task_id='export_to_local')
    def export_to_local(**context):
        ds = context["ds"]
        hdfs_dir = f"/user/airflow/warehouse/fact_accounting/거래일자={ds}"

        list_url = f"{WEBHDFS_BASE}{hdfs_dir}?op=LISTSTATUS"
        resp = requests.get(list_url, allow_redirects=True, timeout=30)

        if resp.status_code == 404:
            print(f"Partition {ds} not found — skipping export")
            return f"skipped:{ds}"

        resp.raise_for_status()
        print(f"Export task registered for partition {ds}")
        return f"exported:{ds}"

    export = export_to_local()

    submit_batch >> verify >> export


dag_instance = accounting_fds_hybrid_dag()
EOF

git add dags/accounting_fds_pipeline_k8s.py
git commit --allow-empty -m 'feat(dag): K8s DAG 추가 (LivyOperator, polling_interval=0 초기값)'

echo "  [C18] feat(spark): add K8s Spark job with argparse"
cat << 'EOF' > dags/spark_jobs/accounting_fds_job_k8s.py
#!/usr/bin/env python3
"""
H8S-DP: 회계 FDS PySpark Job (Livy Batch 모드 대응)
=====================================================
- LivyOperator에서 --input / --output 인자로 경로를 전달받아 실행
- 외부 Docker YARN 클러스터에서 실행됨
"""
import argparse
from datetime import datetime
from pyspark.sql import SparkSession
from pyspark.sql.functions import col
from pyspark.sql.types import StructType, StructField, StringType, LongType, DateType


def run_fds_job(input_path: str, output_path: str, execution_date: str):
    """
    PySpark FDS (Fraud Detection System) 회계 이상 탐지 배치 작업

    Args:
        input_path: HDFS 원천 데이터 경로
        output_path: HDFS Parquet 결과 저장 경로
        execution_date: 배치 실행일 (YYYY-MM-DD)
    """
    spark = SparkSession.builder \
        .appName("AccountingFDS_YARN_{}".format(execution_date)) \
        .config("spark.sql.adaptive.enabled", "true") \
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true") \
        .config("spark.sql.sources.partitionOverwriteMode", "dynamic") \
        .getOrCreate()

    print("[H8S-DP] Spark Session connected to YARN (Client Mode)")
    print("[H8S-DP] Input:  {}".format(input_path))
    print("[H8S-DP] Output: {}".format(output_path))
    print("[H8S-DP] Batch Date: {}".format(execution_date))

    # -------------------------------------------------------------------
    # 1. 데이터 읽기 (CSV → DataFrame)
    # -------------------------------------------------------------------
    schema = StructType([
        StructField("거래번호", StringType(), False),
        StructField("거래일자", StringType(), False),
        StructField("계정과목", StringType(), True),
        StructField("거래처", StringType(), True),
        StructField("금액", LongType(), True),
        StructField("적요", StringType(), True),
        StructField("담당자", StringType(), True),
        StructField("승인자", StringType(), True),
        StructField("이상여부", LongType(), True),
        StructField("이상유형", StringType(), True),
    ])

    raw_df = spark.read.csv(input_path, schema=schema, header=True)

    raw_df = raw_df.filter(col("거래일자") == execution_date)

    row_count = raw_df.count()
    print("[H8S-DP] Raw data loaded: {} rows for date {}".format(
        row_count, execution_date))

    if row_count == 0:
        print("[H8S-DP] No data for date {} — skip write".format(execution_date))
        spark.stop()
        return

    # -------------------------------------------------------------------
    # 2. 데이터 정제 및 변환
    # -------------------------------------------------------------------
    cleaned_df = raw_df \
        .withColumn("거래일자", col("거래일자").cast(DateType())) \
        .fillna({"금액": 0, "이상여부": 0})

    # -------------------------------------------------------------------
    # 3. FDS 로직 - 이상 거래 필터링 및 Flagging
    # -------------------------------------------------------------------
    # (향후 ML 모델 연동 가능 지점)
    anomaly_df = cleaned_df.withColumn(
        "fds_flag",
        col("이상여부").cast("int")
    )

    # -------------------------------------------------------------------
    # 4. 결과 저장 (HDFS Parquet, 거래일자 기준 파티셔닝)
    # -------------------------------------------------------------------
    anomaly_df.write \
        .mode("overwrite") \
        .partitionBy("거래일자") \
        .parquet(output_path)

    print("[H8S-DP] FDS Processing Complete -> {}".format(output_path))
    spark.stop()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="H8S-DP Accounting FDS Job on YARN via Livy"
    )
    parser.add_argument(
        "--input",
        default="hdfs://namenode:9820/user/hive/warehouse/raw_accounting",
        help="HDFS input path for raw accounting data"
    )
    parser.add_argument(
        "--output",
        default="hdfs://namenode:9820/user/airflow/warehouse/fact_accounting",
        help="HDFS output path for Parquet results"
    )
    parser.add_argument(
        "--date",
        default=datetime.now().strftime("%Y-%m-%d"),
        help="Execution date (YYYY-MM-DD)"
    )
    args = parser.parse_args()

    run_fds_job(
        input_path=args.input,
        output_path=args.output,
        execution_date=args.date,
    )
EOF

git add dags/spark_jobs/accounting_fds_job_k8s.py
git commit --allow-empty -m 'feat(spark): K8s Spark Job 추가 (argparse 기반 날짜 필터링)'

echo "  [C19] fix/livy-polling branch"
git checkout -b fix/livy-polling feat/k8s-dag
cat << 'EOF' > dags/accounting_fds_pipeline_k8s.py
"""
H8S-DP: K8s KubernetesExecutor 기반 회계 FDS 파이프라인
========================================================
LivyOperator (polling) + WebHDFS 검증 기반
"""
from datetime import datetime, timedelta
import os

import requests

from airflow.decorators import dag, task
from airflow.providers.apache.livy.operators.livy import LivyOperator

LIVY_CONN_ID = "livy_default"

DOCKER_HOST_IP = os.environ.get("DOCKER_HOST_IP", "172.18.0.1")
WEBHDFS_BASE = f"http://{DOCKER_HOST_IP}:9870/webhdfs/v1"

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}


@dag(
    dag_id='accounting_anomaly_detection_v2_k8s',
    default_args=default_args,
    description='H8S-DP',
    start_date=datetime(2026, 7, 1),
    schedule='@daily',
    catchup=False,
    tags=['h8s-dp'],
)
def accounting_fds_hybrid_dag():

    submit_batch = LivyOperator(
        task_id='submit_fds_batch',
        livy_conn_id=LIVY_CONN_ID,
        file=(
            "hdfs://" + DOCKER_HOST_IP
            + ":9820/user/airflow/spark_jobs/accounting_fds_job_k8s.py"
        ),
        args=[
            "--input",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/hive/warehouse/raw_accounting",
            "--output",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/airflow/warehouse/fact_accounting",
            "--date",
            "{{ ds }}",
        ],
        conf={
            "spark.executor.memory": "1024m",
            "spark.driver.memory": "1024m",
        },
        name="fds_{{ ds_nodash }}",
        polling_interval=30,
    )

    @task(task_id='verify_fds_output')
    def verify_output(**context):
        url = f"{WEBHDFS_BASE}/user/airflow/warehouse/fact_accounting?op=LISTSTATUS"
        resp = requests.get(url, allow_redirects=True, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        dirs = data.get("FileStatuses", {}).get("FileStatus", [])
        count = len(dirs)
        print(f"{count} partitions found")
        if count == 0:
            raise ValueError("No output partitions found")
        return count

    verify = verify_output()

    @task(task_id='export_to_local')
    def export_to_local(**context):
        ds = context["ds"]
        hdfs_dir = f"/user/airflow/warehouse/fact_accounting/거래일자={ds}"

        list_url = f"{WEBHDFS_BASE}{hdfs_dir}?op=LISTSTATUS"
        resp = requests.get(list_url, allow_redirects=True, timeout=30)

        if resp.status_code == 404:
            print(f"Partition {ds} not found — skipping export")
            return f"skipped:{ds}"

        resp.raise_for_status()
        print(f"Export task registered for partition {ds}")
        return f"exported:{ds}"

    export = export_to_local()

    submit_batch >> verify >> export


dag_instance = accounting_fds_hybrid_dag()
EOF

git add dags/accounting_fds_pipeline_k8s.py
git commit --allow-empty -m 'fix(livy): LivyOperator polling_interval 0→30 변경

[에러 현상] submit_fds_batch intermittently fails
[원인 가설] polling_interval=0 skips status polling; Spark failure on YARN not detected
[해결 방향] Set polling_interval=30 — polls batch status every 30s until completion'

git checkout feat/k8s-dag
git merge fix/livy-polling --no-ff -m 'merge: fix/livy-polling 병합'
echo "  [C20] fix/start-date branch"
git checkout -b fix/start-date feat/k8s-dag
cat << 'EOF' > dags/accounting_fds_pipeline_k8s.py
"""
H8S-DP: K8s KubernetesExecutor 기반 회계 FDS 파이프라인
========================================================
LivyOperator (polling) + WebHDFS 검증 기반
"""
from datetime import datetime, timedelta
import os

import requests

from airflow.decorators import dag, task
from airflow.providers.apache.livy.operators.livy import LivyOperator

LIVY_CONN_ID = "livy_default"

DOCKER_HOST_IP = os.environ.get("DOCKER_HOST_IP", "172.18.0.1")
WEBHDFS_BASE = f"http://{DOCKER_HOST_IP}:9870/webhdfs/v1"

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}


@dag(
    dag_id='accounting_anomaly_detection_v2_k8s',
    default_args=default_args,
    description='H8S-DP',
    start_date=datetime(2024, 12, 30),
    schedule='@daily',
    catchup=False,
    tags=['h8s-dp'],
)
def accounting_fds_hybrid_dag():

    submit_batch = LivyOperator(
        task_id='submit_fds_batch',
        livy_conn_id=LIVY_CONN_ID,
        file=(
            "hdfs://" + DOCKER_HOST_IP
            + ":9820/user/airflow/spark_jobs/accounting_fds_job_k8s.py"
        ),
        args=[
            "--input",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/hive/warehouse/raw_accounting",
            "--output",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/airflow/warehouse/fact_accounting",
            "--date",
            "{{ ds }}",
        ],
        conf={
            "spark.executor.memory": "1024m",
            "spark.driver.memory": "1024m",
        },
        name="fds_{{ ds_nodash }}",
        polling_interval=30,
    )

    @task(task_id='verify_fds_output')
    def verify_output(**context):
        url = f"{WEBHDFS_BASE}/user/airflow/warehouse/fact_accounting?op=LISTSTATUS"
        resp = requests.get(url, allow_redirects=True, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        dirs = data.get("FileStatuses", {}).get("FileStatus", [])
        count = len(dirs)
        print(f"{count} partitions found")
        if count == 0:
            raise ValueError("No output partitions found")
        return count

    verify = verify_output()

    @task(task_id='export_to_local')
    def export_to_local(**context):
        ds = context["ds"]
        hdfs_dir = f"/user/airflow/warehouse/fact_accounting/거래일자={ds}"

        list_url = f"{WEBHDFS_BASE}{hdfs_dir}?op=LISTSTATUS"
        resp = requests.get(list_url, allow_redirects=True, timeout=30)

        if resp.status_code == 404:
            print(f"Partition {ds} not found — skipping export")
            return f"skipped:{ds}"

        resp.raise_for_status()
        print(f"Export task registered for partition {ds}")
        return f"exported:{ds}"

    export = export_to_local()

    submit_batch >> verify >> export


dag_instance = accounting_fds_hybrid_dag()
EOF

git add dags/accounting_fds_pipeline_k8s.py
git commit --allow-empty -m 'fix(dag): start_date 2026→2024 수정 (히스토리 트리거 대응)

[에러 현상] DAG trigger with historical logical_date not recognized
[원인 가설] start_date=2026-07-01 is after historical logical_date
[해결 방향] Change start_date to 2024-12-30 for all historical data triggers'

git checkout feat/k8s-dag
git merge fix/start-date --no-ff -m 'merge: fix/start-date 병합'
echo "  [C21] fix/trigger-mcp branch"
git checkout -b fix/trigger-mcp feat/k8s-dag
cat << 'EOF' > dags/accounting_fds_pipeline_k8s.py
"""
H8S-DP: K8s KubernetesExecutor 기반 회계 FDS 파이프라인
========================================================
LivyOperator (polling) + WebHDFS 검증 기반
"""
from datetime import datetime, timedelta
import os

import requests

from airflow.decorators import dag, task
from airflow.providers.apache.livy.operators.livy import LivyOperator

LIVY_CONN_ID = "livy_default"

DOCKER_HOST_IP = os.environ.get("DOCKER_HOST_IP", "172.18.0.1")
WEBHDFS_BASE = f"http://{DOCKER_HOST_IP}:9870/webhdfs/v1"

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}


@dag(
    dag_id='accounting_anomaly_detection_v2_k8s',
    default_args=default_args,
    description='H8S-DP',
    start_date=datetime(2024, 12, 30),
    schedule='@daily',
    catchup=False,
    tags=['h8s-dp'],
)
def accounting_fds_hybrid_dag():

    submit_batch = LivyOperator(
        task_id='submit_fds_batch',
        livy_conn_id=LIVY_CONN_ID,
        file=(
            "hdfs://" + DOCKER_HOST_IP
            + ":9820/user/airflow/spark_jobs/accounting_fds_job_k8s.py"
        ),
        args=[
            "--input",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/hive/warehouse/raw_accounting",
            "--output",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/airflow/warehouse/fact_accounting",
            "--date",
            "{{ dag_run.conf.get('logical_date', ds) }}",
        ],
        conf={
            "spark.executor.memory": "1024m",
            "spark.driver.memory": "1024m",
        },
        name="fds_{{ dag_run.conf.get('logical_date', ds_nodash) }}",
        polling_interval=30,
    )

    @task(task_id='verify_fds_output')
    def verify_output(**context):
        url = f"{WEBHDFS_BASE}/user/airflow/warehouse/fact_accounting?op=LISTSTATUS"
        resp = requests.get(url, allow_redirects=True, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        dirs = data.get("FileStatuses", {}).get("FileStatus", [])
        count = len(dirs)
        print(f"{count} partitions found")
        if count == 0:
            raise ValueError("No output partitions found")
        return count

    verify = verify_output()

    @task(task_id='export_to_local')
    def export_to_local(**context):
        ds = context["ds"]
        hdfs_dir = f"/user/airflow/warehouse/fact_accounting/거래일자={ds}"

        list_url = f"{WEBHDFS_BASE}{hdfs_dir}?op=LISTSTATUS"
        resp = requests.get(list_url, allow_redirects=True, timeout=30)

        if resp.status_code == 404:
            print(f"Partition {ds} not found — skipping export")
            return f"skipped:{ds}"

        resp.raise_for_status()
        print(f"Export task registered for partition {ds}")
        return f"exported:{ds}"

    export = export_to_local()

    submit_batch >> verify >> export


dag_instance = accounting_fds_hybrid_dag()
EOF

git add dags/accounting_fds_pipeline_k8s.py
git commit --allow-empty -m 'fix(trigger): DAG conf fallback 추가 (logical_date 파라미터)

[에러 현상] MCP trigger without dag_run.conf causes empty --date argument
[원인 가설] dag_run.conf is empty dict; {{ dag_run.conf.logical_date }} returns None
[해결 방향] Use dag_run.conf.get(logical_date, ds) Jinja fallback'

git checkout feat/k8s-dag
git merge fix/trigger-mcp --no-ff -m 'merge: fix/trigger-mcp 병합'
git checkout "${BASE_BRANCH}"
git merge feat/k8s-dag --no-ff -m 'merge: feat/k8s-dag 병합'
echo "[STEP 7] feat/webhdfs-export branch"
git checkout -b feat/webhdfs-export "${BASE_BRANCH}"

echo "  [C22] feat(export): add WebHDFS export_to_local @task"
cat << 'EOF' > dags/accounting_fds_pipeline_k8s.py
"""
H8S-DP: K8s KubernetesExecutor 기반 회계 FDS 파이프라인
========================================================
LivyOperator (polling) + WebHDFS 검증 기반
"""
from datetime import datetime, timedelta
import os

import requests

from airflow.decorators import dag, task
from airflow.providers.apache.livy.operators.livy import LivyOperator

LIVY_CONN_ID = "livy_default"

DOCKER_HOST_IP = os.environ.get("DOCKER_HOST_IP", "172.18.0.1")
WEBHDFS_BASE = f"http://{DOCKER_HOST_IP}:9870/webhdfs/v1"

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}


@dag(
    dag_id='accounting_anomaly_detection_v2_k8s',
    default_args=default_args,
    description='H8S-DP',
    start_date=datetime(2024, 12, 30),
    schedule='@daily',
    catchup=False,
    tags=['h8s-dp'],
)
def accounting_fds_hybrid_dag():

    submit_batch = LivyOperator(
        task_id='submit_fds_batch',
        livy_conn_id=LIVY_CONN_ID,
        file=(
            "hdfs://" + DOCKER_HOST_IP
            + ":9820/user/airflow/spark_jobs/accounting_fds_job_k8s.py"
        ),
        args=[
            "--input",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/hive/warehouse/raw_accounting",
            "--output",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/airflow/warehouse/fact_accounting",
            "--date",
            "{{ dag_run.conf.get('logical_date', ds) }}",
        ],
        conf={
            "spark.executor.memory": "1024m",
            "spark.driver.memory": "1024m",
        },
        name="fds_{{ dag_run.conf.get('logical_date', ds_nodash) }}",
        polling_interval=30,
    )

    @task(task_id='verify_fds_output')
    def verify_output(**context):
        url = f"{WEBHDFS_BASE}/user/airflow/warehouse/fact_accounting?op=LISTSTATUS"
        resp = requests.get(url, allow_redirects=True, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        dirs = data.get("FileStatuses", {}).get("FileStatus", [])
        count = len(dirs)
        print(f"{count} partitions found")
        if count == 0:
            raise ValueError("No output partitions found")
        return count

    verify = verify_output()

    @task(task_id='export_to_local')
    def export_to_local(**context):
        import shutil
        ds = context["ds"]
        dag_run = context.get("dag_run")
        if dag_run and dag_run.conf and dag_run.conf.get("logical_date"):
            ds = dag_run.conf["logical_date"]
        hdfs_dir = f"/user/airflow/warehouse/fact_accounting/거래일자={ds}"
        local_dir = f"/opt/airflow/exported_data/fact_accounting/거래일자={ds}"

        list_url = f"{WEBHDFS_BASE}{hdfs_dir}?op=LISTSTATUS"
        resp = requests.get(list_url, allow_redirects=True, timeout=30)

        if resp.status_code == 404:
            print(f"Partition {ds} not found — skipping export")
            return f"skipped:{ds}"

        resp.raise_for_status()
        files = resp.json().get("FileStatuses", {}).get("FileStatus", [])

        parquet_files = [f for f in files if f["pathSuffix"].endswith(".parquet")]
        if not parquet_files:
            print(f"No parquet files in partition {ds} — skipping export")
            return f"empty:{ds}"

        os.makedirs(local_dir, exist_ok=True)

        for f in parquet_files:
            fname = f["pathSuffix"]
            local_path = os.path.join(local_dir, fname)
            download_url = f"{WEBHDFS_BASE}{hdfs_dir}/{fname}?op=OPEN"
            with requests.get(download_url, stream=True, timeout=60) as r:
                r.raise_for_status()
                with open(local_path, "wb") as out:
                    shutil.copyfileobj(r.raw, out)
            print(f"  downloaded: {fname}")

        print(f"Exported {len(parquet_files)} files to {local_dir}")
        return local_dir

    export = export_to_local()

    submit_batch >> verify >> export


dag_instance = accounting_fds_hybrid_dag()
EOF

git add dags/accounting_fds_pipeline_k8s.py
git commit --allow-empty -m 'feat(export): WebHDFS 기반 export_to_local @task 추가'

echo "  [C23] chore(config): add hdfs-site.xml"
cat << 'EOF' > hadoop-conf/hdfs-site.xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>dfs.client.use.datanode.hostname</name>
        <value>true</value>
    </property>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
</configuration>
EOF

git add hadoop-conf/hdfs-site.xml
git commit --allow-empty -m 'chore(config): hdfs-site.xml 추가 (dfs.client.use.datanode.hostname)'

echo "  [C24] fix/webhdfs-dns branch"
git checkout -b fix/webhdfs-dns feat/webhdfs-export
cat << 'EOF' > dags/accounting_fds_pipeline_k8s.py
"""
H8S-DP: K8s KubernetesExecutor 기반 회계 FDS 파이프라인
========================================================
LivyOperator (polling) + WebHDFS 검증 기반
"""
from datetime import datetime, timedelta
import os

import requests

from airflow.decorators import dag, task
from airflow.providers.apache.livy.operators.livy import LivyOperator

LIVY_CONN_ID = "livy_default"

DOCKER_HOST_IP = os.environ.get("DOCKER_HOST_IP", "172.18.0.1")
WEBHDFS_BASE = f"http://{DOCKER_HOST_IP}:9870/webhdfs/v1"

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}


@dag(
    dag_id='accounting_anomaly_detection_v2_k8s',
    default_args=default_args,
    description='H8S-DP',
    start_date=datetime(2024, 12, 30),
    schedule='@daily',
    catchup=False,
    tags=['h8s-dp'],
)
def accounting_fds_hybrid_dag():

    submit_batch = LivyOperator(
        task_id='submit_fds_batch',
        livy_conn_id=LIVY_CONN_ID,
        file=(
            "hdfs://" + DOCKER_HOST_IP
            + ":9820/user/airflow/spark_jobs/accounting_fds_job_k8s.py"
        ),
        args=[
            "--input",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/hive/warehouse/raw_accounting",
            "--output",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/airflow/warehouse/fact_accounting",
            "--date",
            "{{ dag_run.conf.get('logical_date', ds) }}",
        ],
        conf={
            "spark.executor.memory": "1024m",
            "spark.driver.memory": "1024m",
        },
        name="fds_{{ dag_run.conf.get('logical_date', ds_nodash) }}",
        polling_interval=30,
    )

    @task(task_id='verify_fds_output')
    def verify_output(**context):
        url = f"{WEBHDFS_BASE}/user/airflow/warehouse/fact_accounting?op=LISTSTATUS"
        resp = requests.get(url, allow_redirects=True, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        dirs = data.get("FileStatuses", {}).get("FileStatus", [])
        count = len(dirs)
        print(f"{count} partitions found")
        if count == 0:
            raise ValueError("No output partitions found")
        return count

    verify = verify_output()

    @task(task_id='export_to_local')
    def export_to_local(**context):
        import shutil
        ds = context["ds"]
        dag_run = context.get("dag_run")
        if dag_run and dag_run.conf and dag_run.conf.get("logical_date"):
            ds = dag_run.conf["logical_date"]
        hdfs_dir = f"/user/airflow/warehouse/fact_accounting/거래일자={ds}"
        local_dir = f"/opt/airflow/exported_data/fact_accounting/거래일자={ds}"

        list_url = f"{WEBHDFS_BASE}{hdfs_dir}?op=LISTSTATUS"
        resp = requests.get(list_url, allow_redirects=True, timeout=30)

        if resp.status_code == 404:
            print(f"Partition {ds} not found — skipping export")
            return f"skipped:{ds}"

        resp.raise_for_status()
        files = resp.json().get("FileStatuses", {}).get("FileStatus", [])

        parquet_files = [f for f in files if f["pathSuffix"].endswith(".parquet")]
        if not parquet_files:
            print(f"No parquet files in partition {ds} — skipping export")
            return f"empty:{ds}"

        os.makedirs(local_dir, exist_ok=True)

        for f in parquet_files:
            fname = f["pathSuffix"]
            local_path = os.path.join(local_dir, fname)
            download_url = f"{WEBHDFS_BASE}{hdfs_dir}/{fname}?op=OPEN"
            with requests.get(download_url, stream=True, timeout=60, allow_redirects=False) as resp:
                if resp.status_code in (307, 302):
                    from urllib.parse import urlparse, urlunparse
                    redirect_url = resp.headers.get("Location", "")
                    parsed = urlparse(redirect_url)
                    new_netloc = f"{DOCKER_HOST_IP}:{parsed.port or 9864}"
                    redirect_url = urlunparse(parsed._replace(netloc=new_netloc))
                    r = requests.get(redirect_url, stream=True, timeout=60)
                else:
                    r = resp
                r.raise_for_status()
                with open(local_path, "wb") as out:
                    shutil.copyfileobj(r.raw, out)
            print(f"  downloaded: {fname}")

        print(f"Exported {len(parquet_files)} files to {local_dir}")
        return local_dir

    export = export_to_local()

    submit_batch >> verify >> export


dag_instance = accounting_fds_hybrid_dag()
EOF

git add dags/accounting_fds_pipeline_k8s.py
git commit --allow-empty -m 'fix(webhdfs): DataNode 리다이렉트 URL 재작성 구현 (DNS 해결)

[에러 현상] export_to_local fails - DataNode hostname not resolvable from K8s Pod DNS
[원인 가설] WebHDFS OPEN returns HTTP 307 redirect with DataNode hostname
[해결 방향] allow_redirects=False, parse Location header, replace hostname with DOCKER_HOST_IP'

git checkout feat/webhdfs-export
git merge fix/webhdfs-dns --no-ff -m 'merge: fix/webhdfs-dns 병합'
git checkout "${BASE_BRANCH}"
git merge feat/webhdfs-export --no-ff -m 'merge: feat/webhdfs-export 병합'
echo "[STEP 8] feat/deploy-scripts branch"
git checkout -b feat/deploy-scripts "${BASE_BRANCH}"

echo "  [C25] ci(deploy): add deploy_spark_jobs.sh"
cat << 'EOF' > dags/deploy_spark_jobs.sh
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
EOF

chmod +x dags/deploy_spark_jobs.sh
git add dags/deploy_spark_jobs.sh
git commit --allow-empty -m 'ci(deploy): deploy_spark_jobs.sh 추가 (HDFS 업로드)'

echo "  [C26] test(verify): add verify-deployment.sh"
cat << 'EOF' > verify-deployment.sh
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
EOF

chmod +x verify-deployment.sh
git add verify-deployment.sh
git commit --allow-empty -m 'test(verify): verify-deployment.sh 추가 (7단계 배포 검증)'

echo "  Additional: add __init__.py, .airflowignore, .env"
cat << 'EOF' > dags/__init__.py
# H8S-DP: Airflow DAGs Package
# 이 파일은 Airflow가 dags 디렉토리를 Python 패키지로 인식하도록 합니다.
EOF

cat << 'EOF' > dags/.airflowignore
..*
*.pyc
__pycache__
EOF

cat << 'EOF' > .env
AIRFLOW_UID=1000
AIRFLOW_GID=0
EOF

git add dags/__init__.py
git add dags/.airflowignore
git add -f .env
git commit --allow-empty -m 'chore: DAGs 패키지 init, .airflowignore, .env 추가'

echo "  Additional: add hadoop-configmap.yaml alias"
cp helm/airflow/templates/hadoop-configmap-generated.yaml helm/airflow/templates/hadoop-configmap.yaml
git add helm/airflow/templates/hadoop-configmap.yaml
git commit --allow-empty -m 'chore(k8s): hadoop-configmap.yaml alias 추가 (K8s 배포용)'

git checkout "${BASE_BRANCH}"
git merge feat/deploy-scripts --no-ff -m 'merge: feat/deploy-scripts 병합'
echo "[STEP 9] feat/docs branch"
git checkout -b feat/docs "${BASE_BRANCH}"

echo "  [C27] docs: add project documentation"
cat << 'EOF' > README.md
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
EOF

cat << 'EOF' > avante.md
# Hybrid Data Pipeline (H8S-DP) 구축을 위한 프로젝트 지침서

## 역할 (Your Role)
쿠버네티스(K8s), 아파치 하둡(Apache Hadoop), 아파치 스파크(Apache Spark), 아파치 에어플로우(Apache Airflow)에 특화된 데이터 엔지니어 및 인프라 아키텍트이다. 클라우드 네이티브 데이터 플랫폼 구축, 컨테이너 오케스트레이션, 이기종 클러스터 간 연동 분야에 깊은 전문성을 보유하고 있다.


## 미션 (Your Mission)
단일 호스트의 도커 컴포즈(Docker Compose) 기반 데이터 플랫폼을 고성능 하이브리드 데이터 파이프라인으로 전환하여 다음 사항을 달성한다.


- 오케스트레이션 레이어(제어부)와 스토리지/연산 레이어(데이터 처리부)의 철저한 분리
- 헬름 차트(Helm Chart)를 활용하여 쿠버네티스 클러스터 내부에 아파치 에어플로우 배포
- 작업 발생 시 워커 Pod를 동적으로 생성·소멸시키는 `KubernetesExecutor` 기반의 에어플로우 환경 구성
- 쿠버네티스 환경에서 외부 도커 기반 하둡/YARN 클러스터로 PySpark 작업을 제출하기 위한 원격 실행 브릿지(Apache Livy 또는 SSH) 구현
- 기존 하둡 저장소 및 연산 설정의 변경을 최소화하여 시스템 안정성 유지


## 프로젝트 컨텍스트 (Project Context)
이 프로젝트는 기존 도커 기반 HDFS, YARN, PySpark 데이터 마트 파이프라인을 토스(Toss) 등 대형 IT 기업의 아키텍처를 벤치마킹한 하이브리드 구조로 고도화하는 것을 목표로 한다. 쿠버네티스 영역에서는 오케스트레이션을 유연하게 확장하고, 실제 무거운 연산은 격리된 외부 하둡 자원을 활용하도록 설계하여 데이터 인프라 현대화 역량을 증명한다.


## 기술 스택 (Technology Stack)

- **오케스트레이션 (K8s 클러스터):** Kubernetes, Apache Airflow 2.x (Helm 배포), `KubernetesExecutor`
- **연산 및 스토리지 (도커 환경):** Apache Hadoop 3.x (HDFS, YARN), PySpark 3.x, Apache Livy (또는 SSH 게이트웨이)
- **배포 및 인프라 관리:** Helm, Docker Compose, kubectl


## 코딩 및 아키텍처 표준 (Coding & Architectural Standards)

- **코드 기반 인프라 관리:** 모든 쿠버네티스 Manifest 파일과 Helm Value 설정 파일(values.yaml)은 형상 관리가 가능하도록 작성한다.
- **리소스 무상태성(Stateless):** 에어플로우 워커 Pod는 상태를 가지지 않으며, 작업 완료 즉시 소멸되도록 생명주기를 관리한다.
- **역할의 엄격한 분리:** 에어플로우 Pod 내부에서 무거운 스파크 실행 프로세스를 직접 구동하거나 데이터를 영구 저장하지 않으며, 모든 연산 부하는 외부 YARN 클러스터로 위임한다.
- **보안 및 네트워크 연동:** 쿠버네티스 네임스페이스와 외부 도커 브리지 네트워크 간의 통신 경로 및 포트 포워딩 설정을 명확히 기술한다.


# # 출력 언어 및 사고 과정 제약 조건

- **사고 과정(CoT):** 모든 내부 추론, 분석 및 사고 과정은 한국어로만 작성하고 제출해야 합니다.
- **최종 답변:** 최종 답변, 설명 및 코드 주석은 반드시 한국어로만 제출해야 합니다.
- **예외:** 전문 용어, API 이름 및 코드 구문은 원문의 영어 형태를 유지할 수 있습니다.
EOF

cat << 'EOF' > implementation-plan.md
# H8S-DP: KubernetesExecutor 전환 구현 계획 v2

**Project:** KAN @ https://lionsi24816.atlassian.net/
**Date:** 2026-07-17
**Updated:** 2026-07-17 (Context7 MCP 최신 문서 반영)
**Scope:** LocalExecutor → KubernetesExecutor + LivyOperator + WebHDFS 검증 + Parquet Export

---

## Summary

| Metric | Value |
|--------|-------|
| **Project** | KAN (Jira) |
| **Total Tickets** | 7 (기존) + 0 (신규) |
| **Total Story Points** | 21 |
| **Overall Complexity** | Medium |
| **Execution Waves** | 4 |
| **Key Dependencies** | Custom Airflow Image → Helm Deploy → DAG Migration → Stabilization |

---

## Completion Status

| Ticket | Summary | Status | Completed Date | Notes |
|--------|---------|--------|----------------|-------|
| KAN-7 | Custom Airflow Image 빌드 | ✅ 완료 | 2026-07-17 | Dockerfile + Java 17 + Livy/HDFS Providers |
| KAN-2 | Airflow Connections Secret 생성 | ✅ 완료 | 2026-07-17 | env vars로 대체 |
| KAN-4 | Helm values.yaml KubernetesExecutor 전환 | ✅ 완료 | 2026-07-17 | Executor, apiServer, ConfigMaps |
| KAN-5 | DAG 재작성 (LivyOperator) | ⚠️ 부분 완료 | 2026-07-17 | LivyOperator 도입 완료, 안정화 필요 |
| KAN-3 | network-setup.sh 개선 | ✅ 완료 | 2026-07-17 | DAG ConfigMap + IP 치환 |
| KAN-1 | verify-deployment.sh 업데이트 | ✅ 완료 | 2026-07-17 | YAML, Provider, Connection 검증 |
| KAN-6 | 통합 검증 및 종단 테스트 | 🔴 진행 중 | - | submit_fds_batch 실패 디버깅 중 |

---

## Execution Order (Topologically Sorted) — Updated

| # | Ticket | Summary | Points | Risk | Status |
|---|--------|---------|--------|------|--------|
| 1 | KAN-7 | Custom Airflow Image 빌드 | 3 | Low | ✅ 완료 |
| 2 | KAN-2 | Airflow Connections Secret | 2 | Low | ✅ 완료 |
| 3 | KAN-4 | Helm values.yaml K8s Executor | 3 | Medium | ✅ 완료 |
| 4 | KAN-5 | DAG 재작성 (LivyOperator) | 5 | Medium | ⚠️ 부분 완료 |
| 5 | KAN-3 | network-setup.sh 개선 | 3 | Low | ✅ 완료 |
| 6 | KAN-1 | verify-deployment.sh 업데이트 | 2 | Low | ✅ 완료 |
| 7 | KAN-6 | 통합 검증 및 종단 테스트 | 3 | High | 🔴 진행 중 |

---

## Phase 4: Stabilization & Hardening (Current Focus)

### 현재 상황 (2026-07-17 13:06 기준)

**DAG 구조 (최종):**
```
submit_fds_batch (LivyOperator, polling_interval=30)
       ↓
verify_fds_output (@task, WebHDFS LISTSTATUS)
       ↓
export_to_local (@task, WebHDFS OPEN → hostPath)
```

**식별된 문제점:**

| # | 문제 | 심각도 | 상태 |
|---|------|--------|------|
| P1 | `submit_fds_batch` 4회 retry 실패 (마지막 run) | 🔴 Critical | 디버깅 중 |
| P2 | `trigger_rule='all_done'` → upstream 실패 시에도 downstream 실행 | 🟠 High | 수정 필요 |
| P3 | `delete_worker_pods: True` → worker pod 로그 소멸로 디버깅 불가 | 🟠 High | 개발 중 False 권장 |
| P4 | `export_to_local` hostPath 권한 (root 소유, UID 50000 쓰기 불가) | 🟡 Medium | 해결됨 (chmod) |
| P5 | AGENTS.md가 실제 구현과 불일치 (LivySensor, WebHDFSHook) | 🟡 Medium | 업데이트 필요 |
| P6 | Airflow Helm Chart 1.20.0+ `workers.*` → `workers.kubernetes.*` 마이그레이션 | 🟢 Low | 예방적 조치 |

---

### P1: submit_fds_batch 실패 분석

**증상:**
- LivyOperator가 batch를 제출하지만 Spark job 실행 중 실패
- `delete_worker_pods: True`로 인해 worker pod 로그 소멸
- Livy REST API (`:8998`)는 정상 응답 (200 OK)
- 이전 run에서는 `submit_fds_batch` 성공 → `wait_fds_batch` 성공 → 검증 성공 기록 있음

**가능한 원인:**
1. Livy batch 제출 후 Spark job이 YARN에서 OOM 또는 리소스 부족으로 실패
2. LivyOperator의 `polling_interval=30` 내에서 batch 완료를 감지하지 못하고 timeout
3. Worker pod의 네트워크가 Docker bridge로 연결되지 않음 (간헐적)
4. HDFS 경로의 데이터가 존재하지 않음 (raw_accounting에 데이터 없음)

**디버깅 접근법 (Context7 기반):**
```python
# Context7 문서 권장: deferrable 모드로 전환
# - polling_interval 대신 deferrable=True 사용
# - triggerer가 비동기로 polling → worker 리소스 효율적 사용
submit_batch = LivyOperator(
    task_id='submit_fds_batch',
    livy_conn_id=LIVY_CONN_ID,
    file=...,
    args=...,
    conf=...,
    name="fds_{{ ds_nodash }}",
    deferrable=True,        # polling_interval 대신
    polling_interval=30,     # triggerer가 이 간격으로 polling
)
```

**우선 조치:**
1. `delete_worker_pods: False`로 설정 (디버깅용)
2. Worker pod 로그 직접 확인: `kubectl logs -n airflow <worker-pod>`
3. Livy WebUI (`http://172.18.0.1:8998/ui`)에서 batch 상태 직접 확인
4. YARN ResourceManager (`http://172.18.0.1:8088`)에서 Spark application 로그 확인

---

### P2: trigger_rule 버그 수정

**현재 코드 (버그):**
```python
@task(task_id='verify_fds_output', trigger_rule='all_done')
@task(task_id='export_to_local', trigger_rule='all_done')
```

**문제:** `all_done`은 upstream의 성공/실패와 관계없이 실행됨.
`submit_fds_batch` 실패 시에도 검증과 export가 실행되어 잘못된 결과 반환.

**수정:**
```python
# 기본값 'all_success' 사용 — upstream 모두 성공 시에만 실행
@task(task_id='verify_fds_output')
def verify_output(**context): ...

@task(task_id='export_to_local', trigger_rule='all_success')
def export_to_local(**context): ...
```

---

### P3: delete_worker_pods 권장사항

**Context7 문서 기준 Airflow 3.x 권장사항:**
- 개발/디버깅: `delete_worker_pods: False`
- 프로덕션: `delete_worker_pods: True` (리소스 누수 방지)

**values.yaml 수정:**
```yaml
config:
  kubernetes:
    delete_worker_pods: "False"  # 개발 중 False 권장
```

---

### P4: hostPath 권한 (해결됨)

```bash
# Kind 노드에서 hostPath 디렉토리 생성 및 권한 설정
docker exec airflow-control-plane mkdir -p /opt/airflow-exported
docker exec airflow-control-plane chmod 777 /opt/airflow-exported
```

---

### P5: AGENTS.md 동기화

실제 구현과 AGENTS.md 참조 코드의 불일치:

| 항목 | AGENTS.md (참조) | 실제 코드 |
|------|------------------|-----------|
| LivySensor | 사용 | 사용 안 함 (`polling_interval=30`) |
| WebHDFSHook | 사용 | 미사용 (`requests` 직접 호출) |
| `list_status()` | 호출 | `GET /webhdfs/v1/...?op=LISTSTATUS` |
| LivySensor `batch_id` | XCom pull | 필요 없음 |
| DAG 구조 | submit → wait → verify | submit → verify → export |

AGENTS.md 업데이트 필요 항목:
1. DAG Reference 코드를 실제 구현과 일치시킴
2. `polling_interval=30` 패턴 문서화
3. `requests` 기반 WebHDFS 접근 패턴 문서화
4. `trigger_rule='all_done'` → `all_success` 수정 사유 기록

---

### P6: Airflow Helm Chart 1.20.0+ Breaking Changes

**Context7 문서 발견사항 (2026-03-16 Release):**

> `workers` specific sections have been moved to `workers.celery` / `workers.kubernetes` sections.

**영향:** 현재 `values.yaml`에 `workers.*` 키가 없으므로 **즉시 영향 없음**. 다만 향후 worker pod template 커스터마이징 시 주의.

**참고 — 공식 Helm Chart `apiServer` 설정 (Context7 기준):**
```yaml
apiServer:
  service:
    type: ClusterIP  # 기본값, 우리는 NodePort로 override
```

---

## Phase 5: Advanced Enhancements (Backlog)

| # | 항목 | Points | 설명 |
|---|------|--------|------|
| E1 | LivyOperator `deferrable=True` 전환 | 2 | triggerer 활용, worker 리소스 효율화 |
| E2 | Spark job `--date` 필터링 최적화 | 3 | 원천 데이터 필터링으로 처리량 감소 |
| E3 | Worker pod resource limits 명시 | 1 | `workers.kubernetes.*` 섹션 활용 |
| E4 | DAG alerting (Slack/Email on failure) | 2 | 실패 시 알림 |
| E5 | Grafana + Prometheus 모니터링 | 3 | Livy/YARN 메트릭 대시보드 |

---

## Parallel Execution Strategy

### Wave 1: Foundation (5 pts) — ✅ 완료

| Ticket | Summary | Points | Status |
|--------|---------|--------|--------|
| KAN-7 | Custom Airflow Image 빌드 | 3 | ✅ |
| KAN-2 | Airflow Connections Secret | 2 | ✅ |

### Wave 2: Core Migration (11 pts) — ✅ 완료

| Ticket | Summary | Points | Status |
|--------|---------|--------|--------|
| KAN-4 | Helm values.yaml K8s Executor | 3 | ✅ |
| KAN-5 | DAG 재작성 (LivyOperator) | 5 | ⚠️ |
| KAN-3 | network-setup.sh 개선 | 3 | ✅ |

### Wave 3: Verification (5 pts) — ✅ 완료

| Ticket | Summary | Points | Status |
|--------|---------|--------|--------|
| KAN-1 | verify-deployment.sh 업데이트 | 2 | ✅ |
| KAN-6 | 통합 검증 및 종단 테스트 | 3 | 🔴 |

### Wave 4: Stabilization (8 pts) — 🔴 진행 중

| # | Task | Points | Priority |
|---|------|--------|----------|
| S1 | P1 디버깅: submit_fds_batch 실패 원인 파악 | 2 | Critical |
| S2 | P2 수정: trigger_rule all_done → all_success | 1 | High |
| S3 | P3 수정: delete_worker_pods False (디버깅) | 1 | High |
| S4 | P5 수정: AGENTS.md 실제 구현과 동기화 | 2 | Medium |
| S5 | 종단 테스트: 모든 task 성공 확인 | 2 | Critical |

---

## Agent Recommendations

| Work Type | Recommended Agent |
|-----------|-------------------|
| Docker 이미지 빌드 | devops-engineer |
| Helm/K8s 매니페스트 | kubernetes-specialist |
| Airflow DAG 작성/디버깅 | ml-pipeline |
| 네트워크/인프라 스크립트 | devops-engineer |
| Spark job 최적화 | spark-engineer |
| 검증/테스트 | ml-pipeline |

---

## Jira Tickets Status (KAN Project)

| Ticket | Summary | Status |
|--------|---------|--------|
| KAN-1 | verify-deployment.sh 업데이트 | ✅ 완료 |
| KAN-2 | Airflow Connections Secret 생성 | ✅ 완료 |
| KAN-3 | network-setup.sh 개선 | ✅ 완료 |
| KAN-4 | Helm values.yaml K8s Executor 전환 | ✅ 완료 |
| KAN-5 | DAG 재작성 (LivyOperator) | ⚠️ 진행 중 |
| KAN-6 | 통합 검증 및 종단 테스트 | 🔴 진행 중 |
| KAN-7 | Custom Airflow Image 빌드 | ✅ 완료 |

---

## Document Links

- **Repository:** `build_data_mart_with_airflow/`
- **Jira Project:** KAN @ https://lionsi24816.atlassian.net/
- **AGENTS.md:** `/home/ace/code/build_data_mart_with_airflow/AGENTS.md`
EOF

cat << 'EOF' > AGENTS.md
# H8S-DP: Hybrid Data Pipeline — AGENTS.md

## 출력 언어 (Output Language)

- **사고 과정(CoT)과 최종 답변은 한국어로 작성**합니다.
- 전문 용어, API 이름, 코드 구문은 원문 영어를 유지할 수 있습니다.

## Architecture

Hybrid: **Airflow on K8s** (KubernetesExecutor) + **Hadoop/YARN/HDFS/Livy on Docker** (separate host).

| Component | Version | Runtime |
|-----------|---------|---------|
| Apache Airflow | 3.2.2 | K8s (Helm chart 1.22.0) |
| Apache Spark (PySpark) | 3.4.1 | Docker YARN (via Livy) |
| Apache Hadoop (HDFS/YARN) | 3.2.1 | Docker |
| Apache Livy | 0.7.1 | Docker |
| PostgreSQL | 13 | Docker |

- **Control plane** (Airflow)과 **Data plane** (Hadoop/YARN/Spark)이 완전히 분리되어 있습니다.
- Airflow Worker Pod는 **무상태(stateless)** — 각 task 완료 후 자동 소멸됩니다.
- 모든 heavy Spark 연산은 Livy REST API (`:8998`)를 통해 **외부 Docker YARN 클러스터로 위임**됩니다.
- K8s ↔ Docker 간 네트워크 브릿지는 `network-setup.sh`가 Docker bridge gateway IP를 동적 감지하여 ConfigMap에 주입합니다.

### Architecture Diagram

```
                         Kubernetes Cluster
               ┌──────────────────────────────────────────┐
               │  Airflow (Helm)                          │
               │  ┌──────────┐  ┌──────────────────────┐ │
               │  │Scheduler │  │   Webserver          │ │
               │  │          │  │   NodePort :30080    │ │
               │  └────┬─────┘  └──────────────────────┘ │
               │       │                                  │
               │  KubernetesExecutor                      │
               │  ┌────▼────────────────────────────────┐ │
                │  │ Worker Pod (task 실행 시 동적 생성)  │ │
                │  │ • LivyOperator → POST /batches      │ │
                │  │ • PythonOperator + requests         │ │
                │  │ • Hadoop Config via ConfigMap       │ │
               │  └────────────────┬───────────────────┘ │
               └──────────────────┼──────────────────────┘
                                  │ REST API (Livy :8998)
                                  │ HDFS RPC (:9820)
            Docker Host           │
      ┌───────────────────────────┼──────────────────────────┐
      │  ┌────────────────────────▼────────────────────────┐ │
      │  │  livy-server (Livy 0.7.1)                      │ │
      │  │  Python 3.9 / Spark 3.4.1                      │ │
      │  │  HADOOP_CONF_DIR=/opt/livy/conf                │ │
      │  └────────────────────┬───────────────────────────┘ │
      │  ┌────────────────────▼───────────────────────────┐ │
      │  │  resourcemanager (YARN RM :8088)               │ │
      │  │  nodemanager (YARN NM :8042)                   │ │
      │  └────────────────────┬───────────────────────────┘ │
      │  ┌────────────────────▼───────────────────────────┐ │
      │  │  namenode (HDFS NN :9820, :9870)              │ │
      │  │  datanode (HDFS DN :9864)                     │ │
      │  └───────────────────────────────────────────────┘ │
      │  ┌───────────────────────────────────────────────┐ │
      │  │  postgres (:5432) — Airflow metadata DB       │ │
      │  └───────────────────────────────────────────────┘ │
      └──────────────────────────────────────────────────────┘
```

### Architectural Standards

- **IaC (Infrastructure as Code):** 모든 K8s Manifest 와 Helm values 파일은 코드로 관리됩니다.
- **무상태성 (Stateless):** Airflow Worker Pod는 상태를 가지지 않으며, `delete_worker_pods: True`로 task 완료 즉시 소멸됩니다.
- **역할 분리 (Separation of Concerns):** Airflow Pod 내에서 Spark를 직접 실행하지 않으며, 모든 연산은 LivyOperator를 통해 외부 YARN으로 위임합니다.
- **네트워크 보안:** K8s 네임스페이스와 Docker 브릿지 네트워크 간 통신 경로 및 포트 설정을 명확히 문서화합니다.

## Two deployment modes

| Mode | Orchestration | Compute | How to start |
|------|--------------|---------|--------------|
| **Legacy** (v1) | Docker Compose, LocalExecutor | SparkSubmitOperator (in-container) | `docker compose up -d` |
| **Hybrid** (v2, primary) | K8s Helm, KubernetesExecutor | LivyOperator → remote YARN | `docker compose -f hadoop-cluster.yml up -d` → `bash helm/network-setup.sh` → `helm install airflow ...` |

## Key files

| File | Purpose |
|------|---------|
| `dags/accounting_fds_pipeline_k8s.py` | **Active DAG** — LivyOperator + PythonOperator(requests WebHDFS) |
| `dags/accounting_fds_pipeline.py` | Legacy DAG — SparkSubmitOperator, kept for reference |
| `dags/spark_jobs/accounting_fds_job_k8s.py` | **Active Spark job** — argparse `--input`/`--output`/`--date`, runs on YARN via Livy |
| `dags/spark_jobs/accounting_fds_job.py` | Legacy Spark job, kept for reference |
| `hadoop-cluster.yml` | External Hadoop/YARN/Livy cluster (no Airflow) |
| `docker-compose.yml` | Legacy all-in-one stack (kept for reference) |
| `helm/airflow/values.yaml` | Airflow Helm values — `KubernetesExecutor`, Livy/HDFS connections, env vars |
| `helm/airflow/Dockerfile` | Custom Airflow image — includes Livy/HDFS providers + Java 11 |
| `helm/network-setup.sh` | Detects Docker host IP, creates K8s ConfigMap, updates values.yaml |
| `helm/airflow/templates/airflow-connections.yaml` | Secret for Livy + WebHDFS Airflow connections |

## Deployment order (hybrid mode)

```bash
# 1. Start external Hadoop cluster
docker compose -f hadoop-cluster.yml up -d

# 2. Detect Docker host IP & create K8s ConfigMap
bash helm/network-setup.sh

# 3. Build custom Airflow image with Livy/HDFS providers
docker build -t airflow-h8sdp:3.2.2 -f helm/airflow/Dockerfile .

# 4. Load image into kind cluster (if using kind)
kind load docker-image airflow-h8sdp:3.2.2 --name airflow-cluster

# 5. Deploy Airflow via Helm
helm repo add apache-airflow https://airflow.apache.org
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f helm/airflow/templates/hadoop-configmap-generated.yaml
kubectl apply -f helm/airflow/templates/external-db-secret.yaml
kubectl apply -f helm/airflow/templates/airflow-connections.yaml
helm upgrade --install airflow apache-airflow/airflow \
  -f helm/airflow/values.yaml --namespace airflow

# 6. Upload Spark jobs to HDFS
bash dags/deploy_spark_jobs.sh

# 7. Verify deployment
bash verify-deployment.sh
```

## DAG Pattern: LivyOperator (polling) + WebHDFS 검증 + Parquet Export

### Actual DAG structure (`dags/accounting_fds_pipeline_k8s.py`)

```python
"""
H8S-DP: K8s KubernetesExecutor 기반 회계 FDS 파이프라인
LivyOperator (polling) + WebHDFS 검증 기반
"""
from datetime import datetime, timedelta
import os

import requests

from airflow.decorators import dag, task
from airflow.providers.apache.livy.operators.livy import LivyOperator

LIVY_CONN_ID = "livy_default"

DOCKER_HOST_IP = os.environ.get("DOCKER_HOST_IP", "172.18.0.1")
WEBHDFS_BASE = f"http://{DOCKER_HOST_IP}:9870/webhdfs/v1"

default_args = {
    'owner': 'finops_admin',
    'depends_on_past': False,
    'retries': 2,
    'retry_delay': timedelta(minutes=5),
}

@dag(
    dag_id='accounting_anomaly_detection_v2_k8s',
    default_args=default_args,
    description='H8S-DP',
    start_date=datetime(2026, 7, 1),
    schedule='@daily',
    catchup=False,
    tags=['h8s-dp'],
)
def accounting_fds_hybrid_dag():

    submit_batch = LivyOperator(
        task_id='submit_fds_batch',
        livy_conn_id=LIVY_CONN_ID,
        file=(
            "hdfs://" + DOCKER_HOST_IP
            + ":9820/user/airflow/spark_jobs/accounting_fds_job_k8s.py"
        ),
        args=[
            "--input",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/hive/warehouse/raw_accounting",
            "--output",
            "hdfs://" + DOCKER_HOST_IP + ":9820/user/airflow/warehouse/fact_accounting",
            "--date",
            "{{ ds }}",
        ],
        conf={
            "spark.executor.memory": "1024m",
            "spark.driver.memory": "1024m",
        },
        name="fds_{{ ds_nodash }}",
        polling_interval=30,  # LivyOperator 자체가 polling 수행
    )

    @task(task_id='verify_fds_output')
    def verify_output(**context):
        url = f"{WEBHDFS_BASE}/user/airflow/warehouse/fact_accounting?op=LISTSTATUS"
        resp = requests.get(url, allow_redirects=True, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        dirs = data.get("FileStatuses", {}).get("FileStatus", [])
        count = len(dirs)
        print(f"{count} partitions found")
        if count == 0:
            raise ValueError("No output partitions found")
        return count

    verify = verify_output()

    @task(task_id='export_to_local')
    def export_to_local(**context):
        import shutil
        ds = context["ds"]
        hdfs_dir = f"/user/airflow/warehouse/fact_accounting/거래일자={ds}"
        local_dir = f"/opt/airflow/exported_data/fact_accounting/거래일자={ds}"

        list_url = f"{WEBHDFS_BASE}{hdfs_dir}?op=LISTSTATUS"
        resp = requests.get(list_url, allow_redirects=True, timeout=30)

        if resp.status_code == 404:
            print(f"Partition {ds} not found — skipping export")
            return f"skipped:{ds}"

        resp.raise_for_status()
        files = resp.json().get("FileStatuses", {}).get("FileStatus", [])

        parquet_files = [f for f in files if f["pathSuffix"].endswith(".parquet")]
        if not parquet_files:
            print(f"No parquet files in partition {ds} — skipping export")
            return f"empty:{ds}"

        os.makedirs(local_dir, exist_ok=True)

        for f in parquet_files:
            fname = f["pathSuffix"]
            local_path = os.path.join(local_dir, fname)
            download_url = f"{WEBHDFS_BASE}{hdfs_dir}/{fname}?op=OPEN"
            with requests.get(download_url, stream=True, timeout=60) as r:
                r.raise_for_status()
                with open(local_path, "wb") as out:
                    shutil.copyfileobj(r.raw, out)
            print(f"  downloaded: {fname}")

        print(f"Exported {len(parquet_files)} files to {local_dir}")
        return local_dir

    export = export_to_local()

    submit_batch >> verify >> export

dag_instance = accounting_fds_hybrid_dag()
```

### DAG flow

```
submit_fds_batch (LivyOperator, polling_interval=30)
       ↓
verify_fds_output (@task, requests → WebHDFS LISTSTATUS)
       ↓
export_to_local (@task, requests → WebHDFS OPEN → hostPath)
```

### Why polling_interval=30 instead of LivySensor

- `polling_interval > 0`: LivyOperator가 Spark batch 완료까지 **직접 polling** 수행
- `polling_interval=0`: LivyOperator가 batch 제출 직후 반환, 별도 LivySensor 필요
- 단일 polling 모델이 LivySensor + XCom 의존성보다 **단순하고 견고**함

### Why `requests` instead of WebHDFSHook

- Airflow 3.x에서 `WebHDFSHook` API가 변경되어 `list_status()` 미존재
- `requests` 직접 호출이 더 투명하고 디버깅이 쉬움
- WebHDFS REST API (`LISTSTATUS`, `OPEN`)는 안정적인 HTTP interface

### LivyOperator parameters

| Param | Type | Description |
|-------|------|-------------|
| `livy_conn_id` | str | Airflow connection ID for Livy (host: `DOCKER_HOST_IP`, port: `8998`) |
| `file` | str | HDFS path to the PySpark script |
| `args` | list[str] | Arguments passed to the Spark job |
| `conf` | dict | Spark configuration properties |
| `name` | str | Human-readable batch name |
| `polling_interval` | int | Seconds between polls (set `0` to use LivySensor instead) |

### LivySensor parameters

| Param | Type | Description |
|-------|------|-------------|
| `batch_id` | str/int | The batch ID returned by LivyOperator |
| `livy_conn_id` | str | Same connection ID as LivyOperator |

#### Note

LivySensor는 `polling_interval=0`일 때만 필요. 현재는 `polling_interval=30`으로 LivyOperator가 직접 polling하므로 **LivySensor 미사용**.

### WebHDFS REST API endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `?op=LISTSTATUS` | GET | List directory contents (file/dir listing) |
| `?op=OPEN` | GET | Download file content (stream) |

### export_to_local task

- HDFS의 당일 파티션(`거래일자={{ ds }}`) 내 `.parquet` 파일을 WebHDFS OPEN API로 다운로드
- Kind 노드의 hostPath(`/opt/airflow-exported/`)에 저장
- 파티션이 없으면 `skipped:{ds}` 반환 (정상 처리)
- 파티션은 있으나 parquet 파일이 없으면 `empty:{ds}` 반환

## Network quirk

- **Docker-internal:** `hadoop-conf/*.xml` uses container hostnames (`namenode`, `resourcemanager`)
- **K8s → Docker:** ConfigMap (`hadoop-configmap-generated.yaml`) uses Docker bridge gateway IP
- `network-setup.sh`가 Docker host IP를 동적 감지하여 ConfigMap을 생성하고 `values.yaml`을 업데이트합니다.
- Livy batch 제출 시 HDFS 경로는 `hdfs://{DOCKER_HOST_IP}:9820/...` 형식을 사용합니다.

## If modifying DAGs or Spark jobs

- Edit the `_k8s.py` variants. The non-K8s files are legacy and should NOT be modified.
- After changing a Spark job, re-run `bash dags/deploy_spark_jobs.sh` to upload to HDFS.
- The DAG uses `{{ ds }}` Jinja template for the date parameter — no hardcoded dates.
- LivyOperator with `polling_interval=30` polls batch completion internally; no LivySensor/XCom needed.
- Downstream tasks use default `trigger_rule='all_success'` — only run when upstream succeeds.

## Verification

```bash
bash verify-deployment.sh
```

This checks container status, Helm chart files, DAG Python syntax, YAML validity, network connectivity, and Livy API health.

## Known pitfalls

### trigger_rule bug: `all_done` vs `all_success`
- `trigger_rule='all_done'`은 upstream 실패와 관계없이 downstream 실행 → 실제로는 `submit_fds_batch` 실패 시에도 검증이 통과하는 오류 발생
- **기본값 `all_success` 사용 권장** — upstream 모두 성공 시에만 downstream 실행

### delete_worker_pods 설정
- 개발/디버깅 중: `delete_worker_pods: False` — worker pod 로그 보존 필수
- 프로덕션: `delete_worker_pods: True` — 리소스 누수 방지

### Python version in Livy container
- `bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11` ships Python 3.5.3.
- PySpark 3.4.1 requires **Python 3.7+**.
- Fix: `Dockerfile.livy` installs Python 3.9 via Miniconda (`/opt/conda/bin/python3.9`).
- Do NOT try to compile Python from source on Debian Stretch.

### Docker-Compose ENV overrides Dockerfile ENV
- `hadoop-cluster.yml` sets `HADOOP_CONF_DIR=/opt/livy/conf`, overriding Dockerfile ENV.
- If YARN batch jobs get stuck in `starting`, check `HADOOP_CONF_DIR`.

### Airflow 3.x vs 2.x differences
- `schedule_interval` → `schedule`
- `airflow.operators.bash.BashOperator` → `airflow.providers.standard.operators.bash.BashOperator`
- Worker pods use `config.kubernetes.delete_worker_pods` (not `AIRFLOW__KUBERNETES__DELETE_WORKER_PODS`)
- Provider packages must be installed in the Airflow image (`apache-airflow-providers-apache-livy`, `apache-airflow-providers-apache-hdfs`)

### KubernetesExecutor-specific issues
- Worker pods need `HADOOP_CONF_DIR` mounted (ConfigMap volume) + `JAVA_HOME` set (env var)
- Livy connection must be resolvable from worker pods (Docker bridge IP, not `localhost`)
- DAG files must be accessible to all scheduler/worker pods (use ConfigMap or shared volume)
- Worker pod image must include required Airflow providers

### Custom Airflow image
- Base: `apache/airflow:3.2.2`
- Must include: `apache-airflow-providers-apache-livy`, `apache-airflow-providers-apache-hdfs`, OpenJDK 11 JRE
- `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64`
- Build with: `docker build -t airflow-h8sdp:3.2.2 -f helm/airflow/Dockerfile .`

### Network
- K8s→Docker: `{DOCKER_HOST_IP}:{port}` (Docker bridge gateway, e.g., `172.18.0.1`)
- Docker-internal: `{container_name}:{port}` (e.g., `namenode:9820`)
- `network-setup.sh` detects the correct IP; run after any Docker network change.
- LivyOperator uses the Livy connection (HTTP to `{DOCKER_HOST_IP}:8998`)

## No tests/lint/typecheck

This is an infrastructure-as-code repo. There are no test runners, linters, or type checkers configured. Python syntax is checked via `python3 -m py_compile` in `verify-deployment.sh`.
EOF

git add README.md
git add avante.md
git add implementation-plan.md
git add AGENTS.md
git commit --allow-empty -m 'docs: README.md, avante.md, implementation-plan.md, AGENTS.md 추가'

git checkout "${BASE_BRANCH}"
git merge feat/docs --no-ff -m 'merge: feat/docs 병합'
echo "[STEP 10] Conflict simulation"

echo '  Creating feat/conflict-k8s-executor with KubernetesExecutor'
git checkout -b feat/conflict-k8s-executor "${BASE_BRANCH}"
sed -i 's/- AIRFLOW__CORE__EXECUTOR=LocalExecutor/- AIRFLOW__CORE__EXECUTOR=KubernetesExecutor/' docker-compose.yml
git add docker-compose.yml
git commit --allow-empty -m 'feat(executor): docker-compose.yml executor KubernetesExecutor로 변경'

git checkout "${BASE_BRANCH}"
git merge feat/conflict-k8s-executor --no-ff -m 'merge: feat/conflict-k8s-executor 병합'
echo '  Creating feat/conflict-local-executor (will conflict)'
git checkout -b feat/conflict-local-executor "${BASE_BRANCH}~1"
sed -i 's/- AIRFLOW__CORE__EXECUTOR=LocalExecutor/- AIRFLOW__CORE__EXECUTOR=LocalExecutor  # Legacy mode/' docker-compose.yml
git add docker-compose.yml
git commit --allow-empty -m 'feat(executor): docker-compose.yml executor LocalExecutor 유지 (레거시 모드)'

echo "  Merging feat/conflict-local-executor -> ${BASE_BRANCH} (EXPECT CONFLICT)"
git checkout "${BASE_BRANCH}"
set +e
git merge feat/conflict-local-executor --no-ff 2>&1 || true
set -e
# Resolve conflict: keep LocalExecutor (matching Version B)
cat << 'RESOLVED_EOF' > docker-compose.yml
networks:
  finops-network:
    driver: bridge

volumes:
  hadoop_namenode:
  hadoop_datanode:
  postgres_data: 

services:
  # 0. PostgreSQL Metadata Database
  postgres:
    image: postgres:13
    container_name: postgres
    restart: always
    environment:
      - POSTGRES_USER=airflow
      - POSTGRES_PASSWORD=airflow
      - POSTGRES_DB=airflow
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - finops-network

  # 1. HDFS
  namenode:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11
    container_name: namenode
    restart: always
    ports:
      - "9870:9870"
      - "9820:9820"
    volumes:
      - hadoop_namenode:/hadoop/dfs/name
    environment:
      - CLUSTER_NAME=finops_cluster
    env_file:
      - ./hadoop.env
    networks:
      - finops-network

  datanode:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java11
    container_name: datanode
    restart: always
    ports:
      - "9864:9864"
    volumes:
      - hadoop_datanode:/hadoop/dfs/data
    environment:
      - SERVICE_PRECONDITION=namenode:9820
    env_file:
      - ./hadoop.env
    depends_on:
      - namenode
    networks:
      - finops-network

  # YARN Resource Manager
  resourcemanager:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-resourcemanager:2.0.0-hadoop3.2.1-java11
    container_name: resourcemanager
    restart: always
    ports:
      - "8088:8088"
    environment:
      - SERVICE_PRECONDITION=namenode:9820 datanode:9864
      - YARN_CONF_yarn_resourcemanager_scheduler_class=org.apache.hadoop.yarn.server.resourcemanager.scheduler.fifo.FifoScheduler
      - YARN_CONF_yarn_scheduler_minimum___allocation___mb=1024
      - YARN_CONF_yarn_scheduler_maximum___allocation___mb=4096
    env_file:
      - ./hadoop.env
    networks:
      - finops-network

  # YARN Node Manager
  nodemanager:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-nodemanager:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-nodemanager:2.0.0-hadoop3.2.1-java11
    container_name: nodemanager
    restart: always
    ports:
      - "8042:8042"
    environment:
      - SERVICE_PRECONDITION=namenode:9820 datanode:9864 resourcemanager:8088
      - YARN_CONF_yarn_nodemanager_resource_memory___mb=4096
      - YARN_CONF_yarn_scheduler_minimum___allocation___mb=1024
      - YARN_CONF_yarn_scheduler_maximum___allocation___mb=4096
    env_file:
      - ./hadoop.env
    depends_on:
      - resourcemanager
    networks:
      - finops-network

  # 2. HDFS Directory Setup
  hdfs-directory-setup:
    build:
      context: .
      dockerfile: Dockerfile.hadoop-java11
      args:
        - BASE_IMAGE=bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8
    image: bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java11
    container_name: hdfs-directory-setup
    depends_on:
      - namenode
    networks:
      - finops-network
    env_file:
      - ./hadoop.env
    volumes:
      - ./dags/setup_hdfs.sh:/setup_hdfs.sh
      - ./transactions_10k.csv:/transactions_10k.csv
    command: ["/bin/bash", "/setup_hdfs.sh"]

  # 3. Airflow DB 초기화
  airflow-init:
    build: .
    container_name: airflow-init
    depends_on:
      postgres:
        condition: service_started
      hdfs-directory-setup:
        condition: service_completed_successfully
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./db:/opt/airflow/db
      - ./hadoop-conf:/opt/hadoop/conf
      - ./exported_data:/opt/airflow/exported_data
    environment:
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - HADOOP_CONF_DIR=/opt/hadoop/conf
    entrypoint: [ "/entrypoint" ]
    command: >
      bash -c "until nc -z postgres 5432; do echo 'waiting for postgres...'; sleep 3; done &&
               airflow db init &&
               airflow users create --username admin --password admin --firstname Anonymous --lastname Admin --role Admin --email admin@example.com"
    networks:
      - finops-network

  # 4. Apache Airflow Webserver
  airflow-webserver:
    build: .
    container_name: airflow-webserver
    ports:
      - "8080:8080"
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./db:/opt/airflow/db
      - ./hadoop-conf:/opt/hadoop/conf
      - ./exported_data:/opt/airflow/exported_data
    environment:
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CORE__EXECUTOR=LocalExecutor
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - HADOOP_CONF_DIR=/opt/hadoop/conf
    entrypoint: [ "/entrypoint" ]
    command: webserver
    depends_on:
      postgres:
        condition: service_started
      airflow-init:
        condition: service_completed_successfully
    networks:
      - finops-network

  # 5. Apache Airflow Scheduler
  airflow-scheduler:
    build: .
    container_name: airflow-scheduler
    volumes:
      - ./dags:/opt/airflow/dags
      - ./logs:/opt/airflow/logs
      - ./plugins:/opt/airflow/plugins
      - ./db:/opt/airflow/db
      - ./hadoop-conf:/opt/hadoop/conf
      - ./exported_data:/opt/airflow/exported_data
    environment:
      - AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://airflow:airflow@postgres/airflow
      - AIRFLOW__CORE__EXECUTOR=LocalExecutor
      - AIRFLOW__CORE__LOAD_EXAMPLES=False
      - HADOOP_CONF_DIR=/opt/hadoop/conf
    entrypoint: [ "/entrypoint" ]
    command: scheduler
    depends_on:
      postgres:
        condition: service_started
      airflow-init:
        condition: service_completed_successfully
    networks:
      - finops-network

RESOLVED_EOF
git add docker-compose.yml
git commit --allow-empty -m 'conflict: docker-compose.yml executor 타입 머지 충돌 해결'

echo ''
echo '===== Git History Reconstruction Complete ====='
echo ''
echo 'Commit count:'
git log --oneline | wc -l
echo ''
echo 'Verify with:'
echo '  git log --graph --oneline --all'
echo '  diff -rq . ${VERSION_B_DIR} --exclude=.git --exclude=*.csv --exclude=*.tgz --exclude=*.zip --exclude=*.log --exclude=*.db --exclude=__pycache__ --exclude=*.pyc'
echo ''
echo 'Done.'
