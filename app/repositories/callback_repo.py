"""
콜백 저장소 (Repository)

데이터베이스 작업 추상화
"""

from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from app.core.models import CallbackInfo, ChatRoom
from datetime import datetime


class CallbackRepository:
    """콜백 저장소"""

    @staticmethod
    def create_callback(
        db: Session,
        path: str,
        method: str,
        type: str,
        code: str,
        chat_id: int = None,
    ) -> CallbackInfo:
        """
        콜백 생성 (같은 path가 있는지 체크)
        
        chat_id가 제공되면 해당 챗룸과 연결됩니다.

        Args:
            db: 데이터베이스 세션
            path: 콜백 경로
            method: HTTP 메서드
            type: 런타임 타입
            code: 콜백 코드
            chat_id: 연결할 챗룸 ID (선택사항)

        Returns:
            생성된 콜백

        Raises:
            ValueError: 중복된 path 또는 챗룸을 찾을 수 없음
        """
        # 같은 path가 있는지 체크
        existing = db.query(CallbackInfo).filter(CallbackInfo.path == path).first()
        if existing:
            raise ValueError(f"Callback with path '{path}' already exists")

        # chat_id가 제공되면 해당 챗룸 존재 여부 확인
        if chat_id is not None:
            chatroom = db.query(ChatRoom).filter(ChatRoom.chat_id == chat_id).first()
            if not chatroom:
                raise ValueError(f"ChatRoom with id '{chat_id}' not found")

        callback = CallbackInfo(
            path=path,
            method=method,
            type=type,
            code=code,
            status="pending",
        )
        db.add(callback)
        db.flush()  # callback_id를 얻기 위해 flush
        
        # chat_id가 제공되면 챗룸의 callback_id 업데이트
        if chat_id is not None:
            chatroom = db.query(ChatRoom).filter(ChatRoom.chat_id == chat_id).first()
            chatroom.callback_id = callback.callback_id

        db.commit()
        db.refresh(callback)
        return callback

    @staticmethod
    def get_callback_by_id(db: Session, callback_id: int) -> CallbackInfo:
        """
        ID로 콜백 조회

        Args:
            db: 데이터베이스 세션
            callback_id: 콜백 ID

        Returns:
            콜백 정보
        """
        return db.query(CallbackInfo).filter(
            CallbackInfo.callback_id == callback_id
        ).first()

    @staticmethod
    def get_callback_by_path(db: Session, path: str) -> CallbackInfo:
        """
        경로로 콜백 조회

        Args:
            db: 데이터베이스 세션
            path: 콜백 경로

        Returns:
            콜백 정보
        """
        return db.query(CallbackInfo).filter(CallbackInfo.path == path).first()

    @staticmethod
    def get_all_callbacks(db: Session) -> list:
        """
        모든 콜백 조회

        Args:
            db: 데이터베이스 세션

        Returns:
            콜백 리스트
        """
        return db.query(CallbackInfo).all()

    @staticmethod
    def update_callback(
        db: Session,
        callback_id: int,
        **kwargs,
    ) -> CallbackInfo:
        """
        콜백 업데이트
        
        path가 변경되는 경우 중복 체크합니다.

        Args:
            db: 데이터베이스 세션
            callback_id: 콜백 ID
            **kwargs: 업데이트할 필드

        Returns:
            업데이트된 콜백

        Raises:
            ValueError: 중복된 path
        """
        callback = db.query(CallbackInfo).filter(
            CallbackInfo.callback_id == callback_id
        ).first()
        if not callback:
            return None

        # path가 변경되는 경우 중복 체크
        if "path" in kwargs and kwargs["path"] != callback.path:
            existing = db.query(CallbackInfo).filter(
                CallbackInfo.path == kwargs["path"]
            ).first()
            if existing:
                raise ValueError(f"Callback with path '{kwargs['path']}' already exists")

        # chat_id가 제공되는 경우 챗룸 존재 여부 확인
        if "chat_id" in kwargs and kwargs["chat_id"] is not None:
            chatroom = db.query(ChatRoom).filter(
                ChatRoom.chat_id == kwargs["chat_id"]
            ).first()
            if not chatroom:
                raise ValueError(f"ChatRoom with id '{kwargs['chat_id']}' not found")

        for key, value in kwargs.items():
            if hasattr(callback, key):
                setattr(callback, key, value)

        callback.updated_at = datetime.now()
        db.commit()
        db.refresh(callback)
        return callback

    @staticmethod
    def delete_callback(db: Session, callback_id: int) -> bool:
        """
        콜백 삭제

        Args:
            db: 데이터베이스 세션
            callback_id: 콜백 ID

        Returns:
            삭제 성공 여부
        """
        callback = db.query(CallbackInfo).filter(
            CallbackInfo.callback_id == callback_id
        ).first()
        if not callback:
            return False

        db.delete(callback)
        db.commit()
        return True


# 기본 인스턴스
callback_repo = CallbackRepository()
