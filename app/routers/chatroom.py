from fastapi import APIRouter, HTTPException, Depends
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.models.chatroom_model import (
    ChatRoomCreateRequest,
    ChatRoomUpdateRequest,
    ChatRoomResponse,
)
from app.repositories.chatroom_repo import ChatRoomRepository

router = APIRouter(prefix="/chatroom", tags=["chatroom"])

@router.post("/", response_model=ChatRoomResponse)
async def create_chatroom(
    req: ChatRoomCreateRequest,
    db: Session = Depends(get_db),
) -> ChatRoomResponse:
    chatroom = ChatRoomRepository.create_chatroom(
        db=db,
        title=req.title,
        callback_id=req.callback_id,
    )
    return chatroom


@router.get("/{chat_id}", response_model=ChatRoomResponse)
async def get_chatroom(
    chat_id: int,
    db: Session = Depends(get_db),
) -> ChatRoomResponse:
    chatroom = ChatRoomRepository.get_chatroom_by_id(db, chat_id)
    if not chatroom:
        raise HTTPException(status_code=404, detail="Chatroom not found")
    return chatroom


@router.get("/", response_model=list[ChatRoomResponse])
async def list_chatrooms(
    db: Session = Depends(get_db),
) -> list[ChatRoomResponse]:
    chatrooms = ChatRoomRepository.get_all_chatrooms(db)
    return chatrooms


@router.put("/{chat_id}", response_model=ChatRoomResponse)
async def update_chatroom(
    chat_id: int,
    req: ChatRoomUpdateRequest,
    db: Session = Depends(get_db),
) -> ChatRoomResponse:
    update_data = {}
    if req.title is not None:
        update_data["title"] = req.title
    if req.callback_id is not None:
        update_data["callback_id"] = req.callback_id

    chatroom = ChatRoomRepository.update_chatroom(db, chat_id, **update_data)
    if not chatroom:
        raise HTTPException(status_code=404, detail="Chatroom not found")
    return chatroom


@router.delete("/{chat_id}", response_model=dict)
async def delete_chatroom(
    chat_id: int,
    db: Session = Depends(get_db),
) -> dict:
    """
    챗룸 삭제 (같이 연결된 Callback도 같이 삭제)

    Args:
        chat_id: 챗룸 ID
        db: 데이터베이스 세션

    Returns:
        삭제 결과

    Raises:
        HTTPException: 챗룸을 찾을 수 없음
    """
    success = ChatRoomRepository.delete_chatroom(db, chat_id)
    if not success:
        raise HTTPException(status_code=404, detail="Chatroom not found")
    return {"message": "Chatroom and associated callback deleted successfully"}
