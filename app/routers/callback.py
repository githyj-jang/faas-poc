"""
콜백 등록 라우터

콜백 등록 및 관리 엔드포인트
"""

from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.callback_model import (
    CallbackRegisterRequest,
    CallbackUpdateRequest,
    CallbackResponse,
)
from app.repositories.callback_repo import CallbackRepository

router = APIRouter(prefix="/callbacks", tags=["callbacks"])

@router.post("/", response_model=CallbackResponse)
async def register_callback(
    req: CallbackRegisterRequest,
    db: Session = Depends(get_db),
) -> CallbackResponse:
    """
    새 콜백 등록 (같은 path가 있는지 체크)
    
    chat_id가 제공되면 해당 챗룸과 연결됩니다.

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
        )
        return callback
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))


@router.get("/{callback_id}", response_model=CallbackResponse)
async def get_callback(
    callback_id: int,
    db: Session = Depends(get_db),
) -> CallbackResponse:
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

        callback = CallbackRepository.update_callback(db, callback_id, **update_data)
        if not callback:
            raise HTTPException(status_code=404, detail="Callback not found")
        return callback
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))


@router.get("/path/{path}", response_model=CallbackResponse)
async def get_callback_by_path(
    path: str,
    db: Session = Depends(get_db),
) -> CallbackResponse:
    """
    경로로 콜백 조회

    Args:
        path: 콜백 경로
        db: 데이터베이스 세션

    Returns:
        콜백 정보

    Raises:
        HTTPException: 콜백을 찾을 수 없음
    """
    callback = CallbackRepository.get_callback_by_path(db, path)
    if not callback:
        raise HTTPException(status_code=404, detail="Callback not found")
    return callback


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
    success = CallbackRepository.delete_callback(db, callback_id)
    if not success:
        raise HTTPException(status_code=404, detail="Callback not found")
    return {"message": "Callback deleted successfully"}
