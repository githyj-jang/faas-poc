from fastapi import FastAPI

from app.routers import api, deploy


def create_app() -> FastAPI:
    """
    FastAPI 애플리케이션 생성 및 초기화

    Returns:
        초기화된 FastAPI 인스턴스
    """
    app = FastAPI(
        title="FaaS Gateway",
        description="Function as a Service Gateway API",
        version="1.0.0",
    )

    app.include_router(deploy.router)
    app.include_router(api.router)

    @app.get("/health")
    async def health_check() -> dict:
        """헬스 체크 엔드포인트"""
        return {"status": "healthy"}

    return app


app = create_app()
