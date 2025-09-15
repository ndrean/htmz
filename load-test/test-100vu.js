import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  vus: 100,
  duration: "30s",
  thresholds: {
    http_req_duration: ["p(95)<100"], // 95% under 100ms
    http_req_failed: ["rate<0.05"],   // Error rate under 5%
  },
};

const SECRET_KEY = "your-super-secret-key-12345";
const BASE_URL = "http://localhost:8081";

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

let currentJWT = null;

export default function () {
  // Generate initial JWT if we don't have one
  if (!currentJWT) {
    const initialPayload = {
      user_id: `user_${__VU}_${Date.now()}`,
      cart: [],
      exp: Math.floor(Date.now() / 1000) + 3600,
    };
    currentJWT = generateJWT(initialPayload);
  }

  // Helper function to update JWT token from response headers
  function updateJWTFromResponse(response) {
    const newToken = response.headers["X-JWT-Token"] || response.headers["X-Jwt-Token"];
    if (newToken) {
      currentJWT = newToken;
      return true;
    }
    return false;
  }

  const headers = {
    "Authorization": `Bearer ${currentJWT}`,
    "Content-Type": "application/json",
  };

  // Test sequence: items -> add to cart -> check cart

  // 1. Get grocery items (template rendering test)
  let response = http.get(`${BASE_URL}/api/items`);
  check(response, {
    "items status 200": (r) => r.status === 200,
    "items contains data": (r) => r.body && r.body.includes("Apples"),
  });

  // 2. Add item to cart (JWT cart operation test)
  const randomItemId = Math.floor(Math.random() * 8);
  headers["Authorization"] = `Bearer ${currentJWT}`;
  response = http.post(`${BASE_URL}/api/cart/add/${randomItemId}`, null, { headers });

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
    "add returns new JWT": (r) => r.headers["X-JWT-Token"] !== undefined,
  });
  updateJWTFromResponse(response);

  // 3. Check cart contents (JWT verification test)
  headers["Authorization"] = `Bearer ${currentJWT}`;
  response = http.get(`${BASE_URL}/api/cart`, { headers });

  check(response, {
    "cart status 200": (r) => r.status === 200,
  });

  // Small pause to prevent overwhelming
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== 100 VU JWT PERFORMANCE TEST ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

Status: ${
    metrics.http_req_failed.values.rate < 0.05 ? "✅ PASSED" : "❌ FAILED"
  } (error rate ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%)
Performance: ${
    metrics.http_req_duration.values["p(95)"] < 100 ? "✅ EXCELLENT" : "⚠️  SLOW"
  } (95% < 100ms)

🚀 100 VU RESULTS:
- Template rendering: ${metrics.http_reqs.values.count / 3} operations
- JWT cart operations: ${metrics.http_reqs.values.count / 3} operations
- Total throughput: ${metrics.http_reqs.values.rate.toFixed(0)} req/s
- Clean architecture working under load
`);

  return { stdout: "" };
}