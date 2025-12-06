import logging
import sys
from typing import Optional


def setup_logger(
    name: Optional[str] = None,
    level: str = "INFO",
    format_string: Optional[str] = None
) -> logging.Logger:
    """
    애플리케이션 로거를 설정합니다.

    Args:
        name: 로거 이름 (__name__ 사용 권장)
        level: 로그 레벨 (DEBUG, INFO, WARNING, ERROR, CRITICAL)
        format_string: 커스텀 포맷 문자열 (선택사항)

    Returns:
        설정된 Logger 인스턴스
    """
    logger = logging.getLogger(name or __name__)

    # 이미 핸들러가 있으면 중복 추가 방지
    if logger.hasHandlers():
        return logger

    logger.setLevel(getattr(logging, level.upper()))

    # 콘솔 핸들러 생성
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setLevel(getattr(logging, level.upper()))

    # 포맷터 설정
    if format_string is None:
        format_string = '%(asctime)s - %(name)s - %(levelname)s - %(message)s'

    formatter = logging.Formatter(
        format_string,
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    console_handler.setFormatter(formatter)

    # 핸들러 추가
    logger.addHandler(console_handler)

    return logger


def get_logger(name: str) -> logging.Logger:
    """
    기존 로거를 가져오거나 새로 생성합니다.

    Args:
        name: 로거 이름

    Returns:
        Logger 인스턴스
    """
    logger = logging.getLogger(name)

    # 로거가 설정되지 않았으면 setup_logger 호출
    if not logger.hasHandlers():
        return setup_logger(name)

    return logger


# 전역 로거 (모듈 레벨에서 바로 사용 가능)
default_logger = setup_logger("faas-poc")
