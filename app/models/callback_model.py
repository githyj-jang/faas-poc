from pydantic import BaseModel
from typing import Optional

class CallbackDeployRequest(BaseModel):
    callback_id: Optional[int] = None
    status: Optional[bool] = None

class CallbackDeployResponse(BaseModel):
    status_code: int
    body: str

class CallbackInfo(BaseModel):
    callback_id: int
    path: str
    method: str
    type: str
    code: str
    status: str
    updated_at: str