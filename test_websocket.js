const WebSocket = require('ws');

const ws = new WebSocket('ws://localhost:8881');

ws.on('open', function open() {
  console.log('✅ WebSocket connected');
  ws.send('ping');
});

ws.on('message', function message(data) {
  console.log('📩 Received:', data.toString());
  ws.close();
});

ws.on('close', function close() {
  console.log('❌ WebSocket disconnected');
});

ws.on('error', function error(err) {
  console.log('❌ WebSocket error:', err.message);
});

// Timeout after 5 seconds
setTimeout(() => {
  ws.close();
  console.log('⏰ Test timeout');
  process.exit(0);
}, 5000);