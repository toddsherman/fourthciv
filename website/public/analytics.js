import { inject } from '/vendor/vercel-analytics.js';

// Local previews should not contribute visits to the public site's analytics.
if (!['localhost', '127.0.0.1', '[::1]'].includes(window.location.hostname)) {
  inject({ mode: 'production' });
}
