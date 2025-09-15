import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";

export const options = {
  scenarios: {
    quick_stress: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "20s", target: 100 },   // Ramp to 100 VUs (5 VUs/sec)
        { duration: "30s", target: 200 },   // Ramp to 200 VUs (3.33 VUs/sec)
        { duration: "30s", target: 400 },   // Ramp to 400 VUs (6.67 VUs/sec)
        { duration: "30s", target: 600 },   // Ramp to 600 VUs (6.67 VUs/sec)
        { duration: "20s", target: 0 },     // Ramp down
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<1000"], // 95% under 1s
    http_req_failed: ["rate<0.2"],     // Error rate under 20%
  },
};

const itemIds = [0, 1, 2, 3, 4, 5, 6, 7];

export default function () {
  const sessionId = `quick-${__VU}-${__ITER}-${Math.random().toString(36).substr(2, 5)}`;
  const headers = { 'X-Session-Id': sessionId };
  const randomItemId = itemIds[Math.floor(Math.random() * itemIds.length)];

  // Single cart operation per iteration for maximum throughput
  const response = http.post(`http://localhost:8080/api/cart/add/${randomItemId}`, null, { headers });

  check(response, {
    "status 200": (r) => r.status === 200,
  });

  // Minimal sleep to allow some server breathing room
  sleep(0.1);
}

export function handleSummary(data) {
  const metrics = data.metrics;

  console.log(`
=== QUICK STRESS TEST RESULTS ===
Peak VUs: ${metrics.vus_max.values.max}
Total Requests: ${metrics.http_reqs.values.count}
Failed Requests: ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%
Requests/sec: ${metrics.http_reqs.values.rate.toFixed(1)} req/s
Avg Response Time: ${metrics.http_req_duration.values.avg.toFixed(2)}ms
95th Percentile: ${metrics.http_req_duration.values['p(95)'].toFixed(2)}ms

Status: ${metrics.http_req_failed.values.rate < 0.2 ? '✅ PASSED' : '❌ FAILED'} (error rate ${(metrics.http_req_failed.values.rate * 100).toFixed(2)}%)
Performance: ${metrics.http_req_duration.values['p(95)'] < 1000 ? '✅ GOOD' : '⚠️  SLOW'} (95% < 1000ms)
`);

  return { stdout: '' }; // Suppress default summary
}