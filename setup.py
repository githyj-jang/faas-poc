"""
프로젝트 시작 가이드 및 유틸리티

데이터베이스 초기화 및 테스트 데이터 로드를 위한 유틸리티를 제공합니다.
"""

from app.scripts.init_db import init_database
from app.scripts.init_test import init_test_data


def setup_database() -> None:
    """
    데이터베이스 초기화 및 테스트 데이터 로드

    다음 순서로 실행됩니다:
    1. 데이터베이스 스키마 생성
    2. 테스트 데이터 삽입
    """
    print("Setting up database...")
    init_database()
    init_test_data()
    print("✓ Database setup completed!")


if __name__ == "__main__":
    setup_database()
