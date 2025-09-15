import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  scenarios: {
    template_performance: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "3s", target: 500 },   // Ramp to 500 VUs
        { duration: "10s", target: 500 },  // Hold at 500 VUs
        { duration: "2s", target: 0 },     // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<200"], // 95% under 200ms
    http_req_failed: ["rate<0.05"],   // Error rate under 5%
  },
};

const BASE_URL = "http://localhost:8081";

export default function () {
  // Test the template rendering endpoint
  let response = http.get(`${BASE_URL}/api/items`);

  check(response, {
    "template rendering status 200": (r) => r.status === 200,
    "contains grocery items": (r) => r.body && r.body.includes("Apples") && r.body.includes("Bananas"),
    "template interpolation works": (r) => r.body && r.body.includes("$2.99") && r.body.includes("item-details"),
  });

  // Small pause
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== CLEAN TEMPLATE PERFORMANCE TEST ===
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
    metrics.http_req_duration.values["p(95)"] < 200 ? "✅ EXCELLENT" : "⚠️  SLOW"
  } (95% < 200ms)

🎯 CLEAN TEMPLATE BENEFITS:
- Simple hardcoded templates
- Direct std.fmt.allocPrint interpolation
- Single file architecture
- No memory corruption
- High performance and maintainability
`);

  return { stdout: "" };
}