"""
콜백 관련 Pydantic 스키마
"""

from pydantic import BaseModel
from typing import Optional
from datetime import datetime

class CallbackDeployRequest(BaseModel):
    """콜백 배포 요청"""
    callback_id: int
    status: bool  # True: deploy, False: undeploy


class CallbackRegisterRequest(BaseModel):
    """콜백 배포 요청"""

    path: str
    method: str  # GET, POST 등
    type: str  # python, node
    code: str
    chat_id: Optional[int] = None  # 연결할 챗룸 ID (선택사항)


class CallbackDeployResponse(BaseModel):
    """콜백 배포 응답"""

    callback_id: int
    path: str
    status: str
    message: str


class CallbackUpdateRequest(BaseModel):
    """콜백 업데이트 요청"""

    path: Optional[str] = None
    method: Optional[str] = None
    type: Optional[str] = None
    code: Optional[str] = None
    status: Optional[str] = None


class CallbackResponse(BaseModel):
    """콜백 응답"""

    callback_id: int
    path: str
    method: str
    type: str
    status: str
    updated_at: datetime

    class Config:
        from_attributes = True