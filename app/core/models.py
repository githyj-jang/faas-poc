"""
ORM 모델 정의

SQLAlchemy ORM 모델
"""

from sqlalchemy import Column, Integer, String, ForeignKey, DateTime, func, JSON, UniqueConstraint
from sqlalchemy.orm import relationship

from app.core.database import Base


class CallbackInfo(Base):
    """콜백 정보 모델"""

    __tablename__ = "callback_info"

    callback_id = Column(Integer, primary_key=True, index=True)
    path = Column(String, nullable=False, index=True)
    method = Column(String, nullable=False)
    type = Column(String, nullable=False)  # python, node 등
    code = Column(String, nullable=False)
    library = Column(String, nullable=True)  # 라이브러리 (requirements.txt 또는 package.json 형식)
    env = Column(JSON, nullable=True)  # 환경변수 (JSON 형식)
    status = Column(String, default="pending")  # pending, build, deployed, undeployed, failed
    updated_at = Column(DateTime, default=func.now(), onupdate=func.now())

    # path + method 조합으로 unique 제약
    __table_args__ = (
        UniqueConstraint('path', 'method', name='uq_path_method'),
    )

    # 관계
    chatroom = relationship("ChatRoom", back_populates="callback", uselist=False)


class ChatRoom(Base):
    """채팅방 모델"""

    __tablename__ = "chatroom"

    chat_id = Column(Integer, primary_key=True, index=True)
    title = Column(String, nullable=False)
    callback_id = Column(Integer, ForeignKey("callback_info.callback_id"), nullable=True)
    created_at = Column(DateTime, default=func.now())

    # 관계
    callback = relationship("CallbackInfo", back_populates="chatroom")
