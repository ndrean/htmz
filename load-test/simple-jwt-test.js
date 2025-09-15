import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  scenarios: {
    jwt_performance: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "5s", target: 1000 },   // Ramp to 1000 VUs
        { duration: "10s", target: 1000 },  // Hold at 1000 VUs
        { duration: "5s", target: 0 },      // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"], // 95% under 1s
    http_req_failed: ["rate<0.1"],     // Error rate under 10%
  },
};

const SECRET_KEY = "your-super-secret-key-12345";
const BASE_URL = "http://localhost:8081";

const itemIds = [0, 1, 2, 3, 4, 5, 6, 7];

// JWT Generation Function
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

// Global JWT token for this VU
let currentJWT = null;

export default function () {
  // Generate initial JWT if we don't have one
  if (!currentJWT) {
    const initialPayload = {
      user_id: `user_${__VU}_${Date.now()}`,
      cart: [], // Empty cart
      exp: Math.floor(Date.now() / 1000) + 3600, // 1 hour expiry
    };
    currentJWT = generateJWT(initialPayload);
  }

  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // Helper function to update JWT token from response headers
  function updateJWTFromResponse(response) {
    const newToken = response.headers["X-JWT-Token"] || response.headers["X-Jwt-Token"];
    if (newToken) {
      currentJWT = newToken;
      return true;
    }
    return false;
  }

  // Headers with current JWT
  const headers = {
    "Authorization": `Bearer ${currentJWT}`,
    "Content-Type": "application/json",
  };

  // Just test the add cart operation for simplicity
  let response = http.post(
    `${BASE_URL}/api/cart/add/${randomItemId}`,
    null,
    { headers }
  );

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });

  // Update JWT from response header if provided
  updateJWTFromResponse(response);

  // Minimal pause
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== SIMPLIFIED JWT TEMPLATE PERFORMANCE TEST ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

Status: ${
    metrics.http_req_failed.values.rate < 0.1 ? "✅ PASSED" : "❌ FAILED"
  } (error rate ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%)
Performance: ${
    metrics.http_req_duration.values["p(95)"] < 1000 ? "✅ GOOD" : "⚠️  SLOW"
  } (95% < 1000ms)

🚀 SIMPLIFIED TEMPLATE BENEFITS:
- Direct std.fmt.allocPrint approach
- No complex stack buffer parsing
- Maintainable hardcoded templates
- High performance with simplicity
`);

  return { stdout: "" }; // Suppress default summary
}