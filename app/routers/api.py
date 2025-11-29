import uuid

from fastapi import APIRouter, HTTPException, Request

from app.models.callback_model import CallbackDeployResponse
from app.routers.deploy import get_callback_map
from app.utils.docker_utils import run_callback_container
from app.utils.kube_utils import run_lambda_job, get_job_pod_name, read_pod_logs

router = APIRouter(prefix="/api", tags=["api"])

@router.api_route("/kube/{path_name}", methods=["GET", "POST"])
async def execute_callback(path_name: str, request: Request) -> dict:
    callback_map = get_callback_map()

    if f"{path_name}" not in callback_map:
        raise HTTPException(status_code=404, detail="Callback not registered")

    image_name = callback_map[f"{path_name}"]

    # Input event
    event = (
        await request.json()
        if request.method == "POST"
        else dict(request.query_params)
    )

    session_id = str(uuid.uuid4())
    print(f"Image: {image_name}, Session: {session_id}, Event: {event}")

    job_name = run_lambda_job(image_name=image_name, session_id=session_id, event_data=event)
    print(f"Started Job: {job_name}")

    pod_name = get_job_pod_name(job_name)

    logs = read_pod_logs(pod_name)
    print(f"[K8s Logs - {pod_name}] {logs}")

    try:
        result = json.loads(logs)
    except Exception as e:
        result = {"error": "Invalid JSON in pod logs", "raw_logs": logs, "exception": str(e)}

    return result

@router.api_route("/{path_name}", methods=["GET", "POST"])
async def execute_callback(path_name: str, request: Request) -> dict:
    callback_map = get_callback_map()

    if f"{path_name}" not in callback_map:
        raise HTTPException(status_code=404, detail="Callback not registered")

    image_name = callback_map[f"{path_name}"]

    # input event 생성
    event = (
        await request.json()
        if request.method == "POST"
        else dict(request.query_params)
    )

    session_id = str(uuid.uuid4())
    print(
        f"Image Name: {image_name}, Session ID: {session_id}, Event: {event}"
    )

    result = run_callback_container(
        image_name=image_name, session_id=session_id, event_data=event
    )

    return result
