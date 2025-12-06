"""
콜백 등록 라우터

콜백 등록 및 관리 엔드포인트
"""

from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session
from app.routers.deploy import get_callback_map

from app.core.database import get_db
from app.models.callback_model import (
    CallbackRegisterRequest,
    CallbackUpdateRequest,
    CallbackResponse,
    CallbackAllResonse
)
from app.repositories.callback_repo import CallbackRepository

# API 캐시 클리어 함수 임포트를 위한 lazy import 사용
# (순환 임포트 방지)
def _clear_api_caches():
    """API 캐시 클리어"""
    try:
        from app.routers.api import clear_api_caches
        print("Cache clear")
        clear_api_caches()
    except ImportError:
        pass

router = APIRouter(prefix="/callbacks", tags=["callbacks"])

@router.post("/", response_model=CallbackResponse)
async def register_callback(
    req: CallbackRegisterRequest,
    db: Session = Depends(get_db),
) -> CallbackResponse:
    """
    새 콜백 등록 (같은 path가 있는지 체크)
    
    chat_id가 제공되면 해당 챗룸과 연결됩니다.
    library와 env를 포함할 수 있습니다.

    Args:
        req: 콜백 등록 요청
        db: 데이터베이스 세션

    Returns:
        등록된 콜백 정보

    Raises:
        HTTPException: path가 이미 존재하거나 챗룸을 찾을 수 없음
    """
    try:
        callback = CallbackRepository.create_callback(
            db=db,
            path=req.path,
            method=req.method,
            type=req.type,
            code=req.code,
            chat_id=req.chat_id,
            library=req.library,
            env=req.env,
        )
        return callback
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))


@router.get("/{callback_id}", response_model=CallbackAllResonse)
async def get_callback(
    callback_id: int,
    db: Session = Depends(get_db),
) -> CallbackAllResonse:
    """
    콜백 조회

    Args:
        callback_id: 콜백 ID
        db: 데이터베이스 세션

    Returns:
        콜백 정보

    Raises:
        HTTPException: 콜백을 찾을 수 없음
    """
    callback = CallbackRepository.get_callback_by_id(db, callback_id)
    if not callback:
        raise HTTPException(status_code=404, detail="Callback not found")
    return callback


@router.put("/{callback_id}", response_model=CallbackResponse)
async def update_callback(
    callback_id: int,
    req: CallbackUpdateRequest,
    db: Session = Depends(get_db),
) -> CallbackResponse:
    """
    콜백 수정

    path가 변경되는 경우 중복 체크합니다.
    chat_id를 변경하여 다른 챗룸과 연결할 수 있습니다.

    Args:
        callback_id: 콜백 ID
        req: 콜백 업데이트 요청
        db: 데이터베이스 세션

    Returns:
        업데이트된 콜백 정보

    Raises:
        HTTPException: 콜백을 찾을 수 없거나 path가 중복되거나 챗룸을 찾을 수 없음
    """
    try:
        origin_callback = CallbackRepository.get_callback_by_id(db, callback_id)
        if not origin_callback:
            raise HTTPException(status_code=404, detail="Callback not found")
        
        path = req.path if req.path is not None else origin_callback.path
        method = req.method if req.method is not None else origin_callback.method

        callback_map = get_callback_map()
        if callback_map.get(path) and method in callback_map[path]:
            if origin_callback.path != path or origin_callback.method != method:
                raise ValueError(f"Callback with path '{path}' and method '{method}' already exists")

        # 업데이트할 데이터만 추출
        update_data = {}
        if req.path is not None:
            update_data["path"] = req.path
        if req.method is not None:
            update_data["method"] = req.method
        if req.type is not None:
            update_data["type"] = req.type
        if req.code is not None:
            update_data["code"] = req.code
        if req.status is not None:
            update_data["status"] = req.status
        if req.library is not None:
            update_data["library"] = req.library
        if req.env is not None:
            update_data["env"] = req.env

        callback = CallbackRepository.update_callback(db, callback_id, **update_data)
        _clear_api_caches()

        if not callback:
            raise HTTPException(status_code=404, detail="Callback not found")

        return callback
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))


@router.get("/", response_model=list[CallbackResponse])
async def list_callbacks(
    db: Session = Depends(get_db),
) -> list[CallbackResponse]:
    """
    모든 콜백 조회

    Args:
        db: 데이터베이스 세션

    Returns:
        콜백 리스트
    """
    callbacks = CallbackRepository.get_all_callbacks(db)
    return callbacks


@router.delete("/{callback_id}", response_model=dict)
async def delete_callback(
    callback_id: int,
    db: Session = Depends(get_db),
) -> dict:
    """
    콜백 삭제

    Args:
        callback_id: 콜백 ID
        db: 데이터베이스 세션

    Returns:
        삭제 결과

    Raises:
        HTTPException: 콜백을 찾을 수 없음
    """
    callback = CallbackRepository.get_callback_by_id(db, callback_id)
    if not callback:
        raise HTTPException(status_code=404, detail="Callback not found")
    elif callback.status == "build":
        raise HTTPException(status_code=400, detail="Cannot delete callback while it is building")

    success = CallbackRepository.delete_callback(db, callback_id)

    callback_map = get_callback_map()
    if callback.path in callback_map and callback.method in callback_map[callback.path]:
        del callback_map[callback.path][callback.method]
        if not callback_map[callback.path]:
            del callback_map[callback.path]
        
        _clear_api_caches()

    if not success:
        raise HTTPException(status_code=404, detail="Callback not found")
    return {"message": "Callback deleted successfully"}
