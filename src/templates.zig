//! This file contains HTML templates and response constants used in the web application.
pub const grocery_item_template =
    \\<div class="bg-white rounded-lg p-4 shadow-md flex justify-between items-center transition-transform transform hover:scale-[1.02] cursor-pointer" hx-get="/api/item-details/{d}" hx-target="#item-details-card" hx-swap="innerHTML"><div><span class="text-lg font-semibold text-gray-900">{s}</span><span class="text-sm text-gray-500 ml-2">${d:.2}</span></div><button class="px-4 py-2 bg-blue-500 text-white text-sm font-medium rounded-full hover:bg-blue-600 transition-colors" hx-post="/api/cart/add/{d}" hx-swap="none">Add to Cart</button></div>
;

pub const cart_item_template =
    \\<div class="flex justify-between items-center p-4 border-b"><div><span class="font-semibold">{s}</span><br><span class="text-sm text-gray-500">${d:.2}</span></div><div class="flex items-center space-x-2"><button class="px-2 py-1 bg-red-500 text-white rounded" hx-post="/api/cart/decrease-quantity/{d}" hx-target="#qty-{d}" hx-swap="innerHTML">-</button><span id="qty-{d}" class="px-3 py-1 bg-gray-100 rounded">{d}</span><button class="px-2 py-1 bg-green-500 text-white rounded" hx-post="/api/cart/increase-quantity/{d}" hx-target="#qty-{d}" hx-swap="innerHTML">+</button><button class="px-2 py-1 bg-red-600 text-white rounded ml-2" hx-delete="/api/cart/remove/{d}" hx-target="#cart-content" hx-swap="innerHTML">Remove</button></div></div>
;

pub const item_details_template =
    \\<div class="text-center"><h3 class="text-2xl font-bold text-gray-800 mb-4">{s}</h3><div class="w-24 h-24 bg-gray-200 rounded-full mx-auto mb-4 flex items-center justify-center"><svg class="w-12 h-12 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 11V7a4 4 0 00-8 0v4M5 9h14l1 12H4L5 9z"></path></svg></div><div class="bg-blue-50 rounded-lg p-6 mb-6"><p class="text-3xl font-bold text-blue-600">${d:.2}</p><p class="text-gray-600 mt-2">per unit</p></div><button class="w-full bg-blue-600 text-white py-3 px-6 rounded-lg hover:bg-blue-700 transition-colors font-semibold" hx-post="/api/cart/add/{d}" hx-swap="none">Add to Cart</button></div>
;

// HTML response constants
pub const groceries_page_html =
    \\<div class="flex flex-col md:flex-row gap-8 p-4"><div class="md:w-1/2"><h2 class="text-3xl font-bold text-gray-800 mb-6">Grocery Items</h2><div class="space-y-4 max-h-[400px] overflow-y-auto pr-2" hx-get="/api/items" hx-trigger="load, every 60s" hx-target="this" hx-swap="innerHTML"><p class="text-gray-500">Loading items...</p></div></div><div id="item-details-card" class="md:w-1/2 bg-gray-100 rounded-xl p-6 shadow-lg min-h-[300px] flex items-center justify-center transition-all duration-300" hx-get="/item-details/default" hx-trigger="load" hx-target="this" hx-swap="innerHTML"></div></div>
;

pub const shopping_list_page_html =
    \\<div class="flex flex-col items-center"><h2 class="text-3xl font-bold text-gray-800 mb-6">Shopping List</h2><div id="cart-content" class="w-full max-w-xl bg-white rounded-lg p-6 shadow-md max-h-[500px] overflow-y-auto" hx-get="/api/cart" hx-trigger="load, every 30s" hx-target="this" hx-swap="innerHTML"><p class="text-gray-600 text-center">Your cart is empty.</p></div></div>
;

pub const item_details_default_html =
    \\<div class="text-center text-gray-500"><h3 class="text-xl font-semibold mb-4">Select an item</h3><p class="text-gray-400">Click on a grocery item to view its details here.</p></div>
;
