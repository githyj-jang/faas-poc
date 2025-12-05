import uuid

from fastapi import APIRouter, HTTPException, Request, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.logger import setup_logger
from app.repositories.callback_repo import CallbackRepository
from app.routers.deploy import get_callback_map
from app.utils.broadcast_utils import broadcast
from app.utils.docker_utils import run_callback_container
from app.utils.kube_utils import run_lambda_job, get_job_pod_name, read_pod_logs

# 로거 초기화
logger = setup_logger(__name__)

router = APIRouter(prefix="/api", tags=["api"])

@router.api_route("/kube/{path_name}", methods=["GET", "POST", "PUT", "DELETE"])
async def execute_callback(path_name: str, request: Request, db: Session = Depends(get_db)) -> dict:
    method = request.method
    callback_map = get_callback_map()

    if f"{path_name}" not in callback_map:
        raise HTTPException(status_code=404, detail="Callback not registered")

    path_methods = callback_map[path_name]
    callback = CallbackRepository.get_callback_by_path(db=db, path=f"/{path_name}", method=method)

    if method not in path_methods or not callback:
        raise HTTPException(status_code=405, detail=f"Method '{method}' not allowed for path '{path_name}'")

    image_name = path_methods[method]

    # 1. Query String 파싱
    query_params = dict(request.query_params)
    
    # 2. Body 파싱 (POST일 때만)
    body_data = {}
    if request.method == "POST" or request.method == "PUT":
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
    logger.info(f"Executing Kubernetes callback: {method} {path_name} (image: {image_name}, session: {session_id})")
    logger.debug(f"Event data: {unified_event}")

    job_name = run_lambda_job(image_name=image_name, session_id=session_id, event_data=unified_event, env_vars=callback.env)
    logger.info(f"Kubernetes job started: {job_name}")

    pod_name = get_job_pod_name(job_name)

    logs = read_pod_logs(pod_name)
    logger.debug(f"Pod {pod_name} logs: {logs}")

    try:
        import json
        result = json.loads(logs.replace("'", '"'))
        logger.info(f"Kubernetes callback completed: {method} {path_name} (status: {result.get('statusCode', 'unknown')})")
    except Exception as e:
        logger.error(f"Failed to parse Kubernetes pod logs for {path_name}: {str(e)}")
        result = {"error": "Invalid JSON in pod logs", "raw_logs": logs, "exception": str(e)}

    return result

@router.api_route("/{path_name}", methods=["GET", "POST", "PUT", "DELETE"])
async def execute_callback(path_name: str, request: Request, db: Session = Depends(get_db)) -> dict:
    method = request.method
    callback_map = get_callback_map()

    if f"{path_name}" not in callback_map:
        raise HTTPException(status_code=404, detail="Callback not registered")

    path_methods = callback_map[path_name]
    callback = CallbackRepository.get_callback_by_path(db=db, path=f"/{path_name}", method=method)

    if method not in path_methods or not callback:
        raise HTTPException(status_code=405, detail=f"Method '{method}' not allowed for path '{path_name}'")

    image_name = path_methods[method]

    # 1. Query String 파싱
    query_params = dict(request.query_params)
    
    # 2. Body 파싱 (POST일 때만)
    body_data = {}
    if request.method == "POST" or request.method == "PUT":
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
    logger.info(f"Executing Docker callback: {method} {path_name} (image: {image_name}, session: {session_id})")
    logger.debug(f"Event data: {unified_event}")

    result = run_callback_container(
        image_name=image_name, session_id=session_id, event_data=unified_event, env_vars=callback.env
    )
    logger.info(f"Docker callback completed: {method} {path_name} (status: {result.get('lambda_status_code', 'unknown')})")
    await broadcast(result)

    return result
