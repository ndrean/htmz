import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  scenarios: {
    jwt_debug: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 10 },   // Ramp to 10 VUs slowly
        { duration: "10s", target: 50 },   // Ramp to 50 VUs
        { duration: "10s", target: 100 },  // Ramp to 100 VUs
        { duration: "20s", target: 100 },  // Hold at 100 VUs
        { duration: "10s", target: 0 },    // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"], // 95% under 1s
    http_req_failed: ["rate<0.05"],     // Error rate under 5%
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

  // Headers with current JWT
  const headers = {
    "Authorization": `Bearer ${currentJWT}`,
    "Content-Type": "application/json",
  };

  // 1. Add item to cart
  let response = http.post(
    `${BASE_URL}/api/cart/add/${randomItemId}`,
    null,
    { headers }
  );

  const addSuccess = check(response, {
    "add to cart status 200": (r) => r.status === 200,
    "add to cart has JWT token": (r) => r.headers["X-Jwt-Token"] !== undefined,
  });

  if (!addSuccess) {
    console.error(`Add cart failed: ${response.status} - ${response.body}`);
    return; // Skip rest if first request fails
  }

  // Update JWT from response header if provided
  const newToken = response.headers["X-Jwt-Token"];
  if (newToken) {
    currentJWT = newToken;
    headers["Authorization"] = `Bearer ${currentJWT}`;
  }

  // 2. Increase quantity
  response = http.post(
    `${BASE_URL}/api/cart/increase-quantity/${randomItemId}`,
    null,
    { headers }
  );

  const increaseSuccess = check(response, {
    "increase quantity status 200": (r) => r.status === 200,
    "increase quantity returns number": (r) =>
      r.body && !isNaN(parseInt(r.body)),
    "increase quantity has JWT token": (r) => r.headers["X-Jwt-Token"] !== undefined,
  });

  if (!increaseSuccess) {
    console.error(`Increase quantity failed: ${response.status} - ${response.body}`);
  }

  // Update JWT again
  const newToken2 = response.headers["X-Jwt-Token"];
  if (newToken2) {
    currentJWT = newToken2;
    headers["Authorization"] = `Bearer ${currentJWT}`;
  }

  // 3. Decrease quantity
  response = http.post(
    `${BASE_URL}/api/cart/decrease-quantity/${randomItemId}`,
    null,
    { headers }
  );

  const decreaseSuccess = check(response, {
    "decrease quantity status 200": (r) => r.status === 200,
    "decrease quantity has JWT token": (r) => r.headers["X-Jwt-Token"] !== undefined,
  });

  if (!decreaseSuccess) {
    console.error(`Decrease quantity failed: ${response.status} - ${response.body}`);
  }

  // Update JWT again
  const newToken3 = response.headers["X-Jwt-Token"];
  if (newToken3) {
    currentJWT = newToken3;
    headers["Authorization"] = `Bearer ${currentJWT}`;
  }

  // 4. Remove from cart
  response = http.del(
    `${BASE_URL}/api/cart/remove/${randomItemId}`,
    null,
    { headers }
  );

  const removeSuccess = check(response, {
    "remove from cart status 200": (r) => r.status === 200,
    "remove from cart has JWT token": (r) => r.headers["X-Jwt-Token"] !== undefined,
  });

  if (!removeSuccess) {
    console.error(`Remove from cart failed: ${response.status} - ${response.body}`);
  }

  // Final JWT update
  const newToken4 = response.headers["X-Jwt-Token"];
  if (newToken4) {
    currentJWT = newToken4;
  }

  // Slightly longer pause for debugging
  sleep(0.2);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== JWT DEBUG TEST RESULTS ===
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
    metrics.http_req_duration.values["p(95)"] < 1000 ? "✅ GOOD" : "⚠️  SLOW"
  } (95% < 1000ms)
`);

  return { stdout: "" }; // Suppress default summary
}