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

    # 1. Query String 파싱
    query_params = dict(request.query_params)
    
    # 2. Body 파싱 (POST일 때만)
    body_data = {}
    if request.method == "POST":
        try:
            body_data = await request.json()
        except Exception:
            body_data = {} # Body가 없거나 JSON이 아닌 경우

    unified_event = {
        "httpMethod": request.method,           # "GET" or "POST"
        "queryStringParameters": query_params,  # 예: {"name": "foo"}
        "body": body_data,                      # 예: {"id": 123}
        "path": path_name
    }

    session_id = str(uuid.uuid4())
    print(f"Image: {image_name}, Session: {session_id}, Event: {unified_event}")

    job_name = run_lambda_job(image_name=image_name, session_id=session_id, event_data=unified_event)
    print(f"Started Job: {job_name}")

    pod_name = get_job_pod_name(job_name)

    logs = read_pod_logs(pod_name)
    print(f"[K8s Logs - {pod_name}] {logs}")

    try:
        import json
        result = json.loads(logs.replace("'", '"'))
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
