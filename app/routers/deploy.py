from fastapi import APIRouter, HTTPException

from app.models.callback_model import CallbackDeployRequest, CallbackDeployResponse
from app.repositories.callback_repo import (
    get_callback,
    update_status,
)
from app.utils.docker_utils import build_callback_image
from app.utils.kube_utils import build_kube_callback_image

router = APIRouter(prefix="/callback", tags=["callback"])

# 콜백 맵: {path: image_name}
callback_map = {}

@router.post("/deploy/kube")
async def deploy_callback(req: CallbackDeployRequest) -> dict:
    callback = get_callback(req.callback_id)
    if not callback:
        raise HTTPException(status_code=404, detail="Callback not found")

    if req.status is False:
        # undeploy
        if callback["path"] in callback_map:
            del callback_map[callback["path"]]
        update_status(req.callback_id, "undeployed")
        return {"message": "Callback undeployed", "path": callback["path"]}

    # build
    image_name = build_kube_callback_image(
        req.callback_id, callback["code"], callback["type"]
    )

    # callback
    callback_map[callback["path"]] = image_name
    update_status(req.callback_id, "deployed")

    return {
        "message": "Callback deployed",
        "path": callback["path"],
        "image": image_name,
    }

@router.post("/deploy")
async def deploy_callback(req: CallbackDeployRequest) -> dict:
    callback = get_callback(req.callback_id)
    if not callback:
        raise HTTPException(status_code=404, detail="Callback not found")

    if req.status is False:
        # undeploy
        if callback["path"] in callback_map:
            del callback_map[callback["path"]]
        update_status(req.callback_id, "undeployed")
        return {"message": "Callback undeployed", "path": callback["path"]}

    # build
    image_name = build_callback_image(
        req.callback_id, callback["code"], callback["type"]
    )

    # callback
    callback_map[callback["path"]] = image_name
    update_status(req.callback_id, "deployed")

    return {
        "message": "Callback deployed",
        "path": callback["path"],
        "image": image_name,
    }


def get_callback_map() -> dict:
    return callback_map
