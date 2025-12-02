import asyncio
from fastapi import APIRouter, HTTPException, Depends, WebSocket, BackgroundTasks, Query
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.callback_model import CallbackDeployRequest, CallbackResponse
from app.repositories.callback_repo import CallbackRepository
from app.utils.broadcast_utils import connected_websockets
from app.utils.docker_utils import (
    build_callback_image_background,
)
from app.utils.kube_utils import build_kube_callback_image

router = APIRouter(prefix="/deploy", tags=["deploy"])

# { "path": { "METHOD": "image_name" } }
callback_map = {}

# 빌드 중인 콜백: {callback_id: image_name}
building_callbacks = {}

@router.post("/", response_model=CallbackResponse)
async def deploy_callback_docker(
    req: CallbackDeployRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
) -> CallbackResponse:
    """
    Docker로 콜백 배포 (백그라운드 빌드)
    
    즉시 콜백 상태를 'build'로 변경하고 반환합니다.
    빌드는 백그라운드에서 진행되며, WebSocket으로 진행 상황을 확인할 수 있습니다.

    Args:
        req: 콜백 배포 요청
        background_tasks: 백그라운드 작업
        db: 데이터베이스 세션

    Returns:
        콜백 정보 (status='build')

    Raises:
        HTTPException: 콜백을 찾을 수 없음
    """
    callback = CallbackRepository.get_callback_by_id(db, req.callback_id)
    if not callback:
        raise HTTPException(status_code=404, detail="Callback not found")

    if req.status is False:
        # undeploy
        if callback.path in callback_map and callback.method in callback_map[callback.path]:
            del callback_map[callback.path][callback.method]
            if not callback_map[callback.path]:
                del callback_map[callback.path]
        CallbackRepository.update_callback(db, req.callback_id, status="undeployed")
        return callback

    # 상태를 'build'로 변경
    CallbackRepository.update_callback(db, req.callback_id, status="build")
    
    # 백그라운드에서 빌드 작업 추가
    background_tasks.add_task(
        _build_and_register_callback,
        callback.callback_id,
        callback.path,
        callback.method,
        callback.code,
        callback.type,
        callback.library,
        callback.env,
        req.c_type,
        db,
    )

    # 업데이트된 콜백 반환
    updated_callback = CallbackRepository.get_callback_by_id(db, req.callback_id)
    return updated_callback


async def _build_and_register_callback(
    callback_id: int,
    path: str,
    method: str,
    code: str,
    runtime_type: str,
    lib: str,
    env: str,
    c_type: str,
    db: Session,
) -> None:
    """
    백그라운드에서 콜백 이미지를 빌드하고 등록합니다.

    Args:
        callback_id: 콜백 ID
        path: 콜백 경로
        code: 콜백 코드
        runtime_type: 런타임 타입
        db: 데이터베이스 세션
    """
    try:
        image_name = f"callback_{callback_id}".lower()
        print("Create Image")
        print(image_name)
        building_callbacks[callback_id] = image_name

        print("Building...")
        
        # 빌드 실행
        result = await build_callback_image_background(
            callback_id, code, runtime_type, c_type, lib, env
        )
        print("END")
        print(result)

        if result["status"] == "success":
            # 빌드 성공: 콜백 맵에 등록 및 상태 변경
            normalized_path = normalize_path(path)

            if normalized_path not in callback_map:
                callback_map[normalized_path] = {}
            
            callback_map[normalized_path][method] = result["image"]
            
            CallbackRepository.update_callback(
                db, callback_id, status="deployed"
            )
        else:
            # 빌드 실패: 상태를 'failed'로 변경
            CallbackRepository.update_callback(db, callback_id, status="failed")

    except Exception as e:
        # 예외 발생: 상태를 'failed'로 변경
        print(f"Build error for callback {callback_id}: {str(e)}")
        CallbackRepository.update_callback(db, callback_id, status="failed")
    finally:
        # 빌드 중 딕셔너리에서 제거
        if callback_id in building_callbacks:
            del building_callbacks[callback_id]

# -------------------------
#  WebSocket 방식 빌드 진행 상황 모니터링
# -------------------------
@router.websocket("/ws")
async def ws_deploy(websocket: WebSocket):
    await websocket.accept()
    connected_websockets.add(websocket)

    try:
        while True:
            await websocket.receive_text()
    except:
        pass
    finally:
        connected_websockets.remove(websocket)

def get_callback_map() -> dict:
    """콜백 맵 반환"""
    return callback_map

def normalize_path(path: str) -> str:
    if not path:
        return path
    return path.lstrip("/")  # 맨 앞의 / 제거