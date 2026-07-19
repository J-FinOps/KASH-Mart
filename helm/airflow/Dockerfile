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
