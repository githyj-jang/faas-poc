"""
데이터베이스 설정 및 ORM 모델

SQLAlchemy를 사용한 SQLite 데이터베이스 관리
"""

from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from pathlib import Path

# 데이터베이스 경로
PROJECT_ROOT = Path(__file__).parent.parent.parent
DB_PATH = PROJECT_ROOT / "database.db"
DATABASE_URL = f"sqlite:///{DB_PATH}"

# SQLAlchemy 엔진 설정
engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False},
    echo=False,
)

# 세션 팩토리
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# Base 모델
Base = declarative_base()


def get_db():
    """
    데이터베이스 세션 생성 제너레이터

    FastAPI 의존성으로 사용됩니다.
    """
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db():
    """
    모든 테이블 생성
    """
    Base.metadata.create_all(bind=engine)
