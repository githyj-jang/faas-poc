import uuid

from fastapi import APIRouter, HTTPException, Request

from app.models.callback_model import CallbackDeployResponse
from app.routers.deploy import get_callback_map
from app.utils.docker_utils import run_callback_container

router = APIRouter(prefix="/api", tags=["api"])


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
