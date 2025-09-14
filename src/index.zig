// This file contains the complete HTML template for the HTMX application,
// formatted as a Zig multiline string to use by the backend.

pub const index_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="UTF-8" />
    \\<meta name="viewport" content="width=device-width, initial-scale=1.0" />
    \\<title>HTMX-Z Demo</title>
    \\<script src="https://cdn.tailwindcss.com"></script>
    \\<script src="https://unpkg.com/htmx.org@1.9.10"></script>
    \\<link rel="preconnect" href="https://fonts.googleapis.com" />
    \\<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    \\<link
    \\  href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap" rel="stylesheet"/>
    \\</head>
    \\<body class="bg-gray-50 min-h-screen flex flex-col items-center p-6 font-inter">
    \\<header class="mb-8 text-center">
    \\<h1 class="text-5xl font-extrabold text-blue-600">My Shopping Cart</h1>
    \\<p class="text-md text-gray-500 mt-2">Frontend: <code>HTMX</code> & <code>TailwindCSS</code></p>
    \\<p class="text-md text-gray-500 mt-1">Backend:  <code>Zig</code>, <code>Zap</code>, <code>sqlite.zig</code> and <code>zexplorer</code></p>
    \\</header>
    \\<main class="w-full max-w-6xl p-8 bg-white rounded-2xl shadow-xl">
    \\<!-- Navigation -->
    \\<nav class="flex justify-center mb-8 bg-gray-100 rounded-lg p-3 shadow-inner">
    \\<a class="px-6 py-3 font-semibold text-blue-600 rounded-lg transition-colors duration-200 hover:bg-blue-100 mr-4"
    \\          hx-get="/groceries"
    \\          hx-target="#content"
    \\          hx-push-url="true"
    \\          hx-trigger="click"
    \\          >Grocery List</a>
    \\<a class="px-6 py-3 font-semibold text-blue-600 rounded-lg transition-colors duration-200 hover:bg-blue-100"
    \\          hx-get="/shopping-list"
    \\          hx-target="#content"
    \\          hx-push-url="true"
    \\          hx-trigger="click"
    \\          >Shopping List</a>
    \\</nav>
    \\<!-- Main content area will be loaded here -->
    \\<div id="content" class="min-h-[500px] p-6 bg-gray-50 rounded-lg shadow-inner">
    \\<!-- Default content loads on initial page load -->
    \\<div class="flex items-center justify-center h-full text-center text-gray-500">
    \\<p class="text-2xl font-semibold">Select an option from the navigation menu to get started.</p>
    \\</div>
    \\</div>
    \\</main>
    \\<!-- The HTMX content for the grocery list and item details card. -->
    \\<!-- This would normally be returned by the '/groceries' backend endpoint. -->
    \\<template id="groceries-page-template">
    \\<div class="flex flex-col md:flex-row gap-8 p-4">
    \\<!-- Grocery Items List -->
    \\<div class="md:w-1/2">
    \\<h2 class="text-3xl font-bold text-gray-800 mb-6">Grocery Items</h2>
    \\<div class="space-y-4 max-h-[400px] overflow-y-auto pr-2"
    \\            hx-get="/api/items"
    \\            hx-trigger="load, every 60s"
    \\            hx-target="this"
    \\            hx-swap="innerHTML">
    \\<!-- HTMX will load the list of available items here -->
    \\<p class="text-gray-500">Loading items...</p>
    \\</div>
    \\</div>
    \\<!-- Item Details Card -->
    \\<div id="item-details-card"
    \\          class="md:w-1/2 bg-gray-100 rounded-xl p-6 shadow-lg min-h-[300px] flex items-center justify-center transition-all duration-300"
    \\          hx-get="/item-details/default"
    \\          hx-trigger="load"
    \\          hx-target="this"
    \\          hx-swap="innerHTML">
    \\<!-- HTMX will load item details here when an item is clicked -->
    \\</div>
    \\</div>
    \\</template>
    \\<!-- The HTMX content for the dedicated shopping list page. -->
    \\<!-- This would be returned by the '/shopping-list' backend endpoint. -->
    \\<template id="shopping-list-template">
    \\<div class="flex flex-col items-center">
    \\<h2 class="text-3xl font-bold text-gray-800 mb-6">Shopping List</h2>
    \\<div id="cart-content"
    \\          class="w-full max-w-xl bg-white rounded-lg p-6 shadow-md max-h-[500px] overflow-y-auto"
    \\          hx-get="/api/cart"
    \\          hx-trigger="load, every 30s"
    \\          hx-target="this"
    \\          hx-swap="innerHTML">
    \\<!-- HTMX will populate this area with the cart items -->
    \\<p class="text-gray-600 text-center">Your cart is empty.</p>
    \\</div>
    \\</div>
    \\</template>
    \\<!-- The HTMX template for a single grocery item in the list. -->
    \\<!-- Your backend should loop through your data and use this template. -->
    \\<template id="grocery-item-template">
    \\<div class="bg-white rounded-lg p-4 shadow-md flex justify-between items-center transition-transform transform hover:scale-[1.02] cursor-pointer"
    \\        hx-get="/api/item-details/{id}"
    \\        hx-target="#item-details-card"
    \\        hx-swap="innerHTML">
    \\<div>
    \\<span class="text-lg font-semibold text-gray-900">{name}</span>
    \\<span class="text-sm text-gray-500 ml-2">${price}</span>
    \\</div>
    \\<button class="px-4 py-2 bg-blue-500 text-white text-sm font-medium rounded-full hover:bg-blue-600 transition-colors"
    \\    hx-post="/api/cart/add/{id}"
    \\    hx-swap="none">Add to Cart</button>
    \\</div>
    \\</template>
    \\<!-- Template for default item details state -->
    \\<template id="item-details-default-template">
    \\<div class="text-center text-gray-500">
    \\<h3 class="text-xl font-semibold mb-4">Select an item</h3>
    \\<p class="text-gray-400">Click on a grocery item to view its details here.</p>
    \\</div>
    \\</template>
    \\<!-- Template for detailed item view -->
    \\<template id="item-details-template">
    \\<div class="text-center">
    \\<h3 class="text-2xl font-bold text-gray-800 mb-4">{name}</h3>
    \\<!-- Placeholder for future image/icon -->
    \\<div class="w-24 h-24 bg-gray-200 rounded-full mx-auto mb-4 flex items-center justify-center">
    \\<svg class="w-12 h-12 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
    \\<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 11V7a4 4 0 00-8 0v4M5 9h14l1 12H4L5 9z"></path>
    \\</svg>
    \\</div>
    \\<div class="bg-blue-50 rounded-lg p-6 mb-6">
    \\<p class="text-3xl font-bold text-blue-600">${price}</p>
    \\<p class="text-gray-600 mt-2">per unit</p>
    \\</div>
    \\<div class="space-y-3">
    \\<button class="w-full bg-blue-600 text-white py-3 px-6 rounded-lg hover:bg-blue-700 transition-colors font-semibold"
    \\        hx-post="/api/cart/add/{id}"
    \\        hx-swap="none">
    \\Add to Cart
    \\</button>
    \\<button class="w-full border border-gray-300 text-gray-700 py-2 px-6 rounded-lg hover:bg-gray-50 transition-colors"
    \\        onclick="alert('More details coming soon!')">
    \\More Details
    \\</button>
    \\</div>
    \\</div>
    \\</template>
    \\<!-- Template for shopping cart items -->
    \\<template id="cart-item-template">
    \\<div class="bg-white rounded-lg p-4 shadow-sm border border-gray-200 flex items-center justify-between">
    \\<div class="flex-1">
    \\<h4 class="text-lg font-semibold text-gray-800">{}</h4>
    \\<p class="text-sm text-gray-500">${} each</p>
    \\</div>
    \\<div class="flex items-center gap-3">
    \\<div class="flex items-center border border-gray-300 rounded-lg">
    \\<button class="px-3 py-1 text-gray-600 hover:bg-gray-100 transition-colors"
    \\        hx-post="/api/cart/decrease-quantity/{}"
    \\        hx-target="#quantity-{}"
    \\        hx-swap="innerHTML">-</button>
    \\<span id="quantity-{}" class="px-3 py-1 bg-gray-50 text-gray-800 font-medium min-w-[2rem] text-center">{}</span>
    \\<button class="px-3 py-1 text-gray-600 hover:bg-gray-100 transition-colors"
    \\        hx-post="/api/cart/increase-quantity/{}"
    \\        hx-target="#quantity-{}"
    \\        hx-swap="innerHTML">+</button>
    \\</div>
    \\<button class="px-3 py-2 bg-red-500 text-white text-sm rounded-lg hover:bg-red-600 transition-colors"
    \\        hx-delete="/api/cart/remove/{}"
    \\        hx-target="#cart-content"
    \\        hx-swap="innerHTML">Remove</button>
    \\</div>
    \\</div>
    \\</template>
    \\<footer class="mt-8 text-gray-500 text-sm text-center">&copy; 2025 HTMX-Z</footer>
    \\</body>
    \\</html>
;
