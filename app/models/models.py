from database import Base
from sqlalchemy import Column, Integer, String, ForeignKey
from sqlalchemy.orm import relationship


class CallbackInfo(Base):
    __tablename__ = "callback_info"

    callback_id = Column(Integer, primary_key=True, index=True)
    path = Column(String)
    method = Column(String)
    type = Column(String)
    code = Column(String)
    status = Column(String)
    updated_at = Column(String)

    # ChatRoom 에 의해 참조됨 (역참조)
    chatrooms = relationship("ChatRoom", back_populates="callback")\

class ChatRoom(Base):
    __tablename__ = "chat_room"

    chat_id = Column(Integer, primary_key=True, index=True)
    title = Column(String)
    callback_id = Column(Integer, ForeignKey("callback_info.callback_id"), nullable=True)

    # FK 연결
    callback = relationship("CallbackInfo", back_populates="chatrooms")