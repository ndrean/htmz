import http from "k6/http";
import { check, sleep } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  stages: [
    { duration: "10s", target: 5000 },   // Ramp to 5000 VUs in 10s
    { duration: "10s", target: 10000 },  // Ramp to 10000 VUs in 10s
    { duration: "30s", target: 15000 },  // Ramp to 15000 VUs and hold for 30s
    { duration: "10s", target: 0 },      // Ramp down
  ],
  thresholds: {
    http_req_duration: ["p(95)<500"],    // 95% under 500ms (extreme load)
    http_req_failed: ["rate<0.05"],      // Error rate under 5%
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
  // Generate unique user for extreme load test
  const initialPayload = {
    user_id: `extreme_user_${__VU}_${__ITER}`,
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

  // Extreme load test scenarios
  const scenarios = [
    "quick_browse",
    "cart_operations",
    "quantity_changes"
  ];

  const scenario = scenarios[Math.floor(Math.random() * scenarios.length)];

  switch (scenario) {
    case "quick_browse":
      // Fast browsing test
      let response = http.get(`${BASE_URL}/api/items`);
      check(response, {
        "browse items succeeds": (r) => r.status === 200,
      });
      break;

    case "cart_operations":
      // Cart add/remove operations
      const itemId = Math.floor(Math.random() * 8);
      response = http.post(`${BASE_URL}/api/cart/add/${itemId}`, null, { headers: headers() });
      check(response, {
        "cart add succeeds": (r) => r.status === 200,
      });
      updateJWTFromResponse(response);

      // Quick cart view
      response = http.get(`${BASE_URL}/api/cart`, { headers: headers() });
      check(response, {
        "cart view succeeds": (r) => r.status === 200,
      });
      break;

    case "quantity_changes":
      // Optimized quantity operations test
      const modifyItemId = Math.floor(Math.random() * 8);
      const operation = Math.random() > 0.5 ? "increase" : "decrease";

      response = http.post(`${BASE_URL}/api/cart/${operation}-quantity/${modifyItemId}`, null, { headers: headers() });
      check(response, {
        "quantity change succeeds": (r) => r.status === 200 || r.status === 400,
      });
      updateJWTFromResponse(response);
      break;
  }

  // Very small pause for extreme load
  sleep(0.01);
}

export function handleSummary(data) {
  const metrics = data.metrics;
  const totalChecks = data.metrics.checks ? (data.metrics.checks.values.passes + data.metrics.checks.values.fails) : 0;
  const checkRate = totalChecks > 0 ? (data.metrics.checks.values.passes / totalChecks * 100).toFixed(2) : "0.00";

  console.log(`
🔥 === EXTREME LOAD TEST RESULTS ===
Peak Load: ${metrics.vus_max.values.max} concurrent users
Total Operations: ${metrics.http_reqs.values.count}
Operations/sec: ${metrics.http_reqs.values.rate.toFixed(1)} ops/s
Failed Operations: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%

⚡ EXTREME PERFORMANCE METRICS:
- Avg Response: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
- 95th Percentile: ${metrics.http_req_duration.values["p(95)"].toFixed(2)}ms
- 99th Percentile: ${metrics.http_req_duration.values["p(99)"].toFixed(2)}ms
- Check Success: ${checkRate}%

🚀 LOAD PROGRESSION:
- Phase 1: 0 → 5,000 VUs (10s)
- Phase 2: 5,000 → 10,000 VUs (10s)
- Phase 3: 10,000 → 15,000 VUs (30s sustained)
- Phase 4: 15,000 → 0 VUs (10s rampdown)

💥 STRESS TEST SCENARIOS:
- Fast browsing under extreme load
- Cart operations with 15K concurrent users
- Optimized quantity updates at scale
- JWT state management under pressure

Extreme Load Status: ${
    metrics.http_req_failed.values.rate < 0.05 &&
    metrics.http_req_duration.values["p(95)"] < 500 &&
    parseFloat(checkRate) > 90
      ? "🏆 SURVIVED EXTREME LOAD!"
      : "💥 PERFORMANCE DEGRADED UNDER EXTREME LOAD"
  }

${metrics.vus_max.values.max >= 15000 ?
  "🎯 Successfully reached 15,000 concurrent users!" :
  "⚠️  Did not reach target load"}
`);

  return { stdout: "" };
}