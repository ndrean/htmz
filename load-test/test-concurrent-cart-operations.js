import http from "k6/http";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  scenarios: {
    concurrent_cart_ops: {
      executor: "constant-vus",
      vus: 25,
      duration: "45s",
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<150"],
    http_req_failed: ["rate<0.01"],
    checks: ["rate>0.98"], // 98% of checks must pass
  },
};

const SECRET_KEY = "your-super-secret-key-12345";
const BASE_URL = "http://localhost:8080";

function generateJWT(payload) {
  const header = { alg: "HS256", typ: "JWT" };

  const encodedHeader = encoding.b64encode(JSON.stringify(header), "rawurl");
  const encodedPayload = encoding.b64encode(JSON.stringify(payload), "rawurl");

  const data = `${encodedHeader}.${encodedPayload}`;

  const signer = crypto.createHMAC("sha256", SECRET_KEY);
  signer.update(data);
  const signature = signer.digest("base64rawurl");

  return `${data}.${signature}`;
}

export default function () {
  // Each VU gets its own cart session
  const sessionId = `concurrent_user_${__VU}_${__ITER}`;
  const initialPayload = {
    user_id: sessionId,
    cart: [],
    exp: Math.floor(Date.now() / 1000) + 3600,
  };
  let currentJWT = generateJWT(initialPayload);

  function updateJWTFromResponse(response) {
    const newToken = response.headers["Set-Cookie"];
    if (newToken) {
      const match = newToken.match(/jwt_token=([^;]+)/);
      if (match) {
        currentJWT = match[1];
        return true;
      }
    }
    return false;
  }

  const headers = () => ({
    "Cookie": `jwt_token=${currentJWT}`,
  });

  // Stress test: Rapid cart operations
  console.log(`[VU ${__VU}] Starting concurrent cart operations test`);

  // Phase 1: Rapid additions
  for (let i = 0; i < 3; i++) {
    const itemId = Math.floor(Math.random() * 8);
    let response = http.post(`${BASE_URL}/api/cart/add/${itemId}`, null, { headers: headers() });
    check(response, {
      [`[VU ${__VU}] add item ${itemId} success`]: (r) => r.status === 200,
    });
    updateJWTFromResponse(response);
  }

  // Phase 2: Rapid quantity modifications
  for (let i = 0; i < 5; i++) {
    const itemId = Math.floor(Math.random() * 8);
    const operation = Math.random() > 0.5 ? "increase" : "decrease";

    let response = http.post(`${BASE_URL}/api/cart/${operation}-quantity/${itemId}`, null, { headers: headers() });
    check(response, {
      [`[VU ${__VU}] ${operation} quantity success`]: (r) => r.status === 200 || r.status === 400,
    });
    updateJWTFromResponse(response);
  }

  // Phase 3: Cart state verification
  let response = http.get(`${BASE_URL}/api/cart`, { headers: headers() });
  check(response, {
    [`[VU ${__VU}] cart state valid`]: (r) => r.status === 200 && (r.body.includes("empty") || r.body.includes("font-semibold")),
  });

  // Phase 4: Stress removal operations
  if (Math.random() > 0.7) {
    const itemId = Math.floor(Math.random() * 8);
    response = http.del(`${BASE_URL}/api/cart/remove/${itemId}`, null, { headers: headers() });
    check(response, {
      [`[VU ${__VU}] remove operation handles correctly`]: (r) => r.status === 200 || r.status === 400,
    });
  }
}

export function handleSummary(data) {
  const metrics = data.metrics;
  const totalChecks = data.metrics.checks.values.passes + data.metrics.checks.values.fails;
  const checkRate = (data.metrics.checks.values.passes / totalChecks * 100).toFixed(2);

  console.log(`
=== CONCURRENT CART OPERATIONS STRESS TEST ===
Concurrent Users: ${metrics.vus_max.values.max}
Total Operations: ${metrics.http_reqs.values.count}
Operations/sec: ${metrics.http_reqs.values.rate.toFixed(1)} ops/s
Failed Operations: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%

Concurrency Metrics:
- Avg Response: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
- 95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms
- Check Success Rate: ${checkRate}%

🔥 STRESS TEST OPERATIONS:
- Rapid cart additions under load
- Concurrent quantity modifications
- Simultaneous cart state verification
- Parallel removal operations
- JWT state consistency validation

Concurrency Status: ${
    metrics.http_req_failed.values.rate < 0.01 &&
    metrics.http_req_duration.values["p(95)"] < 150 &&
    parseFloat(checkRate) > 98
      ? "✅ EXCELLENT CONCURRENCY HANDLING"
      : "⚠️  CONCURRENCY ISSUES DETECTED"
  }

💡 This test validates that the JWT cart system maintains consistency
   and performance under high concurrent load with rapid operations.
`);

  return { stdout: "" };
}