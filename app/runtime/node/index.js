const { execute_lambda } = require("./runner");  // runner.js에서 execute_lambda 가져오기
const SESSION_ID = process.env.SESSION_ID;
const EVENT = process.env.EVENT;

(async () => {
    try {
        const eventObj = EVENT ? JSON.parse(EVENT) : {};

        await execute_lambda(eventObj, {});
    } catch (err) {
        console.log(JSON.stringify({
            lambdaStatusCode: 500,
            body: err?.message || String(err)
        }));

        process.exit(1);
    }
})();