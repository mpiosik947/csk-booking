// Explicit Node test harness only. Do not import this module from application code.
// Unlike --conditions=react-server this preserves React DOM's normal SSR test runtime.
import { registerHooks } from 'node:module';
registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier === 'server-only') return { url: 'data:text/javascript,export {};', shortCircuit: true };
  return nextResolve(specifier, context);
} });
