import json
import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict
from kubernetes import client, config
import time
import uuid
from app.models.lambda_model import LambdaStatusCode

RUNTIME_TEMPLATE_DIR = Path(__file__).parent.parent / "runtime"
LOCAL_REGISTRY = "localhost:5000"  # 로컬 레지스트리 주소

def build_kube_callback_image(callback_id: int, code: str, runtime_type: str) -> str:
    """
    로컬 Docker 레지스트리를 사용하여 이미지 build & push 후
    Kubernetes에서 사용할 registry URL 반환
    """
    # 1. 임시 빌드 디렉토리 생성
    tmp = tempfile.mkdtemp()
    runtime_dir = RUNTIME_TEMPLATE_DIR / runtime_type

    if not runtime_dir.exists():
        shutil.rmtree(tmp)
        raise ValueError(f"Unknown runtime type: {runtime_type}")

    # 2. entry file 생성
    entry_file = "lambda_function.py" if runtime_type == "python" else "lambda_function.js"
    (Path(tmp) / entry_file).write_text(code, encoding="utf-8")

    # 3. runtime template 복사
    for item in os.listdir(runtime_dir):
        src = runtime_dir / item
        dst = Path(tmp) / item
        if src.is_dir():
            shutil.copytree(src, dst, dirs_exist_ok=True)
        else:
            shutil.copy2(src, dst)

    # 4. 이미지 이름
    image_name = f"callback_{callback_id}:latest"
    full_image_name = f"{LOCAL_REGISTRY}/callback_{callback_id}:latest"

    # 5. Docker build
    subprocess.run(["docker", "build", "-t", image_name, tmp], check=True)

    # 6. 레지스트리 태그
    subprocess.run(["docker", "tag", image_name, full_image_name], check=True)

    # 7. 레지스트리에 push
    subprocess.run(["docker", "push", full_image_name], check=True)

    # 8. 임시 디렉토리 제거
    shutil.rmtree(tmp)

    return full_image_name

def run_lambda_job(image_name, session_id, event_data):
    config.load_kube_config()  # 로컬 kubeconfig 사용

    batch_v1 = client.BatchV1Api()
    job_name = f"lambda-job-{uuid.uuid4().hex[:8]}"

    job = client.V1Job(
        metadata=client.V1ObjectMeta(name=job_name),
        spec=client.V1JobSpec(
            template=client.V1PodTemplateSpec(
                spec=client.V1PodSpec(
                    containers=[
                        client.V1Container(
                            name="lambda-container",
                            image=image_name,
                            env=[
                                client.V1EnvVar(name="SESSION_ID", value="1234")
                            ],
                            image_pull_policy="IfNotPresent"
                        )
                    ],
                    restart_policy="Never",
                    tolerations=[
                        client.V1Toleration(
                            key="node-role.kubernetes.io/control-plane",
                            operator="Exists",
                            effect="NoSchedule"
                        )
                    ]
                )
            )
        )
    )

    # Job 생성
    batch_v1.create_namespaced_job(namespace="default", body=job)
    return job_name

def get_job_pod_name(job_name):
    core = client.CoreV1Api()

    while True:
        pods = core.list_namespaced_pod(
            namespace="default",
            label_selector=f"job-name={job_name}"
        )
        if pods.items:
            return pods.items[0].metadata.name
        time.sleep(1)


def read_pod_logs(pod_name, namespace="default", timeout=30):
    core = client.CoreV1Api()
    start = time.time()
    while time.time() - start < timeout:
        pod = core.read_namespaced_pod(name=pod_name, namespace=namespace)
        if pod.status.phase in ["Running", "Succeeded", "Failed"]:
            break
        time.sleep(1)
    else:
        raise TimeoutError(f"Pod {pod_name} did not start within {timeout} seconds")

    return core.read_namespaced_pod_log(name=pod_name, namespace=namespace)
