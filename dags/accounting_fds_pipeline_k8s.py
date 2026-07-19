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
