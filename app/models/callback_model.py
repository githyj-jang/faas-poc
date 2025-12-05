"""
콜백 관련 Pydantic 스키마
"""

from datetime import datetime
from typing import Optional, Dict, Any

from pydantic import BaseModel


class CallbackDeployRequest(BaseModel):
    """콜백 배포 요청"""
    callback_id: int
    status: bool  # True: deploy, False: undeploy
    c_type: str # kube, docker


class CallbackRegisterRequest(BaseModel):
    """콜백 등록 요청"""

    path: str
    method: str  # GET, POST 등
    type: str  # python, node
    code: str
    chat_id: Optional[int] = None  # 연결할 챗룸 ID (선택사항)
    library: Optional[str] = None  # 라이브러리 (requirements.txt 또는 package.json 형식)
    env: Optional[Dict[str, Any]] = None  # 환경변수 (JSON 형식)


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
    library: Optional[str] = None  # 라이브러리
    env: Optional[Dict[str, Any]] = None  # 환경변수


class CallbackResponse(BaseModel):
    """콜백 응답"""

    callback_id: int
    path: str
    method: str
    type: str
    library: Optional[str] = None
    env: Optional[Dict[str, Any]] = None
    status: str
    updated_at: datetime

    class Config:
        from_attributes = True

class CallbackAllResonse(BaseModel):
    callback_id: int
    path: str
    method: str
    type: str
    code: str
    library: Optional[str] = None
    env: Optional[Dict[str, Any]] = None
    status: str
    updated_at: datetime

    class Config:
        from_attributes = True