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
