import http from "k6/http";
import { check } from "k6";

export const options = {
  scenarios: {
    constant_load: {
      executor: "constant-vus",
      vus: 1,
      duration: "5s",
    },
  },
};

export default function () {
  const sessionId = "test-session-123";
  const headers = {
    'X-Session-Id': sessionId,
  };

  console.log(`Using session ID: ${sessionId}`);

  // 1. Add item to cart
  console.log("1. Adding item to cart...");
  let response = http.post("http://localhost:8080/api/cart/add/0", null, { headers });
  let success = check(response, {
    "add to cart status 200": (r) => r.status === 200,
  });
  console.log(`Add to cart result: ${response.status} - ${response.body}`);

  // 2. Try to increase quantity (this should work if session is working)
  console.log("2. Increasing quantity...");
  response = http.post("http://localhost:8080/api/cart/increase-quantity/0", null, { headers });
  success = check(response, {
    "increase quantity status 200": (r) => r.status === 200,
  });
  console.log(`Increase quantity result: ${response.status} - ${response.body}`);
}