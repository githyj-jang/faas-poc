from fastapi import FastAPI

from app.core.database import init_db
from app.routers import api, deploy, callback, chatroom
from fastapi.middleware.cors import CORSMiddleware

def create_app() -> FastAPI:
    """
    FastAPI 애플리케이션 생성 및 초기화

    Returns:
        초기화된 FastAPI 인스턴스
    """
    # 데이터베이스 초기화
    init_db()

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

    @app.get("/health")
    async def health_check() -> dict:
        """헬스 체크 엔드포인트"""
        return {"status": "healthy"}

    return app


app = create_app()

