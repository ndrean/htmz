import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import { Counter } from "k6/metrics";

export const options = {
  scenarios: {
    failure_stress: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: 500 },  // Ramp up
        { duration: "60s", target: 500 },  // Sustained failure load
        { duration: "10s", target: 0 },    // Ramp down
      ],
    },
  },
  thresholds: {
    // We EXPECT failures, so set high failure tolerance
    http_req_failed: ["rate<0.95"], // Allow up to 95% failures
  },
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:8080";

// Custom metrics to track failure types
const invalidJwtRequests = new Counter("invalid_jwt_requests");
const malformedRequests = new Counter("malformed_requests");
const timeoutRequests = new Counter("timeout_requests");
const validRequests = new Counter("valid_requests");

const badTokens = [
  "invalid_token_123",
  "expired_token_456",
  "malformed.jwt.token",
  "",
  "null",
  "a".repeat(1000), // Very long token
];

const invalidItemIds = [
  "999999",    // Non-existent item
  "-1",        // Negative ID
  "abc",       // Non-numeric
  "0",         // Zero ID
  "999999999999999999", // Huge number
];

export default function () {
  const scenario = Math.random();

  if (scenario < 0.3) {
    // 30% - Invalid JWT tokens
    testInvalidJWT();
  } else if (scenario < 0.5) {
    // 20% - Malformed requests
    testMalformedRequests();
  } else if (scenario < 0.7) {
    // 20% - Timeout scenarios
    testTimeoutScenarios();
  } else {
    // 30% - Valid requests (to keep some normal load)
    testValidRequests();
  }

  sleep(0.1);
}

function testInvalidJWT() {
  const badToken = badTokens[Math.floor(Math.random() * badTokens.length)];
  const itemId = Math.floor(Math.random() * 7) + 1;

  const response = http.post(
    `${BASE_URL}/api/cart/add/${itemId}`,
    null,
    {
      headers: {
        Cookie: `jwt_token=${badToken}`,
        "Content-Type": "application/json"
      },
      timeout: "5s",
    }
  );

  invalidJwtRequests.add(1);

  check(response, {
    "invalid JWT redirects": (r) => r.status === 302 || r.status === 401,
  });
}

function testMalformedRequests() {
  const invalidId = invalidItemIds[Math.floor(Math.random() * invalidItemIds.length)];
  const endpoints = [
    `/api/cart/add/${invalidId}`,
    `/api/cart/remove/${invalidId}`,
    `/api/cart/increase-quantity/${invalidId}`,
    `/api/item-details/${invalidId}`,
  ];

  const endpoint = endpoints[Math.floor(Math.random() * endpoints.length)];

  const response = http.post(
    `${BASE_URL}${endpoint}`,
    null,
    {
      headers: {
        Cookie: "jwt_token=valid_token_but_malformed_request",
        "Content-Type": "application/json"
      },
      timeout: "5s",
    }
  );

  malformedRequests.add(1);

  check(response, {
    "malformed request handled": (r) => r.status >= 400 && r.status < 500,
  });
}

function testTimeoutScenarios() {
  const itemId = Math.floor(Math.random() * 7) + 1;

  // Very short timeout to force timeouts
  const response = http.post(
    `${BASE_URL}/api/cart/add/${itemId}`,
    null,
    {
      headers: {
        Cookie: "jwt_token=some_token",
        "Content-Type": "application/json"
      },
      timeout: "1ms", // Extremely short timeout
    }
  );

  timeoutRequests.add(1);

  check(response, {
    "timeout handled": (r) => r.status === 0 || r.error !== "",
  });
}

function testValidRequests() {
  // Get a real JWT first
  const homeResponse = http.get(`${BASE_URL}/`, { timeout: "10s" });
  let jwtCookie = null;

  const cookieHeader = homeResponse.headers["Set-Cookie"];
  if (cookieHeader) {
    const match = cookieHeader.match(/jwt_token=([^;]+)/);
    if (match) {
      jwtCookie = match[1];
    }
  }

  if (!jwtCookie) {
    return; // Skip if can't get valid token
  }

  const itemId = Math.floor(Math.random() * 7) + 1;
  const response = http.post(
    `${BASE_URL}/api/cart/add/${itemId}`,
    null,
    {
      headers: {
        Cookie: `jwt_token=${jwtCookie}`,
        "Content-Type": "application/json"
      },
      timeout: "10s",
    }
  );

  validRequests.add(1);

  check(response, {
    "valid request succeeds": (r) => r.status === 200,
  });
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== FAILURE STRESS TEST RESULTS ===
🔥 Failure Scenarios:
  Invalid JWT Requests: ${metrics.invalid_jwt_requests?.values?.count || 0}
  Malformed Requests: ${metrics.malformed_requests?.values?.count || 0}
  Timeout Requests: ${metrics.timeout_requests?.values?.count || 0}
  Valid Requests: ${metrics.valid_requests?.values?.count || 0}

📊 Overall Results:
  Total Requests: ${metrics.http_reqs?.values?.count || 0}
  Failed Requests: ${(metrics.http_req_failed?.values?.rate * 100)?.toFixed(2) || 0}%
  Avg Response Time: ${metrics.http_req_duration?.values?.avg?.toFixed(2) || 0}ms

🧪 Memory Leak Detection:
  Monitor VmRSS before and after this test to detect leaks in error paths.
  Run: cat /proc/$(pgrep htmz)/status | grep VmRSS
`);
}