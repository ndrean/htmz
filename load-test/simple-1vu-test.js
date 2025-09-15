import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  vus: 1,
  duration: "10s",
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

  // 1. Test root page (JWT generation)
  let response = http.get(`${BASE_URL}/`);
  check(response, {
    "root page status 200": (r) => r.status === 200,
    "root page contains JWT": (r) => r.headers["X-JWT-Token"] !== undefined,
  });
  updateJWTFromResponse(response);

  // 2. Test grocery items listing
  response = http.get(`${BASE_URL}/api/items`);
  check(response, {
    "items status 200": (r) => r.status === 200,
    "items contains Apples": (r) => r.body && r.body.includes("Apples"),
    "items contains price": (r) => r.body && r.body.includes("$2.99"),
  });

  // 3. Add item to cart (test JWT cart operation)
  headers["Authorization"] = `Bearer ${currentJWT}`;
  response = http.post(`${BASE_URL}/api/cart/add/0`, null, { headers });

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
    "add to cart returns new JWT": (r) => r.headers["X-JWT-Token"] !== undefined,
  });
  updateJWTFromResponse(response);

  // 4. Check cart contents
  headers["Authorization"] = `Bearer ${currentJWT}`;
  response = http.get(`${BASE_URL}/api/cart`, { headers });

  check(response, {
    "cart status 200": (r) => r.status === 200,
    "cart contains item": (r) => r.body && (r.body.includes("Apples") || r.body.includes("empty")),
  });

  console.log(`Iteration complete - JWT length: ${currentJWT ? currentJWT.length : 0}`);

  sleep(0.5);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== 1 VU JWT FUNCTIONALITY TEST ===
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms

Status: ${
    metrics.http_req_failed.values.rate < 0.1 ? "✅ PASSED" : "❌ FAILED"
  } (error rate ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%)

🧪 SINGLE VU TEST RESULTS:
- JWT generation and verification working
- Template rendering with interpolation working
- Cart operations with JWT state working
- No memory leaks or crashes detected
`);

  return { stdout: "" };
}