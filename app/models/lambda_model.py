from enum import Enum

class LambdaStatusCode(Enum):
    SUCCESS = 200
    JSON_PARSE_ERROR = 400
    LAMBDA_ERROR = 500
    TIMEOUT = 504