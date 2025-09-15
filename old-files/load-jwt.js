import http from "k6/http";
import { sleep } from "k6";
import { check } from "k6";
import crypto from "k6/crypto";
import encoding from "k6/encoding";
import { Counter } from "k6/metrics";

// Define a custom metric for tracking successful JWT generations
const jwtGenerations = new Counter("jwt_generations");

// Define your secret key and target URL
// IMPORTANT: Replace with your actual secret key and URL
const SECRET_KEY = "your-super-secret-key-12345";
const PROTECTED_URL = "https://httpbin.org/bearer";
// Example endpoint for adding an item to the cart
const ADD_ITEM_URL = "https://httpbin.org/post";

// Using item IDs instead of names (array indices from grocery_items.zig)
const itemIds = [
  0, // Apples
  1, // Bananas
  2, // Milk
  3, // Bread
  4, // Eggs
  5, // Chicken Breast
  6, // Rice
  7, // Pasta
];

// This function generates a JWT (JSON Web Token) using HS256 algorithm.
// It is self-contained and uses k6's built-in modules.
function generateJwt(payload) {
  // Define the JWT header
  const header = {
    alg: "HS256",
    typ: "JWT",
  };

  // Base64Url encode the header and payload
  const encodedHeader = encoding.b64encode(JSON.stringify(header), "rawurl");
  const encodedPayload = encoding.b64encode(JSON.stringify(payload), "rawurl");

  // Create the data to be signed
  const data = `${encodedHeader}.${encodedPayload}`;

  // Sign the data using HMAC-SHA256 with the secret key
  const signer = crypto.createHMAC("sha256", SECRET_KEY);
  signer.update(data);
  const signature = signer.digest("base64rawurl");

  // Combine all parts to form the final JWT
  const token = `${data}.${signature}`;

  // Increment the custom metric
  jwtGenerations.add(1);

  return token;
}

const shoppingCart = {
  items: [
    { id: 1, name: "Bananas", quantity: 1 },
    { id: 2, name: "Milk", quantity: 1 },
  ],
};

const payload = {
  user_id: `user_${__VU}`,
  cart: shoppingCart, // Include the shopping cart as a JSON object
  exp: Math.floor(Date.now() / 1000) + 60, // Token expires in 60 seconds
};

// 2. Generate the JWT token for this VU.
const token = generateJwt(payload);

// Log the generated token (for debugging purposes, can be commented out)
// console.log(`VU ${__VU} generated token: ${token}`);

// 3. Make the authenticated HTTP request.
const headers = {
  "Content-Type": "application/json",
  Authorization: `Bearer ${token}`,
};
