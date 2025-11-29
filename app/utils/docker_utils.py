import json
import logging
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict

from app.models.lambda_model import LambdaStatusCode

logger = logging.getLogger(__name__)

# 런타임 템플릿 경로
RUNTIME_TEMPLATE_DIR = Path(__file__).parent.parent / "runtime"

def build_callback_image(callback_id: int, code: str, runtime_type: str) -> str:
    tmp = tempfile.mkdtemp()
    runtime_dir = RUNTIME_TEMPLATE_DIR / runtime_type

    if not runtime_dir.exists():
        raise ValueError(f"Unknown runtime type: {runtime_type}")

    entry_file = (
        "lambda_function.py" if runtime_type == "python" else "lambda_function.js"
    )
    with open(Path(tmp) / entry_file, "w", encoding="utf-8") as f:
        f.write(code)

    for item in os.listdir(runtime_dir):
        src = runtime_dir / item
        dst = Path(tmp) / item
        if src.is_dir():
            shutil.copytree(str(src), str(dst), dirs_exist_ok=True)
        else:
            shutil.copy2(str(src), str(dst))

    image_name = f"callback_{callback_id}".lower()

    # Docker build tmp를 컨텍스트
    subprocess.run(["docker", "build", "-t", image_name, tmp], check=True)

    shutil.rmtree(tmp)

    return image_name


def run_callback_container(
    image_name: str, session_id: str, event_data: Dict[str, Any]
) -> Dict[str, Any]:
    event_json = json.dumps(event_data)

    try:
        logger.info("Running Docker Container")
        completed = subprocess.Popen(
            [
                "docker",
                "run",
                "-e",
                f"SESSION_ID={session_id}",
                "-e",
                f"EVENT={event_json}",
                image_name,
            ],
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
