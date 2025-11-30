"""
채팅방 관련 Pydantic 스키마
"""

from pydantic import BaseModel
from typing import Optional
from datetime import datetime


class ChatRoomCreateRequest(BaseModel):
    """채팅방 생성 요청"""

    title: str
    callback_id: Optional[int] = None


class ChatRoomUpdateRequest(BaseModel):
    """채팅방 업데이트 요청"""

    title: Optional[str] = None
    callback_id: Optional[int] = None


class ChatRoomResponse(BaseModel):
    """채팅방 응답"""

    chat_id: int
    title: str
    callback_id: Optional[int] = None
    created_at: datetime

    class Config:
        from_attributes = True
