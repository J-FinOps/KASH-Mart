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
