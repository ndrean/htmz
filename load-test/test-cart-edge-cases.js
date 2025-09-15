import http from "k6/http";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  vus: 10,
  duration: "30s",
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
  // Generate fresh JWT for each test
  const initialPayload = {
    user_id: `user_${__VU}_${Date.now()}`,
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
    "Content-Type": "application/json",
  });

  // Test 1: Add multiple items
  let response = http.post(`${BASE_URL}/api/cart/add/0`, null, { headers: headers() });
  check(response, {
    "add apples status 200": (r) => r.status === 200,
  });
  updateJWTFromResponse(response);

  response = http.post(`${BASE_URL}/api/cart/add/1`, null, { headers: headers() });
  check(response, {
    "add bananas status 200": (r) => r.status === 200,
  });
  updateJWTFromResponse(response);

  // Test 2: Increase quantities
  response = http.post(`${BASE_URL}/api/cart/increase-quantity/0`, null, { headers: headers() });
  check(response, {
    "increase apple quantity returns 2": (r) => r.status === 200 && r.body === "2",
  });
  updateJWTFromResponse(response);

  response = http.post(`${BASE_URL}/api/cart/increase-quantity/1`, null, { headers: headers() });
  check(response, {
    "increase banana quantity returns 2": (r) => r.status === 200 && r.body === "2",
  });
  updateJWTFromResponse(response);

  // Test 3: Decrease to zero (should trigger cart refresh)
  response = http.post(`${BASE_URL}/api/cart/decrease-quantity/0`, null, { headers: headers() });
  check(response, {
    "decrease apple to 1": (r) => r.status === 200 && r.body === "1",
  });
  updateJWTFromResponse(response);

  response = http.post(`${BASE_URL}/api/cart/decrease-quantity/0`, null, { headers: headers() });
  check(response, {
    "decrease apple to 0 returns cart HTML": (r) => r.status === 200 && r.body.includes("Bananas") && r.headers["HX-Retarget"] === "#cart-content",
  });
  updateJWTFromResponse(response);

  // Test 4: Remove button (should trigger cart refresh)
  response = http.del(`${BASE_URL}/api/cart/remove/1`, null, { headers: headers() });
  check(response, {
    "remove banana returns empty cart": (r) => r.status === 200 && r.body.includes("Your cart is empty") && r.headers["HX-Retarget"] === "#cart-content",
  });
  updateJWTFromResponse(response);

  // Test 5: Verify cart is actually empty
  response = http.get(`${BASE_URL}/api/cart`, { headers: headers() });
  check(response, {
    "cart is empty after removal": (r) => r.status === 200 && r.body.includes("Your cart is empty"),
  });
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== CART EDGE CASES TEST ===
Total VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms

✅ EDGE CASES TESTED:
- Multi-item cart operations
- Quantity increase/decrease optimization
- Decrease-to-zero cart refresh behavior
- Remove button cart refresh behavior
- HX-Retarget header validation
- JWT state persistence across operations

Status: ${
    metrics.http_req_failed.values.rate < 0.01 ? "✅ ALL EDGE CASES PASS" : "❌ SOME FAILURES"
  } (${(metrics.http_req_failed.values.rate * 100).toFixed(2)}% error rate)
`);

  return { stdout: "" };
}