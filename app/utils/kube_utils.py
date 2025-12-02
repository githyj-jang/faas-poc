import asyncio
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

async def build_kube_callback_image(image_name: str) -> str:
    """
    로컬 Docker 레지스트리를 사용하여 이미지 build & push 후
    Kubernetes에서 사용할 registry URL 반환
    """
    # 1) docker save
    process_save = await asyncio.create_subprocess_exec(
        "docker", "save", "-o", f"{image_name}.tar", image_name,
    )

    await process_save.wait()

    # 2) ctr import
    process_import = await asyncio.create_subprocess_exec(
        "sudo", "ctr", "-n", "k8s.io", "images", "import", f"{image_name}.tar",
    )

    await process_import.wait()

def run_lambda_job(image_name, session_id, event_data, env_vars: Dict[str, str] = None):
    """
    Kubernetes에서 Lambda 작업을 실행합니다.

    Args:
        image_name: 이미지 이름
        session_id: 세션 ID
        event_data: 이벤트 데이터
        env_vars: 환경변수 (선택사항)

    Returns:
        작업 이름
    """
    config.load_kube_config()  # 로컬 kubeconfig 사용

    batch_v1 = client.BatchV1Api()
    job_name = f"lambda-job-{uuid.uuid4().hex[:8]}"

    # 환경변수 준비
    env_list = [
        client.V1EnvVar(name="SESSION_ID", value=session_id),
        client.V1EnvVar(name="EVENT", value=json.dumps(event_data))
    ]
    
    # 추가 환경변수 있으면 추가
    if env_vars:
        for key, value in env_vars.items():
            env_list.append(client.V1EnvVar(name=key, value=str(value)))

    job = client.V1Job(
        metadata=client.V1ObjectMeta(name=job_name),
        spec=client.V1JobSpec(
            template=client.V1PodTemplateSpec(
                spec=client.V1PodSpec(
                    containers=[
                        client.V1Container(
                            name="lambda-container",
                            image=image_name,
                            env=env_list,
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
