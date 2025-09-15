import http from "k6/http";
import { check, sleep } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  stages: [
    { duration: "10s", target: 20 },  // Ramp up
    { duration: "30s", target: 50 },  // Peak load
    { duration: "10s", target: 0 },   // Ramp down
  ],
  thresholds: {
    http_req_duration: ["p(95)<200"],  // 95% under 200ms
    http_req_failed: ["rate<0.02"],    // Error rate under 2%
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
  // Generate unique user for each VU
  const initialPayload = {
    user_id: `perf_user_${__VU}_${Date.now()}`,
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

  // Mixed workload simulation
  const scenarios = [
    "browse_items",
    "add_items",
    "modify_cart",
    "view_cart"
  ];

  const scenario = scenarios[Math.floor(Math.random() * scenarios.length)];

  switch (scenario) {
    case "browse_items":
      // Browse items (template rendering test)
      let response = http.get(`${BASE_URL}/api/items`);
      check(response, {
        "items load fast": (r) => r.status === 200 && r.body.includes("Apples"),
      });
      break;

    case "add_items":
      // Add random items (JWT cart operations)
      const itemId = Math.floor(Math.random() * 8);
      response = http.post(`${BASE_URL}/api/cart/add/${itemId}`, null, { headers: headers() });
      check(response, {
        "add item succeeds": (r) => r.status === 200,
      });
      updateJWTFromResponse(response);
      break;

    case "modify_cart":
      // Modify cart quantities (optimized operations)
      const modifyItemId = Math.floor(Math.random() * 8);
      const operation = Math.random() > 0.5 ? "increase" : "decrease";

      response = http.post(`${BASE_URL}/api/cart/${operation}-quantity/${modifyItemId}`, null, { headers: headers() });
      check(response, {
        "cart modification succeeds": (r) => r.status === 200 || r.status === 400, // 400 is OK for non-existent items
      });
      updateJWTFromResponse(response);
      break;

    case "view_cart":
      // View cart (cart HTML generation)
      response = http.get(`${BASE_URL}/api/cart`, { headers: headers() });
      check(response, {
        "cart view succeeds": (r) => r.status === 200,
      });
      break;
  }

  sleep(0.1); // Small pause to simulate user behavior
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== MIXED WORKLOAD PERFORMANCE TEST ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%

Performance Metrics:
- Avg Response: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
- 95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms
- 99th Percentile: ${metrics.http_req_duration.values["p(99)"].toFixed(2)}ms

🚀 WORKLOAD SIMULATION:
- Template rendering (browse items)
- JWT cart operations (add items)
- Optimized quantity updates (modify cart)
- Cart HTML generation (view cart)

Status: ${
    metrics.http_req_failed.values.rate < 0.02 && metrics.http_req_duration.values["p(95)"] < 200
      ? "✅ EXCELLENT PERFORMANCE"
      : "⚠️  PERFORMANCE ISSUES"
  }
`);

  return { stdout: "" };
}