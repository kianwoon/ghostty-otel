#!/usr/bin/env node

var command = (process.argv[2] || 'install').toLowerCase();

if (command === 'status') {
  require('./status.js');
} else if (command === 'install') {
  require('./install.js');
} else {
  console.log('ghostty-otel — Real-time Claude Code visibility for Ghostty\n');
  console.log('Usage: npx @kianwoon/ghostty-otel [command]\n');
  console.log('Commands:');
  console.log('  install   Install the plugin (default)');
  console.log('  status    Check plugin health and status');
  console.log('\nOptions:');
  console.log('  -h, --help   Show this help');
  process.exit(0);
}
