import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.database import init_db
from app.core.logger import setup_logger
from app.routers import api, deploy, callback, chatroom

# 애플리케이션 로거 초기화
logger = setup_logger(__name__, level=os.getenv("LOG_LEVEL", "INFO"))


def create_app() -> FastAPI:
    """
    FastAPI 애플리케이션 생성 및 초기화

    Returns:
        초기화된 FastAPI 인스턴스
    """
    logger.info("Initializing FaaS Gateway application")

    # 데이터베이스 초기화
    init_db()
    logger.info("Database initialized successfully")

    app = FastAPI(
        title="FaaS Gateway",
        description="Function as a Service Gateway API",
        version="1.0.0",
    )

    origins = [
        "*"
    ]

    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials=True, 
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # 라우터 등록
    app.include_router(deploy.router)
    app.include_router(api.router)
    app.include_router(callback.router)  # /callbacks 엔드포인트
    app.include_router(chatroom.router)  # /chatroom 엔드포인트
    logger.info("All routers registered successfully")

    @app.get("/health")
    async def health_check() -> dict:
        """헬스 체크 엔드포인트"""
        return {"status": "healthy"}

    logger.info("FaaS Gateway application ready")
    return app


app = create_app()

