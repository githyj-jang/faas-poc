"""
챗룸 저장소 (Repository)

데이터베이스 작업 추상화
"""

from sqlalchemy.orm import Session
from app.core.models import ChatRoom, CallbackInfo


class ChatRoomRepository:
    """챗룸 저장소"""

    @staticmethod
    def create_chatroom(
        db: Session,
        title: str,
        callback_id: int = None,
    ) -> ChatRoom:
        """
        챗룸 생성

        Args:
            db: 데이터베이스 세션
            title: 챗룸 제목
            callback_id: 연결할 콜백 ID (선택사항)

        Returns:
            생성된 챗룸
        """
        chatroom = ChatRoom(
            title=title,
            callback_id=callback_id,
        )
        db.add(chatroom)
        db.commit()
        db.refresh(chatroom)
        return chatroom

    @staticmethod
    def get_chatroom_by_id(db: Session, chat_id: int) -> ChatRoom:
        """
        ID로 챗룸 조회

        Args:
            db: 데이터베이스 세션
            chat_id: 챗룸 ID

        Returns:
            챗룸 정보
        """
        return db.query(ChatRoom).filter(ChatRoom.chat_id == chat_id).first()

    @staticmethod
    def get_all_chatrooms(db: Session) -> list:
        """
        모든 챗룸 조회

        Args:
            db: 데이터베이스 세션

        Returns:
            챗룸 리스트
        """
        return db.query(ChatRoom).all()

    @staticmethod
    def update_chatroom(
        db: Session,
        chat_id: int,
        **kwargs,
    ) -> ChatRoom:
        """
        챗룸 업데이트

        Args:
            db: 데이터베이스 세션
            chat_id: 챗룸 ID
            **kwargs: 업데이트할 필드

        Returns:
            업데이트된 챗룸
        """
        chatroom = db.query(ChatRoom).filter(ChatRoom.chat_id == chat_id).first()
        if not chatroom:
            return None

        for key, value in kwargs.items():
            if hasattr(chatroom, key):
                setattr(chatroom, key, value)

        db.commit()
        db.refresh(chatroom)
        return chatroom

    @staticmethod
    def delete_chatroom(db: Session, chat_id: int) -> bool:
        """
        챗룸 삭제 (같이 연결된 Callback도 같이 삭제)

        Args:
            db: 데이터베이스 세션
            chat_id: 챗룸 ID

        Returns:
            삭제 성공 여부
        """
        chatroom = db.query(ChatRoom).filter(ChatRoom.chat_id == chat_id).first()
        if not chatroom:
            return False

        # 연결된 콜백이 있으면 함께 삭제
        if chatroom.callback_id:
            callback = db.query(CallbackInfo).filter(
                CallbackInfo.callback_id == chatroom.callback_id
            ).first()
            if callback:
                db.delete(callback)

        # 챗룸 삭제
        db.delete(chatroom)
        db.commit()
        return True


# 기본 인스턴스
chatroom_repo = ChatRoomRepository()
