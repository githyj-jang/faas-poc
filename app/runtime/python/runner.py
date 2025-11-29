from lambda_function import lambda_handler

def execute_lambda(event, context):
    try:
        result = lambda_handler(event, context)
        return {
            "lambdaStatusCode": 200,
            "body": result
        }
    except Exception as e:
        return {
            "lambdaStatusCode": 500,
            "body": str(e)
        }
