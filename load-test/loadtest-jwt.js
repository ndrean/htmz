import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  scenarios: {
    jwt_stress: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 2500 },  // Ramp to 2500 VUs (250 VUs/sec)
        { duration: "10s", target: 5000 },  // Ramp to 5000 VUs (250 VUs/sec)
        { duration: "10s", target: 7500 },  // Ramp to 7500 VUs (250 VUs/sec)
        { duration: "10s", target: 10000 }, // Ramp to 10000 VUs (250 VUs/sec)
        { duration: "20s", target: 10000 }, // Hold at 10000 VUs
        { duration: "10s", target: 0 },     // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"], // 95% under 1s
    http_req_failed: ["rate<0.2"],     // Error rate under 20%
  },
};

const SECRET_KEY = "your-super-secret-key-12345";
const BASE_URL = "http://localhost:8080"; // JWT server port

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

  // Helper function to update JWT token from response cookies
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

  // Headers with current JWT as cookie
  const headers = () => ({
    "Cookie": `jwt_token=${currentJWT}`,
    "Content-Type": "application/json",
  });

  // 1. Add item to cart
  let response = http.post(
    `${BASE_URL}/api/cart/add/${randomItemId}`,
    null,
    { headers: headers() }
  );

  check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });

  // Update JWT from response cookie if provided
  updateJWTFromResponse(response);

  // 2. Increase quantity
  response = http.post(
    `${BASE_URL}/api/cart/increase-quantity/${randomItemId}`,
    null,
    { headers: headers() }
  );

  check(response, {
    "increase quantity status 200": (r) => r.status === 200,
    "increase quantity returns number": (r) =>
      r.body && !isNaN(parseInt(r.body)),
  });

  // Update JWT again
  updateJWTFromResponse(response);

  // 3. Decrease quantity
  response = http.post(
    `${BASE_URL}/api/cart/decrease-quantity/${randomItemId}`,
    null,
    { headers: headers() }
  );

  check(response, {
    "decrease quantity status 200": (r) => r.status === 200,
  });

  // Update JWT again
  updateJWTFromResponse(response);

  // 4. Remove from cart
  response = http.del(
    `${BASE_URL}/api/cart/remove/${randomItemId}`,
    null,
    { headers: headers() }
  );

  check(response, {
    "remove from cart status 200": (r) => r.status === 200,
  });

  // Final JWT update
  updateJWTFromResponse(response);

  // Minimal pause for high throughput
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== JWT STATELESS STRESS TEST RESULTS ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

Status: ${
    metrics.http_req_failed.values.rate < 0.2 ? "✅ PASSED" : "❌ FAILED"
  } (error rate ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%)
Performance: ${
    metrics.http_req_duration.values["p(95)"] < 1000 ? "✅ GOOD" : "⚠️  SLOW"
  } (95% < 1000ms)

🎯 JWT BENEFITS:
- No server-side session storage
- Infinite horizontal scalability
- Zero memory growth on server
- Stateless architecture
`);

  return { stdout: "" }; // Suppress default summary
}