const { lambda_handler } = require("./lambda_function");

async function execute_lambda(event, context) {
    let response;
    
    try {
        if (typeof lambda_handler !== "function") {
            throw new Error("lambda_handler is not defined properly.");
        }

        const result = await lambda_handler(event, context);

        response = {
            lambdaStatusCode: 200,
            body: result
        };

    } catch (err) {
        response = {
            lambdaStatusCode: 500,
            body: err?.message || String(err)
        };
    }

    console.log(JSON.stringify(response));

    return response;
}

module.exports = { execute_lambda };