import http from "k6/http";
import { check, sleep } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  stages: [
    { duration: "30s", target: 100 },  // Ramp to 100 VUs
    { duration: "30s", target: 100 },  // Hold 100 VUs
    { duration: "10s", target: 0 },    // Ramp down
  ],
  thresholds: {
    http_req_duration: ["p(95)<200"],
    http_req_failed: ["rate<0.01"],
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
  const initialPayload = {
    user_id: `debug_user_${__VU}_${Date.now()}`,
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

  const headers = {
    "Cookie": `jwt_token=${currentJWT}`,
  };

  // Simple test sequence
  let response = http.get(`${BASE_URL}/api/items`);
  check(response, {
    "items load": (r) => r.status === 200,
  });

  response = http.post(`${BASE_URL}/api/cart/add/0`, null, { headers: headers });
  check(response, {
    "add item": (r) => r.status === 200,
  });
  updateJWTFromResponse(response);

  response = http.post(`${BASE_URL}/api/cart/increase-quantity/0`, null, { headers: headers });
  check(response, {
    "increase quantity": (r) => r.status === 200,
  });
  updateJWTFromResponse(response);

  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== DEBUG 100 VU TEST ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Avg Response: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms

Status: ${metrics.http_req_failed.values.rate < 0.01 ? "✅ PASS" : "❌ ISSUES DETECTED"}
`);

  return { stdout: "" };
}