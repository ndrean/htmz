import http from "k6/http";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";

export const options = {
  scenarios: {
    jwt_simple: {
      executor: "constant-vus",
      vus: 1,
      duration: "5s",
    },
  },
};

const SECRET_KEY = "your-super-secret-key-12345";
const BASE_URL = "http://localhost:8081";

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

let currentJWT = null;

export default function () {
  // Generate initial JWT if we don't have one
  if (!currentJWT) {
    const initialPayload = {
      user_id: `user_${Date.now()}`,
      cart: [], // Empty cart
      exp: Math.floor(Date.now() / 1000) + 3600, // 1 hour expiry
    };
    currentJWT = generateJWT(initialPayload);
    console.log("Generated JWT for test");
  }

  const headers = {
    "Authorization": `Bearer ${currentJWT}`,
    "Content-Type": "application/json",
  };

  console.log("=== STARTING JWT TEST ===");

  // 1. Add item to cart
  console.log("1. Adding item ID 0 to cart...");
  let response = http.post(`${BASE_URL}/api/cart/add/0`, null, { headers });
  console.log(`Add result: status=${response.status}, body='${response.body}'`);

  const addSuccess = check(response, {
    "add to cart status 200": (r) => r.status === 200,
    "add to cart returns HTML": (r) => r.body && r.body.includes("cart"),
  });

  if (addSuccess) {
    // Update JWT from response header
    const newToken = response.headers["X-Jwt-Token"];
    if (newToken) {
      currentJWT = newToken;
      headers["Authorization"] = `Bearer ${currentJWT}`;
      console.log("JWT updated from server");
    }

    // 2. Try to increase quantity
    console.log("2. Increasing quantity for item ID 0...");
    response = http.post(`${BASE_URL}/api/cart/increase-quantity/0`, null, { headers });
    console.log(`Increase result: status=${response.status}, body='${response.body}'`);

    check(response, {
      "increase quantity status 200": (r) => r.status === 200,
    });
  }

  console.log("=== JWT TEST COMPLETE ===");
}