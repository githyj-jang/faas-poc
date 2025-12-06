import asyncio
import json
import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict

from app.utils.broadcast_utils import broadcast
from app.utils.kube_utils import build_kube_callback_image
from app.models.lambda_model import LambdaStatusCode

logger = logging.getLogger(__name__)

# 런타임 템플릿 경로
RUNTIME_TEMPLATE_DIR = Path(__file__).parent.parent / "runtime"

def run_callback_container(
    image_name: str, session_id: str, event_data: Dict[str, Any], env_vars: Dict[str, str] = None
) -> Dict[str, Any]:
    """
    콜백 컨테이너를 실행합니다.

    Args:
        image_name: 이미지 이름
        session_id: 세션 ID
        event_data: 이벤트 데이터
        env_vars: 환경변수 (선택사항)

    Returns:
        실행 결과 딕셔너리
    """
    event_json = json.dumps(event_data)

    try:
        logger.info("Running Docker Container")
        
        # 환경변수 준비
        docker_cmd = [
            "docker",
            "run",
            "-e",
            f"SESSION_ID={session_id}",
            "-e",
            f"EVENT={event_json}",
        ]
        
        # 추가 환경변수 있으면 추가
        if env_vars:
            for key, value in env_vars.items():
                docker_cmd.extend(["-e", f"{key}={value}"])

        print(env_vars)
        
        docker_cmd.append(image_name)
        
        completed = subprocess.Popen(
            docker_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        stdout, stderr = completed.communicate(timeout=30)
        logger.info(f"stdout: {stdout}")
        logger.info(f"stderr: {stderr}")

        parsed = json.loads(stdout)
        logger.info(f"Parsed result: {parsed}")

        return parsed
    except subprocess.TimeoutExpired:
        logger.error("Docker container execution timeout")
        completed.terminate()
        return {
            "lambda_status_code": LambdaStatusCode.TIMEOUT.value,
            "body": "Process Time Out (30s)",
        }
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error: {e}")
        return {
            "lambda_status_code": LambdaStatusCode.JSON_PARSE_ERROR.value,
            "body": "Invalid JSON Response from Container",
        }
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return {
            "lambda_status_code": LambdaStatusCode.LAMBDA_ERROR.value,
            "body": "Lambda execution error",
        }

"""
Status: start, building, import
"""
async def build_callback_image_background(
    callback_id: int,
    code: str,
    runtime_type: str,
    container_type: str,
    library: str = None,
    env: dict = None,
) -> Dict[str, Any]:
    """
    백그라운드에서 콜백 이미지를 빌드합니다.

    Args:
        callback_id: 콜백 ID
        code: 콜백 코드
        runtime_type: 런타임 타입 (python, node)
        container_type: 컨테이너 타입 (docker, kube)
        library: 라이브러리 (requirements.txt 또는 package.json 형식)
        env: 환경변수 (JSON 형식)

    Returns:
        빌드 결과 딕셔너리
    """
    tmp = tempfile.mkdtemp()

    await broadcast({"type": "status", "status": "start", "message": f"Building Callback Id {callback_id}"})
    try:
        runtime_dir = RUNTIME_TEMPLATE_DIR / runtime_type

        if not runtime_dir.exists():
            error_msg = f"Unknown runtime type: {runtime_type}"
            await broadcast({"type": "error", "message": error_msg})
            return {"status": "failed", "error": error_msg}

        # 진입점 파일 생성
        entry_file = (
            "lambda_function.py" if runtime_type == "python" else "lambda_function.js"
        )
        with open(Path(tmp) / entry_file, "w", encoding="utf-8") as f:
            f.write(code)

        await broadcast(
            {"type": "log", "message": f"Entry file created: {entry_file}"}
        )

        # 라이브러리 파일 생성 (있으면)
        if library:
            if runtime_type == "python":
                req_file = Path(tmp) / "requirements.txt"
                with open(req_file, "w", encoding="utf-8") as f:
                    f.write(library)
                await broadcast(
                    {"type": "log", "message": "requirements.txt created"}
                )
            elif runtime_type == "node":
                package_file = Path(tmp) / "package.json"
                with open(package_file, "w", encoding="utf-8") as f:
                    f.write(library)
                await broadcast(
                    {"type": "log", "message": "package.json created"}
                )

        # 런타임 파일 복사
        for item in os.listdir(runtime_dir):
            src = runtime_dir / item
            dst = Path(tmp) / item
            if src.is_dir():
                shutil.copytree(str(src), str(dst), dirs_exist_ok=True)
            else:
                shutil.copy2(str(src), str(dst))

        await broadcast(
            {"type": "log", "message": "Runtime files copied"}
        )

        image_name = f"callback_{callback_id}".lower()

        await broadcast({"status": "building", "message": f"Start docker build Callback Id[{callback_id}]"})
        # async build with logs
        process = await asyncio.create_subprocess_exec(
            "docker",
            "build",
            "-t",
            image_name,
            tmp,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )

        # stream logs
        await broadcast(
            {"type": "log", "message": f"Building Docker image: {image_name}"}
        )

        while True:
            line = await process.stdout.readline()
            if not line:
                break
            await broadcast(
                {"type": "log", "message": line.decode().rstrip()}
            )

        code = await process.wait()

        # Containered image transfer
        if (container_type == "kube"):
            await broadcast({"type": "status", "status": "import", "message": f"Transferring image to Kubernetes cluster - callback id[{callback_id}]"})
            await build_kube_callback_image(image_name)

        if code != 0:
            error_msg = "Build failed"
            await broadcast(
                {"type": "error", "message": f"{error_msg} ❌"}
            )
            return {"status": "failed", "error": error_msg}

        await broadcast(
            {"type": "status", "status": "success", "message": "Build completed ✅"}
        )

        return {"status": "success", "image": image_name}

    except Exception as e:
        error_msg = f"Build error: {str(e)}"
        logger.error(error_msg)
        await broadcast({"type": "error", "message": error_msg})
        return {"status": "failed", "error": error_msg}
    finally:
        if os.path.exists(tmp):
            shutil.rmtree(tmp)